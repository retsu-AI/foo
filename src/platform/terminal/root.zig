const std = @import("std");
const builtin = @import("builtin");

pub const SizeError = error{ TerminalDisconnected, Unexpected };
pub const Size = struct { columns: u16, rows: u16 };
pub const Read = union(enum) { bytes: usize, timeout, eof, terminated };

pub const Terminal = switch (builtin.os.tag) {
    .linux, .macos => @import("posix.zig").Terminal,
    .windows => @import("windows.zig").Terminal,
    else => @compileError("native terminal support requires Linux, macOS, or Windows"),
};

pub const enter = "\x1b[?1049h\x1b[?2004h";
pub const leave = "\x1b[?2004l\x1b[?1049l";

const Lifecycle = enum(u8) { idle, active, terminating };
var lifecycle: std.atomic.Value(Lifecycle) = .init(.idle);

pub fn claim() error{TerminalAlreadyOpen}!void {
    if (lifecycle.cmpxchgStrong(.idle, .active, .acquire, .monotonic) != null)
        return error.TerminalAlreadyOpen;
}

pub fn terminate() void {
    _ = lifecycle.cmpxchgStrong(.active, .terminating, .release, .monotonic);
}

pub fn terminated() bool {
    return lifecycle.load(.acquire) == .terminating;
}

pub fn release() void {
    lifecycle.store(.idle, .release);
}

pub fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}
