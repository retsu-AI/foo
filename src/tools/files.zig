const std = @import("std");
const builtin = @import("builtin");
const foo = @import("foo");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const File = std.Io.File;
const Sha256 = std.crypto.hash.sha2.Sha256;
const base64 = std.base64.standard;

pub const Error = foo.io.Error || error{
    MissingFile,
    UnsupportedTarget,
    PermissionDenied,
    StaleFile,
    InvalidEncoding,
    InvalidRange,
    MissingMatch,
    AmbiguousMatch,
    OverlappingMatches,
    CommitUncertain,
    CommitCancelled,
};

pub const Encoding = enum { utf8, base64 };
pub const Digest = [Sha256.digest_length]u8;
pub const Replacement = struct { old: []const u8, new: []const u8 };
pub const Read = struct { encoding: Encoding, offset: usize, max_bytes: usize };
pub const Edit = struct { expected: Digest, replacements: []const Replacement };
pub const Mutation = union(enum) { write: []const u8, edit: Edit };

pub const Payload = struct { content: []const u8, truncated: bool = false };

const Target = struct { dir: Dir, name: []const u8 };
const Snapshot = struct { stat: File.Stat, bytes: []const u8, digest: Digest };

pub const max_replacements = 64;

pub fn absolute(path: []const u8) bool {
    if (builtin.os.tag == .windows) {
        return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and
            path[1] == ':' and std.fs.path.isSep(path[2]);
    }
    return std.fs.path.isAbsolute(path);
}

pub fn resolve(allocator: Allocator, cwd: []const u8, path: []const u8) Error![]const u8 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null or
        std.fs.path.isSep(path[path.len - 1])) return error.InvalidInput;

    if (builtin.os.tag == .windows) {
        const tail = if (absolute(path)) path[3..] else path;
        if (std.fs.path.isSep(path[0]) or std.mem.indexOfScalar(u8, tail, ':') != null)
            return error.InvalidInput;
        var parts = std.mem.tokenizeAny(u8, tail, "/\\");
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) continue;
            if (part[part.len - 1] == '.' or part[part.len - 1] == ' ') return error.InvalidInput;
        }
    }

    const name = std.fs.path.basename(path);
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
        return error.InvalidInput;
    return std.fs.path.resolveAlloc(allocator, &.{ cwd, path });
}

pub fn decode(allocator: Allocator, encoding: Encoding, input: []const u8, limit: usize) Error![]const u8 {
    if (encoding == .utf8) {
        if (input.len > limit) return error.LimitExceeded;
        return input;
    }
    const size = base64.Decoder.calcSizeForSlice(input) catch return error.InvalidEncoding;
    if (size > limit) return error.LimitExceeded;
    const bytes = try allocator.alloc(u8, size);
    base64.Decoder.decode(bytes, input) catch return error.InvalidEncoding;
    return bytes;
}

pub fn decodeDigest(value: []const u8) Error!Digest {
    var out: Digest = undefined;
    if (value.len != out.len * 2) return error.InvalidInput;
    _ = std.fmt.hexToBytes(&out, value) catch return error.InvalidInput;
    return out;
}

fn digest(bytes: []const u8) Digest {
    var out: Digest = undefined;
    Sha256.hash(bytes, &out, .{});
    return out;
}

fn fileError(err: anyerror) Error {
    return switch (err) {
        error.Cancelled => error.Cancelled,
        error.FileNotFound => error.MissingFile,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => error.PermissionDenied,
        error.IsDir, error.NotDir, error.SymLinkLoop => error.UnsupportedTarget,
        error.BadPathName, error.NameTooLong => error.InvalidInput,
        error.FileTooBig, error.DiskQuota, error.NoSpaceLeft => error.LimitExceeded,
        else => error.IoFailure,
    };
}

fn openTarget(op: foo.io.Context, path: []const u8) Error!Target {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidInput;
    const dir = Dir.openDirAbsolute(op.io, parent, .{}) catch |err| return fileError(err);
    return .{ .dir = dir, .name = std.fs.path.basename(path) };
}

fn targetStat(target: Target, op: foo.io.Context) Error!?File.Stat {
    const stat = target.dir.statFile(op.io, target.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return fileError(err),
    };
    if (stat.kind != .file) return error.UnsupportedTarget;
    return stat;
}

fn sameStat(a: File.Stat, b: File.Stat) bool {
    return a.inode == b.inode and a.size == b.size and a.mtime.nanoseconds == b.mtime.nanoseconds and
        a.ctime.nanoseconds == b.ctime.nanoseconds and a.permissions == b.permissions;
}

fn snapshot(allocator: Allocator, op: foo.io.Context, target: Target, limit: usize) Error!?Snapshot {
    try op.check();
    const original = try targetStat(target, op) orelse return null;
    if (original.size > limit) return error.LimitExceeded;
    const file = target.dir.openFile(op.io, target.name, .{
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |err| return fileError(err);
    defer file.close(op.io);
    const opened = file.stat(op.io) catch |err| return fileError(err);
    if (opened.kind != .file or !sameStat(original, opened)) return error.StaleFile;

    const bytes = try allocator.alloc(u8, @intCast(opened.size));
    var offset: usize = 0;
    while (offset < bytes.len) {
        try op.check();
        const end = offset + @min(64 * 1024, bytes.len - offset);
        const n = file.readPositionalAll(op.io, bytes[offset..end], offset) catch |err| return fileError(err);
        if (n != end - offset) return error.StaleFile;
        offset = end;
    }
    const finished = file.stat(op.io) catch |err| return fileError(err);
    const path_now = try targetStat(target, op) orelse return error.StaleFile;
    if (!sameStat(opened, finished) or !sameStat(finished, path_now)) return error.StaleFile;
    try op.check();
    return .{ .stat = finished, .bytes = bytes, .digest = digest(bytes) };
}

pub fn read(
    allocator: Allocator,
    scratch: Allocator,
    op: foo.io.Context,
    path: []const u8,
    args: Read,
    file_limit: usize,
    output_limit: usize,
) Error!Payload {
    const target = try openTarget(op, path);
    defer target.dir.close(op.io);
    const source = try snapshot(scratch, op, target, file_limit) orelse return error.MissingFile;
    if (args.offset > source.bytes.len) return error.InvalidRange;
    if (args.encoding == .utf8) {
        if (!std.unicode.utf8ValidateSlice(source.bytes)) return error.InvalidEncoding;
        if (args.offset < source.bytes.len and continuation(source.bytes[args.offset]))
            return error.InvalidRange;
    }

    const remaining = source.bytes[args.offset..];
    const max_bytes = @min(args.max_bytes, remaining.len, output_limit);
    const sha256 = std.fmt.bytesToHex(source.digest, .lower);
    const response_buffer = try scratch.alloc(u8, @min(output_limit, 256 +| 6 *| max_bytes));
    const encoded = if (args.encoding == .base64)
        try scratch.alloc(u8, base64.Encoder.calcSize(max_bytes))
    else
        &.{};

    var low: usize = 0;
    var high: usize = max_bytes;
    var best: ?struct { size: usize, truncated: bool } = null;
    while (low <= high) {
        try op.check();
        const count = low + (high - low) / 2;
        const bytes = remaining[0..prefixLength(args.encoding, remaining, count)];
        const truncated = args.offset != 0 or bytes.len != remaining.len;
        var writer = std.Io.Writer.fixed(response_buffer);
        std.json.Stringify.value(.{
            .encoding = @tagName(args.encoding),
            .offset = args.offset,
            .bytes = bytes.len,
            .total_bytes = source.bytes.len,
            .sha256 = sha256[0..],
            .truncated = truncated,
            .content = if (args.encoding == .base64) base64.Encoder.encode(encoded, bytes) else bytes,
        }, .{}, &writer) catch {
            if (count == 0) break;
            high = count - 1;
            continue;
        };
        best = .{ .size = count, .truncated = truncated };
        low = count + 1;
    }
    const fit = best orelse return error.LimitExceeded;
    const bytes = remaining[0..prefixLength(args.encoding, remaining, fit.size)];
    var writer = std.Io.Writer.fixed(response_buffer);
    try op.check();
    std.json.Stringify.value(.{
        .encoding = @tagName(args.encoding),
        .offset = args.offset,
        .bytes = bytes.len,
        .total_bytes = source.bytes.len,
        .sha256 = sha256[0..],
        .truncated = fit.truncated,
        .content = if (args.encoding == .base64) base64.Encoder.encode(encoded, bytes) else bytes,
    }, .{}, &writer) catch unreachable;
    return .{ .content = try allocator.dupe(u8, writer.buffered()), .truncated = fit.truncated };
}

fn continuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn prefixLength(encoding: Encoding, bytes: []const u8, count: usize) usize {
    if (encoding != .utf8 or count == bytes.len) return count;
    var end = count;
    while (continuation(bytes[end])) end -= 1;
    return end;
}

const Match = struct {
    begin: usize,
    end: usize,
    replacement: []const u8,

    fn lessThan(_: void, a: Match, b: Match) bool {
        return a.begin < b.begin;
    }
};

fn applyEdit(scratch: Allocator, op: foo.io.Context, original: Snapshot, edit: Edit, limit: usize) Error![]const u8 {
    if (!std.mem.eql(u8, &original.digest, &edit.expected)) return error.StaleFile;

    const bytes = original.bytes;
    var matches: [max_replacements]Match = undefined;
    for (edit.replacements, matches[0..edit.replacements.len]) |replacement, *match| {
        try op.check();
        const first = std.mem.indexOf(u8, bytes, replacement.old) orelse return error.MissingMatch;
        if (std.mem.indexOfPos(u8, bytes, first + 1, replacement.old) != null)
            return error.AmbiguousMatch;
        match.* = .{ .begin = first, .end = first + replacement.old.len, .replacement = replacement.new };
    }
    const ordered = matches[0..edit.replacements.len];
    std.mem.sort(Match, ordered, {}, Match.lessThan);

    var previous_end: usize = 0;
    var removed: usize = 0;
    var added: usize = 0;
    for (ordered) |match| {
        if (match.begin < previous_end) return error.OverlappingMatches;
        removed += match.end - match.begin;
        added = std.math.add(usize, added, match.replacement.len) catch return error.LimitExceeded;
        previous_end = match.end;
    }
    const size = std.math.add(usize, bytes.len - removed, added) catch return error.LimitExceeded;
    if (size > limit) return error.LimitExceeded;
    const result = try scratch.alloc(u8, size);
    var start: usize = 0;
    var written: usize = 0;
    for (ordered) |match| {
        const unchanged = bytes[start..match.begin];
        @memcpy(result[written..][0..unchanged.len], unchanged);
        written += unchanged.len;
        @memcpy(result[written..][0..match.replacement.len], match.replacement);
        written += match.replacement.len;
        start = match.end;
    }
    @memcpy(result[written..], bytes[start..]);
    return result;
}

pub fn mutate(
    allocator: Allocator,
    scratch: Allocator,
    op: foo.io.Context,
    writer_lock: *std.Io.Mutex,
    path: []const u8,
    mutation: Mutation,
    file_limit: usize,
    output_limit: usize,
) Error!Payload {
    while (!writer_lock.tryLock()) {
        try op.check();
        op.io.sleep(.fromMilliseconds(1), .awake) catch return error.Cancelled;
    }
    defer writer_lock.unlock(op.io);
    try op.check();
    const target = try openTarget(op, path);
    defer target.dir.close(op.io);
    const original = try snapshot(scratch, op, target, file_limit);
    const replacement = switch (mutation) {
        .write => |bytes| bytes,
        .edit => |edit| try applyEdit(scratch, op, original orelse return error.MissingFile, edit, file_limit),
    };
    if (original) |entry| {
        if (entry.stat.permissions.readOnly()) return error.PermissionDenied;
        const writable = target.dir.openFile(op.io, target.name, .{
            .mode = .write_only,
            .allow_directory = false,
            .follow_symlinks = false,
        }) catch |err| return fileError(err);
        writable.close(op.io);
    }

    const sha256 = std.fmt.bytesToHex(digest(replacement), .lower);
    const result = try std.json.Stringify.valueAlloc(allocator, .{
        .bytes = replacement.len,
        .sha256 = sha256[0..],
    }, .{});
    errdefer allocator.free(result);
    if (result.len > output_limit) return error.LimitExceeded;

    try op.check();
    var temporary = target.dir.createFileAtomic(op.io, target.name, .{
        .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600),
        .replace = original != null,
    }) catch |err| return fileError(err);
    defer {
        const protection = op.io.swapCancelProtection(.blocked);
        defer _ = op.io.swapCancelProtection(protection);
        temporary.deinit(op.io);
    }
    var offset: usize = 0;
    while (offset < replacement.len) {
        try op.check();
        const end = offset + @min(64 * 1024, replacement.len - offset);
        temporary.file.writeStreamingAll(op.io, replacement[offset..end]) catch |err| return fileError(err);
        offset = end;
    }
    if (builtin.os.tag != .windows) {
        if (original) |entry| {
            const permissions: File.Permissions = .fromMode(entry.stat.permissions.toMode() & 0o777);
            temporary.file.setPermissions(op.io, permissions) catch |err| return fileError(err);
        }
    }
    temporary.file.sync(op.io) catch |err| return fileError(err);

    const current = try snapshot(scratch, op, target, file_limit);
    if (original) |entry| {
        const now = current orelse return error.StaleFile;
        if (!sameStat(entry.stat, now.stat) or !std.mem.eql(u8, &entry.digest, &now.digest))
            return error.StaleFile;
    } else if (current != null) return error.StaleFile;

    try op.check();
    if (original != null) {
        temporary.replace(op.io) catch |err| return commitError(err);
    } else {
        temporary.link(op.io) catch |err| return commitError(err);
    }
    return .{ .content = result };
}

fn commitError(err: anyerror) Error {
    return switch (err) {
        error.Cancelled => error.CommitCancelled,
        error.Unexpected, error.HardwareFailure, error.NetworkNotFound => error.CommitUncertain,
        error.PathAlreadyExists, error.FileNotFound => error.StaleFile,
        else => fileError(err),
    };
}
