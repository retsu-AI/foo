const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("root.zig");

const posix = std.posix;
const linux = std.os.linux;
const system = posix.system;
const signals = [_]posix.SIG{ .INT, .TERM, .HUP };

pub const Terminal = struct {
    io: std.Io,
    input: posix.fd_t,
    output: posix.fd_t,
    input_mode: posix.termios,
    output_mode: posix.termios,
    output_flags: u32,
    signal_actions: [signals.len]posix.Sigaction,
    active: bool = true,

    /// The caller borrows both streams and owns the terminal until restore.
    /// One reader and one writer may run at a time. Join both before restore.
    pub fn open(io: std.Io, input: std.Io.File, output: std.Io.File) !?Terminal {
        try terminal.claim();
        var opened = false;
        defer if (!opened) terminal.release();
        const in_mode = (try getMode(input.handle)) orelse return null;
        const out_mode = (try getMode(output.handle)) orelse return null;
        const in_flags: posix.O = @bitCast(try fileFlags(input.handle));
        const out_flags = try fileFlags(output.handle);
        const out_access: posix.O = @bitCast(out_flags);
        if (in_flags.ACCMODE == .WRONLY or out_access.ACCMODE == .RDONLY) return null;

        const action: posix.Sigaction = .{
            .handler = .{ .handler = signalHandler },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        var previous: [signals.len]posix.Sigaction = undefined;
        for (signals, &previous) |signal, *saved| posix.sigaction(signal, &action, saved);
        errdefer restoreSignals(&previous);

        const nonblock: u32 = @bitCast(posix.O{ .NONBLOCK = true });
        try setFileFlags(output.handle, out_flags | nonblock);
        errdefer setFileFlags(output.handle, out_flags) catch {};

        var output_raw = out_mode;
        output_raw.oflag.OPOST = false;
        try setMode(output.handle, output_raw);
        errdefer setMode(output.handle, out_mode) catch {};

        var input_raw = in_mode;
        input_raw.iflag = .{};
        input_raw.oflag.OPOST = false;
        input_raw.cflag.CSIZE = .CS8;
        input_raw.cflag.PARENB = false;
        input_raw.lflag.ECHO = false;
        input_raw.lflag.ECHONL = false;
        input_raw.lflag.ICANON = false;
        input_raw.lflag.IEXTEN = false;
        input_raw.lflag.ISIG = false;
        input_raw.cc[@backingInt(posix.V.MIN)] = 0;
        input_raw.cc[@backingInt(posix.V.TIME)] = 0;
        try setMode(input.handle, input_raw);
        errdefer restoreInputMode(input.handle, in_mode) catch {};

        var self: Terminal = .{
            .io = io,
            .input = input.handle,
            .output = output.handle,
            .input_mode = in_mode,
            .output_mode = out_mode,
            .output_flags = out_flags,
            .signal_actions = previous,
        };
        self.write(terminal.enter) catch |err| {
            self.leaveScreen();
            return err;
        };
        opened = true;
        return self;
    }

    pub fn read(self: *Terminal, buffer: []u8, timeout_ms: u32) !terminal.Read {
        if (buffer.len == 0) return .{ .bytes = 0 };
        const deadline = terminal.nowMs(self.io) + timeout_ms;
        while (true) {
            if (terminal.terminated()) return .terminated;
            try self.io.checkCancel();
            const remaining = deadline - terminal.nowMs(self.io);
            const events = try poll(self.input, posix.POLL.IN, @intCast(std.math.clamp(remaining, 0, 20)));
            if (terminal.terminated()) return .terminated;
            if (events & posix.POLL.IN != 0) {
                const count = system.read(self.input, buffer.ptr, buffer.len);
                switch (posix.errno(count)) {
                    .SUCCESS => if (count != 0) return .{ .bytes = @intCast(count) },
                    .INTR, .AGAIN => {},
                    .IO => return .eof,
                    else => |err| return posix.unexpectedErrno(err),
                }
            }
            if (events & (posix.POLL.HUP | posix.POLL.ERR) != 0) return .eof;
            if (terminal.nowMs(self.io) >= deadline) return .timeout;
        }
    }

    pub fn size(self: *Terminal) terminal.SizeError!terminal.Size {
        var area: posix.winsize = undefined;
        while (true) {
            const result = if (builtin.link_libc)
                system.ioctl(self.output, posix.T.IOCGWINSZ, &area)
            else
                linux.ioctl(self.output, posix.T.IOCGWINSZ, @intFromPtr(&area));
            switch (posix.errno(result)) {
                .SUCCESS => return .{ .columns = area.col, .rows = area.row },
                .INTR => continue,
                .NOTTY, .IO => return error.TerminalDisconnected,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }

    pub fn write(self: *Terminal, bytes: []const u8) !void {
        try self.writeBounded(bytes, 250, false);
    }

    pub fn restore(self: *Terminal) void {
        if (!self.active) return;
        self.active = false;
        self.leaveScreen();
        restoreInputMode(self.input, self.input_mode) catch {};
        setMode(self.output, self.output_mode) catch {};
        setFileFlags(self.output, self.output_flags) catch {};
        restoreSignals(&self.signal_actions);
        terminal.release();
    }

    fn leaveScreen(self: *Terminal) void {
        self.writeBounded(terminal.leave, 80, true) catch {};
    }

    fn writeBounded(self: *Terminal, bytes: []const u8, timeout_ms: u32, restoring: bool) !void {
        const deadline = terminal.nowMs(self.io) + timeout_ms;
        var remaining = bytes;
        while (remaining.len != 0) {
            if (!restoring) {
                if (terminal.terminated()) return error.TerminalTerminated;
                try self.io.checkCancel();
            }
            const count = system.write(self.output, remaining.ptr, remaining.len);
            switch (posix.errno(count)) {
                .SUCCESS => {
                    if (count == 0) return error.TerminalDisconnected;
                    remaining = remaining[@intCast(count)..];
                    if (remaining.len == 0) return;
                },
                .AGAIN, .INTR => {},
                .IO, .PIPE => return error.TerminalDisconnected,
                else => |err| return posix.unexpectedErrno(err),
            }
            const time_left = deadline - terminal.nowMs(self.io);
            if (time_left <= 0) return error.TerminalWriteTimeout;
            const events = try poll(self.output, posix.POLL.OUT, @intCast(@min(time_left, 20)));
            if (events & (posix.POLL.HUP | posix.POLL.ERR) != 0) return error.TerminalDisconnected;
        }
    }
};

fn poll(fd: posix.fd_t, events: i16, timeout_ms: i32) !i16 {
    var descriptor: posix.pollfd = .{ .fd = fd, .events = events, .revents = 0 };
    switch (posix.errno(system.poll(@ptrCast(&descriptor), 1, timeout_ms))) {
        .SUCCESS => {
            if (descriptor.revents & posix.POLL.NVAL != 0) return error.TerminalDisconnected;
            return descriptor.revents;
        },
        .INTR => return 0,
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn signalHandler(_: posix.SIG) callconv(.c) void {
    terminal.terminate();
}

fn restoreSignals(actions: *const [signals.len]posix.Sigaction) void {
    for (signals, actions) |signal, *saved| posix.sigaction(signal, saved, null);
}

fn getMode(fd: posix.fd_t) !?posix.termios {
    // Linux's libc termios has a different layout from the kernel struct in std.
    const api = if (builtin.os.tag == .linux) linux else system;
    while (true) {
        var mode: posix.termios = std.mem.zeroes(posix.termios);
        switch (api.errno(api.tcgetattr(fd, &mode))) {
            .SUCCESS => return mode,
            .INTR => continue,
            .NOTTY, .BADF => return null,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn setMode(fd: posix.fd_t, mode: posix.termios) !void {
    const api = if (builtin.os.tag == .linux) linux else system;
    while (true) {
        switch (api.errno(api.tcsetattr(fd, .NOW, &mode))) {
            .SUCCESS => return,
            .INTR => continue,
            .NOTTY, .BADF, .IO => return error.TerminalDisconnected,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn restoreInputMode(fd: posix.fd_t, mode: posix.termios) !void {
    try setMode(fd, mode);
    if (builtin.os.tag == .macos and mode.lflag.ICANON and !mode.lflag.PENDIN) {
        // XNU sets PENDIN when TCSANOW re-enables ICANON. FIONREAD reprocesses queued input without draining output.
        const darwin_fionread = 0x4004667f;
        var available: c_int = undefined;
        while (posix.errno(system.ioctl(fd, darwin_fionread, &available)) == .INTR) {}
    }
}

fn fileFlags(fd: posix.fd_t) !u32 {
    while (true) {
        const result = system.fcntl(fd, posix.F.GETFL, @as(u32, 0));
        switch (posix.errno(result)) {
            .SUCCESS => return @intCast(result),
            .INTR => continue,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn setFileFlags(fd: posix.fd_t, flags: u32) !void {
    while (true) {
        switch (posix.errno(system.fcntl(fd, posix.F.SETFL, flags))) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}
