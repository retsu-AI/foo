const std = @import("std");
const config = @import("config.zig");
const io = @import("io.zig");

pub const Role = enum { system, user, assistant, tool };
pub const ToolCall = struct { id: []const u8, name: []const u8, arguments_json: []const u8 };
pub const ToolResult = struct { call_id: []const u8, content: []const u8, is_error: bool };
pub const Replay = struct {
    family: config.Family,
    endpoint: []const u8,
    model: []const u8,
    bytes: []const u8,

    pub fn compatible(self: Replay, model: config.Model) bool {
        return self.family == model.family and std.mem.eql(u8, self.endpoint, model.endpoint) and
            std.mem.eql(u8, self.model, model.id);
    }
};
pub const Block = union(enum) {
    text: []const u8,
    reasoning: struct { text: []const u8, signature: ?[]const u8 = null },
    tool_call: ToolCall,
    tool_result: ToolResult,
    replay: Replay,
};
pub const Message = struct { role: Role, blocks: []const Block };
pub const ToolSpec = struct { name: []const u8, description: []const u8, schema_json: []const u8 };
pub const Request = struct {
    model: config.Model,
    messages: []const Message,
    tools: []const ToolSpec = &.{},
    limits: config.Limits = .{},
};
pub const Usage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cache_read_tokens: ?u64 = null,
};
pub const Stop = enum { end_turn, tool_use, output_limit, refusal };
pub const Response = struct { message: Message, stop: Stop, usage: Usage = .{} };
pub const Delta = union(enum) {
    text: []const u8,
    reasoning: []const u8,
    tool_arguments: struct { call_id: []const u8, bytes: []const u8 },
};
/// HTTP facts behind a failed stream, reported through Sink.failure.
pub const Failure = struct { status: ?u16 = null, retry_after_ms: ?u64 = null };
pub const Sink = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, io.Context, Delta) io.Error!void,
    failure: ?*Failure = null,

    pub fn emit(self: Sink, operation: io.Context, delta: Delta) io.Error!void {
        try operation.check();
        try self.emit_fn(self.context, operation, delta);
    }
};
pub const Error = io.Error || error{ Authentication, Rejected, RateLimited, Protocol, IncompatibleReplay };
pub const Provider = struct {
    context: *anyopaque,
    /// Requests/deltas are borrowed. All returned slices use result_allocator;
    /// it survives until the host copies history or destroys its response arena.
    /// No callback occurs after return. Delivery is meaningful even on failure.
    stream_fn: *const fn (*anyopaque, std.mem.Allocator, io.Context, Request, Sink, *io.Delivery) Error!Response,
};

/// Use an arena (or reclaim all allocations together) on success and failure.
pub fn copyMessage(allocator: std.mem.Allocator, message: Message) std.mem.Allocator.Error!Message {
    const blocks = try allocator.alloc(Block, message.blocks.len);
    for (message.blocks, blocks) |source, *dest| {
        dest.* = switch (source) {
            .text => |v| .{ .text = try allocator.dupe(u8, v) },
            .reasoning => |v| .{ .reasoning = .{
                .text = try allocator.dupe(u8, v.text),
                .signature = if (v.signature) |s| try allocator.dupe(u8, s) else null,
            } },
            .tool_call => |v| .{ .tool_call = .{
                .id = try allocator.dupe(u8, v.id),
                .name = try allocator.dupe(u8, v.name),
                .arguments_json = try allocator.dupe(u8, v.arguments_json),
            } },
            .tool_result => |v| .{ .tool_result = .{
                .call_id = try allocator.dupe(u8, v.call_id),
                .content = try allocator.dupe(u8, v.content),
                .is_error = v.is_error,
            } },
            .replay => |v| .{ .replay = .{
                .family = v.family,
                .endpoint = try allocator.dupe(u8, v.endpoint),
                .model = try allocator.dupe(u8, v.model),
                .bytes = try allocator.dupe(u8, v.bytes),
            } },
        };
    }
    return .{ .role = message.role, .blocks = blocks };
}
