const std = @import("std");
const foo = @import("foo");
const mcp = @import("mcp");
const t = std.testing;
const io = foo.io;
const link = mcp.link;
const Http = mcp.Http;

const url = "https://mcp.example.test/service";
const modern: foo.config.McpRevision = .@"2026-07-28";
const legacy: foo.config.McpRevision = .@"2025-11-25";
const meta = "\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}";
const json = [_]io.Header{.{ .name = "content-type", .value = "application/json; charset=utf-8" }};
const sse = [_]io.Header{.{ .name = "Content-Type", .value = "text/event-stream" }};
const established = [_]io.Header{ json[0], .{ .name = "mcp-session-id", .value = "session-1" } };
const legacy_headers = [_]ExpectedHeader{
    .{ .name = "MCP-Protocol-Version", .value = "2025-11-25" },
    .{ .name = "MCP-Session-Id", .value = "session-1" },
    .{ .name = "Mcp-Method", .value = null },
};
const init_step: Step = .{
    .headers = &.{
        .{ .name = "MCP-Protocol-Version", .value = null },
        .{ .name = "MCP-Session-Id", .value = null },
    },
    .body_part = "\"method\":\"initialize\"",
    .response_headers = &established,
    .chunks = &.{"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-11-25\"}}"},
};
const initialized_step: Step = .{
    .headers = &legacy_headers,
    .body_part = "\"method\":\"notifications/initialized\"",
    .status = 202,
};
const initialized_request: link.Request = .{
    .revision = legacy,
    .id = null,
    .method = "notifications/initialized",
    .body = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
};

fn initialize(client: link.Link, op: io.Context) !void {
    const reply = try call(client, op, legacyRequest(1, "initialize", "{\"protocolVersion\":\"2025-11-25\"}"), null);
    defer release(reply);
    try t.expectEqualStrings("{\"protocolVersion\":\"2025-11-25\"}", reply.success);
    const ack = try call(client, op, initialized_request, null);
    try t.expectEqual(link.Reply.accepted, ack);
}

const ExpectedHeader = struct { name: []const u8, value: ?[]const u8 };
const Step = struct {
    method: @FieldType(io.HttpRequest, "method") = .post,
    headers: []const ExpectedHeader = &.{},
    body_part: ?[]const u8 = null,
    status: u16 = 200,
    response_headers: []const io.Header = &.{},
    chunks: []const []const u8 = &.{},
    outcome: ?io.Error = null,
    cancel: bool = false,
    send: bool = true,
};

const Script = struct {
    steps: []const Step,
    next: usize = 0,
    cancellation: ?*io.Cancellation = null,

    fn transport(self: *Script) io.HttpTransport {
        return .{ .context = self, .exchange_fn = exchange };
    }

    fn exchange(raw: *anyopaque, op: io.Context, request: io.HttpRequest, sink: io.HttpSink, delivery: *io.Delivery) io.Error!void {
        const self: *Script = @ptrCast(@alignCast(raw));
        t.expect(self.next < self.steps.len) catch return error.InvalidInput;
        const step = self.steps[self.next];
        self.next += 1;

        t.expectEqual(step.method, request.method) catch return error.InvalidInput;
        t.expectEqualStrings(url, request.url) catch return error.InvalidInput;
        if (step.body_part) |needle| {
            t.expect(std.mem.indexOf(u8, request.body.bytes, needle) != null) catch return error.InvalidInput;
        } else if (request.method != .post) {
            t.expectEqualStrings("", request.body.bytes) catch return error.InvalidInput;
        }
        for (step.headers) |wanted| {
            var actual: ?[]const u8 = null;
            for (request.headers) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, wanted.name)) {
                    t.expect(actual == null) catch return error.InvalidInput;
                    actual = header.value;
                }
            }
            if (wanted.value) |value| {
                t.expectEqualStrings(value, actual orelse return error.InvalidInput) catch return error.InvalidInput;
            } else {
                t.expect(actual == null) catch return error.InvalidInput;
            }
        }
        if (!step.send) return step.outcome orelse error.Disconnected;
        delivery.* = .possibly_sent;
        try sink.head_fn(sink.context, op, .{ .status = step.status, .headers = step.response_headers });
        for (step.chunks) |bytes| try sink.body.write(op, bytes);
        if (step.cancel) {
            self.cancellation.?.request();
            return error.Cancelled;
        }
        if (step.outcome) |err| return err;
    }

    fn done(self: Script) !void {
        try t.expectEqual(self.steps.len, self.next);
    }
};

fn opFor(cancellation: *const io.Cancellation) io.Context {
    return .{ .io = t.io, .cancellation = cancellation, .clock = .{ .context = @constCast(cancellation), .now_fn = now } };
}

fn now(_: *anyopaque) u64 {
    return @intCast(std.Io.Clock.awake.now(t.io).toMilliseconds());
}

fn call(client: link.Link, op: io.Context, request: link.Request, observer: ?link.Observer) !link.Reply {
    var delivery: io.Delivery = .unsent;
    return client.exchange(t.allocator, op, request, observer, &delivery);
}

fn release(reply: link.Reply) void {
    switch (reply) {
        .accepted => {},
        .success => |value| t.allocator.free(value),
        .failure => |failure| {
            t.allocator.free(failure.message);
            if (failure.data_json) |value| t.allocator.free(value);
        },
    }
}

fn legacyRequest(comptime id: i64, comptime method: []const u8, comptime params: []const u8) link.Request {
    return .{
        .revision = legacy,
        .id = .{ .number = id },
        .method = method,
        .body = std.fmt.comptimePrint("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params }),
    };
}

fn modernRequest(comptime id: i64, comptime method: []const u8, comptime args: []const u8) link.Request {
    return .{
        .revision = modern,
        .id = .{ .number = id },
        .method = method,
        .body = std.fmt.comptimePrint("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{{{s}{s}}}}}", .{ id, method, meta, args }),
    };
}

const Notices = struct {
    seen: usize = 0,
    on_first: ?struct { client: link.Link, op: io.Context } = null,

    fn observer(self: *Notices) link.Observer {
        return .{ .context = self, .notify_fn = notify };
    }

    fn notify(raw: *anyopaque, _: io.Context, request: foo.jsonrpc.Request) io.Error!void {
        const self: *Notices = @ptrCast(@alignCast(raw));
        if (self.on_first) |job| {
            const reply = call(job.client, job.op, modernRequest(2, "ping", ""), null) catch return error.IoFailure;
            defer release(reply);
            t.expectEqualStrings("{}", reply.success) catch return error.IoFailure;
            self.on_first = null;
            t.expectEqualStrings("notifications/subscriptions/acknowledged", request.method) catch return error.IoFailure;
        }
        self.seen += 1;
    }
};

test "modern POST routes mirrored headers and reads JSON or interleaved SSE" {
    var script: Script = .{ .steps = &.{
        .{
            .headers = &.{
                .{ .name = "MCP-Protocol-Version", .value = "2026-07-28" },
                .{ .name = "Mcp-Method", .value = "server/discover" },
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Accept", .value = "application/json, text/event-stream" },
                .{ .name = "MCP-Session-Id", .value = null },
                .{ .name = "Authorization", .value = "Bearer fixture" },
            },
            .body_part = meta,
            .response_headers = &established,
            .chunks = &.{ "{\"jsonrpc\":\"2.", "0\",\"id\":1,\"result\":{\"ok\":true}}" },
        },
        .{
            .headers = &.{
                .{ .name = "MCP-Protocol-Version", .value = "2026-07-28" },
                .{ .name = "Mcp-Method", .value = "tools/call" },
                .{ .name = "Mcp-Name", .value = "=?base64?aMOpbGxv?=" },
                .{ .name = "mcp-param-region", .value = "us-west1" },
                .{ .name = "Mcp-Param-Sentinel", .value = "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=" },
                .{ .name = "Mcp-Param-Line", .value = "=?base64?YQpi?=" },
                .{ .name = "MCP-Session-Id", .value = null },
            },
            .body_part = "\"arguments\":{\"region\":\"us-west1\",\"sentinel\":\"=?base64?literal?=\",\"line\":\"a\\nb\"}",
            .response_headers = &sse,
            .chunks = &.{
                ": heartbeat\r",
                "\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\r\n\r\n",
                "data: {\"jsonrpc\":\"2.0\",\n",
                "data: \"id\":2,\"result\":{\"done\":true}}\n\n",
            },
        },
    } };
    var cancel: io.Cancellation = .{};
    const op = opFor(&cancel);
    var http = try Http.init(.{
        .transport = script.transport(),
        .url = url,
        .headers = &.{.{ .name = "Authorization", .value = "Bearer fixture" }},
        .scratch_allocator = t.allocator,
        .max_message_bytes = 8192,
    });
    defer http.deinit();
    const client = http.interface();
    const discover = try call(client, op, modernRequest(1, "server/discover", ""), null);
    defer release(discover);
    try t.expectEqualStrings("{\"ok\":true}", discover.success);

    var invocation = modernRequest(2, "tools/call", ",\"name\":\"héllo\",\"arguments\":{\"region\":\"us-west1\",\"sentinel\":\"=?base64?literal?=\",\"line\":\"a\\nb\"}");
    invocation.name = "héllo";
    invocation.headers = &.{
        .{ .name = "Mcp-Param-Region", .value = "us-west1" },
        .{ .name = "Mcp-Param-Sentinel", .value = "=?base64?literal?=" },
        .{ .name = "Mcp-Param-Line", .value = "a\nb" },
    };
    var notices: Notices = .{};
    const result = try call(client, op, invocation, notices.observer());
    defer release(result);
    try t.expectEqualStrings("{\"done\":true}", result.success);
    try t.expectEqual(@as(usize, 1), notices.seen);
    try client.shutdown(op);
    try script.done();
}

test "modern subscription stays on its own POST while a normal request completes" {
    var listener: Script = .{ .steps = &.{.{
        .headers = &.{.{ .name = "Mcp-Method", .value = "subscriptions/listen" }},
        .response_headers = &sse,
        .chunks = &.{
            "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1}}}\n\n",
            "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1}}}\n\n",
            "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\"}}\n\n",
        },
    }} };
    var primary: Script = .{ .steps = &.{.{
        .headers = &.{.{ .name = "Mcp-Method", .value = "ping" }},
        .response_headers = &json,
        .chunks = &.{"{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}"},
    }} };
    var cancel: io.Cancellation = .{};
    const op = opFor(&cancel);
    var http = try Http.init(.{
        .transport = primary.transport(),
        .listener = listener.transport(),
        .url = url,
        .scratch_allocator = t.allocator,
        .max_message_bytes = 8192,
    });
    defer http.deinit();

    const client = http.interface();
    var notices: Notices = .{ .on_first = .{ .client = client, .op = op } };
    var request = modernRequest(1, "subscriptions/listen", ",\"notifications\":{\"toolsListChanged\":true}");
    request.mode = .subscription;
    const reply = try call(client, op, request, notices.observer());
    defer release(reply);
    try t.expectEqualStrings("{\"resultType\":\"complete\"}", reply.success);
    try t.expectEqual(@as(usize, 2), notices.seen);
    try listener.done();
    try primary.done();
}

test "legacy resumes a tool POST by cursor and answers reverse requests independently" {
    var main: Script = .{ .steps = &.{
        init_step,
        initialized_step,
        .{
            .headers = &legacy_headers,
            .body_part = "\"method\":\"tools/call\"",
            .response_headers = &sse,
            .chunks = &.{
                "id: first\r\ndata:\r\n\r\n",
                "id: checkpoint\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"peer-id\",\"method\":\"ping\"}\r\n\r\n",
                "retry: 0\r\n\r\n",
                "id: incomplete\r\ndata: {\"json",
            },
            .outcome = error.Disconnected,
        },
        .{
            .method = .get,
            .headers = &.{
                legacy_headers[0],
                legacy_headers[1],
                .{ .name = "Last-Event-ID", .value = "checkpoint" },
                .{ .name = "Accept", .value = "text/event-stream" },
                .{ .name = "Content-Type", .value = null },
            },
            .response_headers = &sse,
            .chunks = &.{
                "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"sampling/createMessage\"}\n\n",
                "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n",
                "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"restored\":true}}\n\n",
            },
        },
        .{ .method = .delete, .headers = &legacy_headers, .status = 204 },
    } };
    var housekeeping: Script = .{ .steps = &.{
        .{ .headers = &legacy_headers, .body_part = "\"id\":\"peer-id\",\"result\":{}", .status = 202 },
        .{ .headers = &legacy_headers, .body_part = "\"id\":2,\"error\":{\"code\":-32601", .status = 202 },
    } };
    var cancel: io.Cancellation = .{};
    const op = opFor(&cancel);
    var http = try Http.init(.{
        .transport = main.transport(),
        .housekeeping = housekeeping.transport(),
        .url = url,
        .scratch_allocator = t.allocator,
        .max_message_bytes = 8192,
    });
    defer http.deinit();
    const client = http.interface();
    try initialize(client, op);

    var notices: Notices = .{};
    const reply = try call(client, op, legacyRequest(2, "tools/call", "{\"name\":\"fixture\"}"), notices.observer());
    defer release(reply);
    try t.expectEqualStrings("{\"restored\":true}", reply.success);
    try t.expectEqual(@as(usize, 1), notices.seen);
    try client.shutdown(op);
    try client.shutdown(op);
    try main.done();
    try housekeeping.done();
}

test "legacy clean EOF resumes from the committed cursor and rejects malformed events" {
    const checkpoint = "id: checkpoint\ndata:\n\nretry: 0\n\n";
    var main: Script = .{ .steps = &.{
        init_step,
        initialized_step,
        .{
            .headers = &legacy_headers,
            .body_part = "\"method\":\"tools/call\"",
            .response_headers = &sse,
            .chunks = &.{ checkpoint, "id: uncommitted\ndata: {\"result\":\"\xe9\x9b" },
        },
        .{
            .method = .get,
            .headers = &.{ legacy_headers[1], .{ .name = "Last-Event-ID", .value = "checkpoint" } },
            .response_headers = &sse,
            .chunks = &.{"data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}\n\n"},
        },
        .{ .response_headers = &sse, .chunks = &.{ checkpoint, "data: \xff\n\n" } },
        .{ .response_headers = &sse, .chunks = &.{ checkpoint, "data: invalid json\n\n" } },
    } };
    var cancel: io.Cancellation = .{};
    const op = opFor(&cancel);
    var http = try Http.init(.{ .transport = main.transport(), .url = url, .scratch_allocator = t.allocator, .max_message_bytes = 8192 });
    defer http.deinit();
    const client = http.interface();
    try initialize(client, op);

    const reply = try call(client, op, legacyRequest(2, "tools/call", "{\"name\":\"fixture\"}"), null);
    defer release(reply);
    try t.expectEqualStrings("{}", reply.success);
    try t.expectError(error.MalformedPeer, call(client, op, legacyRequest(3, "ping", "{}"), null));
    try t.expectError(error.MalformedPeer, call(client, op, legacyRequest(4, "ping", "{}"), null));
    try main.done();
}

const legacy_listener: link.Request = .{ .revision = legacy, .id = null, .method = "", .body = "", .mode = .legacy_notifications };

test "legacy optional listener and teardown tolerate 405 without dropping the session" {
    var main: Script = .{ .steps = &.{
        init_step,
        initialized_step,
        .{ .headers = &legacy_headers, .response_headers = &json, .chunks = &.{"{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}"} },
        .{ .method = .delete, .headers = &legacy_headers, .status = 405, .chunks = &.{"unsupported"} },
    } };
    var listener: Script = .{ .steps = &.{.{
        .method = .get,
        .headers = &.{ legacy_headers[0], legacy_headers[1], .{ .name = "Accept", .value = "text/event-stream" } },
        .status = 405,
    }} };
    var cancel: io.Cancellation = .{};
    const op = opFor(&cancel);
    var http = try Http.init(.{
        .transport = main.transport(),
        .listener = listener.transport(),
        .url = url,
        .scratch_allocator = t.allocator,
        .max_message_bytes = 8192,
    });
    defer http.deinit();
    const client = http.interface();
    try initialize(client, op);
    try t.expectError(error.StreamUnsupported, call(client, op, legacy_listener, null));
    const result = try call(client, op, legacyRequest(2, "ping", "{}"), null);
    defer release(result);
    try t.expectEqualStrings("{}", result.success);
    try client.shutdown(op);
    try main.done();
    try listener.done();
}

test "legacy session expiry reports uncertain delivery and waits for explicit reinitialization" {
    var main: Script = .{ .steps = &.{
        init_step,
        initialized_step,
        .{ .headers = &legacy_headers, .status = 404, .body_part = "\"method\":\"tools/call\"" },
        init_step,
        initialized_step,
        .{ .method = .delete, .headers = &legacy_headers, .status = 204 },
    } };
    var cancel: io.Cancellation = .{};
    const op = opFor(&cancel);
    var http = try Http.init(.{ .transport = main.transport(), .url = url, .scratch_allocator = t.allocator });
    defer http.deinit();
    const client = http.interface();
    try initialize(client, op);

    const request = legacyRequest(2, "tools/call", "{\"name\":\"fixture\"}");
    var delivery: io.Delivery = .unsent;
    try t.expectError(error.SessionExpired, client.exchange(t.allocator, op, request, null, &delivery));
    try t.expectEqual(io.Delivery.possibly_sent, delivery);
    try t.expectError(error.SessionExpired, client.exchange(t.allocator, op, request, null, &delivery));
    try t.expectEqual(io.Delivery.unsent, delivery);
    try initialize(client, op);
    try client.shutdown(op);
    try main.done();
}

test "legacy connect can retry after revision rejection and a failed initialized notification" {
    const server_info = "\"serverInfo\":{\"name\":\"fixture\",\"version\":\"1\"},\"capabilities\":{\"tools\":{}}";
    const fresh_headers = [_]ExpectedHeader{ legacy_headers[0], .{ .name = "MCP-Session-Id", .value = "session-2" }, legacy_headers[2] };
    var other_revision = init_step;
    other_revision.chunks = &.{"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\"," ++ server_info ++ "}}"};
    var handshake = init_step;
    handshake.chunks = &.{"{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"protocolVersion\":\"2025-11-25\"," ++ server_info ++ "}}"};
    var rejected_notification = initialized_step;
    rejected_notification.status = 500;
    var next_handshake = handshake;
    next_handshake.response_headers = &.{ json[0], .{ .name = "MCP-Session-Id", .value = "session-2" } };
    next_handshake.chunks = &.{"{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"protocolVersion\":\"2025-11-25\"," ++ server_info ++ "}}"};
    var accepted_notification = initialized_step;
    accepted_notification.headers = &fresh_headers;
    var main: Script = .{ .steps = &.{
        other_revision,
        handshake,
        rejected_notification,
        next_handshake,
        accepted_notification,
        .{ .method = .delete, .headers = &fresh_headers, .status = 204 },
    } };
    var cancel: io.Cancellation = .{};
    const op = opFor(&cancel);
    var http = try Http.init(.{ .transport = main.transport(), .url = url, .scratch_allocator = t.allocator });
    defer http.deinit();
    const wire = http.interface();
    var client = try mcp.Client.init(wire, .{ .server_id = "fixture", .revision = legacy });

    try t.expectError(error.InvalidInput, call(wire, op, initialized_request, null));
    try t.expectEqual(0, main.next);
    try t.expectError(error.UnsupportedRevision, client.connect(t.allocator, op));
    try t.expectError(error.InvalidInput, call(wire, op, legacyRequest(1, "ping", "{}"), null));
    try t.expectEqual(1, main.next);
    try t.expectError(error.IoFailure, client.connect(t.allocator, op));
    try t.expectError(error.InvalidInput, call(wire, op, legacy_listener, null));
    try t.expectEqual(3, main.next);
    const profile = try client.connect(t.allocator, op);
    try t.expectEqual(legacy, profile.revision);
    try t.expect(profile.capabilities.tools);
    try t.expectError(error.InvalidInput, call(wire, op, initialized_request, null));
    try t.expectEqual(5, main.next);
    try client.shutdown(op);
    try main.done();
}

test "legacy cancellation sends only a notification for a possibly sent request" {
    var cancel: io.Cancellation = .{};
    var main: Script = .{ .cancellation = &cancel, .steps = &.{
        init_step,
        initialized_step,
        .{ .headers = &legacy_headers, .body_part = "\"id\":\"quoted\\\"id\"", .response_headers = &sse, .cancel = true },
        .{ .headers = &legacy_headers, .body_part = "\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\"quoted\\\"id\"}", .status = 202 },
        .{ .headers = &legacy_headers, .send = false, .outcome = error.Cancelled },
    } };
    var http = try Http.init(.{ .transport = main.transport(), .url = url, .scratch_allocator = t.allocator, .max_message_bytes = 8192 });
    defer http.deinit();
    const client = http.interface();
    const op = opFor(&cancel);
    try initialize(client, op);
    var delivery: io.Delivery = .unsent;
    try t.expectError(error.Cancelled, client.exchange(t.allocator, op, .{
        .revision = legacy,
        .method = "tools/call",
        .id = .{ .string = "quoted\"id" },
        .body = "{\"jsonrpc\":\"2.0\",\"id\":\"quoted\\\"id\",\"method\":\"tools/call\",\"params\":{\"name\":\"fixture\"}}",
    }, null, &delivery));
    try t.expectEqual(io.Delivery.possibly_sent, delivery);
    var second: io.Cancellation = .{};
    try t.expectError(error.Cancelled, client.exchange(t.allocator, opFor(&second), legacyRequest(2, "ping", "{}"), null, &delivery));
    try t.expectEqual(io.Delivery.unsent, delivery);
    try main.done();
}

test "legacy resumption has a finite GET budget and honors retry timing within the deadline" {
    const cursor_headers = [_]ExpectedHeader{ legacy_headers[0], legacy_headers[1], .{ .name = "Last-Event-ID", .value = "tool-cursor" } };
    const empty_resume: Step = .{ .method = .get, .headers = &cursor_headers, .response_headers = &sse };
    var main: Script = .{ .steps = &.{
        init_step,
        initialized_step,
        .{ .response_headers = &sse, .chunks = &.{"id: tool-cursor\ndata:\n\nretry: 0\n\n"} },
        empty_resume,
        empty_resume,
        empty_resume,
        .{ .response_headers = &sse, .chunks = &.{"id: tool-cursor\ndata:\n\nretry: 10000\n\n"} },
        .{ .headers = &legacy_headers, .body_part = "\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":3}", .status = 202 },
    } };
    var cancel: io.Cancellation = .{};
    const op = opFor(&cancel);
    var http = try Http.init(.{ .transport = main.transport(), .url = url, .scratch_allocator = t.allocator, .max_message_bytes = 8192 });
    defer http.deinit();
    const client = http.interface();
    try initialize(client, op);
    try t.expectError(error.Disconnected, call(client, op, legacyRequest(2, "tools/call", "{\"name\":\"fixture\"}"), null));

    var limited = op;
    limited.deadline_ms = op.clock.now() + 100;
    try t.expectError(error.DeadlineExceeded, call(client, limited, legacyRequest(3, "tools/call", "{\"name\":\"fixture\"}"), null));
    try main.done();
}

test "modern discovery distinguishes recognized version errors from a legacy probe signal" {
    var main: Script = .{ .steps = &.{
        .{
            .status = 400,
            .response_headers = &json,
            .chunks = &.{"{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32022,\"message\":\"unsupported\",\"data\":{\"supported\":[\"2025-11-25\"]}}}"},
        },
        .{
            .status = 400,
            .response_headers = &json,
            .chunks = &.{"{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":-32020,\"message\":\"mismatched id\"}}"},
        },
        .{ .status = 400, .chunks = &.{"legacy fixture"} },
        .{ .status = 400, .chunks = &.{"legacy fixture"} },
        .{
            .status = 404,
            .response_headers = &json,
            .chunks = &.{"{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"unsupported method\"}}"},
        },
    } };
    var cancel: io.Cancellation = .{};
    const op = opFor(&cancel);
    var http = try Http.init(.{ .transport = main.transport(), .url = url, .scratch_allocator = t.allocator });
    defer http.deinit();
    const client = http.interface();
    const discover = modernRequest(1, "server/discover", "");

    const version = try call(client, op, discover, null);
    defer release(version);
    try t.expectEqual(@as(i32, -32022), version.failure.code);
    try t.expectEqualStrings("{\"supported\":[\"2025-11-25\"]}", version.failure.data_json.?);
    try t.expectError(error.MalformedPeer, call(client, op, discover, null));
    try t.expectError(error.UnsupportedRevision, call(client, op, discover, null));
    try t.expectError(error.IoFailure, call(client, op, modernRequest(1, "tools/call", ",\"name\":\"fixture\""), null));
    const method = try call(client, op, discover, null);
    defer release(method);
    try t.expectEqual(foo.jsonrpc.Code.method_not_found, method.failure.code);
    try main.done();
}

test "modern auth redirects disconnect and cancellation produce no follow-up request" {
    var cancel: io.Cancellation = .{};
    var main: Script = .{ .cancellation = &cancel, .steps = &.{
        .{
            .status = 401,
            .response_headers = &.{.{ .name = "WWW-Authenticate", .value = "Bearer realm=fixture" }},
        },
        .{
            .status = 307,
            .response_headers = &.{.{ .name = "Location", .value = "https://elsewhere.example.test/mcp" }},
        },
        .{
            .response_headers = &sse,
            .chunks = &.{"id: modern-cursor\n: keepalive\n\n"},
            .outcome = error.Disconnected,
        },
        .{ .response_headers = &sse, .cancel = true },
    } };
    var http = try Http.init(.{
        .transport = main.transport(),
        .url = url,
        .headers = &.{.{ .name = "Authorization", .value = "Bearer private" }},
        .scratch_allocator = t.allocator,
        .max_message_bytes = 8192,
    });
    defer http.deinit();
    const client = http.interface();
    const op = opFor(&cancel);
    const request = modernRequest(1, "tools/call", ",\"name\":\"fixture\"");

    var delivery: io.Delivery = .unsent;
    try t.expectError(error.UnsupportedAuthentication, client.exchange(t.allocator, op, request, null, &delivery));
    try t.expectEqual(io.Delivery.possibly_sent, delivery);
    try t.expectError(error.IoFailure, client.exchange(t.allocator, op, request, null, &delivery));
    try t.expectEqual(io.Delivery.possibly_sent, delivery);
    try t.expectError(error.Disconnected, client.exchange(t.allocator, op, request, null, &delivery));
    try t.expectEqual(io.Delivery.possibly_sent, delivery);
    try t.expectError(error.Cancelled, client.exchange(t.allocator, op, request, null, &delivery));
    try t.expectEqual(io.Delivery.possibly_sent, delivery);
    try main.done();
}

test "HTTP rejects contradictory outbound metadata before sending any bytes" {
    var main: Script = .{ .steps = &.{} };
    const transport = main.transport();
    try t.expectError(error.InvalidInput, Http.init(.{
        .transport = transport,
        .url = url,
        .headers = &.{.{ .name = "mcp-PARAM-Tenant", .value = "configured" }},
    }));
    try t.expectError(error.InvalidInput, Http.init(.{
        .transport = transport,
        .url = url,
        .headers = &.{.{ .name = "aUtHoRiZaTiOn", .value = "Bearer a\r\nContent-Type: other" }},
    }));
    try t.expectError(error.InvalidInput, Http.init(.{ .transport = transport, .url = "https://user:private@mcp.example.test/service" }));

    var http = try Http.init(.{ .transport = transport, .url = url, .scratch_allocator = t.allocator });
    defer http.deinit();
    var cancel: io.Cancellation = .{};
    const op = opFor(&cancel);
    const client = http.interface();

    const valid = modernRequest(1, "tools/call", ",\"name\":\"fixture\"");
    var wrong = valid;
    wrong.id = .{ .string = "1" };
    var delivery: io.Delivery = .possibly_sent;
    try t.expectError(error.InvalidInput, client.exchange(t.allocator, op, wrong, null, &delivery));
    try t.expectEqual(io.Delivery.unsent, delivery);
    wrong = valid;
    wrong.name = "different";
    try t.expectError(error.InvalidInput, client.exchange(t.allocator, op, wrong, null, &delivery));
    try t.expectEqual(io.Delivery.unsent, delivery);
    wrong = valid;
    wrong.method = "ping";
    try t.expectError(error.InvalidInput, client.exchange(t.allocator, op, wrong, null, &delivery));
    try t.expectEqual(io.Delivery.unsent, delivery);
    wrong = valid;
    wrong.body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"fixture\",\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2025-11-25\"}}}";
    try t.expectError(error.InvalidInput, client.exchange(t.allocator, op, wrong, null, &delivery));
    try t.expectEqual(io.Delivery.unsent, delivery);
    wrong = valid;
    wrong.headers = &.{
        .{ .name = "Mcp-Param-Tenant", .value = "one" },
        .{ .name = "MCP-PARAM-TENANT", .value = "two" },
    };
    try t.expectError(error.InvalidInput, client.exchange(t.allocator, op, wrong, null, &delivery));
    try t.expectEqual(io.Delivery.unsent, delivery);
    try main.done();
}

test "HTTP rejects wrong IDs invalid content malformed streams and over-limit responses" {
    const oversized: [260]u8 = @splat('x');
    var main: Script = .{ .steps = &.{
        .{ .response_headers = &json, .chunks = &.{"{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"result\":{}}"} },
        .{ .response_headers = &.{.{ .name = "Content-Type", .value = "application/jsonpatch" }} },
        .{ .response_headers = &sse, .chunks = &.{"data: {\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}\n\n"} },
        .{ .response_headers = &sse, .chunks = &.{"data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n"} },
        .{ .response_headers = &json, .chunks = &.{ oversized[0..250], oversized[250..] } },
        .{ .response_headers = &sse, .chunks = &.{ "data: ", &oversized, "\n\n" } },
    } };
    var http = try Http.init(.{ .transport = main.transport(), .url = url, .max_message_bytes = 256, .scratch_allocator = t.allocator });
    defer http.deinit();
    var cancel: io.Cancellation = .{};
    const op = opFor(&cancel);
    const client = http.interface();
    const request = modernRequest(1, "tools/call", ",\"name\":\"fixture\"");

    var delivery: io.Delivery = .unsent;
    for ([_]link.Error{ error.MalformedPeer, error.MalformedPeer, error.MalformedPeer, error.MalformedPeer, error.LimitExceeded, error.LimitExceeded }) |err| {
        try t.expectError(err, client.exchange(t.allocator, op, request, null, &delivery));
        try t.expectEqual(io.Delivery.possibly_sent, delivery);
    }
    try main.done();
}
