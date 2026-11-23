const std = @import("std");
const io = @import("io.zig");
const events = @import("events.zig");
const provider = @import("provider.zig");
const tool = @import("tool.zig");

pub const format_version: u32 = 1;
pub const NestedTool = struct {
    parent_call_id: []const u8,
    ordinal: u32,
    data: union(enum) { dispatch_intent: tool.Invocation, tool_result: tool.Result },
};

pub const Record = union(enum) {
    header: struct { version: u32 = format_version, config_identity: []const u8 },
    message: provider.Message,
    dispatch_intent: tool.Invocation,
    tool_result: tool.Result,
    nested_tool: NestedTool,
    finished: events.Outcome,
};
pub const Error = io.Error || error{ CommitFailed, CorruptHistory, UnsupportedVersion, WriterBusy };
pub const Recovery = struct {
    messages: []const provider.Message,
    /// Includes unresolved dispatches. An unresolved child follows its parent ID.
    /// Recovery never replays an unresolved call.
    uncertain_call_ids: []const []const u8,
    last_sequence: u64,
    interrupted: bool,
};
pub const Store = struct {
    context: *anyopaque,
    /// Success means the record and referenced artifacts passed the platform's
    /// sync operation; only then may the caller publish or start the next effect.
    /// Failure after an effect stops execution with an uncertain durable outcome.
    commit_fn: *const fn (*anyopaque, io.Context, Record) Error!u64,
    /// Copies a validated completed prefix and uncertainty report into the arena.
    load_fn: *const fn (*anyopaque, std.mem.Allocator, io.Context) Error!Recovery,
};
