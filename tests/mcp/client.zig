const std = @import("std");
const foo = @import("foo");
const mcp = @import("mcp");
const t = std.testing;
const modern: foo.config.McpRevision = .@"2026-07-28";
const legacy: foo.config.McpRevision = .@"2025-11-25";

const discover =
    \\{"resultType":"complete","supportedVersions":["2026-07-28","2025-11-25"],"capabilities":{"tools":{"listChanged":true},"resources":{}}}
;
const initialize =
    \\{"protocolVersion":"2025-11-25","serverInfo":{"name":"fixture","version":"1"},"capabilities":{"tools":{}}}
;

const Step = struct {
    method: []const u8,
    revision: foo.config.McpRevision,
    output: union(enum) { result: []const u8, failure: foo.jsonrpc.RpcError, accepted, fault: mcp.link.Error, wait_for_ack },
    notifications: []const foo.jsonrpc.Request = &.{},
};

const Fixture = struct {
    steps: []const Step,
    calls: usize = 0,
    token: foo.io.Cancellation = .{},

    fn op(self: *Fixture) foo.io.Context {
        return .{ .io = t.io, .cancellation = &self.token, .clock = .{ .context = self, .now_fn = now } };
    }

    fn now(_: *anyopaque) u64 {
        return @intCast(std.Io.Clock.awake.now(t.io).toMilliseconds());
    }

    fn wire(self: *Fixture) mcp.link.Link {
        return .{ .context = self, .exchange_fn = exchange, .shutdown_fn = shutdown };
    }

    fn shutdown(_: *anyopaque, _: foo.io.Context) mcp.link.Error!void {}

    fn exchange(context: *anyopaque, allocator: std.mem.Allocator, operation: foo.io.Context, request: mcp.link.Request, observer: ?mcp.link.Observer, delivery: *foo.io.Delivery) mcp.link.Error!mcp.link.Reply {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (self.calls == self.steps.len) return error.InvalidInput;
        const step = self.steps[self.calls];
        self.calls += 1;
        if (!std.mem.eql(u8, step.method, request.method) or step.revision != request.revision)
            return error.InvalidInput;

        const args = std.json.parseFromSlice(std.json.Value, allocator, request.body, .{}) catch return error.MalformedPeer;
        defer args.deinit();
        if (args.value != .object) return error.MalformedPeer;
        const params = args.value.object.get("params") orelse return error.MalformedPeer;
        if (params != .object) return error.MalformedPeer;
        const id = args.value.object.get("id");
        if (request.id) |expected| {
            if (id == null or id.? != .integer or expected != .number or expected.number != id.?.integer)
                return error.InvalidInput;
        } else if (id != null) return error.InvalidInput;
        const meta = params.object.get("_meta");
        if (request.revision == modern) {
            if (meta == null or meta.? != .object) return error.InvalidInput;
            const version = meta.?.object.get("io.modelcontextprotocol/protocolVersion") orelse return error.InvalidInput;
            const info = meta.?.object.get("io.modelcontextprotocol/clientInfo") orelse return error.InvalidInput;
            const caps = meta.?.object.get("io.modelcontextprotocol/clientCapabilities") orelse return error.InvalidInput;
            if (version != .string or !std.mem.eql(u8, version.string, @tagName(modern)) or info != .object or caps != .object)
                return error.InvalidInput;
        } else if (meta != null) return error.InvalidInput;
        if (std.mem.eql(u8, request.method, "initialize")) {
            const version = params.object.get("protocolVersion") orelse return error.InvalidInput;
            if (version != .string or !std.mem.eql(u8, version.string, @tagName(legacy))) return error.InvalidInput;
        }

        delivery.* = .possibly_sent;
        for (step.notifications) |message| try mcp.link.Observer.notify(observer, operation, message);
        return switch (step.output) {
            .result => |result| .{ .success = try allocator.dupe(u8, result) },
            .failure => |failure| .{ .failure = failure },
            .accepted => .accepted,
            .fault => |reason| reason,
            .wait_for_ack => {
                while (true) {
                    try operation.check();
                    operation.io.sleep(.fromMilliseconds(5), .awake) catch return error.Cancelled;
                }
            },
        };
    }
};

test "modern discovery and per-request metadata complete without a legacy handshake" {
    var f: Fixture = .{ .steps = &.{
        .{ .method = "server/discover", .revision = modern, .output = .{ .result = discover } },
        .{ .method = "tools/list", .revision = modern, .output = .{ .result = "{\"resultType\":\"complete\",\"tools\":[]}" } },
    } };
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    var connection = try mcp.Client.init(f.wire(), .{ .server_id = "fixture" });
    const profile = try connection.connect(a.allocator(), f.op());
    try t.expectEqual(modern, profile.revision);
    try t.expect(profile.capabilities.tools and profile.capabilities.tools_changed);
    var delivery: foo.io.Delivery = .unsent;
    const result = try connection.request(a.allocator(), f.op(), "tools/list", .empty, .{}, &delivery);
    try t.expectEqual(.complete, result.kind);
    try t.expectEqual(.array, std.meta.activeTag(result.fields.get("tools").?));
    try t.expectEqual(.possibly_sent, delivery);
    try t.expectEqual(@as(usize, 2), f.calls);
}

test "auto probes legacy only on explicit compatibility signals" {
    const signals = [_]Step{
        .{ .method = "server/discover", .revision = modern, .output = .{ .fault = error.UnsupportedRevision } },
        .{ .method = "server/discover", .revision = modern, .output = .{ .failure = .{ .code = -32601, .message = "unknown method" } } },
        .{ .method = "server/discover", .revision = modern, .output = .{ .failure = .{ .code = -32022, .message = "unsupported", .data_json = "{\"supported\":[\"2025-11-25\"]}" } } },
    };
    for (signals) |signal| {
        var f: Fixture = .{ .steps = &.{
            signal,
            .{ .method = "initialize", .revision = legacy, .output = .{ .result = initialize } },
            .{ .method = "notifications/initialized", .revision = legacy, .output = .accepted },
            .{ .method = "tools/list", .revision = legacy, .output = .{ .result = "{\"tools\":[]}" } },
        } };
        var a: std.heap.ArenaAllocator = .init(t.allocator);
        defer a.deinit();
        var connection = try mcp.Client.init(f.wire(), .{ .server_id = "fixture" });
        try t.expectEqual(legacy, (try connection.connect(a.allocator(), f.op())).revision);
        var delivery: foo.io.Delivery = .unsent;
        _ = try connection.request(a.allocator(), f.op(), "tools/list", .empty, .{}, &delivery);
        try t.expectEqual(@as(usize, 4), f.calls);
    }
}

test "authentication failures, disconnects, and explicit revision pins cannot force downgrade" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    for ([_]mcp.link.Error{ error.UnsupportedAuthentication, error.Disconnected, error.MalformedPeer, error.UnsupportedRevision }) |failure| {
        var f: Fixture = .{ .steps = &.{.{ .method = "server/discover", .revision = modern, .output = .{ .fault = failure } }} };
        var connection = try mcp.Client.init(f.wire(), .{
            .server_id = "fixture",
            .revision = if (failure == error.UnsupportedRevision) modern else null,
        });
        try t.expectError(failure, connection.connect(a.allocator(), f.op()));
        try t.expectEqual(@as(usize, 1), f.calls);
    }
}

test "legacy expiry requires an explicit new handshake, without replaying an effect" {
    var f: Fixture = .{ .steps = &.{
        .{ .method = "initialize", .revision = legacy, .output = .{ .result = initialize } },
        .{ .method = "notifications/initialized", .revision = legacy, .output = .accepted },
        .{ .method = "tools/call", .revision = legacy, .output = .{ .fault = error.SessionExpired } },
        .{ .method = "initialize", .revision = legacy, .output = .{ .result = initialize } },
        .{ .method = "notifications/initialized", .revision = legacy, .output = .accepted },
    } };
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    var connection = try mcp.Client.init(f.wire(), .{ .server_id = "fixture", .revision = legacy });
    _ = try connection.connect(a.allocator(), f.op());
    var delivery: foo.io.Delivery = .unsent;
    try t.expectError(error.SessionExpired, connection.request(a.allocator(), f.op(), "tools/call", .empty, .{}, &delivery));
    try t.expectEqual(.possibly_sent, delivery);
    try t.expectError(error.SessionExpired, connection.request(a.allocator(), f.op(), "tools/call", .empty, .{}, &delivery));
    try t.expectEqual(.unsent, delivery);
    try t.expectEqual(@as(usize, 3), f.calls);
    _ = try connection.connect(a.allocator(), f.op());
    try t.expectEqual(@as(usize, 5), f.calls);
}

test "unsupported modern input request preserves opaque state and is never replayed" {
    var f: Fixture = .{ .steps = &.{
        .{ .method = "server/discover", .revision = modern, .output = .{ .result = discover } },
        .{ .method = "tools/call", .revision = modern, .output = .{ .result = "{\"resultType\":\"input_required\",\"requestState\":\" snow 雪 \\r\\n\"}" } },
    } };
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    var connection = try mcp.Client.init(f.wire(), .{ .server_id = "fixture" });
    _ = try connection.connect(a.allocator(), f.op());
    var delivery: foo.io.Delivery = .unsent;
    const result = try connection.request(a.allocator(), f.op(), "tools/call", .empty, .{}, &delivery);
    try t.expectEqual(.input_required, std.meta.activeTag(result.kind));
    try t.expectEqualStrings(" snow 雪 \r\n", result.kind.input_required.?);
    try t.expectEqual(@as(usize, 2), f.calls);
}

const ack: foo.jsonrpc.Request = .{ .id = null, .method = "notifications/subscriptions/acknowledged", .params_json =
    \\{"_meta":{"io.modelcontextprotocol/subscriptionId":2},"notifications":{"toolsListChanged":true}}
};
const tool_change: foo.jsonrpc.Request = .{ .id = null, .method = "notifications/tools/list_changed", .params_json =
    \\{"_meta":{"io.modelcontextprotocol/subscriptionId":2}}
};
const closed =
    \\{"resultType":"complete","_meta":{"io.modelcontextprotocol/subscriptionId":2}}
;

test "subscription accepts only acknowledged and correlated catalog notifications" {
    for ([_][]const foo.jsonrpc.Request{ &.{ ack, tool_change }, &.{ tool_change, ack }, &.{ack} }, 0..) |messages, index| {
        var f: Fixture = .{ .steps = &.{
            .{ .method = "server/discover", .revision = modern, .output = .{ .result = discover } },
            .{ .method = "subscriptions/listen", .revision = modern, .notifications = messages, .output = .{ .result = closed } },
        } };
        var a: std.heap.ArenaAllocator = .init(t.allocator);
        defer a.deinit();
        var connection = try mcp.Client.init(f.wire(), .{ .server_id = "fixture" });
        _ = try connection.connect(a.allocator(), f.op());
        if (index == 1) {
            try t.expectError(error.InvalidInput, connection.listen(a.allocator(), f.op()));
        } else {
            try connection.listen(a.allocator(), f.op());
        }
        try t.expectEqual(@as(u64, if (index == 0) 2 else 1), connection.epoch());
    }
}

test "modern subscription has a separate acknowledgment deadline" {
    var f: Fixture = .{ .steps = &.{
        .{ .method = "server/discover", .revision = modern, .output = .{ .result = discover } },
        .{ .method = "subscriptions/listen", .revision = modern, .output = .wait_for_ack },
    } };
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    var connection = try mcp.Client.init(f.wire(), .{ .server_id = "fixture", .handshake_ms = 60 });
    _ = try connection.connect(a.allocator(), f.op());
    var deadline = f.op();
    deadline.deadline_ms = deadline.clock.now() + 2_000;
    try t.expectError(error.DeadlineExceeded, connection.listen(a.allocator(), deadline));
    try t.expect(!f.token.requested.load(.acquire));
}
