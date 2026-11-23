const std = @import("std");
const foo = @import("foo");
const journal = @import("journal");

pub const identity = "fixture-model";
pub const prompt: foo.session.Record = .{ .message = .{
    .role = .user,
    .blocks = &.{.{ .text = "hello" }},
} };
pub const call: foo.provider.ToolCall = .{
    .id = "call-1",
    .name = "mark",
    .arguments_json = "{}",
};
pub const request: foo.session.Record = .{ .message = .{
    .role = .assistant,
    .blocks = &.{.{ .tool_call = call }},
} };
pub const intent: foo.session.Record = .{ .dispatch_intent = .{
    .call = call,
    .declaration = .{
        .identity = .{ .backend = "local", .name = "mark" },
        .spec = .{ .name = "mark", .description = "Write a marker", .schema_json = "{}" },
        .generation = 1,
    },
} };
pub const result: foo.tool.Result = .{
    .call_id = call.id,
    .status = .success,
    .effect = .observed,
    .content = "marked",
};
pub const outcome: foo.session.Record = .{ .finished = .{ .reason = .completed } };

pub fn operation(io: std.Io, cancellation: *const foo.io.Cancellation) foo.io.Context {
    return .{
        .io = io,
        .cancellation = cancellation,
        .clock = .{ .context = @ptrCast(@constCast(cancellation)), .now_fn = now },
    };
}

fn now(_: *anyopaque) u64 {
    return 100;
}

pub fn begin(store: *journal.Store, op: foo.io.Context) !void {
    try std.testing.expectEqual(@as(u64, 2), try store.commit(op, prompt));
    try std.testing.expectEqual(@as(u64, 3), try store.commit(op, request));
}
