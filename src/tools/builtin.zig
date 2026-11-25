const std = @import("std");
const foo = @import("foo");
const exec = @import("exec.zig");
const files = @import("files.zig");

const Allocator = std.mem.Allocator;

pub const Kind = enum { read, write, edit, exec };

pub fn spec(kind: Kind) foo.provider.ToolSpec {
    return switch (kind) {
        .read => .{
            .name = "read",
            .description = "Read a regular file. Returns a byte range and the SHA-256 of the whole file. Request base64 for binary data.",
            .schema_json =
            \\{"type":"object","additionalProperties":false,"required":["path"],"properties":{
            \\  "path":{"type":"string"},
            \\  "encoding":{"type":"string","description":"utf8 (default) or base64"},
            \\  "offset":{"type":"integer","description":"Starting byte offset, default 0"},
            \\  "max_bytes":{"type":"integer","description":"Maximum number of file bytes to return"}
            \\}}
            ,
        },
        .write => .{
            .name = "write",
            .description = "Create a regular file or replace its entire contents. Returns its size and SHA-256.",
            .schema_json =
            \\{"type":"object","additionalProperties":false,"required":["path","content"],"properties":{
            \\  "path":{"type":"string"},
            \\  "encoding":{"type":"string","description":"utf8 (default) or base64"},
            \\  "content":{"type":"string"}
            \\}}
            ,
        },
        .edit => .{
            .name = "edit",
            .description = "Apply exact replacements to one file at the supplied SHA-256. Each old value must match exactly once, and matches must be disjoint.",
            .schema_json =
            \\{"type":"object","additionalProperties":false,"required":["path","expected_sha256","replacements"],"properties":{
            \\  "path":{"type":"string"},
            \\  "encoding":{"type":"string","description":"Encoding of old and new values: utf8 (default) or base64"},
            \\  "expected_sha256":{"type":"string","description":"SHA-256 hex digest from the latest read"},
            \\  "replacements":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["old","new"],"properties":{
            \\    "old":{"type":"string","description":"Nonempty exact match"},
            \\    "new":{"type":"string"}
            \\  }}}
            \\}}
            ,
        },
        .exec => .{
            .name = "exec",
            .description = "Run a program in the configured working directory and environment. Supply the executable and each argument separately.",
            .schema_json =
            \\{"type":"object","additionalProperties":false,"required":["argv"],"properties":{
            \\  "argv":{"type":"array","items":{"type":"string"},"description":"Executable followed by its arguments"}
            \\}}
            ,
        },
    };
}

const ReadInput = struct {
    path: []const u8,
    encoding: files.Encoding = .utf8,
    offset: usize = 0,
    max_bytes: usize = std.math.maxInt(usize),
};
const WriteInput = struct { path: []const u8, encoding: files.Encoding = .utf8, content: []const u8 };
const EditInput = struct {
    path: []const u8,
    encoding: files.Encoding = .utf8,
    expected_sha256: []const u8,
    replacements: []const files.Replacement,
};
const ExecInput = struct { argv: []const []const u8 };

pub const Prepared = union(Kind) {
    read: struct { path: []const u8, args: files.Read },
    write: struct { path: []const u8, bytes: []const u8 },
    edit: struct { path: []const u8, args: files.Edit },
    exec: []const []const u8,

    pub fn target(self: Prepared) []const u8 {
        return switch (self) {
            inline .read, .write, .edit => |file| file.path,
            .exec => |argv| argv[0],
        };
    }

    pub fn run(
        self: Prepared,
        allocator: Allocator,
        scratch: Allocator,
        op: foo.io.Context,
        id: []const u8,
        file_bytes: usize,
        output_bytes: usize,
        writer_lock: *std.Io.Mutex,
        exec_options: exec.Options,
    ) foo.io.Error!foo.tool.Result {
        if (self == .exec) return exec.runCommand(allocator, op, id, self.exec, exec_options);
        const result_id = try allocator.dupe(u8, id);
        errdefer allocator.free(result_id);
        const payload = switch (self) {
            .read => |file| files.read(allocator, scratch, op, file.path, file.args, file_bytes, output_bytes),
            .write => |file| files.mutate(allocator, scratch, op, writer_lock, file.path, .{ .write = file.bytes }, file_bytes, output_bytes),
            .edit => |file| files.mutate(allocator, scratch, op, writer_lock, file.path, .{ .edit = file.args }, file_bytes, output_bytes),
            .exec => unreachable,
        } catch |err| return fileFailure(allocator, result_id, output_bytes, err);
        return .{ .call_id = result_id, .status = .success, .effect = .observed, .content = payload.content, .truncated = payload.truncated };
    }
};

pub fn prepare(kind: Kind, scratch: Allocator, cwd: []const u8, arguments_json: []const u8, file_bytes: usize) files.Error!Prepared {
    return switch (kind) {
        .read => blk: {
            const args = try parse(ReadInput, scratch, arguments_json);
            break :blk .{ .read = .{
                .path = try files.resolve(scratch, cwd, args.path),
                .args = .{ .encoding = args.encoding, .offset = args.offset, .max_bytes = @min(args.max_bytes, file_bytes) },
            } };
        },
        .write => blk: {
            const args = try parse(WriteInput, scratch, arguments_json);
            break :blk .{ .write = .{
                .path = try files.resolve(scratch, cwd, args.path),
                .bytes = try files.decode(scratch, args.encoding, args.content, file_bytes),
            } };
        },
        .edit => blk: {
            const args = try parse(EditInput, scratch, arguments_json);
            const expected = try files.decodeDigest(args.expected_sha256);
            if (args.replacements.len == 0 or args.replacements.len > files.max_replacements) return error.InvalidInput;
            const replacements = try scratch.alloc(files.Replacement, args.replacements.len);
            for (replacements, args.replacements) |*out, in| {
                const old = try files.decode(scratch, args.encoding, in.old, file_bytes);
                if (old.len == 0) return error.InvalidInput;
                out.* = .{ .old = old, .new = try files.decode(scratch, args.encoding, in.new, file_bytes) };
            }
            break :blk .{ .edit = .{
                .path = try files.resolve(scratch, cwd, args.path),
                .args = .{ .expected = expected, .replacements = replacements },
            } };
        },
        .exec => blk: {
            const args = try parse(ExecInput, scratch, arguments_json);
            if (args.argv.len == 0 or args.argv[0].len == 0) return error.InvalidInput;
            for (args.argv) |arg| {
                if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidInput;
            }
            break :blk .{ .exec = args.argv };
        },
    };
}

fn parse(comptime T: type, scratch: Allocator, input: []const u8) files.Error!T {
    return std.json.parseFromSliceLeaky(T, scratch, input, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidInput,
    };
}

pub fn fileFailure(allocator: Allocator, id: []const u8, limit: usize, err: files.Error) foo.io.Error!foo.tool.Result {
    const message = switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => "File operation cancelled before replacement.",
        error.DeadlineExceeded => "File operation timed out before replacement.",
        error.MissingFile => "File or parent directory does not exist.",
        error.UnsupportedTarget => "Target must be a regular file reached without symbolic links.",
        error.PermissionDenied => "Filesystem permission denied.",
        error.StaleFile => "File changed. Read it again before editing.",
        error.InvalidEncoding => "File content uses a different encoding. Use base64 for binary data.",
        error.InvalidRange => "Byte offset must be within the file and on a character boundary for utf8.",
        error.MissingMatch => "An old value was absent from the original file.",
        error.AmbiguousMatch => "An old value matched more than once in the original file. Include more context.",
        error.OverlappingMatches => "Two replacements match overlapping bytes in the original file.",
        error.CommitUncertain, error.CommitCancelled => "Replacement outcome is unknown. Read the file before retrying.",
        error.LimitExceeded => "File operation exceeded a configured size limit.",
        error.InvalidInput => "File path or arguments are invalid.",
        error.Disconnected, error.Untrusted, error.IoFailure, error.Unavailable => "Filesystem operation failed before replacement.",
    };
    return .{
        .call_id = id,
        .status = switch (err) {
            error.Cancelled, error.DeadlineExceeded, error.CommitCancelled => .cancelled,
            else => .failure,
        },
        .effect = switch (err) {
            error.CommitUncertain, error.CommitCancelled => .uncertain,
            else => .not_started,
        },
        .content = try allocator.dupe(u8, message[0..@min(limit, message.len)]),
        .truncated = message.len > limit,
    };
}
