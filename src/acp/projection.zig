const std = @import("std");
const foo = @import("foo");

pub const StopReason = enum { end_turn, max_tokens, refusal, cancelled };

pub fn stop(outcome: foo.events.Outcome) ?StopReason {
    if (outcome.reason == .cancelled) return .cancelled;
    if (outcome.uncertain_effects) return null;
    return switch (outcome.reason) {
        .completed => if (outcome.provider_stop == null or outcome.provider_stop == .end_turn) .end_turn else null,
        .limit_reached => if (outcome.provider_stop == .output_limit) .max_tokens else null,
        .provider_error => if (outcome.provider_stop == .refusal) .refusal else null,
        .cancelled => unreachable,
        .interrupted, .storage_error, .host_error => null,
    };
}

pub const Text = struct {
    type: []const u8 = "text",
    text: []const u8,
};

pub const Chunk = struct {
    sessionUpdate: enum { agent_message_chunk, agent_thought_chunk },
    content: Text,
};

pub const ToolCall = struct {
    sessionUpdate: enum { tool_call } = .tool_call,
    toolCallId: []const u8,
    title: []const u8,
    status: enum { pending } = .pending,
};

pub const ToolResult = struct {
    sessionUpdate: enum { tool_call_update } = .tool_call_update,
    toolCallId: []const u8,
    status: enum { completed, failed },
    content: [1]struct {
        type: []const u8 = "content",
        content: Text,
    },
};

pub fn toolResult(wire_id: []const u8, result: foo.tool.Result) ToolResult {
    return .{
        .toolCallId = wire_id,
        .status = if (result.status == .success) .completed else .failed,
        .content = .{.{ .content = .{
            .text = if (std.unicode.utf8ValidateSlice(result.content)) result.content else "Tool output contains non-text data",
        } }},
    };
}

pub fn messageBytes(message: foo.provider.Message) usize {
    var bytes = @sizeOf(foo.provider.Message) +| (message.blocks.len *| @sizeOf(foo.provider.Block));
    for (message.blocks) |block| bytes +|= switch (block) {
        .text => |value| value.len,
        .reasoning => |value| value.text.len +| (if (value.signature) |signature| signature.len else 0),
        .tool_call => |value| value.id.len +| value.name.len +| value.arguments_json.len,
        .tool_result => |value| value.call_id.len +| value.content.len,
        .replay => |value| value.endpoint.len +| value.model.len +| value.bytes.len,
    };
    return bytes;
}
