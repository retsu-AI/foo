const std = @import("std");
const foo = @import("foo");
const protocol = @import("protocol.zig");
const projection = @import("projection.zig");
const Client = @import("client.zig").Client;
const io = foo.io;
const host = foo.host;
const rpc = foo.jsonrpc;
const wire = foo.wire;

pub const Limits = protocol.Limits;
pub const OpenInput = struct {
    session: foo.events.SessionId,
    cwd: []const u8,
    editor_servers: []const foo.config.McpServer,
    client: host.Host,
};
pub const OpenError = io.Error || error{AuthenticationRequired};
pub const Factory = struct {
    context: *anyopaque,
    /// Own policy checks and MCP registration. Copy any needed editor server data
    /// into session-owned storage. The descriptors are borrowed for this call.
    open_fn: *const fn (*anyopaque, std.mem.Allocator, io.Context, OpenInput) OpenError!Runtime,
};
pub const Runtime = struct {
    context: *anyopaque,
    runner: host.Runner,
    settings: foo.config.Resolved,
    prepare_fn: *const fn (*anyopaque, std.mem.Allocator, io.Context, foo.events.RunId) io.Error!RunServices,
    close_fn: ?*const fn (*anyopaque, io.Context) io.Error!void = null,
};
pub const RunServices = struct {
    tools: foo.tool.Registry,
    services: host.Services,
};
pub const Options = struct { factory: Factory, limits: Limits = .{} };
pub const Shutdown = enum { eof, invalid_frame, input_failed, output_failed, output_pressure, cancelled };
pub const Report = struct {
    reason: Shutdown,
    remote_cleanup_unconfirmed: usize,
    runtime_cleanup_failures: usize,
};

pub fn serveStdio(allocator: std.mem.Allocator, std_io: std.Io, options: Options) !Report {
    return serve(allocator, std_io, .stdin(), .stdout(), options);
}

/// The caller owns the files and supplies an allocator safe for concurrent use.
/// Factory and runner callbacks must honor operation cancellation and deadlines,
/// including Io cancellation of blocked operations. The service joins all tasks
/// before returning.
pub fn serve(allocator: std.mem.Allocator, std_io: std.Io, input: std.Io.File, output: std.Io.File, options: Options) !Report {
    try options.limits.validate();
    const limits = options.limits;
    const records = try allocator.alloc([]u8, limits.queued_frames);
    defer allocator.free(records);
    const frame = try allocator.alloc(u8, limits.frame_bytes);
    defer allocator.free(frame);
    const decode = try allocator.alloc(u8, limits.frame_bytes);
    defer allocator.free(decode);
    const params = try allocator.alloc(u8, limits.frame_bytes);
    defer allocator.free(params);
    const encode = try allocator.alloc(u8, limits.frame_bytes);
    defer allocator.free(encode);
    var connection: Connection = .{
        .io = std_io,
        .allocator = allocator,
        .options = options,
        .input = input,
        .output = output,
        .records = records,
        .framer = .init(frame, .reject),
        .decode_buffer = decode,
        .params_buffer = params,
        .encode_buffer = encode,
        .ids = try wire.correlation.Table.init(allocator, .{
            .pending_per_direction = 2,
            .id_bytes = limits.request_id_bytes,
        }),
    };
    defer connection.ids.deinit();
    defer connection.freeRecords();

    var writer = try std_io.concurrent(Connection.writeLoop, .{&connection});
    defer writer.cancel(std_io);
    var reader = try std_io.concurrent(Connection.readLoop, .{&connection});
    defer reader.cancel(std_io);
    connection.drive();
    reader.cancel(std_io);
    var report = connection.teardown();
    connection.drainOutput();
    writer.cancel(std_io);
    report.reason = connection.shutdown.?;
    return report;
}

const Code = struct {
    const auth_required: i32 = -32000;
    const busy: i32 = -32010;
    const not_initialized: i32 = -32011;
    const capacity: i32 = -32012;
    const cancelled: i32 = -32800;
};
const Failure = struct { code: i32, message: []const u8 };
const invalid_params: Failure = .{ .code = rpc.Code.invalid_params, .message = "Invalid or unsupported method parameters" };
const internal: Failure = .{ .code = rpc.Code.internal_error, .message = "ACP operation failed" };
const cancelled: Failure = .{ .code = Code.cancelled, .message = "Request cancelled" };
const busy: Failure = .{ .code = Code.busy, .message = "Another request owns the runtime" };
const capacity: Failure = .{ .code = Code.capacity, .message = "ACP capacity exceeded" };

const Session = struct {
    arena: std.heap.ArenaAllocator,
    client: Client,
    runtime: ?Runtime = null,
    history: std.ArrayList(foo.provider.Message) = .empty,
    history_bytes: usize = 0,
    unusable: bool = false,

    fn retain(self: *Session, message: foo.provider.Message, limit: usize) io.Error!void {
        errdefer self.unusable = true;
        const bytes = projection.messageBytes(message);
        if (bytes > limit - self.history_bytes) return error.LimitExceeded;
        const allocator = self.arena.allocator();
        const copy = try foo.provider.copyMessage(allocator, message);
        try self.history.append(allocator, copy);
        self.history_bytes += bytes;
    }
};

const Work = struct {
    arena: std.heap.ArenaAllocator,
    ticket: wire.correlation.Ticket,
    deadline: u64,
    cancellation: io.Cancellation = .{},
    deadline_expired: bool = false,
    cancelled_by_peer: bool = false,
    completion: ?Completion = null,
    kind: union(enum) {
        new: struct { id: foo.events.SessionId, input: protocol.SessionInput },
        prompt: struct { session: *Session, id: foo.events.RunId, message: foo.provider.Message },
    },

    const Completion = union(enum) { created: *Session, prompt: projection.StopReason, failure: Failure };

    fn destroy(self: *Work, allocator: std.mem.Allocator) void {
        self.arena.deinit();
        allocator.destroy(self);
    }
};

const Pending = struct {
    outbound: wire.correlation.Outbound,
    cleanup_call: bool,
    allocator: std.mem.Allocator,
    result: ?io.Error![]const u8 = null,
};

const Connection = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
    input: std.Io.File,
    output: std.Io.File,
    framer: wire.framing.Ndjson,
    decode_buffer: []u8,
    params_buffer: []u8,
    encode_buffer: []u8,
    ids: wire.correlation.Table,

    mutex: std.Io.Mutex = .init,
    epoch: std.atomic.Value(u32) = .init(0),
    shutdown: ?Shutdown = null,
    shutdown_at: u64 = 0,
    records: [][]u8,
    head: usize = 0,
    queued_frames: usize = 0,
    queued_bytes: usize = 0,
    writer_done: bool = false,
    write_deadline: ?u64 = null,
    connection_cancellation: io.Cancellation = .{},

    client_capabilities: ?host.Capabilities = null,
    active: ?*Work = null,
    pending: ?*Pending = null,
    sessions: std.ArrayList(*Session) = .empty,
    session_sequence: u64 = 0,
    run_sequence: u64 = 0,
    runtime_cleanup_failures: usize = 0,

    fn clockNow(context: *anyopaque) u64 {
        const self: *Connection = @ptrCast(@alignCast(context));
        return @intCast(@max(0, std.Io.Clock.awake.now(self.io).toMilliseconds()));
    }

    fn operation(self: *Connection, cancellation: *const io.Cancellation, deadline: ?u64) io.Context {
        return .{
            .io = self.io,
            .clock = .{ .context = self, .now_fn = clockNow },
            .cancellation = cancellation,
            .deadline_ms = deadline,
        };
    }

    fn signal(self: *Connection) void {
        _ = self.epoch.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.epoch.raw, std.math.maxInt(u32));
    }

    fn waitSignal(self: *Connection, epoch: u32, deadline: ?u64) std.Io.Cancelable!void {
        const now = clockNow(self);
        const timeout: std.Io.Timeout = if (deadline) |time| .{ .duration = .{
            .clock = .awake,
            .raw = .fromMilliseconds(@intCast(@min(time -| now, std.math.maxInt(i64)))),
        } } else .none;
        try self.io.futexWaitTimeout(u32, &self.epoch.raw, epoch, timeout);
    }

    fn closeLocked(self: *Connection, reason: Shutdown) void {
        if (self.shutdown != null and self.shutdown != .eof) return;
        if (self.shutdown == null) self.shutdown_at = clockNow(self) +| self.options.limits.shutdown_ms;
        self.shutdown = reason;
        self.connection_cancellation.request();
        if (self.active) |work| self.cancelLocked(work);
        if (self.pending) |pending| self.retireReverse(pending, error.Disconnected, false);
        self.signal();
    }

    fn drive(self: *Connection) void {
        var future: ?std.Io.Future(void) = null;
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const now = clockNow(self);
            if (self.write_deadline) |deadline| {
                if (now >= deadline) self.closeLocked(.output_pressure);
            }
            if (self.active) |work| {
                if (now >= work.deadline and work.completion == null) {
                    work.deadline_expired = true;
                    self.cancelLocked(work);
                }
                const abort = work.cancellation.requested.load(.acquire);
                if (work.completion != null or abort) {
                    self.mutex.unlock(self.io);
                    if (future) |*task| {
                        if (abort) task.cancel(self.io) else task.await(self.io);
                        future = null;
                    }
                    self.finishWork(work);
                    continue;
                }
                if (future == null) {
                    future = self.io.concurrent(runWork, .{ self, work }) catch {
                        work.completion = .{ .failure = internal };
                        self.mutex.unlock(self.io);
                        continue;
                    };
                }
            }
            if (self.shutdown != null) {
                self.mutex.unlock(self.io);
                return;
            }
            var deadline = self.write_deadline orelse std.math.maxInt(u64);
            if (self.active) |work| deadline = @min(deadline, work.deadline);
            const epoch = self.epoch.load(.acquire);
            self.mutex.unlock(self.io);
            self.waitSignal(epoch, if (deadline == std.math.maxInt(u64)) null else deadline) catch {
                self.mutex.lockUncancelable(self.io);
                self.closeLocked(.cancelled);
                self.mutex.unlock(self.io);
            };
        }
    }

    fn drainOutput(self: *Connection) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const deadline = @min(self.shutdown_at, self.write_deadline orelse self.shutdown_at);
            if (self.shutdown == .eof and !self.writer_done and clockNow(self) >= deadline) {
                self.closeLocked(.output_pressure);
            }
            const done = self.shutdown != .eof or self.writer_done;
            const epoch = self.epoch.load(.acquire);
            self.mutex.unlock(self.io);
            if (done) return;
            self.waitSignal(epoch, deadline) catch return;
        }
    }

    fn readLoop(self: *Connection) void {
        const op = self.operation(&self.connection_cancellation, null);
        var buffer: [8192]u8 = undefined;
        const reason: Shutdown = while (true) {
            const size = self.input.readStreaming(self.io, &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => {
                    self.framer.finish(op) catch break .invalid_frame;
                    break .eof;
                },
                error.Canceled => return,
                else => break .input_failed,
            };
            if (size == 0) {
                self.framer.finish(op) catch break .invalid_frame;
                break .eof;
            }
            self.framer.feed(op, buffer[0..size], .{ .context = self, .write_fn = receive }) catch |err| switch (err) {
                error.Cancelled, error.Disconnected => return,
                else => break .invalid_frame,
            };
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closeLocked(reason);
    }

    fn writeLoop(self: *Connection) void {
        defer {
            self.mutex.lockUncancelable(self.io);
            self.writer_done = true;
            self.signal();
            self.mutex.unlock(self.io);
        }
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const epoch = self.epoch.load(.acquire);
            const quitting = self.shutdown != null and self.shutdown != .eof;
            const record = if (quitting) null else self.popRecord();
            if (record != null) {
                self.write_deadline = clockNow(self) +| self.options.limits.write_ms;
                self.signal();
            }
            const done = self.shutdown != null and record == null;
            self.mutex.unlock(self.io);
            if (done) return;
            if (record) |bytes| {
                defer self.allocator.free(bytes);
                self.output.writeStreamingAll(self.io, bytes) catch |err| {
                    if (err == error.Canceled) return;
                    self.mutex.lockUncancelable(self.io);
                    self.closeLocked(.output_failed);
                    self.mutex.unlock(self.io);
                    return;
                };
                self.mutex.lockUncancelable(self.io);
                self.write_deadline = null;
                self.signal();
                self.mutex.unlock(self.io);
            } else self.waitSignal(epoch, null) catch return;
        }
    }

    fn receive(context: *anyopaque, _: io.Context, record: []const u8) io.Error!void {
        const self: *Connection = @ptrCast(@alignCast(context));
        const message = wire.jsonrpc.decode(record, self.decode_buffer, self.options.limits.json());
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.shutdown != null) return error.Disconnected;
        const envelope = message catch |err| {
            const failure: Failure = if (err == error.InvalidJson)
                .{ .code = rpc.Code.parse_error, .message = "Invalid JSON" }
            else
                .{ .code = rpc.Code.invalid_request, .message = "Invalid JSON-RPC request" };
            return self.sendError(null, failure);
        };
        switch (envelope) {
            .response => |response| self.receiveResponse(response),
            .request => |request| try self.receiveRequest(request),
        }
    }

    fn receiveRequest(self: *Connection, request: rpc.Request) io.Error!void {
        const method = request.method;
        const params = request.params_json orelse "{}";
        if (request.id == null) {
            self.receiveNotification(method, params);
            return;
        }
        const ticket = self.ids.beginInbound(request.id.?, null) catch |err| {
            const failure: Failure = if (err == error.DuplicateId)
                .{ .code = rpc.Code.invalid_request, .message = "Request ID already in use" }
            else
                capacity;
            return self.sendError(null, failure);
        };
        if (std.mem.eql(u8, method, "initialize")) {
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            if (self.client_capabilities != null) return self.respond(ticket, .{ .failure = .{
                .code = rpc.Code.invalid_request,
                .message = "ACP connection is already initialized",
            } });
            const init = protocol.parse(protocol.Initialize, arena.allocator(), params) catch |err|
                return self.respond(ticket, .{ .failure = parseFailure(err) });
            const caps = init.clientCapabilities;
            self.client_capabilities = .{
                .read_file = caps.fs.readTextFile,
                .write_file = caps.fs.writeTextFile,
                .terminal = caps.terminal,
            };
            return self.respond(ticket, .{ .success = protocol.initialize_result });
        }
        const kind: enum { new, prompt } = if (std.mem.eql(u8, method, "session/new")) .new else if (std.mem.eql(u8, method, "session/prompt")) .prompt else return self.respond(ticket, .{ .failure = .{
            .code = rpc.Code.method_not_found,
            .message = "Method not found",
        } });
        if (self.client_capabilities == null) return self.respond(ticket, .{ .failure = .{
            .code = Code.not_initialized,
            .message = "Initialize ACP version 1 first",
        } });
        if (self.active != null) return self.respond(ticket, .{ .failure = busy });

        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        var transferred = false;
        defer if (!transferred) arena.deinit();
        const allocator = arena.allocator();
        const work = self.allocator.create(Work) catch return self.respond(ticket, .{ .failure = internal });
        defer if (!transferred) self.allocator.destroy(work);
        const limits = self.options.limits;
        const work_kind: @FieldType(Work, "kind") = switch (kind) {
            .new => new: {
                if (self.sessions.items.len == limits.sessions) return self.respond(ticket, .{ .failure = capacity });
                const input = protocol.newSession(allocator, params, limits) catch |err|
                    return self.respond(ticket, .{ .failure = parseFailure(err) });
                const sequence = std.math.add(u64, self.session_sequence, 1) catch
                    return self.respond(ticket, .{ .failure = capacity });
                self.sessions.ensureUnusedCapacity(self.allocator, 1) catch
                    return self.respond(ticket, .{ .failure = internal });
                self.session_sequence = sequence;
                break :new .{ .new = .{ .id = @fromBackingInt(@intCast(sequence)), .input = input } };
            },
            .prompt => prompt: {
                const input = protocol.prompt(allocator, params, limits) catch |err|
                    return self.respond(ticket, .{ .failure = parseFailure(err) });
                const session = self.findSession(input.session) orelse
                    return self.respond(ticket, .{ .failure = invalid_params });
                if (session.unusable) return self.respond(ticket, .{ .failure = .{
                    .code = Code.capacity,
                    .message = "Session history cannot continue",
                } });
                if (projection.messageBytes(input.message) > limits.history_bytes - session.history_bytes)
                    return self.respond(ticket, .{ .failure = capacity });
                const sequence = std.math.add(u64, self.run_sequence, 1) catch
                    return self.respond(ticket, .{ .failure = capacity });
                self.run_sequence = sequence;
                break :prompt .{ .prompt = .{ .session = session, .id = @fromBackingInt(@intCast(sequence)), .message = input.message } };
            },
        };
        work.* = .{ .arena = arena, .ticket = ticket, .deadline = clockNow(self) +| limits.turn_ms, .kind = work_kind };
        transferred = true;
        self.active = work;
        self.signal();
    }

    fn findSession(self: *Connection, id: []const u8) ?*Session {
        for (self.sessions.items) |session| {
            if (std.mem.eql(u8, session.client.wire_id, id)) return session;
        }
        return null;
    }

    fn receiveNotification(self: *Connection, method: []const u8, raw: []const u8) void {
        const work = self.active orelse return;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        if (std.mem.eql(u8, method, "session/cancel")) {
            if (work.kind != .prompt) return;
            const params = protocol.parse(protocol.SessionRef, arena.allocator(), raw) catch return;
            if (std.mem.eql(u8, work.kind.prompt.session.client.wire_id, params.sessionId)) {
                work.cancelled_by_peer = true;
                self.cancelLocked(work);
            }
        } else if (std.mem.eql(u8, method, "$/cancel_request")) {
            const id = protocol.cancelId(arena.allocator(), raw) catch return;
            const admission = self.ids.prepareInboundResponse(work.ticket, clockNow(self)) catch return;
            if (admission == .ready and id.eql(admission.ready.id)) {
                work.cancelled_by_peer = true;
                self.cancelLocked(work);
            }
        }
    }

    fn cancelLocked(self: *Connection, work: *Work) void {
        work.cancellation.request();
        if (self.pending) |pending| {
            if (!pending.cleanup_call) self.retireReverse(pending, error.Cancelled, self.shutdown == null);
        }
        self.signal();
    }

    fn runWork(self: *Connection, work: *Work) void {
        const op = self.operation(&work.cancellation, work.deadline);
        const result: Work.Completion = switch (work.kind) {
            .new => |req| self.openSession(op, req.id, req.input) catch |err| .{ .failure = openFailure(err) },
            .prompt => |req| self.runPrompt(op, work.arena.allocator(), req.session, req.id, req.message) catch |err|
                .{ .failure = if (err == error.Cancelled) cancelled else internal },
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        work.completion = result;
        self.signal();
    }

    fn openSession(self: *Connection, op: io.Context, id: foo.events.SessionId, input: protocol.SessionInput) OpenError!Work.Completion {
        try op.check();
        const session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        session.* = .{ .arena = .init(self.allocator), .client = undefined };
        errdefer session.arena.deinit();
        const allocator = session.arena.allocator();
        const cwd = try allocator.dupe(u8, input.cwd);
        const wire_id = try std.fmt.allocPrint(allocator, "session-{d}", .{@backingInt(id)});
        session.client = .{
            .allocator = self.allocator,
            .peer = .{ .context = self, .call_fn = call },
            .limits = self.options.limits,
            .capabilities = self.client_capabilities.?,
            .session = id,
            .wire_id = wire_id,
        };
        const factory = self.options.factory;
        session.runtime = try factory.open_fn(factory.context, allocator, op, .{
            .session = id,
            .cwd = cwd,
            .editor_servers = input.mcp_servers,
            .client = session.client.adapter(),
        });
        return .{ .created = session };
    }

    fn runPrompt(self: *Connection, op: io.Context, arena: std.mem.Allocator, session: *Session, run: foo.events.RunId, message: foo.provider.Message) io.Error!Work.Completion {
        try op.check();
        session.client.run = run;
        defer {
            var cancellation: io.Cancellation = .{};
            const deadline = clockNow(self) +| self.options.limits.shutdown_ms;
            session.client.cleanup(self.operation(&cancellation, deadline));
        }
        const runtime = session.runtime.?;
        const prepared = try runtime.prepare_fn(runtime.context, arena, op, run);
        const history = session.history.items;
        const messages = try arena.alloc(foo.provider.Message, history.len + 1);
        @memcpy(messages[0..history.len], history);
        messages[history.len] = message;
        var turn: Turn = .{
            .connection = self,
            .session = session,
            .run = run,
            .arena = arena,
            .budget = .{ .limit = self.options.limits.history_bytes - session.history_bytes },
        };
        const result = runtime.runner.run_fn(runtime.runner.context, self.allocator, op, .{
            .session = session.client.session,
            .run = run,
            .settings = runtime.settings,
            .messages = messages,
            .tools = prepared.tools,
            .services = prepared.services,
        }, .{ .context = &turn, .emit_fn = Turn.emit });
        const stop = if (result) |outcome| stop: {
            if (outcome.uncertain_effects) session.unusable = true;
            break :stop projection.stop(outcome);
        } else |_| null;
        if (stop != .refusal) {
            for (turn.committed.items) |entry| try session.retain(entry, self.options.limits.history_bytes);
        }
        if (turn.failure) |err| return err;
        _ = try result;
        return if (stop) |reason| .{ .prompt = reason } else .{ .failure = internal };
    }

    fn finishWork(self: *Connection, work: *Work) void {
        defer work.destroy(self.allocator);
        self.mutex.lockUncancelable(self.io);
        var completion: Work.Completion = work.completion orelse .{ .failure = cancelled };
        const abort = work.cancellation.requested.load(.acquire);
        if (completion == .created and (abort or self.shutdown != null)) {
            var report: Report = .{
                .reason = self.shutdown orelse .cancelled,
                .remote_cleanup_unconfirmed = 0,
                .runtime_cleanup_failures = 0,
            };
            const deadline = if (self.shutdown != null) self.shutdown_at else clockNow(self) +| self.options.limits.shutdown_ms;
            self.mutex.unlock(self.io);
            self.destroySession(completion.created, deadline, &report);
            self.mutex.lockUncancelable(self.io);
            self.runtime_cleanup_failures +|= report.runtime_cleanup_failures;
            completion = .{ .failure = cancelled };
        }

        if (self.shutdown != null) {
            self.ids.retire(work.ticket) catch {};
        } else if (work.cancelled_by_peer) {
            self.respond(work.ticket, if (work.kind == .prompt) .{ .success = "{\"stopReason\":\"cancelled\"}" } else .{ .failure = cancelled }) catch {};
        } else if (work.deadline_expired) {
            self.respond(work.ticket, .{ .failure = .{ .code = rpc.Code.internal_error, .message = "ACP request deadline exceeded" } }) catch {};
        } else switch (completion) {
            .created => |session| {
                self.sessions.appendAssumeCapacity(session);
                const raw = protocol.stringify(self.params_buffer, .{ .sessionId = session.client.wire_id }) catch unreachable;
                self.respond(work.ticket, .{ .success = raw }) catch {};
            },
            .prompt => |stop| {
                const raw = protocol.stringify(self.params_buffer, .{ .stopReason = stop }) catch unreachable;
                self.respond(work.ticket, .{ .success = raw }) catch {};
            },
            .failure => |failure| self.respond(work.ticket, .{ .failure = failure }) catch {},
        }
        self.active = null;
        self.mutex.unlock(self.io);
    }

    fn destroySession(self: *Connection, session: *Session, deadline: u64, report: *Report) void {
        var cancellation: io.Cancellation = .{};
        if (session.runtime.?.close_fn) |close| {
            close(session.runtime.?.context, self.operation(&cancellation, deadline)) catch {
                report.runtime_cleanup_failures +|= 1;
            };
        }
        report.remote_cleanup_unconfirmed +|= session.client.unconfirmed;
        session.client.deinit();
        session.arena.deinit();
        self.allocator.destroy(session);
    }

    fn teardown(self: *Connection) Report {
        self.mutex.lockUncancelable(self.io);
        const reason = self.shutdown.?;
        const deadline = self.shutdown_at;
        self.mutex.unlock(self.io);
        var report: Report = .{
            .reason = reason,
            .remote_cleanup_unconfirmed = 0,
            .runtime_cleanup_failures = self.runtime_cleanup_failures,
        };
        for (self.sessions.items) |session| self.destroySession(session, deadline, &report);
        self.sessions.deinit(self.allocator);
        return report;
    }

    const Result = union(enum) { success: []const u8, failure: Failure };

    fn respond(self: *Connection, ticket: wire.correlation.Ticket, result: Result) io.Error!void {
        const admission = self.ids.prepareInboundResponse(ticket, clockNow(self)) catch return error.IoFailure;
        const id = admission.ready.id;
        defer self.ids.retire(ticket) catch unreachable;
        switch (result) {
            .success => |raw| try self.sendResponse(.{ .success = .{ .id = id, .result_json = raw } }),
            .failure => |failure| try self.sendError(id, failure),
        }
    }

    fn sendError(self: *Connection, id: ?rpc.Id, failure: Failure) io.Error!void {
        try self.sendResponse(.{ .failure = .{ .id = id, .err = .{ .code = failure.code, .message = failure.message } } });
    }

    fn sendResponse(self: *Connection, response: rpc.Response) io.Error!void {
        const encoded = wire.jsonrpc.encodeResponse(self.encode_buffer, response, self.options.limits.json()) catch {
            self.closeLocked(.output_pressure);
            return error.LimitExceeded;
        };
        try self.queueRecord(encoded);
    }

    fn sendRequest(self: *Connection, request: rpc.Request) io.Error!void {
        const encoded = wire.jsonrpc.encodeRequest(self.encode_buffer, request, self.options.limits.json()) catch
            return error.LimitExceeded;
        try self.queueRecord(encoded);
    }

    fn queueRecord(self: *Connection, record: []const u8) io.Error!void {
        if (self.shutdown != null) return error.Disconnected;
        const size = record.len + 1;
        if (self.queued_frames == self.records.len or size > self.options.limits.queued_bytes - self.queued_bytes) {
            self.closeLocked(.output_pressure);
            return error.Disconnected;
        }
        const owned = self.allocator.alloc(u8, size) catch |err| {
            self.closeLocked(.output_pressure);
            return err;
        };
        @memcpy(owned[0..record.len], record);
        owned[record.len] = '\n';
        self.records[(self.head + self.queued_frames) % self.records.len] = owned;
        self.queued_frames += 1;
        self.queued_bytes += size;
        self.signal();
    }

    fn popRecord(self: *Connection) ?[]u8 {
        if (self.queued_frames == 0) return null;
        const record = self.records[self.head];
        self.head = (self.head + 1) % self.records.len;
        self.queued_frames -= 1;
        self.queued_bytes -= record.len;
        return record;
    }

    fn freeRecords(self: *Connection) void {
        while (self.popRecord()) |record| self.allocator.free(record);
    }

    fn call(context: *anyopaque, allocator: std.mem.Allocator, op: io.Context, method: []const u8, params: []const u8, cleanup_call: bool) io.Error![]const u8 {
        const self: *Connection = @ptrCast(@alignCast(context));
        const deadline = @min(op.deadline_ms orelse std.math.maxInt(u64), clockNow(self) +| self.options.limits.reverse_ms);
        self.mutex.lockUncancelable(self.io);
        var pending: Pending = .{
            .outbound = self.beginReverse(op, method, params, deadline, cleanup_call) catch |err| {
                self.mutex.unlock(self.io);
                return err;
            },
            .cleanup_call = cleanup_call,
            .allocator = allocator,
        };
        self.pending = &pending;
        defer {
            self.pending = null;
            self.mutex.unlock(self.io);
        }
        while (true) {
            if (pending.result) |result| return result;
            if (self.shutdown != null) {
                self.retireReverse(&pending, error.Disconnected, false);
                continue;
            }
            op.check() catch |err| {
                self.retireReverse(&pending, err, true);
                continue;
            };
            if (clockNow(self) >= deadline) {
                self.retireReverse(&pending, error.DeadlineExceeded, true);
                continue;
            }
            const epoch = self.epoch.load(.acquire);
            self.mutex.unlock(self.io);
            const wake = self.waitSignal(epoch, deadline);
            self.mutex.lockUncancelable(self.io);
            wake catch self.retireReverse(&pending, error.Cancelled, true);
        }
    }

    fn beginReverse(self: *Connection, op: io.Context, method: []const u8, params: []const u8, deadline: u64, cleanup_call: bool) io.Error!wire.correlation.Outbound {
        if (self.shutdown != null) return error.Disconnected;
        const work = self.active orelse return error.InvalidInput;
        if (!cleanup_call) {
            if (op.cancellation != &work.cancellation) return error.InvalidInput;
            try work.cancellation.check();
        }
        try op.check();
        if (self.pending != null) return error.Unavailable;
        const outbound = self.ids.beginOutbound(deadline) catch return error.LimitExceeded;
        errdefer self.ids.retire(outbound.ticket) catch unreachable;
        try self.sendRequest(.{ .id = outbound.id, .method = method, .params_json = params });
        return outbound;
    }

    fn retireReverse(self: *Connection, pending: *Pending, err: io.Error, notify_peer: bool) void {
        if (pending.result != null) return;
        self.ids.retire(pending.outbound.ticket) catch unreachable;
        pending.result = err;
        if (notify_peer and self.shutdown == null) {
            const raw = protocol.stringify(self.params_buffer, .{ .requestId = pending.outbound.id.number }) catch unreachable;
            self.sendRequest(.{ .id = null, .method = "$/cancel_request", .params_json = raw }) catch {};
        }
        self.signal();
    }

    fn receiveResponse(self: *Connection, response: rpc.Response) void {
        const resolution = self.ids.resolve(response, clockNow(self)) catch return;
        const pending = self.pending orelse unreachable;
        switch (resolution) {
            .expired => |ticket| {
                std.debug.assert(ticket.eql(pending.outbound.ticket));
                pending.result = error.DeadlineExceeded;
            },
            .response => |ticket| {
                std.debug.assert(ticket.eql(pending.outbound.ticket));
                pending.result = switch (response) {
                    .success => |success| pending.allocator.dupe(u8, success.result_json),
                    .failure => error.Unavailable,
                };
            },
        }
        self.signal();
    }

    fn notify(self: *Connection, session: *Session, update: anytype) io.Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const raw = try protocol.stringify(self.params_buffer, .{ .sessionId = session.client.wire_id, .update = update });
        try self.sendRequest(.{ .id = null, .method = "session/update", .params_json = raw });
    }
};

const Turn = struct {
    connection: *Connection,
    session: *Session,
    run: foo.events.RunId,
    arena: std.mem.Allocator,
    budget: io.Budget,
    committed: std.ArrayList(foo.provider.Message) = .empty,
    order: foo.events.Order = .{},
    failure: ?io.Error = null,

    fn emit(context: *anyopaque, operation: io.Context, event: foo.events.Event) io.Error!void {
        const self: *Turn = @ptrCast(@alignCast(context));
        self.project(operation, event) catch |err| {
            self.failure = self.failure orelse err;
            return err;
        };
    }

    fn retain(self: *Turn, message: foo.provider.Message) io.Error!void {
        errdefer self.session.unusable = true;
        try self.budget.take(projection.messageBytes(message));
        try self.committed.append(self.arena, try foo.provider.copyMessage(self.arena, message));
    }

    fn project(self: *Turn, operation: io.Context, event: foo.events.Event) io.Error!void {
        if (event.run != self.run) return error.InvalidInput;
        self.order.accept(event) catch return error.InvalidInput;
        const connection = self.connection;
        const session = self.session;
        switch (event.data) {
            .delta => |delta| {
                try operation.check();
                switch (delta) {
                    .text => |value| try connection.notify(session, projection.Chunk{
                        .sessionUpdate = .agent_message_chunk,
                        .content = .{ .text = value },
                    }),
                    .reasoning => |value| try connection.notify(session, projection.Chunk{
                        .sessionUpdate = .agent_thought_chunk,
                        .content = .{ .text = value },
                    }),
                    .tool_arguments => {},
                }
            },
            .message_committed => |entry| {
                try self.retain(entry.message);
                for (entry.message.blocks) |block| {
                    if (block != .tool_call) continue;
                    var id_buffer: protocol.ToolIdBuffer = undefined;
                    try connection.notify(session, projection.ToolCall{
                        .toolCallId = try protocol.toolId(&id_buffer, self.run, block.tool_call.id),
                        .title = block.tool_call.name,
                    });
                }
            },
            .tool_committed => |entry| {
                const result = entry.result;
                if (result.effect == .uncertain) session.unusable = true;
                const block: foo.provider.Block = .{ .tool_result = .{
                    .call_id = result.call_id,
                    .content = result.content,
                    .is_error = result.status != .success,
                } };
                const retained = self.retain(.{ .role = .tool, .blocks = &.{block} });
                var id_buffer: protocol.ToolIdBuffer = undefined;
                const id = try protocol.toolId(&id_buffer, self.run, result.call_id);
                try connection.notify(session, projection.toolResult(id, result));
                try retained;
            },
            .finished => {},
        }
    }
};

fn parseFailure(err: io.Error) Failure {
    return if (err == error.OutOfMemory) internal else if (err == error.LimitExceeded) capacity else invalid_params;
}

fn openFailure(err: OpenError) Failure {
    return switch (err) {
        error.AuthenticationRequired => .{ .code = Code.auth_required, .message = "Configured provider credential is required" },
        error.Cancelled => cancelled,
        error.InvalidInput => invalid_params,
        error.Unavailable => .{ .code = rpc.Code.internal_error, .message = "Session runtime is unavailable" },
        error.LimitExceeded => capacity,
        error.DeadlineExceeded, error.Disconnected, error.IoFailure, error.OutOfMemory => internal,
    };
}
