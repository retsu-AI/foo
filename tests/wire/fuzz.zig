const std = @import("std");
const foo = @import("foo");
const support = @import("support");
const framing = foo.wire.framing;
const json = foo.wire.json;
const rpc = foo.wire.jsonrpc;
const assertEqual = std.testing.expectEqualDeep;

test "fuzz line and event framing across chunk boundaries" {
    try std.testing.fuzz({}, fuzzFraming, .{ .corpus = &.{
        seed("data: one\r\ndata: two\n\nid: 1\r\rdata:\n\n"),
        seed("\xef\xbb\xbf: keepalive\revent: update\rid: ☃\rdata: 大\r\r"),
        seed("{\"payload\":\"é\\n雪\"}\r\n{\"next\":true}\n"),
        seed("line\rremaining\n"),
        seed("data: \xf0\x28\x8c\x28\n\n"),
        seed("data: unfinished\n"),
    } });
}

test "fuzz bounded JSON-RPC decode and encode" {
    try std.testing.fuzz({}, fuzzCodec, .{ .corpus = &.{
        seed("{\"jsonrpc\":\"2.0\",\"method\":\"notify/雪\",\"params\": { \"x\": [ true, null ] }}"),
        seed("{\"jsonrpc\":\"2.0\",\"id\":\"r\\u0031\",\"result\":[1,{},null]}"),
        seed("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"parse\\nerror\",\"data\":null}}"),
        seed("{\"jsonrpc\":\"2.0\",\"id\":1,\"\\u0069d\":2,\"method\":\"m\"}"),
        seed("[[[[[[[[[0]]]]]]]]]"),
        seed("{\"incomplete\":"),
    } });
}

fn seed(comptime bytes: []const u8) []const u8 {
    return comptime result: {
        var size: [4]u8 = undefined;
        std.mem.writeInt(u32, &size, bytes.len, .little);
        break :result &(size ++ bytes[0..bytes.len].*);
    };
}

fn fuzzFraming(_: void, smith: *std.testing.Smith) !void {
    var bytes: [512]u8 = undefined;
    const len = smith.sliceWithHash(&bytes, 0x14864750);
    const input = bytes[0..len];
    try assertEqual(summarize(.ndjson, input, input.len + 1), summarize(.ndjson, input, 1));
    try assertEqual(summarize(.sse, input, input.len + 1), summarize(.sse, input, 1));
}

const Digest = struct {
    hash: std.hash.Wyhash = .init(0),
    records: usize = 0,

    fn bytes(self: *Digest, slice: []const u8) void {
        self.hash.update(std.mem.asBytes(&slice.len));
        self.hash.update(slice);
    }

    fn record(context: *anyopaque, _: foo.io.Context, line: []const u8) foo.io.Error!void {
        const self: *Digest = @ptrCast(@alignCast(context));
        self.records += 1;
        self.bytes(line);
    }

    fn event(context: *anyopaque, _: foo.io.Context, value: framing.Sse.Event) framing.Error!void {
        const self: *Digest = @ptrCast(@alignCast(context));
        self.records += 1;
        self.bytes(value.event);
        self.bytes(value.data);
        self.bytes(if (value.last_event_id != null) "id" else "no id");
        if (value.last_event_id) |id| self.bytes(id);
    }
};

const Summary = struct {
    failure: ?framing.Error,
    records: usize,
    hash: u64,
    retry_ms: ?u64 = null,
};

fn summarize(comptime kind: enum { ndjson, sse }, input: []const u8, chunk_size: usize) Summary {
    var cancellation: foo.io.Cancellation = .{};
    var clock: support.Clock = .{};
    const operation: foo.io.Context = .{ .io = std.testing.io, .cancellation = &cancellation, .clock = clock.interface() };
    var digest: Digest = .{};
    var line: [128]u8 = undefined;

    switch (kind) {
        .ndjson => {
            var reader = framing.Ndjson.init(&line, .skip);
            const sink: foo.io.ByteSink = .{ .context = &digest, .write_fn = Digest.record };
            const result = feed(&reader, operation, input, chunk_size, sink);
            return .{ .failure = if (result) |_| null else |err| err, .records = digest.records, .hash = digest.hash.final() };
        },
        .sse => {
            var data: [128]u8 = undefined;
            var name: [32]u8 = undefined;
            var id: [32]u8 = undefined;
            var pending_id: [32]u8 = undefined;
            var reader = framing.Sse.init(.{
                .line = &line,
                .data = &data,
                .event = &name,
                .id = &id,
                .pending_id = &pending_id,
                .max_event_bytes = 128,
            });
            const sink: framing.Sse.EventSink = .{ .context = &digest, .emit_fn = Digest.event };
            const result = feed(&reader, operation, input, chunk_size, sink);
            if (reader.lastEventId()) |last_id| {
                digest.bytes("id");
                digest.bytes(last_id);
            } else {
                digest.bytes("no id");
            }
            return .{
                .failure = if (result) |_| null else |err| err,
                .records = digest.records,
                .hash = digest.hash.final(),
                .retry_ms = reader.retryMilliseconds(),
            };
        },
    }
}

fn feed(reader: anytype, operation: foo.io.Context, input: []const u8, chunk_size: usize, sink: anytype) framing.Error!void {
    var rest = input;
    while (rest.len != 0) {
        const n = @min(chunk_size, rest.len);
        try reader.feed(operation, rest[0..n], sink);
        rest = rest[n..];
    }
    try reader.finish(operation);
}

fn fuzzCodec(_: void, smith: *std.testing.Smith) !void {
    var input: [512]u8 = undefined;
    const len = smith.sliceWithHash(&input, 0x14864751);
    const limits: json.Limits = .{ .max_bytes = 2048, .max_depth = 8 };
    var scratch: [1024]u8 = undefined;
    const message = rpc.decode(input[0..len], &scratch, limits) catch return;
    try json.validate(input[0..len], limits);
    var output: [2048]u8 = undefined;
    const encoded = try encode(&output, message, limits);
    try std.testing.expect(std.mem.findAny(u8, encoded, "\r\n") == null);
    var decoded_storage: [1024]u8 = undefined;
    const roundtrip = try rpc.decode(encoded, &decoded_storage, limits);
    var canonical: [2048]u8 = undefined;
    try std.testing.expectEqualStrings(encoded, try encode(&canonical, roundtrip, limits));
}

fn encode(output: []u8, message: rpc.Envelope, limits: json.Limits) rpc.EncodeError![]const u8 {
    return switch (message) {
        .request => |request| rpc.encodeRequest(output, request, limits),
        .response => |response| rpc.encodeResponse(output, response, limits),
    };
}
