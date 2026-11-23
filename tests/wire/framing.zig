const std = @import("std");
const foo = @import("foo");
const support = @import("support");
const framing = foo.wire.framing;
const io = foo.io;
const testing = std.testing;

fn operation(cancellation: *const io.Cancellation, clock: *support.Clock) io.Context {
    return .{ .io = testing.io, .cancellation = cancellation, .clock = clock.interface() };
}

const Records = struct {
    expected: []const []const u8 = &.{},
    count: usize = 0,
    failure: ?io.Error = null,

    fn sink(self: *Records) io.ByteSink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, _: io.Context, record: []const u8) io.Error!void {
        const self: *Records = @ptrCast(@alignCast(context));
        if (self.count == self.expected.len) return error.InvalidInput;
        testing.expectEqualStrings(self.expected[self.count], record) catch return error.InvalidInput;
        self.count += 1;
        if (self.failure) |failure| return failure;
    }
};

const Events = struct {
    expected: []const framing.Sse.Event = &.{},
    count: usize = 0,
    failure: ?framing.Error = null,

    fn sink(self: *Events) framing.Sse.EventSink {
        return .{ .context = self, .emit_fn = emit };
    }

    fn emit(context: *anyopaque, _: io.Context, received: framing.Sse.Event) framing.Error!void {
        const self: *Events = @ptrCast(@alignCast(context));
        if (self.count == self.expected.len) return error.InvalidInput;
        const expected = self.expected[self.count];
        testing.expectEqualStrings(expected.data, received.data) catch return error.InvalidInput;
        testing.expectEqualStrings(expected.event, received.event) catch return error.InvalidInput;
        testing.expectEqual(expected.last_event_id != null, received.last_event_id != null) catch return error.InvalidInput;
        if (expected.last_event_id) |id| {
            testing.expectEqualStrings(id, received.last_event_id.?) catch return error.InvalidInput;
        }
        self.count += 1;
        if (self.failure) |failure| return failure;
    }
};

const SseBuffers = struct {
    line: [96]u8 = undefined,
    data: [48]u8 = undefined,
    event: [16]u8 = undefined,
    id: [16]u8 = undefined,
    pending_id: [16]u8 = undefined,

    fn storage(self: *SseBuffers, max_event_bytes: usize) framing.Sse.Storage {
        return .{
            .line = &self.line,
            .data = &self.data,
            .event = &self.event,
            .id = &self.id,
            .pending_id = &self.pending_id,
            .max_event_bytes = max_event_bytes,
        };
    }
};

test "NDJSON records survive every split, including UTF-8, a JSON escape, and CRLF" {
    const record = "{\"text\":\"naïve\\n雪\"}";
    const input = record ++ "\r\n\n{}\n[]\r\n";
    const expected = [_][]const u8{ record, "{}", "[]" };
    var cancel: io.Cancellation = .{};
    var clock: support.Clock = .{};
    const op = operation(&cancel, &clock);
    for (0..input.len + 1) |split| {
        var storage: [record.len]u8 = undefined;
        var reader = framing.Ndjson.init(&storage, .skip);
        var records: Records = .{ .expected = &expected };
        try reader.feed(op, input[0..split], records.sink());
        try reader.feed(op, input[split..], records.sink());
        try reader.finish(op);
        try testing.expectEqual(expected.len, records.count);
        try testing.expectError(error.Closed, reader.feed(op, "{}", records.sink()));
        try testing.expectError(error.Closed, reader.finish(op));
    }
}

test "NDJSON rejects malformed and oversized records and closes on truncated EOF" {
    var cancel: io.Cancellation = .{};
    var clock: support.Clock = .{};
    const op = operation(&cancel, &clock);
    var records: Records = .{};
    var buffer: [4]u8 = undefined;
    const rejected = .{
        .{ "\r\n", error.MalformedFrame },
        .{ "a\rb\n", error.MalformedFrame },
        .{ "\xed\xa0\x80\n", error.MalformedFrame },
        .{ "12345", error.LimitExceeded },
    };
    inline for (rejected) |case| {
        var reader = framing.Ndjson.init(&buffer, .reject);
        try testing.expectError(case[1], reader.feed(op, case[0], records.sink()));
        try testing.expectError(error.Closed, reader.finish(op));
    }
    for ([_][]const u8{ "{}", "{}\r", "\xe9\x9b", "\r" }) |input| {
        var reader = framing.Ndjson.init(&buffer, .reject);
        try reader.feed(op, input, records.sink());
        try testing.expectError(error.TruncatedFrame, reader.finish(op));
        try testing.expectError(error.Closed, reader.feed(op, "\n", records.sink()));
    }
    try testing.expectEqual(0, records.count);
}

test "SSE preserves events, cursor updates, and retry across every byte split" {
    const input = "\xef\xbb\xbf: keepalive\r\n\r\n" ++
        "data: first\r\r" ++
        "id: 雪\r\nretry: 0042\r\n\r\n" ++
        "event: update\r\nDATA: ignored\nid: ignored\x00\rdata: café\r\ndata:  extra\xef\xbb\xbf\n\n" ++
        "data\ndata:\n\n" ++
        "event: discarded\nid:\n\n" ++
        "retry: +5\nretry: 3x\nretry: 18446744073709551616\nretry:\n" ++
        "data:\n\n";
    const expected = [_]framing.Sse.Event{
        .{ .data = "first", .event = "message", .last_event_id = null },
        .{ .data = "café\n extra\xef\xbb\xbf", .event = "update", .last_event_id = "雪" },
        .{ .data = "\n", .event = "message", .last_event_id = "雪" },
        .{ .data = "", .event = "message", .last_event_id = "" },
    };
    var cancel: io.Cancellation = .{};
    var clock: support.Clock = .{};
    const op = operation(&cancel, &clock);
    for (0..input.len + 1) |split| {
        var buffers: SseBuffers = .{};
        var reader = framing.Sse.init(buffers.storage(80));
        var events: Events = .{ .expected = &expected };
        try reader.feed(op, input[0..split], events.sink());
        try reader.feed(op, input[split..], events.sink());
        try reader.finish(op);
        try testing.expectEqual(expected.len, events.count);
        try testing.expectEqualStrings("", reader.lastEventId().?);
        try testing.expectEqual(@as(?u64, 42), reader.retryMilliseconds());
        try testing.expectError(error.Closed, reader.finish(op));
    }
}

test "SSE commits IDs only at blank lines and never emits an incomplete event" {
    var cancel: io.Cancellation = .{};
    var clock: support.Clock = .{};
    const op = operation(&cancel, &clock);
    var buffers: SseBuffers = .{};
    var events: Events = .{};
    for ([_][]const u8{ "data: unfinished", "data: unfinished\r", "data:\n", "event:\n", "\xef\xbb" }) |input| {
        var reader = framing.Sse.init(buffers.storage(80));
        try reader.feed(op, input, events.sink());
        try testing.expectError(error.TruncatedFrame, reader.finish(op));
        try testing.expectError(error.Closed, reader.feed(op, "\n\n", events.sink()));
    }
    var reader = framing.Sse.init(buffers.storage(80));
    try reader.feed(op, "id: ready\r\n", events.sink());
    try testing.expectEqual(null, reader.lastEventId());
    try reader.feed(op, "\r", events.sink());
    try testing.expectEqualStrings("ready", reader.lastEventId().?);
    try reader.feed(op, "\nid: pending\n", events.sink());
    try testing.expectError(error.TruncatedFrame, reader.finish(op));
    try testing.expectEqualStrings("ready", reader.lastEventId().?);
    try testing.expectEqual(0, events.count);
}

test "SSE accepts a BOM and control lines at orderly EOF" {
    var cancel: io.Cancellation = .{};
    var clock: support.Clock = .{};
    const op = operation(&cancel, &clock);
    var buffers: SseBuffers = .{};
    var events: Events = .{};
    var reader = framing.Sse.init(buffers.storage(0));
    try reader.feed(op, "\xef\xbb\xbf", events.sink());
    try reader.feed(op, ": keepalive\rretry: 18446744073709551615\r", events.sink());
    try reader.finish(op);
    try testing.expectEqual(@as(?u64, std.math.maxInt(u64)), reader.retryMilliseconds());
    try testing.expectEqual(0, events.count);
}

test "SSE rejects malformed UTF-8 and enforces each buffer and the aggregate event limit" {
    var cancel: io.Cancellation = .{};
    var clock: support.Clock = .{};
    const op = operation(&cancel, &clock);
    var buffers: SseBuffers = .{};
    var events: Events = .{};
    var reader = framing.Sse.init(buffers.storage(80));
    try reader.feed(op, ": \xef", events.sink());
    try testing.expectError(error.MalformedFrame, reader.feed(op, "\xbc\n", events.sink()));
    reader = framing.Sse.init(buffers.storage(80));
    try reader.feed(op, "\xef\xbb", events.sink());
    try testing.expectError(error.MalformedFrame, reader.feed(op, "\n", events.sink()));
    reader = framing.Sse.init(buffers.storage(80));
    const long_line: [97]u8 = @splat(':');
    try testing.expectError(error.LimitExceeded, reader.feed(op, &long_line, events.sink()));
    const long_data: [49]u8 = @splat('x');
    reader = framing.Sse.init(buffers.storage(80));
    try testing.expectError(error.LimitExceeded, reader.feed(op, "data:" ++ long_data ++ "\n", events.sink()));
    const long_metadata: [17]u8 = @splat('x');
    reader = framing.Sse.init(buffers.storage(80));
    try testing.expectError(error.LimitExceeded, reader.feed(op, "event:" ++ long_metadata ++ "\n", events.sink()));
    var storage = buffers.storage(80);
    storage.id = storage.id[0..1];
    reader = framing.Sse.init(storage);
    try testing.expectError(error.LimitExceeded, reader.feed(op, "id:ab\n", events.sink()));
    reader = framing.Sse.init(buffers.storage(80));
    try testing.expectError(error.LimitExceeded, reader.feed(op, "id:" ++ long_metadata ++ "\n", events.sink()));
    reader = framing.Sse.init(buffers.storage(5));
    events.expected = &.{.{ .data = "123", .event = "t", .last_event_id = "x" }};
    try reader.feed(op, "id:x\n\nevent:t\ndata:123\n\n", events.sink());
    try testing.expectError(error.LimitExceeded, reader.feed(op, "event:t\ndata:1234\n", events.sink()));
    try testing.expectError(error.Closed, reader.finish(op));
    try testing.expectEqual(1, events.count);
}

test "readers stop after a callback fails and report cancellation and deadlines" {
    var cancel: io.Cancellation = .{};
    var clock: support.Clock = .{};
    var op = operation(&cancel, &clock);
    var buffer: [8]u8 = undefined;
    var ndjson = framing.Ndjson.init(&buffer, .reject);
    var records: Records = .{ .expected = &.{"{}"}, .failure = error.Disconnected };
    try testing.expectError(error.Disconnected, ndjson.feed(op, "{}\n[]\n", records.sink()));
    try testing.expectError(error.Closed, ndjson.finish(op));
    try testing.expectEqual(1, records.count);

    var buffers: SseBuffers = .{};
    var sse = framing.Sse.init(buffers.storage(80));
    var events: Events = .{
        .expected = &.{.{ .data = "first", .event = "message", .last_event_id = null }},
        .failure = error.Unavailable,
    };
    try testing.expectError(error.Unavailable, sse.feed(op, "data:first\n\ndata:second\n\n", events.sink()));
    try testing.expectError(error.Closed, sse.finish(op));
    try testing.expectEqual(1, events.count);

    op.deadline_ms = 0;
    sse = framing.Sse.init(buffers.storage(80));
    try testing.expectError(error.DeadlineExceeded, sse.feed(op, "data:first\n\n", events.sink()));
    try testing.expectError(error.Closed, sse.finish(op));
    cancel.request();
    ndjson = framing.Ndjson.init(&buffer, .reject);
    try testing.expectError(error.Cancelled, ndjson.feed(op, "{}\n", records.sink()));
    try testing.expectEqual(1, records.count);
    try testing.expectEqual(1, events.count);
}

test "writer admits complete UTF-8 records and closes after a sink failure" {
    var cancel: io.Cancellation = .{};
    var cancelled: io.Cancellation = .{};
    cancelled.request();
    var clock: support.Clock = .{};
    const op = operation(&cancel, &clock);
    var scratch: [6]u8 = undefined;
    var records: Records = .{ .expected = &.{ "\"雪\"\n", "{}\n" } };
    var writer = framing.Writer.init(&scratch, records.sink());
    for ([_][]const u8{ "", "{}\n", "{}\r", "\"" ++ "\xff" ++ "\"" }) |invalid| {
        try testing.expectError(error.MalformedFrame, writer.write(op, invalid));
    }
    try testing.expectError(error.LimitExceeded, writer.write(op, "[1234]"));
    try testing.expectError(error.Cancelled, writer.write(operation(&cancelled, &clock), "{}"));
    try testing.expectEqual(0, records.count);
    try writer.write(op, "\"雪\"");
    records.failure = error.Disconnected;
    try testing.expectError(error.Disconnected, writer.write(op, "{}"));
    try testing.expectError(error.Closed, writer.write(op, "[]"));
    try testing.expectEqual(2, records.count);
}

test "one concurrent writer reaches the sink and a busy caller can retry" {
    const BlockedWrite = struct {
        entered: std.Io.Event = .unset,
        released: std.Io.Event = .unset,
        records: Records = .{ .expected = &.{ "{}\n", "[]\n" } },
        result: framing.Error!void = {},

        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } };

        fn write(context: *anyopaque, op: io.Context, record: []const u8) io.Error!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.entered.set(op.io);
            self.released.waitTimeout(op.io, timeout) catch return error.IoFailure;
            return self.records.sink().write(op, record);
        }

        fn run(self: *@This(), writer: *framing.Writer, op: io.Context) void {
            defer self.entered.set(op.io);
            self.result = writer.write(op, "{}");
        }
    };

    var cancel: io.Cancellation = .{};
    var clock: support.Clock = .{};
    const op = operation(&cancel, &clock);
    var sink: BlockedWrite = .{};
    var scratch: [3]u8 = undefined;
    var writer = framing.Writer.init(&scratch, .{ .context = &sink, .write_fn = BlockedWrite.write });
    {
        const first = try std.Thread.spawn(.{}, BlockedWrite.run, .{ &sink, &writer, op });
        defer first.join();
        defer sink.released.set(op.io);
        try sink.entered.waitTimeout(op.io, BlockedWrite.timeout);
        try testing.expectError(error.Busy, writer.write(op, "[]"));
    }
    try sink.result;
    try writer.write(op, "[]");
    try testing.expectEqual(2, sink.records.count);
}
