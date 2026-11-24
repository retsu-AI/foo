const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("terminal");

const Mode = enum { read, @"error", eof, signal };
const Outcome = enum { exit, @"error", eof, terminated };

extern "kernel32" fn GetConsoleMode(std.os.windows.HANDLE, *u32) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
extern "kernel32" fn GenerateConsoleCtrlEvent(u32, u32) callconv(.winapi) std.os.windows.BOOL;

const ConsoleState = if (builtin.os.tag == .windows) struct {
    input_mode: u32,
    output_mode: u32,
    code_page: u32,
} else void;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const mode = if (args.len == 1) .read else std.meta.stringToEnum(Mode, args[1]) orelse return error.UnknownMode;
    const io = init.io;
    const input: std.Io.File = .stdin();
    const output: std.Io.File = .stdout();
    const previous = consoleState(input, output);

    var device = try terminal.Terminal.open(io, input, output) orelse {
        try output.writeStreamingAll(io, "fallback\n");
        return;
    };

    const result = run(&device, mode) catch |err| switch (err) {
        error.InjectedFailure => Outcome.@"error",
        else => return err,
    };
    device.restore();
    if (builtin.os.tag == .windows) {
        const restored = consoleState(input, output) orelse return error.ConsoleDetached;
        if (!std.meta.eql(previous.?, restored)) return error.ConsoleModeChanged;
    }

    if (result == .eof) {
        try std.Io.File.stderr().writeStreamingAll(io, "eof\n");
    } else {
        try output.writeStreamingAll(io, switch (result) {
            .exit => "exit\r\n",
            .@"error" => "error\r\n",
            .terminated => "terminated\r\n",
            .eof => unreachable,
        });
    }
}

fn run(device: *terminal.Terminal, mode: Mode) !Outcome {
    defer device.restore();
    var last_size = try device.size();
    try reportSize(device, "ready", last_size);
    var buffer: [128]u8 = undefined;
    while (true) {
        switch (try device.read(&buffer, 20)) {
            .bytes => |count| {
                const bytes = buffer[0..count];
                if (mode == .@"error" and std.mem.indexOfScalar(u8, bytes, '!') != null)
                    return error.InjectedFailure;
                if (mode == .signal and std.mem.indexOfScalar(u8, bytes, '!') != null) {
                    if (builtin.os.tag == .windows) {
                        if (GenerateConsoleCtrlEvent(1, 0) == .FALSE) return error.ControlEventFailed;
                    }
                    continue;
                }
                if (std.mem.indexOfScalar(u8, bytes, 4) != null) return .exit;
                var formatted: [buffer.len * 2 + 8]u8 = undefined;
                @memcpy(formatted[0..6], "input ");
                const digits = "0123456789abcdef";
                for (bytes, 0..) |byte, index| {
                    formatted[6 + index * 2] = digits[byte >> 4];
                    formatted[7 + index * 2] = digits[byte & 0xf];
                }
                @memcpy(formatted[6 + count * 2 ..][0..2], "\r\n");
                try device.write(formatted[0 .. 8 + count * 2]);
            },
            .timeout => {},
            .eof => return .eof,
            .terminated => return .terminated,
        }

        const size = device.size() catch |err| switch (err) {
            error.TerminalDisconnected => return .eof,
            else => return err,
        };
        if (!std.meta.eql(last_size, size)) {
            try reportSize(device, "size", size);
            last_size = size;
        }
    }
}

fn consoleState(input: std.Io.File, output: std.Io.File) ?ConsoleState {
    if (builtin.os.tag != .windows) return {};
    var state: ConsoleState = undefined;
    if (GetConsoleMode(input.handle, &state.input_mode) == .FALSE or
        GetConsoleMode(output.handle, &state.output_mode) == .FALSE) return null;
    state.code_page = GetConsoleOutputCP();
    return state;
}

fn reportSize(device: *terminal.Terminal, label: []const u8, size: terminal.Size) !void {
    var buffer: [48]u8 = undefined;
    try device.write(try std.fmt.bufPrint(&buffer, "{s} {d} {d}\r\n", .{ label, size.columns, size.rows }));
}
