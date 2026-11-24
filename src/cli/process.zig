const std = @import("std");
const builtin = @import("builtin");
const foo = @import("foo");
const cli = @import("root.zig");

const check_interval: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } };
const SignalState = enum(u8) { vacant, clear, interrupted };
var state: std.atomic.Value(SignalState) = .init(.vacant);

/// Use from the process entrypoint when the CLI owns the signal handlers.
pub fn execute(
    allocator: std.mem.Allocator,
    operation: foo.io.Context,
    args: []const []const u8,
    options: cli.Options,
) cli.Exit {
    if (args.len == 0 or !(std.mem.eql(u8, args[0], "run") or std.mem.eql(u8, args[0], "rpc")))
        return cli.execute(allocator, operation, args, options);

    return withSignals(operation, executeActive, .{ allocator, args, options });
}

pub fn withSignals(
    operation: foo.io.Context,
    comptime function: anytype,
    args: anytype,
) cli.Exit {
    operation.check() catch |err| return cli.Exit.fromError(err);
    const handlers = Handlers.install() catch return .host;
    defer handlers.restore();
    var cancellation: foo.io.Cancellation = .{};
    var active = operation;
    active.cancellation = &cancellation;
    var watcher = operation.io.concurrent(watch, .{ operation, &cancellation }) catch return .host;
    defer watcher.cancel(operation.io);
    return @call(.auto, function, .{active} ++ args);
}

fn executeActive(operation: foo.io.Context, allocator: std.mem.Allocator, args: []const []const u8, options: cli.Options) cli.Exit {
    return cli.execute(allocator, operation, args, options);
}

fn watch(operation: foo.io.Context, cancellation: *foo.io.Cancellation) void {
    while (state.load(.acquire) != .interrupted) {
        operation.cancellation.check() catch {
            cancellation.request();
            return;
        };
        std.Io.sleep(operation.io, .fromMilliseconds(10), .awake) catch return;
    }
    cancellation.request();
}

pub fn fileOperation(
    operation: foo.io.Context,
    comptime function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
    const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const Task = struct {
        fn run(io: std.Io, done: *std.Io.Event, values: @TypeOf(args)) Result {
            defer done.set(io);
            return @call(.auto, function, values);
        }
    };
    try operation.check();
    const io = operation.io;
    var done: std.Io.Event = .unset;
    var future = io.concurrent(Task.run, .{ io, &done, args }) catch return error.Unavailable;
    errdefer if (future.cancel(io)) |_| {} else |_| {};
    while (!done.isSet()) {
        try operation.check();
        done.waitTimeout(io, check_interval) catch |err| switch (err) {
            error.Canceled => return error.Cancelled,
            error.Timeout => {},
        };
    }
    return future.await(io);
}

fn handlePosix(_: std.posix.SIG) callconv(.c) void {
    interrupt();
}

fn handleConsole(event: u32) callconv(.winapi) c_int {
    const ctrl_c = 0;
    const ctrl_break = 1;
    if (event != ctrl_c and event != ctrl_break) return 0;
    interrupt();
    return 1;
}

fn interrupt() void {
    _ = state.cmpxchgStrong(.clear, .interrupted, .release, .monotonic);
}

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: *const fn (u32) callconv(.winapi) c_int,
    add: c_int,
) callconv(.winapi) c_int;

const Handlers = struct {
    saved: if (builtin.os.tag == .windows) void else [2]std.posix.Sigaction,

    fn install() error{ SignalHandlersBusy, SignalHandlersUnavailable }!Handlers {
        if (state.cmpxchgStrong(.vacant, .clear, .acquire, .monotonic) != null)
            return error.SignalHandlersBusy;
        errdefer state.store(.vacant, .release);
        var self: Handlers = undefined;
        switch (builtin.os.tag) {
            .windows => {
                if (SetConsoleCtrlHandler(handleConsole, 1) == 0) return error.SignalHandlersUnavailable;
            },
            .linux, .macos => {
                const action: std.posix.Sigaction = .{
                    .handler = .{ .handler = handlePosix },
                    .mask = std.posix.sigemptyset(),
                    .flags = 0,
                };
                std.posix.sigaction(.INT, &action, &self.saved[0]);
                std.posix.sigaction(.TERM, &action, &self.saved[1]);
            },
            else => return error.SignalHandlersUnavailable,
        }
        return self;
    }

    fn restore(self: Handlers) void {
        switch (builtin.os.tag) {
            .windows => _ = SetConsoleCtrlHandler(handleConsole, 0),
            .linux, .macos => {
                std.posix.sigaction(.TERM, &self.saved[1], null);
                std.posix.sigaction(.INT, &self.saved[0], null);
            },
            else => unreachable,
        }
        state.store(.vacant, .release);
    }
};
