const std = @import("std");
const config = @import("config.zig");
const io = @import("io.zig");
const provider = @import("provider.zig");
const tool = @import("tool.zig");

pub const RunId = enum(u64) { _ };
pub const SessionId = enum(u64) { _ };
pub const Stop = enum { completed, cancelled, interrupted, limit_reached, provider_error, storage_error, host_error };
/// Why a provider_error run failed. A refusal has provider_stop instead.
pub const Detail = union(enum) {
    authentication: struct { endpoint: []const u8, status: ?u16 = null },
    rate_limited: struct { endpoint: []const u8, retry_after_ms: ?u64 = null },
    rejected: struct { endpoint: []const u8, status: u16 },
    transport: struct { endpoint: []const u8, kind: enum { trust, connect, disconnected, deadline } },
    protocol: struct { endpoint: []const u8 },

    /// Formats one user-facing sentence. The credential names the variable to set.
    pub fn reason(self: Detail, credential: config.SecretRef) Reason {
        return .{ .detail = self, .credential = credential };
    }

    pub const Reason = struct {
        detail: Detail,
        credential: config.SecretRef,

        pub fn format(self: Reason, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self.detail) {
                .authentication => |v| {
                    try writer.print("authentication failed for {s}", .{v.endpoint});
                    if (v.status) |status| try writer.print(" (HTTP {d})", .{status});
                    if (self.credential == .environment) try writer.print(". Set {s}", .{self.credential.environment});
                },
                .rate_limited => |v| {
                    try writer.print("rate limited by {s}", .{v.endpoint});
                    if (v.retry_after_ms) |ms| try writer.print(", retry after {d} s", .{ms / 1000 + @intFromBool(ms % 1000 != 0)});
                },
                .rejected => |v| try writer.print("{s} rejected the request (HTTP {d})", .{ v.endpoint, v.status }),
                .transport => |v| try writer.print("could not reach {s}: {s}", .{ v.endpoint, switch (v.kind) {
                    .trust => "certificate not trusted",
                    .connect => "connection failed",
                    .disconnected => "connection lost",
                    .deadline => "deadline exceeded",
                } }),
                .protocol => |v| try writer.print("{s} sent an invalid response", .{v.endpoint}),
            }
        }
    };
};
pub const Outcome = struct {
    reason: Stop,
    provider_stop: ?provider.Stop = null,
    uncertain_effects: bool = false,
    /// Set on every provider_error except a refusal. Borrows the run's endpoint.
    detail: ?Detail = null,

    /// Omits a null detail so journals without one stay readable by earlier builds.
    pub fn jsonStringify(self: Outcome, json: anytype) !void {
        try json.beginObject();
        try json.objectField("reason");
        try json.write(self.reason);
        if (self.provider_stop != null or json.options.emit_null_optional_fields) {
            try json.objectField("provider_stop");
            try json.write(self.provider_stop);
        }
        try json.objectField("uncertain_effects");
        try json.write(self.uncertain_effects);
        if (self.detail) |detail| {
            try json.objectField("detail");
            try json.write(detail);
        }
        try json.endObject();
    }
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
