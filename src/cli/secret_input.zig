const std = @import("std");
const builtin = @import("builtin");
const foo = @import("foo");
const auth = @import("auth");
const posix = std.posix;
const win = std.os.windows;
const File = std.Io.File;
const Error = foo.io.Error || error{TerminalRequired};

pub fn read(operation: foo.io.Context, input: File, diagnostic: File, prompt: []const u8, buffer: []u8) Error![]const u8 {
    const mode = try Mode.hide(input);
    defer diagnostic.writeStreamingAll(operation.io, "\n") catch {};
    defer mode.restore(input);
    diagnostic.writeStreamingAll(operation.io, prompt) catch return error.IoFailure;
    const key = if (builtin.os.tag == .windows)
        try readWindows(operation, input, buffer)
    else
        try readPosix(operation, input, buffer);
    try operation.check();
    if (key.len == 0) return error.InvalidInput;
    return key;
}

const Termios = if (builtin.os.tag == .linux) std.os.linux.termios else if (builtin.os.tag == .macos) posix.termios else void;
const terminal = if (builtin.os.tag == .linux) std.os.linux else posix.system;
const Mode = struct {
    original: if (builtin.os.tag == .windows) u32 else Termios,

    fn hide(input: File) Error!Mode {
        if (builtin.os.tag == .windows) {
            var original: u32 = undefined;
            var count: u32 = undefined;
            if (GetConsoleMode(input.handle, &original) == .FALSE or
                GetNumberOfConsoleInputEvents(input.handle, &count) == .FALSE) return error.TerminalRequired;
            const processed_line_echo = 0x0007;
            if (SetConsoleMode(input.handle, original & ~@as(u32, processed_line_echo)) == .FALSE) return error.IoFailure;
            return .{ .original = original };
        }
        if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.TerminalRequired;
        var original: Termios = undefined;
        while (true) switch (terminal.errno(terminal.tcgetattr(input.handle, &original))) {
            .SUCCESS => break,
            .INTR => continue,
            .NOTTY, .BADF => return error.TerminalRequired,
            else => return error.IoFailure,
        };
        var hidden = original;
        hidden.lflag.ECHO = false;
        hidden.lflag.ECHONL = false;
        hidden.lflag.ICANON = false;
        hidden.lflag.ISIG = false;
        hidden.lflag.IEXTEN = false;
        hidden.cc[@backingInt(terminal.V.MIN)] = 1;
        hidden.cc[@backingInt(terminal.V.TIME)] = 0;
        try setMode(input, hidden);
        return .{ .original = original };
    }

    fn restore(self: Mode, input: File) void {
        if (builtin.os.tag == .windows) {
            _ = FlushConsoleInputBuffer(input.handle);
            _ = SetConsoleMode(input.handle, self.original);
        } else {
            setMode(input, self.original) catch return;
            if (builtin.os.tag == .macos and self.original.lflag.ICANON and !self.original.lflag.PENDIN) {
                const darwin_fionread = 0x4004667f;
                var available: c_int = undefined;
                while (posix.errno(terminal.ioctl(input.handle, darwin_fionread, &available)) == .INTR) {}
            }
        }
    }
};

fn setMode(input: File, mode: Termios) Error!void {
    while (true) switch (terminal.errno(terminal.tcsetattr(input.handle, .FLUSH, &mode))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.IoFailure,
    };
}

fn readPosix(operation: foo.io.Context, input: File, buffer: []u8) Error![]const u8 {
    var len: usize = 0;
    var pending: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &pending);
    while (true) {
        try operation.check();
        var watch = [_]posix.pollfd{.{ .fd = input.handle, .events = posix.POLL.IN, .revents = 0 }};
        if ((posix.poll(&watch, 20) catch return error.IoFailure) == 0) continue;
        const count = input.readStreaming(operation.io, &.{&pending}) catch |err| return switch (err) {
            error.EndOfStream, error.Canceled => error.Cancelled,
            else => error.IoFailure,
        };
        if (count == 0) return error.Cancelled;
        for (pending[0..count]) |byte| switch (byte) {
            '\r', '\n' => return buffer[0..len],
            3, 4, 26 => return error.Cancelled,
            8, 127 => {
                if (len == 0) continue;
                len -= 1;
                while (len > 0 and buffer[len] & 0xc0 == 0x80) len -= 1;
            },
            21 => len = 0,
            else => {
                if (len == buffer.len) return error.LimitExceeded;
                buffer[len] = byte;
                len += 1;
            },
        };
    }
}

const InputRecord = extern struct {
    kind: u16,
    key: extern struct {
        down: win.BOOL,
        repeat: u16,
        virtual_key: u16,
        scan: u16,
        text: u16,
        modifiers: u32,
    },
};
extern "kernel32" fn GetConsoleMode(win.HANDLE, *u32) callconv(.winapi) win.BOOL;
extern "kernel32" fn SetConsoleMode(win.HANDLE, u32) callconv(.winapi) win.BOOL;
extern "kernel32" fn ReadConsoleInputW(win.HANDLE, *InputRecord, u32, *u32) callconv(.winapi) win.BOOL;
extern "kernel32" fn FlushConsoleInputBuffer(win.HANDLE) callconv(.winapi) win.BOOL;
extern "kernel32" fn WaitForSingleObject(win.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn GetNumberOfConsoleInputEvents(win.HANDLE, *u32) callconv(.winapi) win.BOOL;

fn readWindows(operation: foo.io.Context, input: File, buffer: []u8) Error![]const u8 {
    var text: [auth.max_secret_bytes]u16 = undefined;
    defer std.crypto.secureZero(u16, &text);
    var len: usize = 0;
    while (true) {
        try operation.check();
        switch (WaitForSingleObject(input.handle, 20)) {
            0 => {},
            258 => continue,
            else => return error.IoFailure,
        }
        var count: u32 = undefined;
        if (GetNumberOfConsoleInputEvents(input.handle, &count) == .FALSE) return error.TerminalRequired;
        if (count == 0) continue;
        var record: InputRecord = undefined;
        if (ReadConsoleInputW(input.handle, &record, 1, &count) == .FALSE) return error.IoFailure;
        defer std.crypto.secureZero(u8, std.mem.asBytes(&record));
        if (count == 0 or record.kind != 1 or record.key.down == .FALSE) continue;
        const byte = record.key.text;
        for (0..record.key.repeat) |_| switch (byte) {
            0 => {},
            '\r', '\n' => return encodeUtf8(buffer, text[0..len]),
            3, 4, 26 => return error.Cancelled,
            8, 127 => {
                if (len == 0) continue;
                len -= 1;
                if (len > 0 and text[len] >= 0xdc00 and text[len] <= 0xdfff) len -= 1;
            },
            21 => len = 0,
            else => {
                if (len == text.len) return error.LimitExceeded;
                text[len] = byte;
                len += 1;
            },
        };
    }
}

fn encodeUtf8(buffer: []u8, text: []const u16) Error![]const u8 {
    var it = std.unicode.Utf16LeIterator.init(text);
    var len: usize = 0;
    while (it.nextCodepoint() catch return error.InvalidInput) |point| {
        const size = std.unicode.utf8CodepointSequenceLength(point) catch unreachable;
        if (size > buffer.len - len) return error.LimitExceeded;
        len += std.unicode.utf8Encode(point, buffer[len..]) catch unreachable;
    }
    return buffer[0..len];
}
