const io = @import("io.zig");
const provider = @import("provider.zig");
const tool = @import("tool.zig");

pub const RunId = enum(u64) { _ };
pub const SessionId = enum(u64) { _ };
pub const Stop = enum { completed, cancelled, interrupted, limit_reached, provider_error, storage_error, host_error };
pub const Outcome = struct {
    reason: Stop,
    provider_stop: ?provider.Stop = null,
    uncertain_effects: bool = false,
};
/// Only committed records carry a journal sequence. Deltas are always provisional.
pub const Event = struct {
    run: RunId,
    data: union(enum) {
        delta: provider.Delta,
        message_committed: struct { sequence: u64, message: provider.Message },
        tool_committed: struct { sequence: u64, result: tool.Result },
        finished: Outcome,
    },
};
pub const Sink = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, io.Context, Event) io.Error!void,
};

pub const Order = struct {
    last_sequence: u64 = 0,
    finished: bool = false,

    pub fn accept(self: *Order, event: Event) error{ InvalidSequence, AlreadyFinished }!void {
        if (self.finished) return error.AlreadyFinished;
        const sequence: ?u64 = switch (event.data) {
            .message_committed => |v| v.sequence,
            .tool_committed => |v| v.sequence,
            .delta, .finished => null,
        };
        if (sequence) |value| {
            if (value <= self.last_sequence) return error.InvalidSequence;
            self.last_sequence = value;
        }
        if (event.data == .finished) self.finished = true;
    }
};
