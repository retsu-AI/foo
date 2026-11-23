const std = @import("std");
const foo = @import("foo");
const mcp = @import("mcp");
const process = @import("process");
const Stdio = mcp.Stdio;
const link = mcp.link;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const modern: foo.config.McpRevision = .@"2026-07-28";
const legacy: foo.config.McpRevision = .@"2025-11-25";
const modern_meta = "{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}";

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 5) return error.MissingMode;
    const mode = args[1];
    const blocked = eql(mode, "blocked-stdin");
    const guardian = if (args[4].len > 0) args[4] else null;
    var native: process.Native = .{ .environ = init.minimal.environ, .guardian_path = guardian };
    var token: foo.io.Cancellation = .{};
    var clock_io = init.io;
    const op: foo.io.Context = .{
        .io = init.io,
        .clock = .{ .context = &clock_io, .now_fn = now },
        .cancellation = &token,
        .deadline_ms = now(&clock_io) + 10_000,
    };
    const stdio = try Stdio.init(init.gpa, op, native.interface(), .{
        .argv = &.{ args[2], args[3], mode, "one argument", "quote\"$ &" },
        .cwd = try std.process.currentPathAlloc(init.io, allocator),
        .environment = &.{.{ .name = "FOO_MCP_FIXTURE", .value = "child" }},
        .inherit_environment = true,
    }, .{
        .limits = .{ .wire_message_bytes = if (blocked) 2 * 1024 * 1024 else 1024, .server_stderr_bytes = 64 },
        .write_timeout_ms = if (blocked) 250 else 1000,
        .shutdown_grace_ms = if (eql(mode, "tree")) 300 else 1000,
    });
    defer stdio.deinit(op) catch |err| @panic(@errorName(err));
    errdefer if (stdio.stderrSnapshot(allocator)) |diagnostics| {
        std.debug.print("child stderr: {s}\n", .{diagnostics.stderr});
    } else |_| {};

    if (blocked) return checkBlockedWrite(stdio, allocator, op);
    if (eql(mode, "modern")) return checkModern(stdio, init.gpa, allocator, op);
    if (eql(mode, "legacy")) return checkLegacy(stdio, allocator, op);
    if (eql(mode, "slow") or eql(mode, "cancel") or eql(mode, "tree")) return checkInterrupted(stdio, allocator, op, mode);

    var delivery: foo.io.Delivery = .unsent;
    const result = exchange(stdio, allocator, op, legacy, .{ .number = 1 }, "tools/call", .request, "{}", null, &delivery);
    if (eql(mode, "death")) {
        try std.testing.expectError(error.Disconnected, result);
        try expectEqual(.possibly_sent, delivery);
        try std.testing.expectError(error.Disconnected, exchange(stdio, allocator, op, legacy, .{ .number = 2 }, "tools/call", .request, "{}", null, &delivery));
        try expectEqual(.unsent, delivery);
    } else {
        try std.testing.expectError(if (eql(mode, "oversized")) error.LimitExceeded else error.MalformedPeer, result);
        try expectEqual(.possibly_sent, delivery);
    }
}

fn checkModern(stdio: *Stdio, concurrent_allocator: std.mem.Allocator, allocator: std.mem.Allocator, op: foo.io.Context) !void {
    var delivery: foo.io.Delivery = .unsent;
    const discovered = try exchange(stdio, allocator, op, modern, .{ .number = 1 }, "server/discover", .request, modern_meta, null, &delivery);
    try expectEqual(.possibly_sent, delivery);
    try expect(std.mem.indexOf(u8, discovered.success, "雪\\nstdio") != null);

    var watcher: Subscription = .{};
    var watching = op;
    watching.cancellation = &watcher.stop;
    var future = try op.io.concurrent(Subscription.run, .{ &watcher, stdio, concurrent_allocator, watching, foo.jsonrpc.Id{ .string = "2" } });
    defer {
        watcher.release_ack.set(op.io);
        watcher.stop.request();
        _ = future.await(op.io) catch {};
    }
    try wait(&watcher.acknowledged, op.io);
    const regular = try exchange(stdio, allocator, op, modern, .{ .number = 2 }, "tools/list", .request, modern_meta, null, &delivery);
    try expectEqualStrings("{\"tools\": []}", regular.success);
    watcher.release_ack.set(op.io);
    try wait(&watcher.changed, op.io);
    const rejected = try exchange(stdio, allocator, op, modern, .{ .number = 3 }, "tools/list", .request, modern_meta, null, &delivery);
    try expectEqual(-32602, rejected.failure.code);
    try expectEqualStrings("bad request\n雪", rejected.failure.message);
    try expectEqualStrings("{\"fixture\": true}", rejected.failure.data_json.?);

    watcher.stop.request();
    try std.testing.expectError(error.Cancelled, future.await(op.io));
    try expectEqual(.possibly_sent, watcher.delivery);
    _ = try exchange(stdio, allocator, op, modern, .{ .number = 4 }, "ping", .request, modern_meta, null, &delivery);

    var peer_ended: Subscription = .{};
    peer_ended.release_ack.set(op.io);
    try std.testing.expectError(error.Disconnected, peer_ended.run(stdio, concurrent_allocator, op, .{ .number = 5 }));
    try wait(&peer_ended.acknowledged, op.io);
    _ = try exchange(stdio, allocator, op, modern, .{ .number = 6 }, "ping", .request, modern_meta, null, &delivery);
    try stdio.interface().shutdown(op);
    try stdio.interface().shutdown(op);
}

const Subscription = struct {
    stop: foo.io.Cancellation = .{},
    acknowledged: std.Io.Event = .unset,
    release_ack: std.Io.Event = .unset,
    changed: std.Io.Event = .unset,
    delivery: foo.io.Delivery = .unsent,

    fn run(self: *Subscription, stdio: *Stdio, allocator: std.mem.Allocator, op: foo.io.Context, id: foo.jsonrpc.Id) link.Error!void {
        const observer: link.Observer = .{ .context = self, .notify_fn = notify };
        const result = try exchange(stdio, allocator, op, modern, id, "subscriptions/listen", .subscription, modern_meta, observer, &self.delivery);
        switch (result) {
            .accepted => {},
            .success => |raw| allocator.free(raw),
            .failure => |failure| {
                allocator.free(failure.message);
                if (failure.data_json) |raw| allocator.free(raw);
            },
        }
    }

    fn notify(raw: *anyopaque, op: foo.io.Context, message: foo.jsonrpc.Request) foo.io.Error!void {
        const self: *Subscription = @ptrCast(@alignCast(raw));
        if (eql(message.method, "notifications/subscriptions/acknowledged")) {
            self.acknowledged.set(op.io);
            wait(&self.release_ack, op.io) catch return error.DeadlineExceeded;
        } else if (eql(message.method, "notifications/tools/list_changed")) {
            self.changed.set(op.io);
        } else return error.InvalidInput;
    }
};

fn checkLegacy(stdio: *Stdio, allocator: std.mem.Allocator, op: foo.io.Context) !void {
    var delivery: foo.io.Delivery = .unsent;
    const initialized = try exchange(stdio, allocator, op, legacy, .{ .number = 1 }, "initialize", .request, "{\"protocolVersion\":\"2025-11-25\"}", null, &delivery);
    try expect(std.mem.indexOf(u8, initialized.success, "2025-11-25") != null);
    const notification = try exchange(stdio, allocator, op, legacy, null, "notifications/initialized", .request, null, null, &delivery);
    try expectEqual(.accepted, notification);
    var observer: LegacyObserver = .{ .method = "notifications/tools/list_changed" };
    const listed = try exchange(stdio, allocator, op, legacy, .{ .number = 2 }, "tools/list", .request, "{}", observer.interface(), &delivery);
    try expectEqualStrings("{\"tools\": []}", listed.success);
    try expectEqual(1, observer.seen);

    var stop: foo.io.Cancellation = .{};
    var listening = op;
    listening.cancellation = &stop;
    var idle: LegacyObserver = .{ .method = "notifications/resources/list_changed", .stop = &stop };
    try std.testing.expectError(error.Cancelled, exchange(stdio, allocator, listening, legacy, null, "", .legacy_notifications, null, idle.interface(), &delivery));
    try expectEqual(.unsent, delivery);
    try expectEqual(1, idle.seen);
    try stdio.shutdown(op);
    const diagnostics = try stdio.stderrSnapshot(allocator);
    try expect(diagnostics.truncated);
    try expectEqual(64, diagnostics.stderr.len);
    try expect(std.mem.startsWith(u8, diagnostics.stderr, "xxxxxxxx"));
}

const LegacyObserver = struct {
    method: []const u8,
    stop: ?*foo.io.Cancellation = null,
    seen: usize = 0,

    fn interface(self: *LegacyObserver) link.Observer {
        return .{ .context = self, .notify_fn = notify };
    }

    fn notify(raw: *anyopaque, _: foo.io.Context, message: foo.jsonrpc.Request) foo.io.Error!void {
        const self: *LegacyObserver = @ptrCast(@alignCast(raw));
        if (!eql(message.method, self.method) or message.id != null) return error.InvalidInput;
        self.seen += 1;
        if (self.stop) |token| token.request();
    }
};

fn checkInterrupted(stdio: *Stdio, allocator: std.mem.Allocator, op: foo.io.Context, mode: []const u8) !void {
    const slow = eql(mode, "slow");
    const tree = eql(mode, "tree");
    var delivery: foo.io.Delivery = .unsent;
    var token: foo.io.Cancellation = .{};
    var interrupted = op;
    interrupted.cancellation = &token;
    if (slow) {
        _ = try exchange(stdio, allocator, op, legacy, .{ .number = 1 }, "ping", .request, "{}", null, &delivery);
        interrupted.deadline_ms = op.clock.now() + 500;
    }
    var observer: LegacyObserver = .{ .method = "notifications/progress", .stop = &token };
    const result = exchange(stdio, allocator, interrupted, legacy, .{ .string = "7" }, "tools/call", .request, "{}", if (slow) null else observer.interface(), &delivery);
    try std.testing.expectError(if (slow) error.DeadlineExceeded else error.Cancelled, result);
    try expectEqual(.possibly_sent, delivery);
    try expectEqual(if (slow) @as(usize, 0) else 1, observer.seen);
    const subsequent = try exchange(stdio, allocator, op, legacy, .{ .number = 7 }, "ping", .request, "{}", null, &delivery);
    try expectEqualStrings(if (tree) "{}" else "{\"late\": false}", subsequent.success);
    try stdio.shutdown(op);
}

fn checkBlockedWrite(stdio: *Stdio, allocator: std.mem.Allocator, op: foo.io.Context) !void {
    const payload = try allocator.alloc(u8, 1024 * 1024);
    @memset(payload, 'x');
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = 1,
        .method = "tools/call",
        .params = .{ .payload = payload },
    }, .{});
    var delivery: foo.io.Delivery = .unsent;
    const result = stdio.interface().exchange(allocator, op, .{
        .revision = legacy,
        .id = .{ .number = 1 },
        .method = "tools/call",
        .body = body,
    }, null, &delivery);
    try std.testing.expectError(error.DeadlineExceeded, result);
    try expectEqual(.possibly_sent, delivery);
    try std.testing.expectError(error.Disconnected, exchange(stdio, allocator, op, legacy, .{ .number = 2 }, "ping", .request, "{}", null, &delivery));
    try expectEqual(.unsent, delivery);
    try stdio.shutdown(op);
}

fn exchange(stdio: *Stdio, allocator: std.mem.Allocator, op: foo.io.Context, revision: foo.config.McpRevision, id: ?foo.jsonrpc.Id, method: []const u8, mode: link.Mode, params: ?[]const u8, observer: ?link.Observer, delivery: *foo.io.Delivery) link.Error!link.Reply {
    var buffer: [1024]u8 = undefined;
    const body = if (mode == .legacy_notifications) "" else foo.wire.jsonrpc.encodeRequest(&buffer, .{ .id = id, .method = method, .params_json = params }, .{}) catch return error.InvalidInput;
    return stdio.interface().exchange(allocator, op, .{
        .revision = revision,
        .id = id,
        .method = method,
        .mode = mode,
        .body = body,
    }, observer, delivery);
}

fn wait(event: *std.Io.Event, io: std.Io) !void {
    try event.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
}

fn now(context: *anyopaque) u64 {
    const io: *std.Io = @ptrCast(@alignCast(context));
    return @intCast(std.Io.Clock.awake.now(io.*).toMilliseconds());
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
