const std = @import("std");
const foo = @import("foo");
const link = @import("link.zig");
const rpc = foo.wire.jsonrpc;
const io = foo.io;
const Allocator = std.mem.Allocator;
const Id = foo.jsonrpc.Id;

const wire_id_bytes = 4096;
const wait_interval_ms = 10;
const control_timeout_ms = 100;
const cancelled_method = "notifications/cancelled";
const ack_method = "notifications/subscriptions/acknowledged";
const subscription_id_key = "io.modelcontextprotocol/subscriptionId";

const Notice = struct {
    node: std.DoublyLinkedList.Node = .{},
    bytes: []u8,
    method_len: usize,
    has_params: bool,

    fn message(self: Notice) foo.jsonrpc.Request {
        return .{
            .id = null,
            .method = self.bytes[0..self.method_len],
            .params_json = if (self.has_params) self.bytes[self.method_len..] else null,
        };
    }
};

const Pending = struct {
    id: ?Id,
    mode: link.Mode,
    observer: ?link.Observer,
    stage: enum { queued, sent, retired } = .queued,
    outcome: ?link.Error!link.Reply = null,
    notices: std.DoublyLinkedList = .{},
};

pub const Stdio = struct {
    pub const Options = struct {
        limits: foo.config.Limits = .{},
        write_timeout_ms: u64 = 1000,
        shutdown_grace_ms: u64 = 250,
    };

    pub const Diagnostics = struct {
        stderr: []const u8,
        truncated: bool,
    };

    allocator: Allocator,
    io_backend: std.Io,
    clock: io.Clock,
    options: Options,
    child: io.Child,
    reader: foo.wire.framing.Ndjson,
    decode_scratch: []u8,
    writer: foo.wire.framing.Writer,
    stdout_task: std.Io.Future(void) = undefined,
    stderr_task: std.Io.Future(void) = undefined,
    stop_pipes: io.Cancellation = .{},

    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    state: union(enum) { open, failed: link.Error, stopping, closed: ?link.Error } = .open,
    writing: bool = false,
    revision: ?foo.config.McpRevision = null,
    pending: []?*Pending,
    retired: []?Id,
    next_retired: usize = 0,
    queued_events: usize = 0,
    queued_bytes: usize = 0,
    stderr_ring: []u8,
    stderr_total: usize = 0,
    stderr_end: usize = 0,

    /// The allocator and startup I/O and clock must support concurrent use and
    /// remain available until deinit. Startup cancellation only applies to launch.
    pub fn init(allocator: Allocator, startup: io.Context, spawner: io.Spawner, spawn: io.Spawn, options: Options) link.Error!*Stdio {
        const limits = options.limits;
        if (limits.wire_message_bytes == 0 or limits.wire_message_bytes == std.math.maxInt(usize) or
            limits.json_depth == 0 or limits.pending_requests == 0 or limits.pending_requests >= std.math.maxInt(u16) or
            limits.pending_events == 0 or options.write_timeout_ms == 0)
            return error.InvalidInput;
        try startup.check();

        const self = try allocator.create(Stdio);
        errdefer allocator.destroy(self);
        const pending = try allocator.alloc(?*Pending, limits.pending_requests);
        errdefer allocator.free(pending);
        const retired = try allocator.alloc(?Id, limits.pending_requests);
        errdefer allocator.free(retired);
        const read_buffer = try allocator.alloc(u8, limits.wire_message_bytes);
        errdefer allocator.free(read_buffer);
        const decode_scratch = try allocator.alloc(u8, limits.wire_message_bytes);
        errdefer allocator.free(decode_scratch);
        const write_buffer = try allocator.alloc(u8, limits.wire_message_bytes + 1);
        errdefer allocator.free(write_buffer);
        const stderr_ring = try allocator.alloc(u8, limits.server_stderr_bytes);
        errdefer allocator.free(stderr_ring);
        @memset(pending, null);
        @memset(retired, null);

        const child = try spawner.spawn_fn(spawner.context, allocator, startup, spawn);
        var cleanup_token: io.Cancellation = .{};
        errdefer child.release_fn(child.context, .{ .io = startup.io, .clock = startup.clock, .cancellation = &cleanup_token }) catch {};
        self.* = .{
            .allocator = allocator,
            .io_backend = startup.io,
            .clock = startup.clock,
            .options = options,
            .child = child,
            .reader = .init(read_buffer, .reject),
            .decode_scratch = decode_scratch,
            .writer = .init(write_buffer, child.stdin),
            .pending = pending,
            .retired = retired,
            .stderr_ring = stderr_ring,
        };

        self.stderr_task = startup.io.concurrent(drainStderr, .{self}) catch return error.Unavailable;
        errdefer {
            self.stop_pipes.request();
            self.stderr_task.await(startup.io);
        }
        self.stdout_task = startup.io.concurrent(readStdout, .{self}) catch return error.Unavailable;
        return self;
    }

    pub fn interface(self: *Stdio) link.Link {
        return .{ .context = self, .exchange_fn = exchange, .shutdown_fn = shutdownLink };
    }

    /// Like the MCP protocol, the link requires a new ID for each request.
    /// Observer callbacks borrow their notification and must return before
    /// shutdown can complete.
    fn exchange(raw: *anyopaque, allocator: Allocator, op: io.Context, request: link.Request, observer: ?link.Observer, delivery: *io.Delivery) link.Error!link.Reply {
        const self: *Stdio = @ptrCast(@alignCast(raw));
        try self.validateRequest(request, observer);
        var pending: Pending = .{ .id = request.id, .mode = request.mode, .observer = observer };
        const slot = try self.register(&pending);
        defer self.remove(slot);

        if (request.mode != .legacy_notifications) {
            try self.send(op, request.body, &pending, request.revision, delivery);
            if (request.id == null) return .accepted;
        }

        return self.receive(allocator, op, &pending) catch |err| {
            if (request.id) |id| {
                if (self.retire(&pending) and !std.mem.eql(u8, request.method, "initialize")) self.sendCancellation(id);
            }
            return err;
        };
    }

    fn validateRequest(self: *Stdio, request: link.Request, observer: ?link.Observer) link.Error!void {
        switch (request.mode) {
            .request => {},
            .subscription => if (request.revision != .@"2026-07-28" or request.id == null or observer == null or
                !std.mem.eql(u8, request.method, "subscriptions/listen"))
                return error.InvalidInput,
            .legacy_notifications => {
                if (request.revision != .@"2025-11-25" or request.id != null or request.body.len != 0 or observer == null)
                    return error.InvalidInput;
                return;
            },
        }
        if (std.mem.indexOfAny(u8, request.body, "\r\n") != null) return error.InvalidInput;
        if (request.id) |id| if (tooLong(id)) return error.LimitExceeded;
        var scratch: [wire_id_bytes * 2]u8 = undefined;
        const envelope = rpc.decode(request.body, &scratch, self.wireLimits()) catch |err| return switch (err) {
            error.MessageTooLarge, error.NestingTooDeep, error.OutOfMemory => error.LimitExceeded,
            else => error.InvalidInput,
        };
        if (envelope != .request or !sameId(envelope.request.id, request.id) or
            !std.mem.eql(u8, envelope.request.method, request.method)) return error.InvalidInput;
    }

    fn register(self: *Stdio, pending: *Pending) link.Error!usize {
        self.mutex.lockUncancelable(self.io_backend);
        defer self.mutex.unlock(self.io_backend);
        try self.checkOpen();
        if (pending.id) |id| if (self.hasRetired(id)) return error.InvalidInput;
        var free_slot: ?usize = null;
        for (self.pending, 0..) |entry, slot| {
            if (entry) |existing| {
                if (pending.mode == .legacy_notifications and existing.mode == .legacy_notifications) return error.InvalidInput;
                if (pending.id != null and sameId(pending.id, existing.id)) return error.InvalidInput;
            } else if (free_slot == null) free_slot = slot;
        }
        const slot = free_slot orelse return error.LimitExceeded;
        self.pending[slot] = pending;
        return slot;
    }

    fn remove(self: *Stdio, slot: usize) void {
        self.mutex.lockUncancelable(self.io_backend);
        defer self.mutex.unlock(self.io_backend);
        const pending = self.pending[slot].?;
        while (pending.notices.popFirst()) |node| {
            const notice: *Notice = @fieldParentPtr("node", node);
            self.freeNotice(notice);
        }
        if (pending.outcome) |outcome| {
            if (outcome) |reply| freeReply(self.allocator, reply) else |_| {}
        }
        self.pending[slot] = null;
        self.changed.broadcast(self.io_backend);
    }

    fn send(self: *Stdio, op: io.Context, bytes: []const u8, pending: ?*Pending, revision: ?foo.config.McpRevision, delivery: ?*io.Delivery) link.Error!void {
        const write_op = limited(op, self.options.write_timeout_ms);
        {
            self.mutex.lockUncancelable(self.io_backend);
            defer self.mutex.unlock(self.io_backend);
            while (self.writing) {
                try self.checkOpen();
                try self.waitChanged(write_op);
            }
            try self.checkOpen();
            try check(write_op);
            self.writing = true;
            if (pending) |entry| entry.stage = .sent;
            if (revision) |value| self.revision = value;
            if (delivery) |value| value.* = .possibly_sent;
        }

        const result = self.writer.write(write_op, bytes) catch |err| mapFrameError(err);
        const incomplete = self.writer.closed;
        if (incomplete) self.child.terminate_fn(self.child.context, self.background()) catch {};
        self.mutex.lockUncancelable(self.io_backend);
        defer self.mutex.unlock(self.io_backend);
        self.writing = false;
        if (incomplete) self.failLocked(error.Disconnected);
        self.changed.broadcast(self.io_backend);
        return result;
    }

    const Event = union(enum) { notice: *Notice, reply: link.Reply };

    fn receive(self: *Stdio, allocator: Allocator, op: io.Context, pending: *Pending) link.Error!link.Reply {
        while (true) {
            switch (try self.nextEvent(op, pending)) {
                .notice => |notice| {
                    defer {
                        self.mutex.lockUncancelable(self.io_backend);
                        self.freeNotice(notice);
                        self.mutex.unlock(self.io_backend);
                    }
                    try check(op);
                    try link.Observer.notify(pending.observer, op, notice.message());
                },
                .reply => |reply| {
                    const response: foo.jsonrpc.Response = switch (reply) {
                        .accepted => return .accepted,
                        .success => |raw| .{ .success = .{ .id = pending.id.?, .result_json = raw } },
                        .failure => |err| .{ .failure = .{ .id = pending.id.?, .err = err } },
                    };
                    return link.copyReply(allocator, pending.id.?, response);
                },
            }
        }
    }

    fn nextEvent(self: *Stdio, op: io.Context, pending: *Pending) link.Error!Event {
        self.mutex.lockUncancelable(self.io_backend);
        defer self.mutex.unlock(self.io_backend);
        while (true) {
            try check(op);
            if (self.state == .stopping or self.state == .closed) return error.Disconnected;
            if (pending.notices.popFirst()) |node| return .{ .notice = @fieldParentPtr("node", node) };
            if (pending.outcome) |outcome| return .{ .reply = try outcome };
            try self.checkOpen();
            try self.waitChanged(op);
        }
    }

    fn retire(self: *Stdio, pending: *Pending) bool {
        self.mutex.lockUncancelable(self.io_backend);
        defer self.mutex.unlock(self.io_backend);
        if (self.state != .open or pending.stage != .sent or pending.outcome != null) return false;
        self.rememberRetired(pending.id.?) catch {
            self.failLocked(error.OutOfMemory);
            return false;
        };
        pending.stage = .retired;
        return true;
    }

    fn sendCancellation(self: *Stdio, id: Id) void {
        const record = std.json.Stringify.valueAlloc(self.allocator, .{
            .jsonrpc = "2.0",
            .method = cancelled_method,
            .params = .{ .requestId = idValue(id) },
        }, .{}) catch return;
        defer self.allocator.free(record);
        self.send(limited(self.background(), control_timeout_ms), record, null, null, null) catch {};
    }

    fn readStdout(self: *Stdio) void {
        const op = self.background();
        self.readFrames(op) catch |err| {
            self.mutex.lockUncancelable(self.io_backend);
            const terminate = self.state == .open;
            self.failLocked(err);
            self.mutex.unlock(self.io_backend);
            if (terminate) self.child.terminate_fn(self.child.context, op) catch {};
        };
    }

    fn readFrames(self: *Stdio, op: io.Context) link.Error!void {
        const source = self.child.stdout;
        var buffer: [8192]u8 = undefined;
        const sink: io.ByteSink = .{ .context = self, .write_fn = readFrame };
        while (true) {
            const count = try source.read_fn(source.context, op, &buffer);
            if (count == 0) break;
            self.reader.feed(op, buffer[0..count], sink) catch |err| {
                if (err == error.InvalidInput) return error.MalformedPeer;
                return mapFrameError(err);
            };
        }
        self.reader.finish(op) catch |err| return mapFrameError(err);
        return error.Disconnected;
    }

    fn readFrame(raw: *anyopaque, op: io.Context, frame: []const u8) io.Error!void {
        const self: *Stdio = @ptrCast(@alignCast(raw));
        const envelope = rpc.decode(frame, self.decode_scratch, self.wireLimits()) catch |err| return switch (err) {
            error.MessageTooLarge, error.NestingTooDeep, error.OutOfMemory => error.LimitExceeded,
            else => error.InvalidInput,
        };
        switch (envelope) {
            .request => |message| if (message.id) |id| {
                try self.reverse(op, id, message.method);
            } else {
                try self.handleNotice(message);
            },
            .response => |response| try self.handleResponse(response),
        }
    }

    fn handleResponse(self: *Stdio, response: foo.jsonrpc.Response) io.Error!void {
        const id = switch (response) {
            .success => |success| success.id,
            .failure => |failure| failure.id orelse return error.InvalidInput,
        };
        self.mutex.lockUncancelable(self.io_backend);
        defer self.mutex.unlock(self.io_backend);
        if (self.state != .open) return;
        const pending = self.find(id) orelse {
            if (self.hasRetired(id)) return;
            return error.InvalidInput;
        };
        if (pending.stage == .retired) return;
        if (pending.stage != .sent or pending.outcome != null) return error.InvalidInput;
        pending.outcome = link.copyReply(self.allocator, id, response) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidInput,
        };
        self.changed.broadcast(self.io_backend);
    }

    fn handleNotice(self: *Stdio, message: foo.jsonrpc.Request) io.Error!void {
        self.mutex.lockUncancelable(self.io_backend);
        defer self.mutex.unlock(self.io_backend);
        if (self.state != .open) return;
        if (self.revision == .@"2026-07-28") {
            try self.modernNotice(message);
        } else {
            for (self.pending) |entry| if (entry) |pending| {
                if (pending.mode == .legacy_notifications) {
                    try self.enqueue(pending, message);
                    return;
                }
            };
            for (self.pending) |entry| if (entry) |pending| {
                if (pending.stage == .sent and pending.outcome == null and pending.observer != null)
                    try self.enqueue(pending, message);
            };
        }
    }

    fn modernNotice(self: *Stdio, message: foo.jsonrpc.Request) io.Error!void {
        const cancelled = std.mem.eql(u8, message.method, cancelled_method);
        const Params = struct {
            _meta: struct { @"io.modelcontextprotocol/subscriptionId": ?std.json.Value = null } = .{},
            requestId: ?std.json.Value = null,
        };
        const raw = message.params_json orelse "{}";
        const parsed = std.json.parseFromSlice(Params, self.allocator, raw, .{ .ignore_unknown_fields = true }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (cancelled) return;
            return error.InvalidInput;
        };
        defer parsed.deinit();
        const value = if (cancelled) parsed.value.requestId else @field(parsed.value._meta, subscription_id_key);
        const id_value = value orelse {
            if (std.mem.eql(u8, message.method, ack_method)) return error.InvalidInput;
            return;
        };
        const id = switch (id_value) {
            .integer => |number| Id{ .number = number },
            .string => |bytes| Id{ .string = bytes },
            else => if (cancelled) return else return error.InvalidInput,
        };
        const pending = self.find(id) orelse {
            if (cancelled or self.hasRetired(id)) return;
            return error.InvalidInput;
        };
        if (pending.stage == .retired) return;
        if (pending.mode != .subscription or pending.stage != .sent or pending.outcome != null) {
            if (cancelled) return;
            return error.InvalidInput;
        }
        if (cancelled) {
            pending.stage = .retired;
            pending.outcome = error.Disconnected;
            self.rememberRetired(id) catch return error.OutOfMemory;
            self.changed.broadcast(self.io_backend);
        } else try self.enqueue(pending, message);
    }

    fn enqueue(self: *Stdio, pending: *Pending, message: foo.jsonrpc.Request) io.Error!void {
        const params = message.params_json orelse "";
        const len = message.method.len + params.len;
        if (self.queued_events == self.options.limits.pending_events or
            len > self.options.limits.wire_message_bytes - self.queued_bytes) return error.LimitExceeded;
        const queued = try self.allocator.create(Notice);
        errdefer self.allocator.destroy(queued);
        const bytes = try self.allocator.alloc(u8, len);
        @memcpy(bytes[0..message.method.len], message.method);
        @memcpy(bytes[message.method.len..], params);
        queued.* = .{ .bytes = bytes, .method_len = message.method.len, .has_params = message.params_json != null };
        self.queued_events += 1;
        self.queued_bytes += len;
        pending.notices.append(&queued.node);
        self.changed.broadcast(self.io_backend);
    }

    fn freeNotice(self: *Stdio, queued: *Notice) void {
        self.queued_events -= 1;
        self.queued_bytes -= queued.bytes.len;
        self.allocator.free(queued.bytes);
        self.allocator.destroy(queued);
    }

    fn reverse(self: *Stdio, op: io.Context, id: Id, method: []const u8) io.Error!void {
        if (tooLong(id)) return error.LimitExceeded;
        const legacy = profile: {
            self.mutex.lockUncancelable(self.io_backend);
            defer self.mutex.unlock(self.io_backend);
            if (self.state != .open) return;
            break :profile self.revision == .@"2025-11-25";
        };
        const reply: foo.jsonrpc.Response = if (legacy and std.mem.eql(u8, method, "ping"))
            .{ .success = .{ .id = id, .result_json = "{}" } }
        else
            .{ .failure = .{ .id = id, .err = .{ .code = foo.jsonrpc.Code.method_not_found, .message = "Method not supported" } } };
        var buffer: [wire_id_bytes * 6 + 256]u8 = undefined;
        const record = rpc.encodeResponse(&buffer, reply, self.wireLimits()) catch return error.LimitExceeded;
        self.send(op, record, null, null, null) catch |err| switch (err) {
            error.Cancelled, error.DeadlineExceeded, error.Disconnected => |reason| return reason,
            else => return error.IoFailure,
        };
    }

    fn find(self: *Stdio, id: Id) ?*Pending {
        for (self.pending) |entry| if (entry) |pending| {
            if (sameId(pending.id, id)) return pending;
        };
        return null;
    }

    fn hasRetired(self: *Stdio, id: Id) bool {
        for (self.retired) |entry| if (sameId(entry, id)) return true;
        return false;
    }

    // An evicted late reply fails the connection as an unexpected response.
    fn rememberRetired(self: *Stdio, id: Id) Allocator.Error!void {
        const owned: Id = switch (id) {
            .number => id,
            .string => |bytes| .{ .string = try self.allocator.dupe(u8, bytes) },
        };
        self.freeRetired(self.retired[self.next_retired]);
        self.retired[self.next_retired] = owned;
        self.next_retired = (self.next_retired + 1) % self.retired.len;
    }

    fn freeRetired(self: *Stdio, entry: ?Id) void {
        if (entry) |id| if (id == .string) self.allocator.free(id.string);
    }

    fn drainStderr(self: *Stdio) void {
        const source = self.child.stderr;
        const op = self.background();
        var buffer: [8192]u8 = undefined;
        while (true) {
            const count = source.read_fn(source.context, op, &buffer) catch return;
            if (count == 0) return;
            self.mutex.lockUncancelable(self.io_backend);
            self.stderr_total +|= count;
            const ring = self.stderr_ring;
            if (ring.len != 0) {
                const tail = buffer[count -| ring.len..count];
                const first = @min(tail.len, ring.len - self.stderr_end);
                @memcpy(ring[self.stderr_end..][0..first], tail[0..first]);
                @memcpy(ring[0 .. tail.len - first], tail[first..]);
                self.stderr_end = (self.stderr_end + tail.len) % ring.len;
            }
            self.mutex.unlock(self.io_backend);
        }
    }

    pub fn stderrSnapshot(self: *Stdio, allocator: Allocator) Allocator.Error!Diagnostics {
        self.mutex.lockUncancelable(self.io_backend);
        defer self.mutex.unlock(self.io_backend);
        const ring = self.stderr_ring;
        const len = @min(self.stderr_total, ring.len);
        const truncated = self.stderr_total > len;
        const bytes = try allocator.alloc(u8, len);
        const start = if (len == ring.len) self.stderr_end else 0;
        const first = @min(len, ring.len - start);
        @memcpy(bytes[0..first], ring[start..][0..first]);
        @memcpy(bytes[first..], ring[0 .. len - first]);
        return .{ .stderr = bytes, .truncated = truncated };
    }

    fn shutdownLink(raw: *anyopaque, cleanup: io.Context) link.Error!void {
        const self: *Stdio = @ptrCast(@alignCast(raw));
        return self.shutdown(cleanup);
    }

    pub fn shutdown(self: *Stdio, cleanup: io.Context) link.Error!void {
        {
            self.mutex.lockUncancelable(self.io_backend);
            defer self.mutex.unlock(self.io_backend);
            while (self.state == .stopping) self.changed.waitUncancelable(self.io_backend, &self.mutex);
            if (self.state == .closed) {
                if (self.state.closed) |err| return err;
                return;
            }
            self.state = .stopping;
            self.changed.broadcast(self.io_backend);
            while (self.writing) self.changed.waitUncancelable(self.io_backend, &self.mutex);
        }

        var token: io.Cancellation = .{};
        const release_op: io.Context = .{ .io = self.io_backend, .clock = cleanup.clock, .cancellation = &token };
        var failure: ?link.Error = null;
        self.child.close_stdin_fn(self.child.context, release_op) catch |err| {
            failure = err;
        };
        var grace = limited(cleanup, self.options.shutdown_grace_ms);
        grace.io = self.io_backend;
        if (self.child.wait_fn(self.child.context, grace)) |_| {} else |err| {
            if (err != error.DeadlineExceeded and err != error.Cancelled and failure == null) failure = err;
            self.child.terminate_fn(self.child.context, release_op) catch {};
        }
        self.stop_pipes.request();
        self.stdout_task.await(self.io_backend);
        self.stderr_task.await(self.io_backend);
        self.child.release_fn(self.child.context, release_op) catch |err| {
            if (failure == null) failure = err;
        };

        self.mutex.lockUncancelable(self.io_backend);
        defer self.mutex.unlock(self.io_backend);
        for (self.pending) |*entry| while (entry.* != null) {
            self.changed.waitUncancelable(self.io_backend, &self.mutex);
        };
        self.state = .{ .closed = failure };
        self.changed.broadcast(self.io_backend);
        if (failure) |err| return err;
    }

    /// Shutdown is idempotent. The owner joins callers before freeing the link.
    pub fn deinit(self: *Stdio, cleanup: io.Context) link.Error!void {
        const allocator = self.allocator;
        defer allocator.destroy(self);
        defer allocator.free(self.pending);
        defer allocator.free(self.retired);
        defer for (self.retired) |entry| self.freeRetired(entry);
        defer allocator.free(self.reader.buffer);
        defer allocator.free(self.decode_scratch);
        defer allocator.free(self.writer.scratch);
        defer allocator.free(self.stderr_ring);
        try self.shutdown(cleanup);
    }

    fn background(self: *Stdio) io.Context {
        return .{ .io = self.io_backend, .clock = self.clock, .cancellation = &self.stop_pipes };
    }

    fn wireLimits(self: *const Stdio) foo.wire.json.Limits {
        return .{ .max_bytes = self.options.limits.wire_message_bytes, .max_depth = self.options.limits.json_depth };
    }

    fn checkOpen(self: *Stdio) link.Error!void {
        return switch (self.state) {
            .open => {},
            .failed => |err| err,
            .stopping, .closed => error.Disconnected,
        };
    }

    fn failLocked(self: *Stdio, err: link.Error) void {
        if (self.state != .open) return;
        self.state = .{ .failed = err };
        self.changed.broadcast(self.io_backend);
    }

    fn waitChanged(self: *Stdio, op: io.Context) io.Error!void {
        try check(op);
        const timeout_ms = if (op.deadline_ms) |deadline| @min(wait_interval_ms, deadline -| op.clock.now()) else wait_interval_ms;
        self.changed.waitTimeout(self.io_backend, &self.mutex, .{
            .duration = .{ .clock = .awake, .raw = .fromMilliseconds(@intCast(timeout_ms)) },
        }) catch |err| switch (err) {
            error.Canceled => return error.Cancelled,
            error.Timeout => {},
        };
    }
};

fn check(op: io.Context) io.Error!void {
    try op.check();
    op.io.checkCancel() catch return error.Cancelled;
}

fn limited(op: io.Context, duration_ms: u64) io.Context {
    var result = op;
    const deadline = op.clock.now() +| duration_ms;
    result.deadline_ms = @min(op.deadline_ms orelse deadline, deadline);
    return result;
}

fn sameId(a: ?Id, b: ?Id) bool {
    if (a) |left| return if (b) |right| left.eql(right) else false;
    return b == null;
}

fn tooLong(id: Id) bool {
    return id == .string and id.string.len > wire_id_bytes;
}

fn idValue(id: Id) std.json.Value {
    return switch (id) {
        .number => |number| .{ .integer = number },
        .string => |bytes| .{ .string = bytes },
    };
}

fn freeReply(allocator: Allocator, reply: link.Reply) void {
    switch (reply) {
        .accepted => {},
        .success => |bytes| allocator.free(bytes),
        .failure => |failure| {
            allocator.free(failure.message);
            if (failure.data_json) |bytes| allocator.free(bytes);
        },
    }
}

fn mapFrameError(err: foo.wire.framing.Error) link.Error {
    return switch (err) {
        error.MalformedFrame, error.TruncatedFrame => error.MalformedPeer,
        error.Closed => error.Disconnected,
        error.Busy => error.IoFailure,
        else => |reason| reason,
    };
}
