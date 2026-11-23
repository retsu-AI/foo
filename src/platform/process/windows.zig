const std = @import("std");
const foo = @import("foo");
const api = @import("windows_api.zig");
const windows = std.os.windows;
const io = foo.io;
const Allocator = std.mem.Allocator;
const HANDLE = windows.HANDLE;
const path = std.Io.Dir.path;

const wait_slice_ms = 10;
const max_transfer_bytes = 64 * 1024;

pub const Native = struct {
    environ: std.process.Environ = .empty,
    guardian_path: ?[]const u8 = null,

    pub fn interface(self: *Native) io.Spawner {
        return .{ .context = self, .spawn_fn = spawn };
    }

    fn spawn(raw: *anyopaque, allocator: Allocator, operation: io.Context, spec: io.Spawn) io.Error!io.Child {
        const self: *Native = @ptrCast(@alignCast(raw));
        try operation.check();
        if (spec.argv.len == 0 or spec.argv[0].len == 0 or spec.cwd.len == 0) return error.InvalidInput;

        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const line = try commandLine(arena, spec.argv);
        const cwd = try fullPath(arena, try wideString(arena, spec.cwd));
        var env = if (spec.inherit_environment)
            self.environ.createMap(arena) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Unexpected => error.IoFailure,
            }
        else
            std.process.Environ.Map.init(arena);
        for (spec.environment) |entry| {
            if (entry.name.len == 0 or std.mem.findAny(u8, entry.name, "\x00=") != null or
                !std.unicode.wtf8ValidateSlice(entry.name))
                return error.InvalidInput;
            try env.put(entry.name, entry.value);
        }
        const block = try environmentBlock(arena, &env);
        const executable = try executableName(arena, spec.argv[0]);

        const owned = try allocator.create(Child);
        errdefer allocator.destroy(owned);
        const job = api.CreateJobObjectW(null, null) orelse return winError(windows.GetLastError());
        var process_to_reap: ?HANDLE = null;
        errdefer {
            windows.CloseHandle(job);
            if (process_to_reap) |process| {
                waitHandle(process, null) catch {};
                windows.CloseHandle(process);
            }
        }
        var limits: api.JobLimits = std.mem.zeroes(api.JobLimits);
        limits.basic.flags = api.kill_on_job_close;
        if (!api.SetInformationJobObject(job, .extended_limit, &limits, @sizeOf(api.JobLimits)).toBool())
            return winError(windows.GetLastError());

        const device = try openPipeDevice();
        defer windows.CloseHandle(device);
        const input = try Pipe.open(device, .input);
        errdefer windows.CloseHandle(input.parent);
        defer windows.CloseHandle(input.child);
        const output = try Pipe.open(device, .output);
        errdefer windows.CloseHandle(output.parent);
        defer windows.CloseHandle(output.child);
        const diagnostic = try Pipe.open(device, .output);
        errdefer windows.CloseHandle(diagnostic.parent);
        defer windows.CloseHandle(diagnostic.child);

        var attribute_bytes: usize = 0;
        _ = api.InitializeProcThreadAttributeList(null, 2, 0, &attribute_bytes);
        if (attribute_bytes == 0) return winError(windows.GetLastError());
        const attributes: *api.AttributeList = @ptrCast(try arena.alignedAlloc(u8, .of(usize), attribute_bytes));
        if (!api.InitializeProcThreadAttributeList(attributes, 2, 0, &attribute_bytes).toBool())
            return winError(windows.GetLastError());
        defer api.DeleteProcThreadAttributeList(attributes);

        const handles = [_]HANDLE{ input.child, output.child, diagnostic.child };
        const jobs = [_]HANDLE{job};
        if (!api.UpdateProcThreadAttribute(attributes, 0, .handle_list, &handles, @sizeOf(@TypeOf(handles)), null, null).toBool())
            return winError(windows.GetLastError());
        // The child must already be in the job if the owner dies inside CreateProcessW.
        if (!api.UpdateProcThreadAttribute(attributes, 0, .job_list, &jobs, @sizeOf(@TypeOf(jobs)), null, null).toBool()) {
            return switch (windows.GetLastError()) {
                .INVALID_PARAMETER, .NOT_SUPPORTED => error.Unavailable,
                else => |err| winError(err),
            };
        }

        var launch: Launch = .{
            .cwd = cwd,
            .command = line,
            .command_copy = try arena.allocSentinel(u16, line.len, 0),
            .environment = block,
            .info = .{
                .startup = std.mem.zeroes(windows.STARTUPINFOW),
                .attributes = attributes,
            },
        };
        launch.info.startup.cb = @sizeOf(api.StartupInfo);
        launch.info.startup.dwFlags = windows.STARTF_USESTDHANDLES;
        launch.info.startup.hStdInput = input.child;
        launch.info.startup.hStdOutput = output.child;
        launch.info.startup.hStdError = diagnostic.child;

        const process = try launch.start(arena, operation, executable, env.get("PATH"));
        process_to_reap = process.hProcess;
        defer windows.CloseHandle(process.hThread);
        try operation.check();
        if (windows.ntdll.NtResumeThread(process.hThread, null) != .SUCCESS) return error.IoFailure;

        owned.* = .{
            .allocator = allocator,
            .job = job,
            .process = process.hProcess,
            .stdin = input.parent,
            .stdout = output.parent,
            .stderr = diagnostic.parent,
        };
        return .{
            .context = owned,
            .stdin = .{ .context = owned, .write_fn = Child.write },
            .stdout = .{ .context = owned.stdout, .read_fn = read },
            .stderr = .{ .context = owned.stderr, .read_fn = read },
            .close_stdin_fn = Child.closeStdin,
            .terminate_fn = Child.terminate,
            .wait_fn = Child.wait,
            .release_fn = Child.release,
        };
    }
};

const Child = struct {
    allocator: Allocator,
    job: HANDLE,
    process: HANDLE,
    stdin: ?HANDLE,
    stdout: HANDLE,
    stderr: HANDLE,
    exit: ?io.ProcessExit = null,

    fn write(raw: *anyopaque, operation: io.Context, bytes: []const u8) io.Error!void {
        const self: *Child = @ptrCast(@alignCast(raw));
        try operation.check();
        const handle = self.stdin orelse return error.Disconnected;
        var remaining = bytes;
        while (remaining.len != 0) {
            const written = try transfer(handle, operation, .{ .write = remaining });
            if (written == 0) return error.IoFailure;
            remaining = remaining[written..];
        }
    }

    fn closeStdin(raw: *anyopaque, operation: io.Context) io.Error!void {
        const self: *Child = @ptrCast(@alignCast(raw));
        try operation.check();
        if (self.stdin) |handle| windows.CloseHandle(handle);
        self.stdin = null;
    }

    fn terminate(raw: *anyopaque, operation: io.Context) io.Error!void {
        const self: *Child = @ptrCast(@alignCast(raw));
        try operation.check();
        try stopJob(self.job);
    }

    fn wait(raw: *anyopaque, operation: io.Context) io.Error!io.ProcessExit {
        const self: *Child = @ptrCast(@alignCast(raw));
        try operation.check();
        if (self.exit) |exit| return exit;
        try waitHandle(self.process, operation);
        var status: u32 = undefined;
        if (!api.GetExitCodeProcess(self.process, &status).toBool()) return winError(windows.GetLastError());
        try stopJob(self.job);
        try waitJob(self.job, operation);
        const exit: io.ProcessExit = .{ .exited = @bitCast(status) };
        self.exit = exit;
        return exit;
    }

    fn release(raw: *anyopaque, _: io.Context) io.Error!void {
        const self: *Child = @ptrCast(@alignCast(raw));
        defer self.allocator.destroy(self);
        if (self.stdin) |handle| windows.CloseHandle(handle);
        windows.CloseHandle(self.stdout);
        windows.CloseHandle(self.stderr);
        if (stopJob(self.job)) |_| {
            defer windows.CloseHandle(self.job);
            const waited = waitHandle(self.process, null);
            windows.CloseHandle(self.process);
            try waited;
            try waitJob(self.job, null);
        } else |err| {
            // Closing the last job handle also terminates all of its processes.
            windows.CloseHandle(self.job);
            defer windows.CloseHandle(self.process);
            try waitHandle(self.process, null);
            return err;
        }
    }
};

fn stopJob(job: HANDLE) io.Error!void {
    if (!api.TerminateJobObject(job, 1).toBool()) return winError(windows.GetLastError());
}

fn waitJob(job: HANDLE, operation: ?io.Context) io.Error!void {
    while (true) {
        if (operation) |ctx| try ctx.check();
        var accounting: api.JobAccounting = undefined;
        if (!api.QueryInformationJobObject(job, .basic_accounting, &accounting, @sizeOf(api.JobAccounting), null).toBool())
            return winError(windows.GetLastError());
        if (accounting.active_processes == 0) return;
        api.Sleep(wait_slice_ms);
    }
}

fn waitHandle(handle: HANDLE, operation: ?io.Context) io.Error!void {
    while (true) {
        if (operation) |ctx| try ctx.check();
        switch (api.WaitForSingleObject(handle, if (operation != null) wait_slice_ms else api.infinite)) {
            .signalled => return,
            .timeout => continue,
            else => return winError(windows.GetLastError()),
        }
    }
}

fn openPipeDevice() io.Error!HANDLE {
    var handle: HANDLE = undefined;
    var status: windows.IO_STATUS_BLOCK = undefined;
    const name = std.unicode.utf8ToUtf16LeStringLiteral("\\Device\\NamedPipe\\");
    if (windows.ntdll.NtOpenFile(
        &handle,
        .{ .STANDARD = .{ .SYNCHRONIZE = true } },
        &.{ .ObjectName = @constCast(&windows.UNICODE_STRING.init(name)) },
        &status,
        .VALID_FLAGS,
        .{ .IO = .SYNCHRONOUS_NONALERT },
    ) != .SUCCESS) return error.IoFailure;
    return handle;
}

const Pipe = struct {
    parent: HANDLE,
    child: HANDLE,

    fn open(device: HANDLE, comptime direction: enum { input, output }) io.Error!Pipe {
        const inbound = direction == .output;
        var parent: HANDLE = undefined;
        var child: HANDLE = undefined;
        var status: windows.IO_STATUS_BLOCK = undefined;
        // Opening the client relative to the server handle keeps the pipe anonymous.
        if (windows.ntdll.NtCreateNamedPipeFile(
            &parent,
            .{
                .SPECIFIC = .{ .FILE_PIPE = .{
                    .READ_DATA = inbound,
                    .WRITE_DATA = !inbound,
                    .READ_ATTRIBUTES = true,
                    .WRITE_ATTRIBUTES = true,
                } },
                .STANDARD = .{ .SYNCHRONIZE = true },
            },
            &.{ .RootDirectory = device },
            &status,
            .{ .READ = true, .WRITE = true },
            .CREATE,
            .{ .IO = .ASYNCHRONOUS },
            .{ .TYPE = .BYTE_STREAM },
            .{ .MODE = .BYTE_STREAM },
            .{ .OPERATION = .QUEUE },
            1,
            if (inbound) 4096 else 0,
            if (inbound) 0 else 4096,
            &(-10 * std.time.ns_per_s / 100),
        ) != .SUCCESS) return error.IoFailure;
        errdefer windows.CloseHandle(parent);
        if (windows.ntdll.NtOpenFile(
            &child,
            .{
                .SPECIFIC = .{ .FILE_PIPE = .{
                    .READ_DATA = !inbound,
                    .WRITE_DATA = inbound,
                    .READ_ATTRIBUTES = true,
                    .WRITE_ATTRIBUTES = true,
                } },
                .STANDARD = .{ .SYNCHRONIZE = true },
            },
            &.{ .RootDirectory = parent, .Attributes = .{ .INHERIT = true } },
            &status,
            .{ .READ = true, .WRITE = true },
            .{ .IO = .SYNCHRONOUS_NONALERT },
        ) != .SUCCESS) return error.IoFailure;
        return .{ .parent = parent, .child = child };
    }
};

fn read(handle: *anyopaque, operation: io.Context, buffer: []u8) io.Error!usize {
    if (buffer.len == 0) return error.InvalidInput;
    return transfer(handle, operation, .{ .read = buffer }) catch |err| switch (err) {
        error.Disconnected => 0,
        else => |failure| return failure,
    };
}

const Transfer = union(enum) { read: []u8, write: []const u8 };

fn transfer(handle: HANDLE, operation: io.Context, data: Transfer) io.Error!usize {
    try operation.check();
    const event = api.CreateEventW(null, .TRUE, .FALSE, null) orelse return winError(windows.GetLastError());
    defer windows.CloseHandle(event);
    var request: api.Overlapped = .{ .event = event };
    var count: u32 = undefined;
    const started = switch (data) {
        .read => |buffer| api.ReadFile(handle, buffer.ptr, @intCast(@min(buffer.len, max_transfer_bytes)), null, &request),
        .write => |bytes| api.WriteFile(handle, bytes.ptr, @intCast(@min(bytes.len, max_transfer_bytes)), null, &request),
    };
    if (!started.toBool()) {
        const err = windows.GetLastError();
        if (err != .IO_PENDING) return winError(err);
        waitHandle(event, operation) catch |wait_err| {
            _ = api.CancelIoEx(handle, &request);
            // CancelIoEx requests cancellation. Wait for Windows to release the borrowed buffer.
            _ = api.GetOverlappedResult(handle, &request, &count, .TRUE);
            return wait_err;
        };
    }
    if (!api.GetOverlappedResult(handle, &request, &count, .FALSE).toBool())
        return winError(windows.GetLastError());
    return count;
}

fn wideString(arena: Allocator, value: []const u8) io.Error![:0]u16 {
    if (std.mem.findScalar(u8, value, 0) != null) return error.InvalidInput;
    return std.unicode.wtf8ToWtf16LeAllocZ(arena, value) catch |err| switch (err) {
        error.InvalidWtf8 => error.InvalidInput,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn fullPath(arena: Allocator, from: [:0]const u16) io.Error![:0]u16 {
    const size = api.GetFullPathNameW(from.ptr, 0, null, null);
    if (size == 0) return winError(windows.GetLastError());
    const buffer = try arena.alloc(u16, size);
    const len = api.GetFullPathNameW(from.ptr, size, buffer.ptr, null);
    if (len == 0) return winError(windows.GetLastError());
    if (len >= size) return error.InvalidInput;
    return buffer[0..len :0];
}

fn commandLine(arena: Allocator, argv: []const []const u8) io.Error![:0]u16 {
    if (std.mem.findScalar(u8, argv[0], '"') != null) return error.InvalidInput;
    var line: std.ArrayList(u8) = .empty;
    // Windows parses argv[0] as a pathname with its own quoting rules.
    try line.append(arena, '"');
    try line.appendSlice(arena, argv[0]);
    try line.append(arena, '"');
    for (argv[1..]) |arg| {
        try line.appendSlice(arena, " \"");
        var backslashes: usize = 0;
        for (arg) |byte| {
            if (byte == '\\') {
                backslashes += 1;
                continue;
            }
            const escape = if (byte == '"') backslashes + 1 else 0;
            try line.appendNTimes(arena, '\\', backslashes + escape);
            try line.append(arena, byte);
            backslashes = 0;
        }
        try line.appendNTimes(arena, '\\', backslashes * 2);
        try line.append(arena, '"');
    }
    const result = try wideString(arena, line.items);
    if (result.len >= 32767) return error.LimitExceeded;
    return result;
}

const EnvEntry = struct {
    name: []const u16,
    value: []const u16,

    fn lessThan(_: void, a: EnvEntry, b: EnvEntry) bool {
        const len = @min(a.name.len, b.name.len);
        for (a.name[0..len], b.name[0..len]) |left, right| {
            const l = windows.toUpperWtf16(left);
            const r = windows.toUpperWtf16(right);
            if (l != r) return l < r;
        }
        return a.name.len < b.name.len;
    }
};

fn environmentBlock(arena: Allocator, env: *const std.process.Environ.Map) io.Error![:0]u16 {
    const entries = try arena.alloc(EnvEntry, env.count());
    var size: usize = 1;
    for (entries, env.keys(), env.values()) |*entry, key, value| {
        entry.* = .{ .name = try wideString(arena, key), .value = try wideString(arena, value) };
        size += entry.name.len + 1 + entry.value.len + 1;
    }
    std.mem.sortUnstable(EnvEntry, entries, {}, EnvEntry.lessThan);
    const block = try arena.alloc(u16, @max(size, 2));
    var at: usize = 0;
    for (entries) |entry| {
        @memcpy(block[at..][0..entry.name.len], entry.name);
        at += entry.name.len;
        block[at] = '=';
        at += 1;
        @memcpy(block[at..][0..entry.value.len], entry.value);
        at += entry.value.len;
        block[at] = 0;
        at += 1;
    }
    @memset(block[at..], 0);
    return block[0 .. block.len - 1 :0];
}

fn executableName(arena: Allocator, name: []const u8) io.Error![]const u8 {
    const base = path.basenameWindows(name);
    if (base.len == 0 or std.mem.endsWith(u8, name, "\\") or std.mem.endsWith(u8, name, "/"))
        return error.InvalidInput;
    const extension = path.extension(base);
    if (extension.len == 0) return std.mem.concat(arena, u8, &.{ name, ".exe" });
    if (!std.ascii.eqlIgnoreCase(extension, ".exe")) return error.InvalidInput;
    return name;
}

const Launch = struct {
    cwd: [:0]const u16,
    command: [:0]const u16,
    command_copy: [:0]u16,
    environment: [:0]const u16,
    info: api.StartupInfo,

    fn start(self: *Launch, arena: Allocator, operation: io.Context, executable: []const u8, search_path: ?[]const u8) io.Error!windows.PROCESS.INFORMATION {
        const cwd = try std.unicode.wtf16LeToWtf8Alloc(arena, self.cwd);
        const candidate = try resolvePath(arena, cwd, executable);
        if (try self.tryStart(operation, candidate)) |process| return process;
        if (!std.mem.eql(u8, executable, path.basenameWindows(executable))) return error.Unavailable;
        var directories = std.mem.tokenizeScalar(u8, search_path orelse "", ';');
        while (directories.next()) |directory| {
            const base = std.mem.trim(u8, directory, "\"");
            const folder = try path.resolveAllocWindows(arena, &.{ cwd, base });
            const from_path = try resolvePath(arena, folder, executable);
            if (try self.tryStart(operation, from_path)) |process| return process;
        }
        return error.Unavailable;
    }

    fn tryStart(self: *Launch, operation: io.Context, executable: [:0]const u16) io.Error!?windows.PROCESS.INFORMATION {
        try operation.check();
        // CreateProcessW may modify the command line even when a candidate fails.
        @memcpy(self.command_copy, self.command);
        var process: windows.PROCESS.INFORMATION = undefined;
        if (windows.kernel32.CreateProcessW(
            executable.ptr,
            self.command_copy.ptr,
            null,
            null,
            .TRUE,
            .{
                .create_no_window = true,
                .create_suspended = true,
                .create_unicode_environment = true,
                .extended_startupinfo_present = true,
            },
            self.environment.ptr,
            self.cwd.ptr,
            &self.info.startup,
            &process,
        ).toBool()) return process;
        return switch (windows.GetLastError()) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => null,
            else => |err| winError(err),
        };
    }
};

fn resolvePath(arena: Allocator, cwd: []const u8, name: []const u8) io.Error![:0]u16 {
    const resolved = switch (path.getWin32PathType(u8, name)) {
        .drive_absolute, .unc_absolute, .local_device, .root_local_device => name,
        else => try path.resolveAllocWindows(arena, &.{ cwd, name }),
    };
    switch (path.getWin32PathType(u8, resolved)) {
        .drive_absolute, .unc_absolute, .local_device, .root_local_device => return wideString(arena, resolved),
        else => return error.InvalidInput,
    }
}

fn winError(err: windows.Win32Error) io.Error {
    return switch (err) {
        .NOT_ENOUGH_MEMORY, .OUTOFMEMORY => error.OutOfMemory,
        .BROKEN_PIPE, .HANDLE_EOF, .NO_DATA, .PIPE_NOT_CONNECTED => error.Disconnected,
        .INVALID_NAME, .DIRECTORY, .FILENAME_EXCED_RANGE, .BAD_EXE_FORMAT => error.InvalidInput,
        .FILE_NOT_FOUND, .PATH_NOT_FOUND, .NOT_SUPPORTED, .CALL_NOT_IMPLEMENTED => error.Unavailable,
        else => error.IoFailure,
    };
}
