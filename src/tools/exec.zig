const std = @import("std");
const foo = @import("foo");
const Allocator = std.mem.Allocator;

pub const Args = struct { argv: []const []const u8, input: []const u8 };

pub const Options = struct {
    spawner: foo.io.Spawner,
    cwd: []const u8,
    environment: []const foo.io.Environment = &.{},
    inherit_environment: bool = false,
    timeout_ms: u64 = 30_000,
    cleanup_ms: u64 = 2_000,
    output_bytes: usize = 65_536,
    spool: ?Spool = null,
};

pub const Spool = struct {
    directory: std.Io.Dir,
    max_bytes: u64,
};

const frame_header_bytes = 5;
const report_reserve = 512;
const Stream = enum(u8) { stdout = 1, stderr = 2 };

const Capture = struct {
    bytes: []u8,
    used: usize = 0,
    total: u64 = 0,

    fn drain(self: *Capture, op: foo.io.Context, source: foo.io.ByteSource, stream: Stream, spool: *SpoolFile) foo.io.Error!void {
        var scratch: [8192]u8 = undefined;
        while (true) {
            try op.check();
            const size = try source.read_fn(source.context, op, &scratch);
            if (size == 0) return;
            if (size > scratch.len) return error.IoFailure;
            self.total +|= size;
            const count = @min(self.bytes.len - self.used, size);
            @memcpy(self.bytes[self.used..][0..count], scratch[0..count]);
            self.used += count;
            if (spool.file != null) try spool.append(op, stream, scratch[0..size]);
        }
    }
};

const SpoolFile = struct {
    directory: std.Io.Dir = undefined,
    name: []const u8 = "",
    file: ?std.Io.File = null,
    limit: u64 = 0,
    offset: u64 = 0,
    truncated: bool = false,
    failed: bool = false,
    mutex: std.Io.Mutex = .init,

    fn open(op: foo.io.Context, options: Spool, name: []const u8) foo.io.Error!SpoolFile {
        try op.check();
        const file = options.directory.createFile(op.io, name, .{ .exclusive = true }) catch |err| return switch (err) {
            error.Canceled => error.Cancelled,
            else => error.IoFailure,
        };
        return .{ .directory = options.directory, .name = name, .file = file, .limit = options.max_bytes };
    }

    fn append(self: *SpoolFile, op: foo.io.Context, stream: Stream, bytes: []const u8) foo.io.Error!void {
        self.mutex.lock(op.io) catch return error.Cancelled;
        defer self.mutex.unlock(op.io);
        try op.check();
        if (self.failed) return;
        const room = self.limit - self.offset;
        if (room <= frame_header_bytes) {
            self.truncated = true;
            return;
        }
        const count: usize = @intCast(@min(room - frame_header_bytes, bytes.len));
        self.truncated = self.truncated or count < bytes.len;
        var header: [frame_header_bytes]u8 = undefined;
        header[0] = @backingInt(stream);
        std.mem.writeInt(u32, header[1..5], @intCast(count), .little);
        const file = self.file.?;
        file.writePositionalAll(op.io, &header, self.offset) catch |err| return self.writeFailed(err);
        file.writePositionalAll(op.io, bytes[0..count], self.offset + header.len) catch |err| return self.writeFailed(err);
        self.offset += header.len + count;
    }

    fn writeFailed(self: *SpoolFile, err: std.Io.File.WritePositionalError) foo.io.Error!void {
        self.failed = true;
        if (err == error.Canceled) return error.Cancelled;
    }

    fn close(self: *SpoolFile, op: foo.io.Context, keep: bool) ?foo.tool.Artifact {
        const file = self.file orelse return null;
        if (keep and !self.failed) file.sync(op.io) catch {
            self.failed = true;
        };
        file.close(op.io);
        self.file = null;
        if (keep and !self.failed) return .{ .relative_path = self.name, .bytes = self.offset };
        self.directory.deleteFile(op.io, self.name) catch {};
        return null;
    }
};

const Completion = union(enum) {
    stdin: foo.io.Error!void,
    stdout: foo.io.Error!void,
    stderr: foo.io.Error!void,
    exit: foo.io.Error!foo.io.ProcessExit,
};

const Observation = struct {
    exit: ?foo.io.ProcessExit = null,
    failure: ?foo.io.Error = null,
};

const Mode = enum { tool, command };

fn observe(op: foo.io.Context, cleanup_ms: u64, child: foo.io.Child, input: []const u8, stdout: *Capture, stderr: *Capture, spool: *SpoolFile) Observation {
    var responses: [4]Completion = undefined;
    var tasks: std.Io.Select(Completion) = .init(op.io, &responses);
    var stop_token: foo.io.Cancellation = .{};
    var observation: Observation = .{};
    defer {
        if (observation.failure != null) child.terminate_fn(child.context, cleanupContext(op, &stop_token, cleanup_ms)) catch {};
        tasks.cancelDiscard();
    }

    tasks.concurrent(.stdout, Capture.drain, .{ stdout, op, child.stdout, .stdout, spool }) catch return fail(&observation, error.Unavailable);
    tasks.concurrent(.stderr, Capture.drain, .{ stderr, op, child.stderr, .stderr, spool }) catch return fail(&observation, error.Unavailable);
    tasks.concurrent(.stdin, feed, .{ child, op, input }) catch return fail(&observation, error.Unavailable);
    tasks.concurrent(.exit, wait, .{ child, op }) catch return fail(&observation, error.Unavailable);

    var input_disconnected = false;
    for (0..responses.len) |_| {
        const completion = tasks.await() catch return fail(&observation, error.Cancelled);
        switch (completion) {
            .stdin => |value| value catch |err| {
                if (err != error.Disconnected) return fail(&observation, err);
                input_disconnected = true;
            },
            .stdout, .stderr => |value| value catch |err| return fail(&observation, err),
            .exit => |value| observation.exit = value catch |err| return fail(&observation, err),
        }
    }
    if (input_disconnected) observation.failure = error.Disconnected;
    return observation;
}

fn feed(child: foo.io.Child, op: foo.io.Context, input: []const u8) foo.io.Error!void {
    if (input.len > 0) try child.stdin.write(op, input);
    try child.close_stdin_fn(child.context, op);
}

fn wait(child: foo.io.Child, op: foo.io.Context) foo.io.Error!foo.io.ProcessExit {
    return child.wait_fn(child.context, op);
}

fn cleanupContext(op: foo.io.Context, token: *const foo.io.Cancellation, ms: u64) foo.io.Context {
    return .{
        .io = op.io,
        .clock = op.clock,
        .cancellation = token,
        .deadline_ms = op.clock.now() +| ms,
    };
}

fn fail(observation: *Observation, err: foo.io.Error) Observation {
    observation.failure = err;
    return observation.*;
}

pub fn run(allocator: Allocator, operation: foo.io.Context, call_id: []const u8, args: Args, options: Options) foo.io.Error!foo.tool.Result {
    return execute(allocator, operation, call_id, args, options, .tool);
}

pub fn runCommand(allocator: Allocator, operation: foo.io.Context, call_id: []const u8, argv: []const []const u8, options: Options) foo.io.Error!foo.tool.Result {
    return execute(allocator, operation, call_id, .{ .argv = argv, .input = "" }, options, .command);
}

fn execute(allocator: Allocator, operation: foo.io.Context, call_id: []const u8, args: Args, options: Options, mode: Mode) foo.io.Error!foo.tool.Result {
    const result_id = try allocator.dupe(u8, call_id);
    errdefer allocator.free(result_id);
    operation.check() catch |err| return rejected(allocator, result_id, err, options.output_bytes);
    if (options.output_bytes == 0 or options.timeout_ms == 0 or options.cleanup_ms == 0 or
        args.argv.len == 0 or args.argv[0].len == 0 or options.cwd.len == 0)
        return rejected(allocator, result_id, error.InvalidInput, options.output_bytes);
    for (args.argv) |arg| if (std.mem.indexOfScalar(u8, arg, 0) != null)
        return rejected(allocator, result_id, error.InvalidInput, options.output_bytes);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const diagnostic_bytes = (options.output_bytes -| report_reserve) / 4;
    const stdout_bytes = if (mode == .tool) options.output_bytes else diagnostic_bytes;
    var stdout: Capture = .{ .bytes = try scratch.alloc(u8, stdout_bytes) };
    var stderr: Capture = .{ .bytes = try scratch.alloc(u8, diagnostic_bytes) };

    var op = operation;
    const timeout = op.clock.now() +| options.timeout_ms;
    op.deadline_ms = @min(op.deadline_ms orelse timeout, timeout);
    var spool: SpoolFile = .{};
    var spool_name: ?[]const u8 = null;
    if (options.spool) |limits| {
        if (limits.max_bytes < frame_header_bytes + 1)
            return rejected(allocator, result_id, error.InvalidInput, options.output_bytes);
        var nonce: [16]u8 = undefined;
        op.io.random(&nonce);
        spool_name = try std.fmt.allocPrint(allocator, "exec-{s}.frames", .{std.fmt.bytesToHex(nonce, .lower)});
        spool = SpoolFile.open(op, limits, spool_name.?) catch |err| {
            allocator.free(spool_name.?);
            return rejected(allocator, result_id, err, options.output_bytes);
        };
    }
    var keep_spool_name = false;
    defer if (!keep_spool_name) {
        if (spool_name) |name| allocator.free(name);
    };
    defer if (spool.file != null) {
        _ = spool.close(op, false);
    };
    const fallback = try boundedCopy(allocator, "Process diagnostics unavailable", options.output_bytes);
    var keep_fallback = false;
    defer if (!keep_fallback) allocator.free(fallback);

    const child = options.spawner.spawn_fn(options.spawner.context, scratch, op, .{
        .argv = args.argv,
        .cwd = options.cwd,
        .environment = options.environment,
        .inherit_environment = options.inherit_environment,
    }) catch |err| {
        var result = try rejected(allocator, result_id, err, options.output_bytes);
        switch (err) {
            error.Cancelled, error.DeadlineExceeded, error.IoFailure, error.Disconnected => result.effect = .uncertain,
            else => {},
        }
        return result;
    };

    const observation = observe(op, options.cleanup_ms, child, args.input, &stdout, &stderr, &spool);
    var cleanup_token: foo.io.Cancellation = .{};
    const cleanup = cleanupContext(op, &cleanup_token, options.cleanup_ms);
    const released = if (child.release_fn(child.context, cleanup)) |_| true else |_| false;
    const artifact = spool.close(cleanup, true);
    keep_spool_name = artifact != null;

    const cancelled = if (observation.failure) |failure| failure == error.Cancelled else false;
    const success = if (observation.exit) |status| switch (status) {
        .exited => |code| code == 0,
        .signalled => false,
    } else false;
    const truncated = stdout.total > stdout.used or stderr.total > stderr.used or spool.truncated or spool.failed;
    const observed = released and observation.failure == null;
    const process_ok = observed and success and !spool.failed;
    const Reply = struct { content: []const u8, is_error: bool = false };
    if (mode == .tool and process_ok and stdout.total == stdout.used and std.unicode.utf8ValidateSlice(stdout.bytes[0..stdout.used])) {
        if (std.json.parseFromSlice(Reply, scratch, stdout.bytes[0..stdout.used], .{})) |reply| {
            const content = allocator.dupe(u8, reply.value.content) catch {
                keep_fallback = true;
                return .{
                    .call_id = result_id,
                    .status = .failure,
                    .effect = .observed,
                    .content = fallback,
                    .artifact = artifact,
                    .truncated = true,
                };
            };
            return .{
                .call_id = result_id,
                .status = if (reply.value.is_error) .failure else .success,
                .effect = .observed,
                .content = content,
                .truncated = truncated,
                .artifact = artifact,
            };
        } else |_| {}
    }
    const exited = observation.exit != null and observation.exit.? == .exited;
    const signalled = observation.exit != null and observation.exit.? == .signalled;
    const stdout_excerpt = if (mode == .command) stdout.bytes[0..stdout.used] else "";
    const stderr_excerpt = stderr.bytes[0..stderr.used];
    const stdout_text = isText(stdout_excerpt);
    const stderr_text = isText(stderr_excerpt);
    var result: foo.tool.Result = .{
        .call_id = result_id,
        .status = if (cancelled) .cancelled else if (mode == .command and process_ok) .success else .failure,
        .effect = if (observed) .observed else .uncertain,
        .content = fallback,
        .truncated = true,
        .artifact = artifact,
    };
    const encoded = std.json.Stringify.valueAlloc(allocator, .{
        .exit_code = if (exited) observation.exit.?.exited else null,
        .signal = if (signalled) observation.exit.?.signalled else null,
        .error_name = if (observation.failure) |err| @as(?[]const u8, @errorName(err)) else if (process_ok)
            if (mode == .command) null else if (stdout.total > stdout.used) "ReplyTooLarge" else "InvalidReply"
        else if (spool.failed)
            "SpoolFailure"
        else if (!released)
            "CleanupUnconfirmed"
        else
            "ProcessFailed",
        .cleanup_confirmed = released,
        .stdout = if (stdout_text) stdout_excerpt else null,
        .stdout_base64 = if (!stdout_text) base64(scratch, stdout_excerpt) catch "" else null,
        .stderr = if (stderr_text) stderr_excerpt else null,
        .stderr_base64 = if (!stderr_text) base64(scratch, stderr_excerpt) catch "" else null,
        .stdout_bytes = stdout.total,
        .stderr_bytes = stderr.total,
        .spool_truncated = spool.truncated,
        .spool_failed = spool.failed,
    }, .{}) catch {
        keep_fallback = true;
        return result;
    };
    if (encoded.len > options.output_bytes) {
        allocator.free(encoded);
        keep_fallback = true;
    } else {
        result.content = encoded;
        result.truncated = truncated;
    }
    return result;
}

fn isText(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte < 0x20 and byte != '\n' and byte != '\r' and byte != '\t') return false;
    }
    return std.unicode.utf8ValidateSlice(bytes);
}

fn base64(allocator: Allocator, bytes: []const u8) error{OutOfMemory}![]const u8 {
    const encoder = std.base64.standard.Encoder;
    return encoder.encode(try allocator.alloc(u8, encoder.calcSize(bytes.len)), bytes);
}

fn boundedCopy(allocator: Allocator, text: []const u8, limit: usize) error{OutOfMemory}![]const u8 {
    return allocator.dupe(u8, text[0..@min(text.len, limit)]);
}

fn rejected(allocator: Allocator, id: []const u8, err: foo.io.Error, limit: usize) foo.io.Error!foo.tool.Result {
    const message = @errorName(err);
    return .{
        .call_id = id,
        .status = if (err == error.Cancelled) .cancelled else .failure,
        .effect = .not_started,
        .content = try boundedCopy(allocator, message, limit),
        .truncated = message.len > limit,
    };
}
