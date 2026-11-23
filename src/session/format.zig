const std = @import("std");
const foo = @import("foo");
const session = foo.session;

const checksum_start = "{\"crc32\":\"";
const payload_start = "\",\"payload\":";
const prefix_len = checksum_start.len + 8 + payload_start.len;

pub const Payload = struct {
    sequence: u64,
    record: session.Record,
};

const WirePayload = struct {
    sequence: u64,
    record: union(enum) {
        header: struct { version: u32, config_identity: []const u8 },
        message: foo.provider.Message,
        dispatch_intent: foo.tool.Invocation,
        tool_result: foo.tool.Result,
        finished: foo.events.Outcome,
    },
};

pub fn encode(buffer: []u8, payload: Payload) session.Error![]const u8 {
    if (buffer.len < prefix_len + 2) return error.LimitExceeded;
    var writer = std.Io.Writer.fixed(buffer[prefix_len .. buffer.len - 2]);
    std.json.Stringify.value(payload, .{}, &writer) catch return error.LimitExceeded;
    const bytes = writer.buffered();
    const checksum = std.hash.Crc32.hash(bytes);
    @memcpy(buffer[0..checksum_start.len], checksum_start);
    _ = std.fmt.bufPrint(buffer[checksum_start.len..][0..8], "{x:0>8}", .{checksum}) catch unreachable;
    @memcpy(buffer[checksum_start.len + 8 .. prefix_len], payload_start);
    const end = prefix_len + bytes.len;
    buffer[end..][0..2].* = "}\n".*;
    return buffer[0 .. end + 2];
}

pub fn decode(allocator: std.mem.Allocator, line: []const u8) session.Error!Payload {
    if (line.len <= prefix_len or line[line.len - 1] != '}' or
        !std.mem.startsWith(u8, line, checksum_start) or
        !std.mem.eql(u8, line[checksum_start.len + 8 .. prefix_len], payload_start))
        return error.CorruptHistory;
    const digits = line[checksum_start.len..][0..8];
    for (digits) |digit| {
        if (!std.ascii.isDigit(digit) and !(digit >= 'a' and digit <= 'f')) return error.CorruptHistory;
    }
    const checksum = std.fmt.parseInt(u32, digits, 16) catch return error.CorruptHistory;
    const bytes = line[prefix_len .. line.len - 1];
    if (std.hash.Crc32.hash(bytes) != checksum) return error.CorruptHistory;
    const wire = std.json.parseFromSliceLeaky(WirePayload, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CorruptHistory,
    };
    const record: session.Record = switch (wire.record) {
        .header => |header| .{ .header = .{ .version = header.version, .config_identity = header.config_identity } },
        inline else => |value, tag| @unionInit(session.Record, @tagName(tag), value),
    };
    return .{ .sequence = wire.sequence, .record = record };
}
