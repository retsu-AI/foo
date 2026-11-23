const std = @import("std");
const foo = @import("foo");
const process = foo.io;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Fd = posix.fd_t;
const Pipe = [2]Fd;
const PipeKind = enum { stdin, stdout, stderr, lease, status };
const pipe_count = @typeInfo(PipeKind).@"enum".field_names.len;
const Message = enum(u8) { ready = 1, exited, signalled, failed };
const LaunchFailure = enum(u8) { invalid = 1, unavailable, limit, io };

extern "c" fn foo_process_pipes(pipes: *[pipe_count]Pipe) c_int;
extern "c" fn foo_process_spawn(
    pid: *posix.pid_t,
    path: [*:0]const u8,
    fds: [*]const Fd,
    fd_count: usize,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) c_int;
extern "c" fn foo_process_write(fd: Fd, bytes: [*]const u8, len: usize) isize;

pub const Native = struct {
    environ: std.process.Environ = .empty,
    guardian_path: ?[]const u8 = null,

    pub fn interface(self: *Native) process.Spawner {
        return .{ .context = self, .spawn_fn = spawn };
    }

    fn spawn(
        opaque_self: *anyopaque,
        allocator: Allocator,
        operation: process.Context,
        request: process.Spawn,
    ) process.Error!process.Child {
        const self: *Native = @ptrCast(@alignCast(opaque_self));
        try check(operation);
        const guardian = self.guardian_path orelse return error.Unavailable;
        if (!std.Io.Dir.path.isAbsolutePosix(guardian) or hasNull(guardian)) return error.InvalidInput;
        if (request.argv.len == 0 or request.argv[0].len == 0 or request.cwd.len == 0 or hasNull(request.cwd))
            return error.InvalidInput;
        for (request.argv) |arg| if (hasNull(arg)) return error.InvalidInput;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var environment = if (request.inherit_environment)
            self.environ.createMap(scratch) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Unexpected => error.IoFailure,
            }
        else
            std.process.Environ.Map.init(scratch);
        for (request.environment) |entry| {
            if (entry.name.len == 0 or hasNull(entry.name) or
                std.mem.findScalar(u8, entry.name, '=') != null or hasNull(entry.value)) return error.InvalidInput;
            try environment.put(entry.name, entry.value);
        }
        var environment_bytes: std.ArrayList(u8) = .empty;
        var entries = environment.iterator();
        while (entries.next()) |entry| {
            try environment_bytes.appendSlice(scratch, entry.key_ptr.*);
            try environment_bytes.append(scratch, '=');
            try environment_bytes.appendSlice(scratch, entry.value_ptr.*);
            try environment_bytes.append(scratch, 0);
        }
        const environment_size = std.math.cast(u32, environment_bytes.items.len) orelse return error.LimitExceeded;

        const argv = try scratch.allocSentinel(?[*:0]const u8, request.argv.len + 3, null);
        const guardian_z = try scratch.dupeSentinel(u8, guardian, 0);
        argv[0] = guardian_z.ptr;
        argv[1] = try std.fmt.allocPrintSentinel(scratch, "{d}", .{posix.system.getpid()}, 0);
        argv[2] = (try scratch.dupeSentinel(u8, request.cwd, 0)).ptr;
        for (request.argv, argv[3..]) |arg, *out| out.* = (try scratch.dupeSentinel(u8, arg, 0)).ptr;

        const owned = try allocator.create(OwnedChild);
        errdefer allocator.destroy(owned);
        var pipes: [pipe_count]Pipe = undefined;
        if (foo_process_pipes(&pipes) != 0) return error.IoFailure;
        defer for (&pipes) |*pipe| {
            for (pipe) |fd| if (fd >= 0) close(fd);
        };
        const lease = &pipes[@backingInt(PipeKind.lease)][1];
        const source_fds = [pipe_count]Fd{
            pipes[@backingInt(PipeKind.stdin)][0],
            pipes[@backingInt(PipeKind.stdout)][1],
            pipes[@backingInt(PipeKind.stderr)][1],
            pipes[@backingInt(PipeKind.lease)][0],
            pipes[@backingInt(PipeKind.status)][1],
        };
        try check(operation);
        var guardian_pid: posix.pid_t = undefined;
        const guardian_env = [_:null]?[*:0]const u8{};
        const spawn_error = foo_process_spawn(&guardian_pid, guardian_z.ptr, &source_fds, source_fds.len, argv.ptr, &guardian_env);
        if (spawn_error != 0) return switch (@as(posix.E, @fromBackingInt(@intCast(spawn_error)))) {
            .@"2BIG" => error.LimitExceeded,
            .ACCES, .NOENT, .NOTDIR, .PERM => error.Unavailable,
            else => error.IoFailure,
        };
        for (&pipes, source_fds) |*pipe, source| {
            close(source);
            pipe[if (pipe[0] == source) 0 else 1] = -1;
        }
        const status = &pipes[@backingInt(PipeKind.status)][0];
        errdefer {
            close(take(lease));
            reap(guardian_pid, status.*, false) catch {};
        }
        const header = std.mem.asBytes(&environment_size);
        writeAll(lease.*, operation, header) catch |err| {
            if (err != error.Disconnected) return err;
        };
        writeAll(lease.*, operation, environment_bytes.items) catch |err| {
            if (err != error.Disconnected) return err;
        };
        const result = try readMessage(status.*, operation);
        switch (result.kind) {
            .ready => {},
            .failed => return launchError(result.value),
            else => return error.IoFailure,
        }
        try check(operation);

        owned.* = .{
            .allocator = allocator,
            .guardian_pid = guardian_pid,
            .lease = .init(take(lease)),
            .status = take(status),
            .stdin = take(&pipes[@backingInt(PipeKind.stdin)][1]),
            .stdout = take(&pipes[@backingInt(PipeKind.stdout)][0]),
            .stderr = take(&pipes[@backingInt(PipeKind.stderr)][0]),
        };
        return .{
            .context = owned,
            .stdin = .{ .context = owned, .write_fn = OwnedChild.writeStdin },
            .stdout = .{ .context = &owned.stdout, .read_fn = readOutput },
            .stderr = .{ .context = &owned.stderr, .read_fn = readOutput },
            .close_stdin_fn = OwnedChild.closeStdin,
            .terminate_fn = OwnedChild.terminate,
            .wait_fn = OwnedChild.wait,
            .release_fn = OwnedChild.release,
        };
    }
};

const OwnedChild = struct {
    allocator: Allocator,
    guardian_pid: posix.pid_t,
    lease: std.atomic.Value(Fd),
    status: Fd,
    stdin: Fd,
    stdout: Fd,
    stderr: Fd,
    exit: ?process.ProcessExit = null,

    fn writeStdin(context: *anyopaque, operation: process.Context, bytes: []const u8) process.Error!void {
        const self: *OwnedChild = @ptrCast(@alignCast(context));
        if (self.stdin < 0) return error.Disconnected;
        try writeAll(self.stdin, operation, bytes);
    }

    fn closeStdin(context: *anyopaque, _: process.Context) process.Error!void {
        const self: *OwnedChild = @ptrCast(@alignCast(context));
        close(take(&self.stdin));
    }

    fn terminate(context: *anyopaque, _: process.Context) process.Error!void {
        const self: *OwnedChild = @ptrCast(@alignCast(context));
        close(self.lease.swap(-1, .acq_rel));
    }

    fn wait(context: *anyopaque, operation: process.Context) process.Error!process.ProcessExit {
        const self: *OwnedChild = @ptrCast(@alignCast(context));
        try check(operation);
        if (self.exit) |exit| return exit;
        const result = try readMessage(self.status, operation);
        self.exit = switch (result.kind) {
            .exited => .{ .exited = result.value },
            .signalled => .{ .signalled = result.value },
            .failed => return launchError(result.value),
            .ready => return error.IoFailure,
        };
        return self.exit.?;
    }

    fn release(context: *anyopaque, operation: process.Context) process.Error!void {
        const self: *OwnedChild = @ptrCast(@alignCast(context));
        defer self.allocator.destroy(self);
        defer {
            close(self.stdin);
            close(self.stdout);
            close(self.stderr);
            close(self.status);
        }
        try terminate(context, operation);
        try reap(self.guardian_pid, self.status, self.exit != null);
    }
};

fn hasNull(bytes: []const u8) bool {
    return std.mem.findScalar(u8, bytes, 0) != null;
}

fn check(operation: process.Context) process.Error!void {
    try operation.check();
    operation.io.checkCancel() catch return error.Cancelled;
}

fn take(fd: *Fd) Fd {
    const result = fd.*;
    fd.* = -1;
    return result;
}

fn close(fd: Fd) void {
    if (fd >= 0) _ = posix.system.close(fd);
}

fn reap(pid: posix.pid_t, status_fd: Fd, saw_exit: bool) process.Error!void {
    while (true) {
        var status: c_int = undefined;
        switch (posix.errno(std.c.waitpid(pid, &status, 0))) {
            .SUCCESS => if (status == 0) return else return error.IoFailure,
            .CHILD => return awaitStatusClose(status_fd, saw_exit),
            .INTR => continue,
            else => return error.IoFailure,
        }
    }
}

fn awaitStatusClose(fd: Fd, saw_exit: bool) process.Error!void {
    // A host SIGCHLD handler may already have reaped the guardian. The terminal
    // record is written after group cleanup and EOF proves it closed the pipe.
    var complete = saw_exit;
    var descriptor: posix.pollfd = .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };
    var message: [2]u8 = undefined;
    while (true) {
        const result = posix.system.read(fd, &message, message.len);
        switch (posix.errno(result)) {
            .SUCCESS => switch (result) {
                0 => return if (complete) {} else error.IoFailure,
                message.len => complete = complete or message[0] == @backingInt(Message.exited) or
                    message[0] == @backingInt(Message.signalled),
                else => return error.IoFailure,
            },
            .INTR => continue,
            .AGAIN => switch (posix.errno(posix.system.poll(@ptrCast(&descriptor), 1, -1))) {
                .SUCCESS, .INTR => continue,
                else => return error.IoFailure,
            },
            else => return error.IoFailure,
        }
    }
}

fn poll(fd: Fd, events: i16, operation: process.Context) process.Error!void {
    var descriptor: posix.pollfd = .{ .fd = fd, .events = events, .revents = 0 };
    const interval: u64 = 10;
    while (true) {
        try check(operation);
        const timeout = if (operation.deadline_ms) |deadline|
            @min(interval, deadline -| operation.clock.now())
        else
            interval;
        const result = posix.system.poll(@ptrCast(&descriptor), 1, @intCast(timeout));
        switch (posix.errno(result)) {
            .SUCCESS => if (result != 0) return,
            .INTR => continue,
            else => return error.IoFailure,
        }
    }
}

fn readOutput(context: *anyopaque, operation: process.Context, buffer: []u8) process.Error!usize {
    const fd: *const Fd = @ptrCast(@alignCast(context));
    return read(fd.*, operation, buffer);
}

fn read(fd: Fd, operation: process.Context, buffer: []u8) process.Error!usize {
    while (true) {
        try check(operation);
        const result = posix.system.read(fd, buffer.ptr, buffer.len);
        switch (posix.errno(result)) {
            .SUCCESS => return @intCast(result),
            .INTR => continue,
            .AGAIN => try poll(fd, posix.POLL.IN, operation),
            else => return error.IoFailure,
        }
    }
}

fn writeAll(fd: Fd, operation: process.Context, bytes: []const u8) process.Error!void {
    var rest = bytes;
    while (rest.len > 0) {
        try check(operation);
        const result = foo_process_write(fd, rest.ptr, rest.len);
        switch (posix.errno(result)) {
            .SUCCESS => rest = rest[@intCast(result)..],
            .INTR => continue,
            .AGAIN => try poll(fd, posix.POLL.OUT, operation),
            .PIPE => return error.Disconnected,
            else => return error.IoFailure,
        }
    }
}

fn readMessage(fd: Fd, operation: process.Context) process.Error!struct { kind: Message, value: u8 } {
    var message: [2]u8 = undefined;
    switch (try read(fd, operation, &message)) {
        0 => return error.Disconnected,
        message.len => {},
        else => return error.IoFailure,
    }
    const kind = std.enums.fromInt(Message, message[0]) orelse return error.IoFailure;
    return .{ .kind = kind, .value = message[1] };
}

fn launchError(value: u8) process.Error {
    return switch (std.enums.fromInt(LaunchFailure, value) orelse return error.IoFailure) {
        .invalid => error.InvalidInput,
        .unavailable => error.Unavailable,
        .limit => error.LimitExceeded,
        .io => error.IoFailure,
    };
}
