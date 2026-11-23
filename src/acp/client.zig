const std = @import("std");
const foo = @import("foo");
const protocol = @import("protocol.zig");
const host = foo.host;
const io = foo.io;

pub const Peer = struct {
    context: *anyopaque,
    call_fn: *const fn (*anyopaque, std.mem.Allocator, io.Context, []const u8, []const u8, bool) io.Error![]const u8,
};

const Terminal = struct {
    id: host.CommandId,
    remote: []const u8,
    running: bool = true,
};
const TerminalRef = struct { sessionId: []const u8, terminalId: []const u8 };
const Exit = struct { exitCode: ?u32 = null, signal: ?[]const u8 = null };

pub const Client = struct {
    allocator: std.mem.Allocator,
    peer: Peer,
    limits: protocol.Limits,
    capabilities: host.Capabilities,
    session: foo.events.SessionId,
    wire_id: []const u8,
    run: ?foo.events.RunId = null,
    terminals: std.ArrayList(Terminal) = .empty,
    sequence: u64 = 0,
    unconfirmed: usize = 0,

    pub fn adapter(self: *Client) host.Host {
        return .{
            .capabilities = self.capabilities,
            .files = if (self.capabilities.read_file or self.capabilities.write_file) .{
                .context = self,
                .read_fn = read,
                .write_fn = write,
            } else null,
            .processes = if (self.capabilities.terminal) .{
                .context = self,
                .start_fn = start,
                .output_fn = output,
                .wait_fn = wait,
                .kill_fn = kill,
                .release_fn = release,
            } else null,
            .permissions = .{ .context = self, .decide_fn = decide },
        };
    }

    fn decide(context: *anyopaque, op: io.Context, prepared: host.PreparedOperation) io.Error!host.Decision {
        const self: *Client = @ptrCast(@alignCast(context));
        if (prepared.session != self.session or prepared.run != self.run) return error.InvalidInput;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const call = prepared.invocation.call;
        const identity = prepared.invocation.declaration.identity;
        const Location = struct { path: []const u8 };
        if (prepared.targets.len > self.limits.prompt_blocks) return error.LimitExceeded;
        const locations = try allocator.alloc(Location, prepared.targets.len);
        var location_count: usize = 0;
        for (prepared.targets) |target| {
            if (!protocol.absolutePath(target)) continue;
            locations[location_count] = .{ .path = target };
            location_count += 1;
        }

        var argv: ?[]const []const u8 = null;
        if (std.mem.eql(u8, identity.backend, "builtin") and std.mem.eql(u8, identity.name, "exec")) {
            foo.wire.json.validate(call.arguments_json, self.limits.json()) catch return error.InvalidInput;
            const args = try protocol.parse(struct { argv: []const []const u8 }, allocator, call.arguments_json);
            if (args.argv.len == 0) return error.InvalidInput;
            for (prepared.targets) |target| {
                if (std.mem.eql(u8, target, args.argv[0])) argv = args.argv;
            }
            if (argv == null) return error.InvalidInput;
        }
        var id_buffer: protocol.ToolIdBuffer = undefined;
        const result = self.request(struct {
            outcome: struct { outcome: []const u8, optionId: ?[]const u8 = null },
        }, allocator, op, "session/request_permission", .{
            .sessionId = self.wire_id,
            .toolCall = .{
                .toolCallId = try protocol.toolId(&id_buffer, prepared.run, call.id),
                .title = identity.name,
                .locations = locations[0..location_count],
                .rawInput = .{
                    .operationId = prepared.operation_id,
                    .runId = @backingInt(prepared.run),
                    .tool = identity.name,
                    .targets = prepared.targets,
                    .argv = argv,
                },
            },
            .options = [_]struct { kind: []const u8, name: []const u8, optionId: []const u8 }{
                .{ .kind = "allow_once", .name = "Allow once", .optionId = "allow_once" },
                .{ .kind = "reject_once", .name = "Reject once", .optionId = "reject_once" },
            },
        }, false) catch |err| return switch (err) {
            error.Cancelled => .cancelled,
            error.DeadlineExceeded => .deny_once,
            else => err,
        };
        try op.check();
        if (std.mem.eql(u8, result.outcome.outcome, "cancelled")) return .cancelled;
        if (std.mem.eql(u8, result.outcome.outcome, "selected")) {
            if (result.outcome.optionId) |option| {
                if (std.mem.eql(u8, option, "allow_once")) return .allow_once;
            }
        }
        return .deny_once;
    }

    fn read(context: *anyopaque, allocator: std.mem.Allocator, op: io.Context, id: foo.events.SessionId, path: []const u8, max_bytes: usize) io.Error![]const u8 {
        const self: *Client = @ptrCast(@alignCast(context));
        try self.checkFile(id, path, self.capabilities.read_file);
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const result = try self.request(struct { content: []const u8 }, arena.allocator(), op, "fs/read_text_file", .{
            .sessionId = self.wire_id,
            .path = path,
        }, false);
        if (result.content.len > max_bytes) return error.LimitExceeded;
        return allocator.dupe(u8, result.content);
    }

    fn write(context: *anyopaque, op: io.Context, id: foo.events.SessionId, path: []const u8, content: []const u8) io.Error!void {
        const self: *Client = @ptrCast(@alignCast(context));
        try self.checkFile(id, path, self.capabilities.write_file);
        if (!std.unicode.utf8ValidateSlice(content)) return error.InvalidInput;
        try self.ack(op, "fs/write_text_file", .{ .sessionId = self.wire_id, .path = path, .content = content }, false);
    }

    fn checkFile(self: *Client, id: foo.events.SessionId, path: []const u8, allowed: bool) io.Error!void {
        if (!allowed) return error.Unavailable;
        if (id != self.session or self.run == null or !protocol.absolutePath(path)) return error.InvalidInput;
    }

    fn start(context: *anyopaque, op: io.Context, cmd: host.Command) io.Error!host.CommandId {
        const self: *Client = @ptrCast(@alignCast(context));
        if (!self.capabilities.terminal) return error.Unavailable;
        if (self.run == null or cmd.argv.len == 0 or cmd.argv[0].len == 0 or
            !protocol.absolutePath(cmd.cwd)) return error.InvalidInput;
        if (self.terminals.items.len == self.limits.terminals or
            cmd.argv.len > 256 or cmd.environment.len > 128) return error.LimitExceeded;
        for (cmd.argv) |arg| if (!protocol.noNul(arg)) return error.InvalidInput;
        for (cmd.environment) |value| {
            if (!protocol.environmentName(value.name) or !protocol.noNul(value.value)) return error.InvalidInput;
        }
        try op.check();
        const sequence = std.math.add(u64, self.sequence, 1) catch return error.LimitExceeded;
        try self.terminals.ensureUnusedCapacity(self.allocator, 1);
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const result = self.request(struct { terminalId: []const u8 }, arena.allocator(), op, "terminal/create", .{
            .sessionId = self.wire_id,
            .command = cmd.argv[0],
            .args = cmd.argv[1..],
            .cwd = cmd.cwd,
            .env = cmd.environment,
            .outputByteLimit = self.limits.terminal_bytes,
        }, false) catch |err| {
            switch (err) {
                error.Cancelled, error.DeadlineExceeded, error.Disconnected, error.IoFailure, error.InvalidInput, error.OutOfMemory => self.unconfirmed +|= 1,
                else => {},
            }
            return err;
        };
        if (result.terminalId.len == 0 or result.terminalId.len > self.limits.request_id_bytes) {
            self.unconfirmed +|= 1;
            return error.InvalidInput;
        }
        for (self.terminals.items) |terminal| {
            if (std.mem.eql(u8, terminal.remote, result.terminalId)) {
                self.unconfirmed +|= 1;
                return error.InvalidInput;
            }
        }
        const remote = self.allocator.dupe(u8, result.terminalId) catch |err| {
            self.unconfirmed +|= 1;
            return err;
        };
        self.sequence = sequence;
        const id: host.CommandId = @fromBackingInt(@intCast(sequence));
        self.terminals.appendAssumeCapacity(.{ .id = id, .remote = remote });
        return id;
    }

    fn output(context: *anyopaque, allocator: std.mem.Allocator, op: io.Context, id: host.CommandId, offset: u64, max_bytes: usize) io.Error!host.CommandOutput {
        const self: *Client = @ptrCast(@alignCast(context));
        const terminal = try self.find(id);
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const result = try self.request(struct {
            output: []const u8,
            truncated: bool,
            exitStatus: ?Exit = null,
        }, arena.allocator(), op, "terminal/output", self.reference(terminal.*), false);
        if (result.exitStatus) |status| if (exitStatus(status) != .cleanup_unconfirmed) {
            terminal.running = false;
        };
        if (result.truncated) return error.LimitExceeded;
        if (result.output.len > self.limits.terminal_bytes or offset > result.output.len) return error.InvalidInput;
        const available = result.output[@intCast(offset)..];
        return .{
            .bytes = try allocator.dupe(u8, available[0..@min(available.len, max_bytes)]),
            .truncated = available.len > max_bytes,
        };
    }

    fn wait(context: *anyopaque, op: io.Context, id: host.CommandId) io.Error!host.CommandStatus {
        const self: *Client = @ptrCast(@alignCast(context));
        const terminal = try self.find(id);
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const result = exitStatus(try self.request(Exit, arena.allocator(), op, "terminal/wait_for_exit", self.reference(terminal.*), false));
        if (result != .cleanup_unconfirmed) terminal.running = false;
        return result;
    }

    fn exitStatus(status: Exit) host.CommandStatus {
        if (status.exitCode) |code| return .{ .exited = @bitCast(code) };
        if (status.signal) |signal| {
            const known = .{
                .{ "SIGHUP", 1 },  .{ "SIGINT", 2 },   .{ "SIGQUIT", 3 },
                .{ "SIGKILL", 9 }, .{ "SIGPIPE", 13 }, .{ "SIGTERM", 15 },
            };
            inline for (known) |entry| {
                if (std.mem.eql(u8, entry[0], signal)) return .{ .signalled = entry[1] };
            }
        }
        return .cleanup_unconfirmed;
    }

    fn kill(context: *anyopaque, op: io.Context, id: host.CommandId) io.Error!void {
        const self: *Client = @ptrCast(@alignCast(context));
        const terminal = try self.find(id);
        if (!terminal.running) return;
        try self.ack(op, "terminal/kill", self.reference(terminal.*), false);
        terminal.running = false;
    }

    fn release(context: *anyopaque, op: io.Context, id: host.CommandId) io.Error!void {
        const self: *Client = @ptrCast(@alignCast(context));
        try op.check();
        const index = try self.findIndex(id);
        return self.releaseTerminal(op, index);
    }

    fn releaseTerminal(self: *Client, op: io.Context, index: usize) io.Error!void {
        const terminal = self.terminals.items[index];
        const ref = self.reference(terminal);
        const protection = op.io.swapCancelProtection(.blocked);
        defer _ = op.io.swapCancelProtection(protection);
        if (terminal.running) self.ack(op, "terminal/kill", ref, true) catch {};
        const result = self.ack(op, "terminal/release", ref, true);
        self.allocator.free(self.terminals.swapRemove(index).remote);
        result catch |err| {
            self.unconfirmed +|= 1;
            return err;
        };
    }

    pub fn cleanup(self: *Client, op: io.Context) void {
        while (self.terminals.items.len != 0) {
            self.releaseTerminal(op, self.terminals.items.len - 1) catch {};
        }
        self.run = null;
    }

    pub fn deinit(self: *Client) void {
        std.debug.assert(self.terminals.items.len == 0);
        self.terminals.deinit(self.allocator);
    }

    fn find(self: *Client, id: host.CommandId) io.Error!*Terminal {
        return &self.terminals.items[try self.findIndex(id)];
    }

    fn findIndex(self: *Client, id: host.CommandId) io.Error!usize {
        for (self.terminals.items, 0..) |terminal, index| if (terminal.id == id) return index;
        return error.InvalidInput;
    }

    fn reference(self: *Client, terminal: Terminal) TerminalRef {
        return .{ .sessionId = self.wire_id, .terminalId = terminal.remote };
    }

    fn ack(self: *Client, op: io.Context, method: []const u8, params: anytype, cleanup_call: bool) io.Error!void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        _ = try self.request(struct {}, arena.allocator(), op, method, params, cleanup_call);
    }

    fn request(self: *Client, comptime Result: type, allocator: std.mem.Allocator, op: io.Context, method: []const u8, params: anytype, cleanup_call: bool) io.Error!Result {
        try op.check();
        const buffer = try allocator.alloc(u8, self.limits.frame_bytes);
        const raw = try protocol.stringify(buffer, params);
        const result = try self.peer.call_fn(self.peer.context, allocator, op, method, raw, cleanup_call);
        return protocol.parse(Result, allocator, result);
    }
};
