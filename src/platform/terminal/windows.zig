const std = @import("std");
const terminal = @import("root.zig");
const win = std.os.windows;

const processed_input = 0x0001;
const line_input = 0x0002;
const echo_input = 0x0004;
const window_input = 0x0008;
const mouse_input = 0x0010;
const quick_edit = 0x0040;
const extended_flags = 0x0080;
const vt_input = 0x0200;

const processed_output = 0x0001;
const vt_output = 0x0004;
const delayed_wrap = 0x0008;
const utf8_code_page = 65001;

const KeyEvent = extern struct {
    down: win.BOOL,
    repeat: u16,
    key: u16,
    scan: u16,
    text: u16,
    modifiers: u32,
};

const InputRecord = extern struct {
    kind: u16,
    event: extern union {
        key: KeyEvent,
    },
};

const ScreenInfo = extern struct {
    size: win.COORD,
    cursor: win.COORD,
    attributes: u16,
    left: i16,
    top: i16,
    right: i16,
    bottom: i16,
    max_window: win.COORD,
};

extern "kernel32" fn GetConsoleMode(win.HANDLE, *u32) callconv(.winapi) win.BOOL;
extern "kernel32" fn SetConsoleMode(win.HANDLE, u32) callconv(.winapi) win.BOOL;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
extern "kernel32" fn SetConsoleOutputCP(u32) callconv(.winapi) win.BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(win.HANDLE, *ScreenInfo) callconv(.winapi) win.BOOL;
extern "kernel32" fn GetNumberOfConsoleInputEvents(win.HANDLE, *u32) callconv(.winapi) win.BOOL;
extern "kernel32" fn ReadConsoleInputW(win.HANDLE, *InputRecord, u32, *u32) callconv(.winapi) win.BOOL;
extern "kernel32" fn WaitForSingleObject(win.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn SetConsoleCtrlHandler(*const fn (u32) callconv(.winapi) win.BOOL, win.BOOL) callconv(.winapi) win.BOOL;

pub const Terminal = struct {
    io: std.Io,
    input: win.HANDLE,
    output: std.Io.File,
    input_mode: u32,
    output_mode: u32,
    code_page: u32,
    keys: KeyStream = .{},
    active: bool = true,

    /// The caller borrows both streams and owns the terminal until restore.
    /// One reader and one writer may run at a time. Join both before restore.
    pub fn open(io: std.Io, input: std.Io.File, output: std.Io.File) !?Terminal {
        try terminal.claim();
        var opened = false;
        defer if (!opened) terminal.release();
        var input_mode: u32 = undefined;
        var output_mode: u32 = undefined;
        var count: u32 = undefined;
        var area: ScreenInfo = undefined;
        if (GetConsoleMode(input.handle, &input_mode) == .FALSE or
            GetConsoleMode(output.handle, &output_mode) == .FALSE or
            GetNumberOfConsoleInputEvents(input.handle, &count) == .FALSE or
            GetConsoleScreenBufferInfo(output.handle, &area) == .FALSE)
            return null;

        const code_page = GetConsoleOutputCP();
        if (code_page == 0) return error.TerminalSetupFailed;
        if (SetConsoleCtrlHandler(controlHandler, .TRUE) == .FALSE) return error.TerminalSetupFailed;
        errdefer _ = SetConsoleCtrlHandler(controlHandler, .FALSE);

        if (SetConsoleMode(input.handle, (input_mode & ~@as(u32, processed_input | line_input | echo_input | mouse_input | quick_edit)) |
            window_input | extended_flags | vt_input) == .FALSE) return error.TerminalSetupFailed;
        errdefer _ = SetConsoleMode(input.handle, input_mode);
        if (SetConsoleMode(output.handle, output_mode | processed_output | vt_output | delayed_wrap) == .FALSE)
            return error.TerminalSetupFailed;
        errdefer _ = SetConsoleMode(output.handle, output_mode);
        if (SetConsoleOutputCP(utf8_code_page) == .FALSE) return error.TerminalSetupFailed;
        errdefer _ = SetConsoleOutputCP(code_page);

        var self: Terminal = .{
            .io = io,
            .input = input.handle,
            .output = output,
            .input_mode = input_mode,
            .output_mode = output_mode,
            .code_page = code_page,
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
        var count: usize = 0;
        while (true) {
            if (terminal.terminated()) return .terminated;
            try self.io.checkCancel();
            count += self.keys.drain(buffer[count..]);
            if (count == buffer.len) break;

            const now = terminal.nowMs(self.io);
            const remaining = if (count != 0) 0 else std.math.clamp(deadline - now, 0, 20);
            switch (WaitForSingleObject(self.input, @intCast(remaining))) {
                0 => {
                    var record: InputRecord = undefined;
                    var read_count: u32 = undefined;
                    if (ReadConsoleInputW(self.input, &record, 1, &read_count) == .FALSE) {
                        if (terminal.terminated()) return .terminated;
                        return switch (win.GetLastError()) {
                            .INVALID_HANDLE, .BROKEN_PIPE, .HANDLE_EOF => if (count != 0) .{ .bytes = count } else .eof,
                            else => error.TerminalReadFailed,
                        };
                    }
                    if (read_count != 0 and record.kind == 1) self.keys.feed(record.event.key);
                    if (now >= deadline and self.keys.repeat == 0) break;
                },
                258 => if (count != 0 or terminal.nowMs(self.io) >= deadline) break,
                else => return switch (win.GetLastError()) {
                    .INVALID_HANDLE, .BROKEN_PIPE, .HANDLE_EOF => if (count != 0) .{ .bytes = count } else .eof,
                    else => error.TerminalReadFailed,
                },
            }
        }
        return if (count != 0) .{ .bytes = count } else .timeout;
    }

    pub fn size(self: *Terminal) terminal.SizeError!terminal.Size {
        var area: ScreenInfo = undefined;
        if (GetConsoleScreenBufferInfo(self.output.handle, &area) == .FALSE)
            return error.TerminalDisconnected;
        return .{
            .columns = @intCast(@as(i32, area.right) - area.left + 1),
            .rows = @intCast(@as(i32, area.bottom) - area.top + 1),
        };
    }

    pub fn write(self: *Terminal, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len != 0) {
            if (terminal.terminated()) return error.TerminalTerminated;
            const chunk = utf8Chunk(remaining);
            const count = try self.output.writeStreaming(self.io, &.{}, &.{chunk}, 1);
            if (count == 0) return error.TerminalDisconnected;
            remaining = remaining[count..];
        }
    }

    pub fn restore(self: *Terminal) void {
        if (!self.active) return;
        self.active = false;
        self.leaveScreen();
        _ = SetConsoleOutputCP(self.code_page);
        _ = SetConsoleMode(self.output.handle, self.output_mode);
        _ = SetConsoleMode(self.input, self.input_mode);
        _ = SetConsoleCtrlHandler(controlHandler, .FALSE);
        terminal.release();
    }

    fn leaveScreen(self: *Terminal) void {
        const previous = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(previous);
        var done: std.Io.Event = .unset;
        var writer = self.io.concurrent(writeExitSequence, .{ self.output, self.io, &done }) catch return;
        done.waitTimeout(self.io, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(80) } }) catch {};
        writer.cancel(self.io);
    }
};

fn writeExitSequence(output: std.Io.File, io: std.Io, done: *std.Io.Event) void {
    defer done.set(io);
    _ = output.writeStreaming(io, &.{}, &.{terminal.leave}, 1) catch {};
}

fn controlHandler(event: u32) callconv(.winapi) win.BOOL {
    const ctrl_c = 0;
    const ctrl_break = 1;
    if (event != ctrl_c and event != ctrl_break) return .FALSE;
    terminal.terminate();
    return .TRUE;
}

fn utf8Chunk(bytes: []const u8) []const u8 {
    var end = @min(bytes.len, 4096);
    if (end == bytes.len) return bytes;
    while (end > 0 and bytes[end] & 0xc0 == 0x80) end -= 1;
    return bytes[0..if (end == 0) 4096 else end];
}

const KeyStream = struct {
    bytes: [12]u8 = undefined,
    len: usize = 0,
    offset: usize = 0,
    repeat: u16 = 0,
    high_surrogate: ?u16 = null,

    fn drain(self: *KeyStream, out: []u8) usize {
        var written: usize = 0;
        while (self.repeat != 0 and written < out.len) {
            const count = @min(out.len - written, self.len - self.offset);
            @memcpy(out[written..][0..count], self.bytes[self.offset..][0..count]);
            written += count;
            self.offset += count;
            if (self.offset == self.len) {
                self.offset = 0;
                self.repeat -= 1;
            }
        }
        return written;
    }

    fn feed(self: *KeyStream, event: KeyEvent) void {
        const menu_key = 0x12;
        if (event.down == .FALSE and !(event.key == menu_key and event.text != 0)) return;
        const alt = event.modifiers & 0x0003 != 0;
        const ctrl = event.modifiers & 0x000c != 0;
        const sequence: []const u8 = switch (event.key) {
            0x0d => if (ctrl and !alt) "\x1b[13;5u" else if (alt and !ctrl) "\x1b\r" else "\r",
            0x08 => "\x7f",
            0x1b => "\x1b",
            0x21 => "\x1b[5~",
            0x22 => "\x1b[6~",
            0x23 => "\x1b[F",
            0x24 => "\x1b[H",
            0x25 => "\x1b[D",
            0x26 => "\x1b[A",
            0x27 => "\x1b[C",
            0x28 => "\x1b[B",
            0x2e => "\x1b[3~",
            else => "",
        };

        const unit = if (event.text == 0 and ctrl and !alt and event.key >= 'A' and event.key <= 'Z')
            event.key - 'A' + 1
        else
            event.text;
        if (sequence.len == 0 and unit == 0) return;

        self.len = 0;
        const high = self.high_surrogate;
        self.high_surrogate = null;
        if (sequence.len != 0) {
            if (high != null) self.appendCodepoint(0xfffd);
            @memcpy(self.bytes[self.len..][0..sequence.len], sequence);
            self.len += sequence.len;
        } else switch (unit) {
            0xd800...0xdbff => {
                if (high != null) self.appendCodepoint(0xfffd);
                self.high_surrogate = unit;
            },
            0xdc00...0xdfff => {
                const codepoint: u21 = if (high) |lead|
                    0x10000 + ((@as(u21, lead) - 0xd800) << 10) + (@as(u21, unit) - 0xdc00)
                else
                    0xfffd;
                self.appendCodepoint(codepoint);
            },
            else => {
                if (high != null) self.appendCodepoint(0xfffd);
                self.appendCodepoint(unit);
            },
        }
        if (self.len != 0) self.repeat = @max(event.repeat, 1);
    }

    fn appendCodepoint(self: *KeyStream, codepoint: u21) void {
        self.len += std.unicode.utf8Encode(codepoint, self.bytes[self.len..]) catch unreachable;
    }
};
