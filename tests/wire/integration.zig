const std = @import("std");
const foo = @import("foo");
const support = @import("support");
const io = foo.io;
const wire = foo.wire;
const expect = std.testing.expect;
const expectStrings = std.testing.expectEqualStrings;

fn operation(clock: *support.Clock, cancellation: *io.Cancellation) io.Context {
    return .{ .io = std.testing.io, .clock = clock.interface(), .cancellation = cancellation };
}

test "HTTP transport response chunks feed the same SSE parser for provider and MCP data" {
    var decoder_buffers: SseBuffers = undefined;
    var reader = wire.framing.Sse.init(decoder_buffers.storage());
    var transport: support.Http = .{ .chunks = &.{
        "data: {\"delta\":\"\xe9", "\x9b", "\xaa\"}\r", "\n\r", "\n",
    } };
    var posted = ProviderData{};
    const provider_sink: wire.framing.Sse.EventSink = .{ .context = &posted, .emit_fn = ProviderData.emit };
    try receiveEvents(&reader, transport.interface(), provider_sink);
    try expect(posted.received);

    var pending = try wire.correlation.Table.init(std.testing.allocator, .{});
    defer pending.deinit();
    const request = try pending.beginOutbound(null);
    var reply: RpcData = .{ .pending = &pending };
    reader = wire.framing.Sse.init(decoder_buffers.storage());
    transport.chunks = &.{
        "id: 42\nevent: message\ndata: {\"jsonrpc\":\"2.0\",",
        "\"id\":1,\"result\":{\"ready\":true}}\n\n",
    };
    try receiveEvents(&reader, transport.interface(), .{ .context = &reply, .emit_fn = RpcData.event });
    try expect(reply.response.?.eql(request.ticket));
    try expectStrings("42", reader.lastEventId().?);
}

test "newline writer and reader exchange independent ACP stdio messages" {
    var stdout: [256]u8 = undefined;
    var stdin: [256]u8 = undefined;
    var encode_buffer: [128]u8 = undefined;
    var line_buffer: [128]u8 = undefined;
    var read_buffer: [5]u8 = undefined;
    var pending = try wire.correlation.Table.init(std.testing.allocator, .{});
    defer pending.deinit();
    const request = try pending.beginOutbound(100);
    const encoded = try wire.jsonrpc.encodeRequest(&encode_buffer, .{
        .id = request.id,
        .method = "session/prompt",
        .params_json = "{\n \"text\": \"first\\n雪\"\n}",
    }, .{});
    var process: support.Process = .{
        .input = .{ .buffer = &stdin },
        .stdout_bytes = "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"text\":\"雪\"}}\r\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ready\":true}}\n",
        .stderr_bytes = "peer diagnostics",
    };
    const child = process.interface();
    var clock = support.Clock{};
    var cancel = io.Cancellation{};
    const op = operation(&clock, &cancel);
    var writer = wire.framing.Writer.init(&stdout, child.stdin);
    try writer.write(op, encoded);
    const written = process.input.buffer[0..process.input.used];
    try expect(written.len > 0 and written[written.len - 1] == '\n');
    const line = written[0 .. written.len - 1];
    try expect(std.mem.findAny(u8, line, "\r\n") == null);
    var decoded: [128]u8 = undefined;
    const decoded_request = (try wire.jsonrpc.decode(line, &decoded, .{})).request;
    try expect(decoded_request.id.?.eql(request.id));
    try expectStrings("session/prompt", decoded_request.method);
    try expectStrings("{\"text\":\"first\\n雪\"}", decoded_request.params_json.?);

    var reply: RpcData = .{ .pending = &pending };
    var reader = wire.framing.Ndjson.init(&line_buffer, .reject);
    const sink: io.ByteSink = .{ .context = &reply, .write_fn = RpcData.line };
    while (true) {
        const n = try child.stdout.read_fn(child.stdout.context, op, &read_buffer);
        if (n == 0) break;
        try reader.feed(op, read_buffer[0..n], sink);
    }
    try reader.finish(op);
    try expect(reply.notification);
    try expect(reply.response.?.eql(request.ticket));
}

const SseBuffers = struct {
    line: [128]u8,
    data: [128]u8,
    event: [16]u8,
    id: [16]u8,
    pending_id: [16]u8,

    fn storage(self: *SseBuffers) wire.framing.Sse.Storage {
        return .{
            .line = &self.line,
            .data = &self.data,
            .event = &self.event,
            .id = &self.id,
            .pending_id = &self.pending_id,
            .max_event_bytes = 128,
        };
    }
};

const ProviderData = struct {
    received: bool = false,

    fn emit(context: *anyopaque, _: io.Context, msg: wire.framing.Sse.Event) wire.framing.Error!void {
        const self: *ProviderData = @ptrCast(@alignCast(context));
        var memory: [256]u8 = undefined;
        var scratch = std.heap.FixedBufferAllocator.init(&memory);
        const payload = wire.json.decode(struct { delta: []const u8 }, msg.data, &scratch, .{}, .{}) catch return error.InvalidInput;
        if (self.received or !std.mem.eql(u8, payload.delta, "雪")) return error.InvalidInput;
        self.received = true;
    }
};

const RpcData = struct {
    pending: *wire.correlation.Table,
    notification: bool = false,
    response: ?wire.correlation.Ticket = null,

    fn event(context: *anyopaque, op: io.Context, msg: wire.framing.Sse.Event) wire.framing.Error!void {
        if (!std.mem.eql(u8, msg.event, "message")) return error.InvalidInput;
        try line(context, op, msg.data);
    }

    fn line(context: *anyopaque, op: io.Context, bytes: []const u8) io.Error!void {
        const self: *RpcData = @ptrCast(@alignCast(context));
        var scratch: [256]u8 = undefined;
        const message = wire.jsonrpc.decode(bytes, &scratch, .{}) catch return error.InvalidInput;
        switch (message) {
            .request => |request| {
                if (request.id != null or self.notification or self.response != null or
                    !std.mem.eql(u8, request.method, "session/update")) return error.InvalidInput;
                self.notification = true;
            },
            .response => |response| {
                if (response != .success or self.response != null or
                    !std.mem.eql(u8, response.success.result_json, "{\"ready\":true}")) return error.InvalidInput;
                const matched = self.pending.resolve(response, op.clock.now()) catch return error.InvalidInput;
                if (matched != .response) return error.DeadlineExceeded;
                self.response = matched.response;
            },
        }
    }
};

const SseExchange = struct {
    reader: *wire.framing.Sse,
    events: wire.framing.Sse.EventSink,
    parser_error: ?wire.framing.Error = null,

    fn head(_: *anyopaque, _: io.Context, value: io.HttpHead) io.Error!void {
        if (value.status != 200) return error.InvalidInput;
    }

    fn body(context: *anyopaque, op: io.Context, bytes: []const u8) io.Error!void {
        const self: *SseExchange = @ptrCast(@alignCast(context));
        self.reader.feed(op, bytes, self.events) catch |err| {
            self.parser_error = err;
            return error.IoFailure;
        };
    }
};

fn receiveEvents(reader: *wire.framing.Sse, transport: io.HttpTransport, sink: wire.framing.Sse.EventSink) !void {
    var clock: support.Clock = .{};
    var cancellation: io.Cancellation = .{};
    const op = operation(&clock, &cancellation);
    var exchange: SseExchange = .{ .reader = reader, .events = sink };
    var delivery: io.Delivery = .unsent;
    transport.exchange_fn(transport.context, op, .{
        .method = .get,
        .url = "http://127.0.0.1/stream",
        .max_response_bytes = 256,
    }, .{
        .context = &exchange,
        .head_fn = SseExchange.head,
        .body = .{ .context = &exchange, .write_fn = SseExchange.body },
    }, &delivery) catch |err| return exchange.parser_error orelse err;
    try reader.finish(op);
}
