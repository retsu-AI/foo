const std = @import("std");
const foo = @import("foo");
const correlation = foo.wire.correlation;
const rpc = foo.jsonrpc;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

test "IDs retain types and directions under a full correlation table" {
    var pending = try correlation.Table.init(std.testing.allocator, .{ .pending_per_direction = 2, .id_bytes = 4 });
    defer pending.deinit();

    const out = try pending.beginOutbound(null);
    const other = try pending.beginOutbound(null);
    try expectError(error.LimitExceeded, pending.beginOutbound(null));
    const inbound_number = try pending.beginInbound(out.id, null);
    const inbound_string = try pending.beginInbound(.{ .string = "1" }, null);
    try expectError(error.DuplicateId, pending.beginInbound(out.id, null));
    try expectError(error.LimitExceeded, pending.beginInbound(.{ .number = 3 }, null));

    const result = try pending.resolve(success(out.id), 0);
    try expect(result.response.eql(out.ticket));
    try expectError(error.RetiredId, pending.resolve(success(out.id), 0));
    try expectError(error.UnknownId, pending.resolve(success(.{ .string = "1" }), 0));
    try expectError(error.UnknownId, pending.resolve(success(.{ .number = 4 }), 0));
    try expectError(error.UnknownId, pending.resolve(.{ .failure = .{
        .err = .{ .code = rpc.Code.parse_error, .message = "invalid input" },
    } }, 0));
    try expect((try pending.requestId(inbound_number)).eql(out.id));
    try expect((try pending.requestId(inbound_string)).eql(.{ .string = "1" }));

    try pending.retire(other.ticket);
    const next = try pending.beginOutbound(null);
    try expectEqual(@as(i64, 3), next.id.number);
}

test "owned inbound IDs survive discarded frame storage and stale completion" {
    var pending = try correlation.Table.init(std.testing.allocator, .{ .pending_per_direction = 1, .id_bytes = 4 });
    defer pending.deinit();
    var copied: [4]u8 = "abcd".*;
    const first = try pending.beginInbound(.{ .string = &copied }, null);
    @memset(&copied, 0);
    try std.testing.expectEqualStrings("abcd", (try pending.requestId(first)).string);
    try expectError(error.DuplicateId, pending.beginInbound(.{ .string = "abcd" }, null));
    const cancelled = try pending.cancel(.inbound, .{ .string = "abcd" });
    try expect(cancelled.eql(first));
    try expectError(error.LimitExceeded, pending.beginInbound(.{ .string = "longer" }, null));
    const second = try pending.beginInbound(.{ .string = "abcd" }, null);
    try expectError(error.StaleRequest, pending.retire(first));

    var other = try correlation.Table.init(std.testing.allocator, .{});
    defer other.deinit();
    try expectError(error.StaleRequest, other.requestId(second));
    try std.testing.expectEqualStrings("abcd", (try pending.requestId(second)).string);
    try pending.retire(second);
    try expectError(error.StaleRequest, pending.requestId(second));
}

test "deadline, resolution, cancellation, and shutdown retire each ticket once" {
    var pending = try correlation.Table.init(std.testing.allocator, .{});
    defer pending.deinit();

    const cancelled = try pending.beginOutbound(50);
    try expect((try pending.cancel(.outbound, cancelled.id)).eql(cancelled.ticket));
    try expectError(error.RetiredId, pending.resolve(success(cancelled.id), 49));

    const timeout = try pending.beginOutbound(70);
    const expired = try pending.resolve(success(timeout.id), 70);
    try expect(expired.expired.eql(timeout.ticket));
    try expectError(error.RetiredId, pending.resolve(success(timeout.id), 71));

    const inbound = try pending.beginInbound(.{ .number = 99 }, 100);
    const outbound = try pending.beginOutbound(null);
    try expectEqual(@as(?correlation.Ticket, null), pending.expireNext(99));
    try expect(pending.expireNext(100).?.eql(inbound));
    try expectEqual(@as(?correlation.Ticket, null), pending.expireNext(100));
    try expectEqual(@as(?correlation.Ticket, null), pending.drainNext());
    const remaining = try pending.beginInbound(.{ .string = "bye" }, null);
    pending.close();
    pending.close();
    try expectError(error.Closed, pending.resolve(success(outbound.id), 100));
    try expectError(error.Closed, pending.beginInbound(.{ .number = 40 }, null));
    try expectError(error.Closed, pending.beginOutbound(null));
    try expectError(error.Closed, pending.retire(remaining));
    try expect(pending.drainNext().?.eql(outbound.ticket));
    try expect(pending.drainNext().?.eql(remaining));
    try expectEqual(@as(?correlation.Ticket, null), pending.drainNext());
}

fn success(id: rpc.Id) rpc.Response {
    return .{ .success = .{ .id = id, .result_json = "null" } };
}
