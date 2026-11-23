const std = @import("std");
const platform = @import("builtin");
const foo = @import("foo");
const tools = @import("tools").builtin_tools;

const testing = std.testing;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Allocator = std.mem.Allocator;

const file_limit = 2048;
const output_limit = 2048;
const name = "sample é.txt";
const ReadResult = struct {
    encoding: enum { utf8, base64 },
    offset: usize,
    bytes: usize,
    total_bytes: usize,
    sha256: []const u8,
    truncated: bool,
    content: []const u8,
};
const Replacement = struct { old: []const u8, new: []const u8 };

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    cwd: []const u8,
    writer_lock: std.Io.Mutex = .init,
    cancellation: foo.io.Cancellation = .{},

    fn init() !Fixture {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        errdefer arena.deinit();
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const cwd = try tmp.parent_dir.realPathFileAlloc(testing.io, &tmp.sub_path, arena.allocator());
        return .{ .arena = arena, .tmp = tmp, .cwd = cwd };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn seed(self: *Fixture, contents: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = contents });
    }

    fn expectFile(self: *Fixture, expected: []const u8) !void {
        const bytes = try self.tmp.dir.readFileAlloc(testing.io, name, self.arena.allocator(), .limited(file_limit));
        try testing.expectEqualStrings(expected, bytes);
    }

    fn operation(self: *Fixture) foo.io.Context {
        return .{
            .io = testing.io,
            .cancellation = &self.cancellation,
            .clock = .{ .context = self, .now_fn = now },
        };
    }

    fn now(_: *anyopaque) u64 {
        return 0;
    }

    fn prepare(self: *Fixture, kind: tools.Kind, args: anytype) !tools.Prepared {
        const allocator = self.arena.allocator();
        const json = try std.json.Stringify.valueAlloc(allocator, args, .{});
        return tools.prepare(kind, allocator, self.cwd, json, file_limit);
    }

    fn run(self: *Fixture, prepared: tools.Prepared, op: foo.io.Context, limit: usize) !foo.tool.Result {
        const allocator = self.arena.allocator();
        return prepared.run(allocator, allocator, op, "call-1", file_limit, limit, &self.writer_lock, undefined);
    }

    fn read(self: *Fixture, args: anytype, limit: usize) !ReadResult {
        const result = try self.run(try self.prepare(.read, args), self.operation(), limit);
        try testing.expectEqual(.success, result.status);
        try testing.expectEqual(.observed, result.effect);
        try testing.expect(result.content.len <= limit);
        const data = try std.json.parseFromSliceLeaky(ReadResult, self.arena.allocator(), result.content, .{});
        try testing.expectEqual(data.truncated, result.truncated);
        return data;
    }

    fn edit(self: *Fixture, expected: []const u8, replacements: []const Replacement) !tools.Prepared {
        return self.prepare(.edit, .{ .path = name, .expected_sha256 = expected, .replacements = replacements });
    }
};

fn sha256(bytes: []const u8) [Sha256.digest_length * 2]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn expectRejected(result: foo.tool.Result, message: []const u8) !void {
    try testing.expectEqual(.failure, result.status);
    try testing.expectEqual(.not_started, result.effect);
    try testing.expect(std.mem.indexOf(u8, result.content, message) != null);
}

test "built-in preparation rejects invalid arguments and owns literal argv" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const scratch = fixture.arena.allocator();
    const cases: []const struct { kind: tools.Kind, json: []const u8 } = &.{
        .{ .kind = .read, .json = "{\"path\":\"f\",\"path\":\"g\"}" },
        .{ .kind = .read, .json = "{\"path\":\"f\",\"unknown\":0}" },
        .{ .kind = .read, .json = "{\"path\":\"f\",\"offset\":-1}" },
        .{ .kind = .read, .json = "{\"path\":\"f\",\"max_bytes\":null}" },
        .{ .kind = .read, .json = "{\"path\":\"f\",\"encoding\":\"binary\"}" },
        .{ .kind = .write, .json = "{\"path\":\"\",\"content\":\"\"}" },
        .{ .kind = .write, .json = "{\"path\":\"x\\u0000z\",\"content\":\"\"}" },
        .{ .kind = .edit, .json = "{\"path\":\"f\",\"expected_sha256\":\"none\",\"replacements\":[]}" },
        .{ .kind = .exec, .json = "{\"argv\":[]}" },
        .{ .kind = .exec, .json = "{\"argv\":[\"\"]}" },
        .{ .kind = .exec, .json = "{\"argv\":[\"exe\",\"x\\u0000z\"]}" },
        .{ .kind = .exec, .json = "{\"argv\":[\"exe\"],\"cwd\":\"x\"}" },
    };
    for (cases) |case| {
        try testing.expectError(error.InvalidInput, tools.prepare(case.kind, scratch, fixture.cwd, case.json, file_limit));
    }
    const digest = sha256("original");
    try testing.expectError(error.InvalidInput, fixture.edit(&digest, &.{}));
    try testing.expectError(error.InvalidInput, fixture.edit(&digest, &.{.{ .old = "", .new = "x" }}));
    try testing.expectError(error.InvalidEncoding, fixture.prepare(.write, .{ .path = name, .encoding = "base64", .content = "////?" }));
    const oversized: [file_limit + 1]u8 = @splat('x');
    try testing.expectError(error.LimitExceeded, fixture.prepare(.write, .{ .path = name, .content = oversized[0..] }));

    const input: []u8 = try scratch.dupe(u8, "{\"argv\":[\"exe\",\"\",\"a b\",\"a | b\",\"$(ignored)\"]}");
    const command = try tools.prepare(.exec, scratch, fixture.cwd, input, file_limit);
    @memset(input, ' ');
    try testing.expectEqualStrings("exe", command.target());
    for ([_][]const u8{ "exe", "", "a b", "a | b", "$(ignored)" }, command.exec) |want, got| {
        try testing.expectEqualStrings(want, got);
    }
    const prepared = try fixture.prepare(.read, .{ .path = "dir/../" ++ name });
    const expected_target = try std.fs.path.resolveAlloc(scratch, &.{ fixture.cwd, name });
    try testing.expectEqualStrings(expected_target, prepared.target());
}

test "read reports UTF-8 range, entire digest, and actual output limit" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const original = "aé🙂\r\nb";
    try fixture.seed(original);
    const range = try fixture.read(.{ .path = name, .offset = 1, .max_bytes = 4 }, output_limit);
    try testing.expectEqualStrings("é", range.content);
    try testing.expectEqual(@as(usize, 1), range.offset);
    try testing.expectEqual(@as(usize, 2), range.bytes);
    try testing.expectEqual(@as(usize, original.len), range.total_bytes);
    try testing.expect(range.truncated);
    try testing.expectEqualStrings(&sha256(original), range.sha256);

    const invalid = try fixture.prepare(.read, .{ .path = name, .offset = 2 });
    try expectRejected(try fixture.run(invalid, fixture.operation(), output_limit), "character boundary");
    const outside = try fixture.prepare(.read, .{ .path = name, .offset = original.len + 1 });
    try expectRejected(try fixture.run(outside, fixture.operation(), output_limit), "within the file");

    const escapes: [300]u8 = @splat(0);
    try fixture.seed(&escapes);
    const bounded = try fixture.read(.{ .path = name }, 200);
    try testing.expect(bounded.truncated);
    try testing.expect(bounded.bytes > 0);
    try testing.expectEqualStrings(escapes[0..bounded.bytes], bounded.content);
    try testing.expectEqualStrings(&sha256(&escapes), bounded.sha256);
    const full = try fixture.read(.{ .path = name }, output_limit);
    try testing.expect(!full.truncated);
    try testing.expectEqualStrings(&escapes, full.content);
}

test "binary write, read, and edit preserve bytes" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const write = try fixture.prepare(.write, .{ .path = name, .encoding = "base64", .content = "AP9B" });
    const created = try fixture.run(write, fixture.operation(), output_limit);
    try testing.expectEqual(.success, created.status);
    try testing.expectEqual(.observed, created.effect);
    try testing.expectEqualStrings("call-1", created.call_id);
    try fixture.expectFile("\x00\xffA");

    const utf8 = try fixture.prepare(.read, .{ .path = name });
    try expectRejected(try fixture.run(utf8, fixture.operation(), output_limit), "base64");
    const read = try fixture.read(.{ .path = name, .encoding = "base64" }, output_limit);
    try testing.expectEqualStrings("AP9B", read.content);
    try testing.expectEqualStrings(&sha256("\x00\xffA"), read.sha256);
    const edit = try fixture.prepare(.edit, .{
        .path = name,
        .encoding = "base64",
        .expected_sha256 = read.sha256,
        .replacements = @as([]const Replacement, &.{.{ .old = "/0E=", .new = "gA==" }}),
    });
    try testing.expectEqual(.success, (try fixture.run(edit, fixture.operation(), output_limit)).status);
    try fixture.expectFile("\x00\x80");
}

test "edit resolves every unique disjoint replacement against one snapshot" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const original = "head\r\nα\r\nβ\r\ntail\r\n";
    try fixture.seed(original);
    const observation = try fixture.read(.{ .path = name }, output_limit);
    const edit = try fixture.edit(observation.sha256, &.{
        .{ .old = "β", .new = "last" },
        .{ .old = "α", .new = "β" },
    });
    const result = try fixture.run(edit, fixture.operation(), output_limit);
    try testing.expectEqual(.success, result.status);
    try testing.expectEqual(.observed, result.effect);
    const expected = "head\r\nβ\r\nlast\r\ntail\r\n";
    const metadata = try std.json.parseFromSliceLeaky(struct { bytes: usize, sha256: []const u8 }, fixture.arena.allocator(), result.content, .{});
    try testing.expectEqual(@as(usize, expected.len), metadata.bytes);
    try testing.expectEqualStrings(&sha256(expected), metadata.sha256);
    try fixture.expectFile(expected);
    try expectRejected(try fixture.run(edit, fixture.operation(), output_limit), "Read it again");
    try fixture.expectFile(expected);
}

test "failed edit preconditions cause no replacement" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const original = "aaa\r\nbcde\r\n";
    const expected_digest = sha256(original);
    try fixture.seed(original);
    const attempts: []const struct { replacements: []const Replacement, message: []const u8 } = &.{
        .{ .replacements = &.{ .{ .old = "bcde", .new = "valid" }, .{ .old = "absent", .new = "new" } }, .message = "absent" },
        .{ .replacements = &.{.{ .old = "aa", .new = "ambiguous" }}, .message = "more than once" },
        .{ .replacements = &.{ .{ .old = "bc", .new = "first" }, .{ .old = "cd", .new = "second" } }, .message = "overlapping" },
        .{ .replacements = &.{.{ .old = "bcde", .new = &@as([file_limit]u8, @splat('x')) }}, .message = "size limit" },
    };
    for (attempts) |attempt| {
        const edit = try fixture.edit(&expected_digest, attempt.replacements);
        try expectRejected(try fixture.run(edit, fixture.operation(), output_limit), attempt.message);
        try fixture.expectFile(original);
    }
    const write = try fixture.prepare(.write, .{ .path = name, .content = "replacement" });
    const too_small = try fixture.run(write, fixture.operation(), 4);
    try testing.expectEqual(.failure, too_small.status);
    try testing.expectEqual(.not_started, too_small.effect);
    try testing.expectEqual(@as(usize, 4), too_small.content.len);
    try testing.expect(too_small.truncated);
    try fixture.expectFile(original);
}

test "missing, directory, and read-only targets" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const read = try fixture.prepare(.read, .{ .path = name });
    try expectRejected(try fixture.run(read, fixture.operation(), output_limit), "does not exist");
    try fixture.seed("original");
    try fixture.tmp.dir.createDir(testing.io, "actual", .default_dir);
    const directory = try fixture.prepare(.read, .{ .path = "actual" });
    try expectRejected(try fixture.run(directory, fixture.operation(), output_limit), "regular file");

    const file = try fixture.tmp.dir.openFile(testing.io, name, .{ .mode = .read_write });
    defer file.close(testing.io);
    const writable: std.Io.File.Permissions = if (platform.os.tag == .windows)
        @fromBackingInt(@as(u32, @bitCast(std.os.windows.FILE.ATTRIBUTE{ .NORMAL = true })))
    else
        .fromMode(0o600);
    const read_only: std.Io.File.Permissions = if (platform.os.tag == .windows)
        @fromBackingInt(@as(u32, @bitCast(std.os.windows.FILE.ATTRIBUTE{ .READONLY = true })))
    else
        .fromMode(0o444);
    try file.setPermissions(testing.io, read_only);
    defer file.setPermissions(testing.io, writable) catch {};
    const write = try fixture.prepare(.write, .{ .path = name, .content = "replacement" });
    try expectRejected(try fixture.run(write, fixture.operation(), output_limit), "permission denied");
    try fixture.expectFile("original");
}

test "file and directory symbolic links are rejected" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed("original");
    try fixture.tmp.dir.createDir(testing.io, "actual", .default_dir);

    fixture.tmp.dir.symLink(testing.io, name, "link", .{}) catch |err| {
        if (platform.os.tag == .windows and (err == error.AccessDenied or err == error.PermissionDenied))
            return error.SkipZigTest;
        return err;
    };
    const link = try fixture.prepare(.write, .{ .path = "link", .content = "replacement" });
    try expectRejected(try fixture.run(link, fixture.operation(), output_limit), "regular file");
    try fixture.expectFile("original");

    try fixture.tmp.dir.symLink(testing.io, "actual", "alias", .{ .is_directory = true });
    const escape = try fixture.prepare(.write, .{ .path = "alias/new", .content = "replacement" });
    try expectRejected(try fixture.run(escape, fixture.operation(), output_limit), "regular file");
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.openFile(testing.io, "actual/new", .{}));
}

const Interference = struct {
    threadlocal var active: ?*Fixture = null;
    threadlocal var stats_until_pipe_swap: usize = 0;

    extern "c" fn mkfifo(path: [*:0]const u8, mode: std.posix.mode_t) c_int;

    fn changeFile(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        try testing.io.vtable.fileSync(userdata, file);
        const fixture = active.?;
        active = null;
        fixture.seed("external change") catch return error.InputOutput;
    }

    fn moveParent(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        try testing.io.vtable.fileSync(userdata, file);
        const dir = active.?.tmp.dir;
        active = null;
        dir.rename("approved", dir, "moved", testing.io) catch return error.InputOutput;
        dir.createDir(testing.io, "approved", .default_dir) catch return error.InputOutput;
        dir.writeFile(testing.io, .{ .sub_path = "approved/" ++ name, .data = "other" }) catch return error.InputOutput;
    }

    fn swapPipeAfterStat(
        userdata: ?*anyopaque,
        dir: std.Io.Dir,
        path: []const u8,
        options: std.Io.Dir.StatFileOptions,
    ) std.Io.Dir.StatFileError!std.Io.Dir.Stat {
        const stat = try testing.io.vtable.dirStatFile(userdata, dir, path, options);
        if (stats_until_pipe_swap == 0) return stat;
        stats_until_pipe_swap -= 1;
        if (stats_until_pipe_swap == 0) dir.rename("pipe", dir, path, testing.io) catch return error.Unexpected;
        return stat;
    }

    fn cancelRename(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir, _: []const u8) std.Io.Dir.RenameError!void {
        return error.Canceled;
    }

    fn cancelWait(_: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
        return error.Canceled;
    }
};

test "an external write during preparation wins over a stale edit" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed("before");
    const edit = try fixture.edit(&sha256("before"), &.{.{ .old = "before", .new = "edited" }});
    var vtable = testing.io.vtable.*;
    vtable.fileSync = Interference.changeFile;
    Interference.active = &fixture;
    defer Interference.active = null;
    var op = fixture.operation();
    op.io.vtable = &vtable;
    try expectRejected(try fixture.run(edit, op, output_limit), "Read it again");
    try testing.expect(Interference.active == null);
    try fixture.expectFile("external change");
}

test "a pipe substituted during file open is rejected without waiting for a peer" {
    if (platform.os.tag != .linux and platform.os.tag != .macos) return error.SkipZigTest;
    for ([_]tools.Kind{ .read, .write }) |kind| {
        var fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.seed("original");
        if (platform.os.tag == .linux and !platform.link_libc) {
            const rc = std.os.linux.mknodat(fixture.tmp.dir.handle, "pipe", std.posix.S.IFIFO | 0o600, 0);
            try testing.expectEqual(.SUCCESS, std.posix.errno(rc));
        } else {
            const fifo = try std.fmt.allocPrintSentinel(fixture.arena.allocator(), "{s}/pipe", .{fixture.cwd}, 0);
            try testing.expectEqual(0, Interference.mkfifo(fifo, 0o600));
        }

        const prepared = if (kind == .read)
            try fixture.prepare(.read, .{ .path = name })
        else
            try fixture.prepare(.write, .{ .path = name, .content = "replacement" });
        var vtable = testing.io.vtable.*;
        vtable.dirStatFile = Interference.swapPipeAfterStat;
        Interference.stats_until_pipe_swap = if (kind == .read) 1 else 2;
        var op = fixture.operation();
        op.io.vtable = &vtable;
        try expectRejected(try fixture.run(prepared, op, output_limit), "Read it again");
        const stat = try fixture.tmp.dir.statFile(testing.io, name, .{ .follow_symlinks = false });
        try testing.expectEqual(.named_pipe, stat.kind);
    }
}

test "a renamed parent is rejected before replacing a file" {
    if (platform.os.tag == .windows) return error.SkipZigTest;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.createDir(testing.io, "approved", .default_dir);
    const path = "approved/" ++ name;
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = "original" });
    const write = try fixture.prepare(.write, .{ .path = path, .content = "replacement" });
    var vtable = testing.io.vtable.*;
    vtable.fileSync = Interference.moveParent;
    Interference.active = &fixture;
    defer Interference.active = null;
    var op = fixture.operation();
    op.io.vtable = &vtable;
    try expectRejected(try fixture.run(write, op, output_limit), "Read it again");
    const allocator = fixture.arena.allocator();
    const original = try fixture.tmp.dir.readFileAlloc(testing.io, "moved/" ++ name, allocator, .limited(file_limit));
    try testing.expectEqualStrings("original", original);
    const replacement = try fixture.tmp.dir.readFileAlloc(testing.io, path, allocator, .limited(file_limit));
    try testing.expectEqualStrings("other", replacement);
}

test "cancellation distinguishes pre-commit and uncertain rename" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed("original");
    const write = try fixture.prepare(.write, .{ .path = name, .content = "updated" });
    var vtable = testing.io.vtable.*;
    vtable.dirRename = Interference.cancelRename;
    var op = fixture.operation();
    op.io.vtable = &vtable;

    const at_rename = try fixture.run(write, op, output_limit);
    try testing.expectEqual(.cancelled, at_rename.status);
    try testing.expectEqual(.uncertain, at_rename.effect);
    try fixture.expectFile("original");

    fixture.cancellation.request();
    const before_contact = try fixture.run(write, op, output_limit);
    try testing.expectEqual(.cancelled, before_contact.status);
    try testing.expectEqual(.not_started, before_contact.effect);
    try fixture.expectFile("original");
}

test "cancellation while another writer holds the lock leaves the file intact" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.seed("original");
    const write = try fixture.prepare(.write, .{ .path = name, .content = "updated" });
    try testing.expect(fixture.writer_lock.tryLock());
    defer fixture.writer_lock.unlock(testing.io);
    var vtable = testing.io.vtable.*;
    vtable.sleep = Interference.cancelWait;
    var op = fixture.operation();
    op.io.vtable = &vtable;
    const result = try fixture.run(write, op, output_limit);
    try testing.expectEqual(.cancelled, result.status);
    try testing.expectEqual(.not_started, result.effect);
    try fixture.expectFile("original");
}
