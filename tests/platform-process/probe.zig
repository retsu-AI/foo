const std = @import("std");
const builtin = @import("builtin");
const foo = @import("foo");
const process = @import("process");
const exec = @import("exec");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const frame_cap = 32768;
const stream_size = 256 * 1024;

extern "kernel32" fn ExitProcess(u32) callconv(.winapi) noreturn;
extern "c" fn raise(c_int) c_int;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.MissingMode;
    const inherited_marker = init.environ_map.get("F05_PARENT_ONLY") orelse "";
    const io = init.io;
    const mode = args[1];
    if (std.mem.eql(u8, mode, "args")) {
        try expectEqualStrings("one argument", args[2]);
        try expectEqualStrings("", args[3]);
        try expectEqualStrings("雪", args[4]);
        try expectEqualStrings("\\quoted\"$", args[5]);
        try expectEqualStrings("hello", init.environ_map.get("F05_FIXTURE") orelse "");
        try expectEqualStrings("", inherited_marker);
        const marker = try std.Io.Dir.cwd().openFile(io, "working-directory", .{});
        marker.close(io);
        try std.Io.File.stdout().writeStreamingAll(io, "stdout");
        try std.Io.File.stderr().writeStreamingAll(io, "stderr");
        if (builtin.os.tag == .windows) ExitProcess(0x12345678);
        std.process.exit(37);
    }
    if (std.mem.eql(u8, mode, "heartbeat")) return heartbeat(io);
    if (std.mem.eql(u8, mode, "tree") or std.mem.eql(u8, mode, "leader-exit")) {
        var grandchild = try std.process.spawn(io, .{ .argv = &.{ args[2], "heartbeat" } });
        if (std.mem.eql(u8, mode, "leader-exit")) {
            try awaitHeartbeat(io);
            std.process.exit(0);
        }
        _ = try grandchild.wait(io);
        return;
    }
    if (std.mem.eql(u8, mode, "signal")) {
        if (builtin.os.tag != .windows) _ = raise(15);
        return error.ExpectedSignal;
    }
    if (std.mem.eql(u8, mode, "protocol")) {
        var buffer: [8192]u8 = undefined;
        var count: usize = 0;
        while (true) {
            count += std.Io.File.stdin().readStreaming(io, &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
        }
        try expectEqual(stream_size, count);
        try std.Io.File.stdout().writeStreamingAll(io, "{\"content\":\"hello from child\"}");
        @memset(&buffer, 'E');
        for (0..stream_size / buffer.len) |_| try std.Io.File.stderr().writeStreamingAll(io, &buffer);
        return;
    }
    if (std.mem.eql(u8, mode, "invalid-json")) {
        try std.Io.File.stdout().writeStreamingAll(io, "{} {}");
        return;
    }
    if (std.mem.eql(u8, mode, "closed-stdin")) {
        std.Io.File.stdin().close(io);
        try io.sleep(.fromMilliseconds(40), .awake);
        try std.Io.File.stderr().writeStreamingAll(io, "rejected");
        std.process.exit(31);
    }
    if (std.mem.eql(u8, mode, "large")) {
        var buffer: [8192]u8 = @splat('X');
        for (0..stream_size / buffer.len) |_| {
            try std.Io.File.stdout().writeStreamingAll(io, &buffer);
            try std.Io.File.stderr().writeStreamingAll(io, &buffer);
        }
        return;
    }
    if (args.len != 4) return error.MissingConfiguration;

    var native: process.Native = .{ .environ = init.minimal.environ, .guardian_path = if (args[3].len == 0) null else args[3] };
    const spawner = native.interface();
    var cancelled: foo.io.Cancellation = .{};
    var clock_io = io;
    const op: foo.io.Context = .{
        .io = io,
        .cancellation = &cancelled,
        .clock = .{ .context = &clock_io, .now_fn = now },
    };
    const cwd = try std.process.currentPathAlloc(io, init.arena.allocator());
    const executable = args[2];

    if (std.mem.eql(u8, mode, "check-args")) {
        const child = try spawn(spawner, init.gpa, op, cwd, &.{ executable, "args", "one argument", "", "雪", "\\quoted\"$" });
        defer release(child, op);
        const expected_code: i32 = if (builtin.os.tag == .windows) 0x12345678 else 37;
        try expectEqual(foo.io.ProcessExit{ .exited = expected_code }, try child.wait_fn(child.context, op));
        try expectEqual(foo.io.ProcessExit{ .exited = expected_code }, try child.wait_fn(child.context, op));
        var buffer: [32]u8 = undefined;
        const out_len = try child.stdout.read_fn(child.stdout.context, op, &buffer);
        try expectEqualStrings("stdout", buffer[0..out_len]);
        const err_len = try child.stderr.read_fn(child.stderr.context, op, &buffer);
        try expectEqualStrings("stderr", buffer[0..err_len]);
        try expectEqual(0, try child.stdout.read_fn(child.stdout.context, op, &buffer));
        return;
    }
    if (std.mem.eql(u8, mode, "check-signal")) {
        if (builtin.os.tag == .windows) return;
        const child = try spawn(spawner, init.gpa, op, cwd, &.{ executable, "signal" });
        defer release(child, op);
        try expectEqual(foo.io.ProcessExit{ .signalled = 15 }, try child.wait_fn(child.context, op));
        return;
    }
    if (std.mem.eql(u8, mode, "check-tree-deadline") or std.mem.eql(u8, mode, "check-tree-cancel") or std.mem.eql(u8, mode, "check-owner-death")) {
        const child = try spawn(spawner, init.gpa, op, cwd, &.{ executable, "tree", executable });
        defer release(child, op);
        try awaitHeartbeat(io);
        if (std.mem.eql(u8, mode, "check-owner-death")) {
            try std.Io.File.stdout().writeStreamingAll(io, "ready\n");
            _ = try child.wait_fn(child.context, op);
            return error.OwnerShouldHaveBeenKilled;
        }
        var buffer: [32]u8 = undefined;
        var limited = op;
        if (std.mem.eql(u8, mode, "check-tree-deadline")) {
            limited.deadline_ms = now(&clock_io) + 50;
            try std.testing.expectError(error.DeadlineExceeded, child.stderr.read_fn(child.stderr.context, limited, &buffer));
        } else {
            var request = try io.concurrent(requestCancel, .{ io, &cancelled });
            defer request.await(io);
            try std.testing.expectError(error.Cancelled, child.stdout.read_fn(child.stdout.context, op, &buffer));
        }
        var cleanup_token: foo.io.Cancellation = .{};
        const cleanup = cleanupOperation(op, &cleanup_token);
        try child.terminate_fn(child.context, cleanup);
        _ = try child.wait_fn(child.context, cleanup);
        return;
    }
    if (std.mem.eql(u8, mode, "check-leader-exit")) {
        const child = try spawn(spawner, init.gpa, op, cwd, &.{ executable, "leader-exit", executable });
        defer release(child, op);
        try expectEqual(foo.io.ProcessExit{ .exited = 0 }, try child.wait_fn(child.context, op));
        return;
    }
    if (std.mem.eql(u8, mode, "check-exec")) {
        return checkExec(init, op, spawner, cwd, executable);
    }
    return error.UnknownMode;
}

fn checkExec(init: std.process.Init, op: foo.io.Context, spawner: foo.io.Spawner, cwd: []const u8, executable: []const u8) !void {
    const allocator = init.arena.allocator();
    const payload = try allocator.alloc(u8, stream_size);
    @memset(payload, 'x');
    payload[0] = '"';
    payload[payload.len - 1] = '"';
    const options: exec.Options = .{
        .spawner = spawner,
        .cwd = cwd,
        .output_bytes = 1024,
        .spool = .{ .directory = .cwd(), .max_bytes = frame_cap },
    };
    const valid = try exec.run(allocator, op, "a", .{ .argv = &.{ executable, "protocol" }, .input = payload }, options);
    try expectEqual(.success, valid.status);
    try expectEqual(.observed, valid.effect);
    try expectEqualStrings("hello from child", valid.content);
    try expect(valid.truncated);
    try checkSpool(allocator, op.io, valid.artifact.?);
    const invalid = try exec.run(allocator, op, "b", .{ .argv = &.{ executable, "invalid-json" }, .input = "" }, options);
    try expectEqual(.failure, invalid.status);
    try expect(std.mem.indexOf(u8, invalid.content, "InvalidReply") != null);
    const bounded = try exec.runCommand(allocator, op, "c", &.{ executable, "large" }, options);
    try expectEqual(.success, bounded.status);
    try expect(bounded.truncated);
    try expect(std.mem.indexOf(u8, bounded.content, "\"stdout_bytes\":262144") != null);
    try expect(std.mem.indexOf(u8, bounded.content, "\"stderr_bytes\":262144") != null);
    try checkSpool(allocator, op.io, bounded.artifact.?);
    const closed = try exec.run(allocator, op, "closed", .{ .argv = &.{ executable, "closed-stdin" }, .input = payload }, options);
    try expectEqual(.failure, closed.status);
    try expect(std.mem.indexOf(u8, closed.content, "\"exit_code\":31") != null);
    try expect(std.mem.indexOf(u8, closed.content, "cmVqZWN0ZWQ=") != null);
    var invalid_options = options;
    invalid_options.spool.?.max_bytes = 4;
    const rejected = try exec.runCommand(allocator, op, "d", &.{ executable, "large" }, invalid_options);
    try expectEqual(.not_started, rejected.effect);
    try expectEqual(null, rejected.artifact);
}

fn checkSpool(allocator: std.mem.Allocator, io: std.Io, artifact: foo.tool.Artifact) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, artifact.relative_path, allocator, .limited(frame_cap + 1));
    try expectEqual(artifact.bytes, bytes.len);
    try expect(bytes.len <= frame_cap and bytes.len >= frame_cap - 5);
    var cursor: usize = 0;
    while (cursor < bytes.len) {
        try expect(cursor + 5 <= bytes.len);
        try expect(bytes[cursor] == 1 or bytes[cursor] == 2);
        const size = std.mem.readInt(u32, bytes[cursor + 1 ..][0..4], .little);
        cursor += 5 + size;
        try expect(cursor <= bytes.len);
    }
}

fn spawn(spawner: foo.io.Spawner, allocator: std.mem.Allocator, op: foo.io.Context, cwd: []const u8, argv: []const []const u8) !foo.io.Child {
    return spawner.spawn_fn(spawner.context, allocator, op, .{ .argv = argv, .cwd = cwd, .environment = &.{.{ .name = "F05_FIXTURE", .value = "hello" }} });
}

fn now(context: *anyopaque) u64 {
    const io: *std.Io = @ptrCast(@alignCast(context));
    return @intCast(std.Io.Clock.awake.now(io.*).toMilliseconds());
}

fn cleanupOperation(op: foo.io.Context, token: *const foo.io.Cancellation) foo.io.Context {
    return .{ .io = op.io, .clock = op.clock, .cancellation = token, .deadline_ms = op.clock.now() + 2000 };
}

fn release(child: foo.io.Child, op: foo.io.Context) void {
    var token: foo.io.Cancellation = .{};
    child.release_fn(child.context, cleanupOperation(op, &token)) catch |err| @panic(@errorName(err));
}

fn requestCancel(io: std.Io, token: *foo.io.Cancellation) void {
    io.sleep(.fromMilliseconds(80), .awake) catch return;
    token.request();
}

fn heartbeat(io: std.Io) !void {
    const file = try std.Io.Dir.cwd().createFile(io, "heartbeat", .{});
    defer file.close(io);
    for (0..400) |offset| {
        try file.writePositionalAll(io, ".", offset);
        try io.sleep(.fromMilliseconds(25), .awake);
    }
}

fn awaitHeartbeat(io: std.Io) !void {
    for (0..300) |_| {
        if (std.Io.Dir.cwd().statFile(io, "heartbeat", .{})) |stat| {
            if (stat.size > 1) return;
        } else |err| if (err != error.FileNotFound) return err;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.DescendantDidNotStart;
}
