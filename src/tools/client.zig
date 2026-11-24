const std = @import("std");
const foo = @import("foo");
const builtin_tools = @import("builtin.zig");
const exec = @import("exec.zig");
const files = @import("files.zig");

const Allocator = std.mem.Allocator;
const Context = foo.io.Context;
const Error = foo.io.Error;
const Result = foo.tool.Result;

const Options = struct {
    host: foo.host.Host,
    session: foo.events.SessionId,
    execution: exec.Options,
    file_bytes: usize,
};

pub fn spec(kind: builtin_tools.Kind, host: foo.host.Host, inherit_environment: bool) Error!foo.provider.ToolSpec {
    var tool = builtin_tools.spec(kind);
    tool.description = switch (kind) {
        .read => if (host.capabilities.read_file and host.files != null)
            "Read a text file through the editor. Returns a byte range and the SHA-256 of the editor's complete text."
        else
            return error.Unavailable,
        .write => if (host.capabilities.write_file and host.files != null)
            "Replace a text file through the editor. Returns the size and SHA-256 of the submitted text."
        else
            return error.Unavailable,
        .exec => if (host.capabilities.terminal and host.processes != null and !inherit_environment)
            "Run a program through the editor terminal. Supply the executable and each argument separately. Returns merged terminal output."
        else
            return error.Unavailable,
        .edit => return error.Unavailable,
    };
    return tool;
}

pub fn run(prepared: builtin_tools.Prepared, allocator: Allocator, scratch: Allocator, op: Context, id: []const u8, options: Options) Error!Result {
    const result_id = try allocator.dupe(u8, id);
    errdefer allocator.free(result_id);
    const limit = options.execution.output_bytes;
    op.check() catch |err| return failure(allocator, result_id, limit, err, .not_started);
    switch (prepared) {
        .read => |file| {
            const backend = options.host.files.?;
            const bytes = backend.read_fn(backend.context, scratch, op, options.session, file.path, options.file_bytes) catch |err|
                return failure(allocator, result_id, limit, err, .not_started);
            if (bytes.len > options.file_bytes) return failure(allocator, result_id, limit, error.LimitExceeded, .not_started);
            const payload = files.readClient(allocator, scratch, op, bytes, file.args, limit) catch |err|
                return builtin_tools.fileFailure(allocator, result_id, limit, err);
            return .{ .call_id = result_id, .status = .success, .effect = .observed, .content = payload.content, .truncated = payload.truncated };
        },
        .write => |file| {
            if (!std.unicode.utf8ValidateSlice(file.bytes)) return failure(allocator, result_id, limit, error.InvalidInput, .not_started);
            const content = files.writeResult(allocator, file.bytes, limit) catch |err|
                return builtin_tools.fileFailure(allocator, result_id, limit, err);
            op.check() catch |err| {
                allocator.free(content);
                return failure(allocator, result_id, limit, err, .not_started);
            };
            const backend = options.host.files.?;
            backend.write_fn(backend.context, op, options.session, file.path, file.bytes) catch |err| {
                allocator.free(content);
                return failure(allocator, result_id, limit, err, .uncertain);
            };
            return .{ .call_id = result_id, .status = .success, .effect = .observed, .content = content };
        },
        .exec => |argv| return runTerminal(allocator, scratch, op, result_id, argv, options.host.processes.?, options.execution),
        .edit => unreachable,
    }
}

fn runTerminal(allocator: Allocator, scratch: Allocator, operation: Context, id: []const u8, argv: []const []const u8, backend: foo.host.Processes, options: exec.Options) Error!Result {
    const environment = try scratch.alloc(foo.host.Env, options.environment.len);
    for (options.environment, environment) |source, *entry| entry.* = .{ .name = source.name, .value = source.value };
    var op = operation;
    const deadline = op.clock.now() +| options.timeout_ms;
    op.deadline_ms = @min(op.deadline_ms orelse deadline, deadline);
    const limit = options.output_bytes;
    op.check() catch |err| return failure(allocator, id, limit, err, .not_started);
    const terminal = backend.start_fn(backend.context, op, .{ .argv = argv, .cwd = options.cwd, .environment = environment }) catch |err|
        return failure(allocator, id, limit, err, .uncertain);

    const waited = backend.wait_fn(backend.context, op, terminal);
    const status = waited catch foo.host.CommandStatus.cleanup_unconfirmed;
    const exited = status == .exited or status == .signalled;
    const output_limit = (limit -| 256) / 6;
    const output = if (exited) backend.output_fn(backend.context, scratch, op, terminal, 0, output_limit) else error.Unavailable;
    var token: foo.io.Cancellation = .{};
    const cleanup: Context = .{ .io = op.io, .clock = op.clock, .cancellation = &token, .deadline_ms = op.clock.now() +| options.cleanup_ms };
    // ACP release also kills a terminal whose exit has not been observed.
    const released = if (backend.release_fn(backend.context, cleanup, terminal)) |_| true else |_| false;
    const output_error: ?Error = if (output) |_| null else |err| if (err == error.LimitExceeded) null else err;
    const command_error: ?Error = if (waited) |_| if (exited) output_error else error.IoFailure else |err| err;
    const observed = exited and released;
    const cancelled = if (command_error) |err| err == error.Cancelled or err == error.DeadlineExceeded else false;
    const result_status: foo.tool.Status = if (cancelled)
        .cancelled
    else if (observed and command_error == null and status == .exited and status.exited == 0)
        .success
    else
        .failure;
    const reported = output catch foo.host.CommandOutput{ .bytes = "", .truncated = true };
    const excerpt = reported.bytes[0..@min(reported.bytes.len, output_limit)];
    const text = std.unicode.utf8ValidateSlice(excerpt);
    const base64 = std.base64.standard.Encoder;
    const encoded = if (text) null else base64.encode(try scratch.alloc(u8, base64.calcSize(excerpt.len)), excerpt);
    const content = try std.json.Stringify.valueAlloc(allocator, .{
        .exit_code = if (status == .exited) status.exited else null,
        .signal = if (status == .signalled) status.signalled else null,
        .cleanup_confirmed = released,
        .error_name = if (command_error) |err| @errorName(err) else null,
        .output = if (text) excerpt else null,
        .output_base64 = encoded,
    }, .{});
    const fits = content.len <= limit;
    if (!fits) allocator.free(content);
    return .{
        .call_id = id,
        .status = result_status,
        .effect = if (observed) .observed else .uncertain,
        .content = if (fits) content else try boundedCopy(allocator, "Terminal diagnostics exceeded the output limit", limit),
        .truncated = !fits or reported.truncated or excerpt.len < reported.bytes.len,
    };
}

fn failure(allocator: Allocator, id: []const u8, limit: usize, err: Error, effect: foo.tool.Effect) Error!Result {
    const message = @errorName(err);
    return .{
        .call_id = id,
        .status = if (err == error.Cancelled or err == error.DeadlineExceeded) .cancelled else .failure,
        .effect = effect,
        .content = try boundedCopy(allocator, message, limit),
        .truncated = message.len > limit,
    };
}

fn boundedCopy(allocator: Allocator, message: []const u8, limit: usize) Error![]const u8 {
    return allocator.dupe(u8, message[0..@min(message.len, limit)]);
}
