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
pub const child_id = "call-1:child-1";

pub fn nestedIntent(parent_id: []const u8, ordinal: u32, id: []const u8) foo.session.Record {
    var invocation = intent.dispatch_intent;
    invocation.call.id = id;
    return .{ .nested_tool = .{
        .parent_call_id = parent_id,
        .ordinal = ordinal,
        .data = .{ .dispatch_intent = invocation },
    } };
}

pub fn nestedResult(parent_id: []const u8, ordinal: u32, child: foo.tool.Result) foo.session.Record {
    return .{ .nested_tool = .{
        .parent_call_id = parent_id,
        .ordinal = ordinal,
        .data = .{ .tool_result = child },
    } };
}

pub const child_result: foo.tool.Result = .{
    .call_id = child_id,
    .status = .success,
    .effect = .observed,
    .content = "nested marker",
};

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
