const std = @import("std");
const foo = @import("foo");

pub const Clock = struct {
    time_ms: u64 = 0,

    pub fn interface(self: *Clock) foo.io.Clock {
        return .{ .context = self, .now_fn = now };
    }

    fn now(context: *anyopaque) u64 {
        const self: *Clock = @ptrCast(@alignCast(context));
        return self.time_ms;
    }
};

pub const Bytes = struct {
    buffer: []u8,
    used: usize = 0,
    reject: bool = false,

    pub fn interface(self: *Bytes) foo.io.ByteSink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, operation: foo.io.Context, bytes: []const u8) foo.io.Error!void {
        const self: *Bytes = @ptrCast(@alignCast(context));
        try operation.check();
        if (self.reject) return error.Unavailable;
        if (bytes.len > self.buffer.len - self.used) return error.LimitExceeded;
        @memcpy(self.buffer[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
    }
};

pub const Provider = struct {
    deltas: []const foo.provider.Delta = &.{},
    response: foo.provider.Response,
    failure: ?foo.provider.Error = null,
    calls: usize = 0,

    pub fn interface(self: *Provider) foo.provider.Provider {
        return .{ .context = self, .stream_fn = stream };
    }

    fn stream(context: *anyopaque, allocator: std.mem.Allocator, operation: foo.io.Context, request: foo.provider.Request, sink: foo.provider.Sink, delivery: *foo.io.Delivery) foo.provider.Error!foo.provider.Response {
        const self: *Provider = @ptrCast(@alignCast(context));
        try operation.check();
        self.calls += 1;
        delivery.* = .possibly_sent;
        for (self.deltas) |delta| try sink.emit(operation, delta);
        if (self.failure) |failure| return failure;
        for (self.response.message.blocks) |block| {
            if (block == .replay and !block.replay.compatible(request.model)) return error.IncompatibleReplay;
        }
        return .{
            .message = try foo.provider.copyMessage(allocator, self.response.message),
            .stop = self.response.stop,
            .usage = self.response.usage,
        };
    }
};

pub const Tools = struct {
    declarations: []const foo.tool.Declaration,
    calls: usize = 0,
    effects: usize = 0,
    failure: bool = false,
    revoked: bool = false,

    pub fn interface(self: *Tools) foo.tool.Registry {
        return .{ .context = self, .declarations = self.declarations, .invoke_fn = invoke };
    }

    fn invoke(context: *anyopaque, allocator: std.mem.Allocator, operation: foo.io.Context, invocation: foo.tool.Invocation) foo.io.Error!foo.tool.Result {
        const self: *Tools = @ptrCast(@alignCast(context));
        try operation.check();
        self.calls += 1;
        const call_id = try allocator.dupe(u8, invocation.call.id);
        var present = false;
        for (self.declarations) |decl| {
            if (std.mem.eql(u8, decl.spec.name, invocation.call.name) and
                decl.generation == invocation.declaration.generation) present = true;
        }
        if (!present or self.revoked) return .{
            .call_id = call_id,
            .status = .catalog_changed,
            .effect = .not_started,
            .content = "catalog_changed",
        };
        self.effects += 1;
        return .{
            .call_id = call_id,
            .status = if (self.failure) .failure else .success,
            .effect = .observed,
            .content = if (self.failure) "scripted failure" else "scripted result",
        };
    }
};

pub const Journal = struct {
    sequence: u64 = 0,
    fail_commit: bool = false,
    pending: ?[]const u8 = null,
    committed: usize = 0,

    pub fn interface(self: *Journal) foo.session.Store {
        return .{ .context = self, .commit_fn = commit, .load_fn = load };
    }

    fn commit(context: *anyopaque, operation: foo.io.Context, record: foo.session.Record) foo.session.Error!u64 {
        const self: *Journal = @ptrCast(@alignCast(context));
        try operation.check();
        if (self.fail_commit) return error.CommitFailed;
        switch (record) {
            .dispatch_intent => |v| {
                if (self.pending != null) return error.CorruptHistory;
                self.pending = v.call.id;
            },
            .tool_result => |v| {
                if (self.pending == null or !std.mem.eql(u8, self.pending.?, v.call_id)) return error.CorruptHistory;
                self.pending = null;
            },
            else => {},
        }
        self.sequence += 1;
        self.committed += 1;
        return self.sequence;
    }

    fn load(context: *anyopaque, allocator: std.mem.Allocator, operation: foo.io.Context) foo.session.Error!foo.session.Recovery {
        const self: *Journal = @ptrCast(@alignCast(context));
        try operation.check();
        const ids = try allocator.alloc([]const u8, if (self.pending == null) 0 else 1);
        if (self.pending) |id| ids[0] = try allocator.dupe(u8, id);
        return .{ .messages = &.{}, .uncertain_call_ids = ids, .last_sequence = self.sequence, .interrupted = self.pending != null };
    }
};

pub const Http = struct {
    status: u16 = 200,
    chunks: []const []const u8,
    calls: usize = 0,
    failure: ?foo.io.Error = null,
    upload: Bytes = .{ .buffer = &.{} },

    pub fn interface(self: *Http) foo.io.HttpTransport {
        return .{ .context = self, .exchange_fn = exchange };
    }

    fn exchange(context: *anyopaque, operation: foo.io.Context, request: foo.io.HttpRequest, sink: foo.io.HttpSink, delivery: *foo.io.Delivery) foo.io.Error!void {
        const self: *Http = @ptrCast(@alignCast(context));
        try operation.check();
        self.calls += 1;
        delivery.* = .possibly_sent;
        switch (request.body) {
            .bytes => |bytes| try self.upload.interface().write(operation, bytes),
            .stream => |stream| {
                var buffer: [4096]u8 = undefined;
                var remaining = stream.content_length;
                while (remaining == null or remaining.? != 0) {
                    try operation.check();
                    const capacity: usize = @intCast(@min(buffer.len, remaining orelse buffer.len));
                    const count = try stream.source.read_fn(stream.source.context, operation, buffer[0..capacity]);
                    if (count > capacity) return error.InvalidInput;
                    try operation.check();
                    if (count == 0) {
                        if (remaining != null) return error.IoFailure;
                        break;
                    }
                    try self.upload.interface().write(operation, buffer[0..count]);
                    if (remaining) |*length| length.* -= count;
                }
            },
        }
        try operation.check();
        try sink.head_fn(sink.context, operation, .{ .status = self.status, .headers = &.{} });
        var budget: foo.io.Budget = .{ .limit = request.max_response_bytes };
        for (self.chunks) |chunk| {
            try budget.take(chunk.len);
            try sink.body.write(operation, chunk);
        }
        try operation.check();
        if (self.failure) |failure| return failure;
    }
};

pub const Editor = struct {
    decision: foo.host.Decision = .deny_once,
    calls: usize = 0,
    operation_id: ?u64 = null,

    pub fn interface(self: *Editor) foo.host.PermissionHandler {
        return .{ .context = self, .decide_fn = decide };
    }

    fn decide(context: *anyopaque, operation: foo.io.Context, prepared: foo.host.PreparedOperation) foo.io.Error!foo.host.Decision {
        const self: *Editor = @ptrCast(@alignCast(context));
        try operation.check();
        self.calls += 1;
        self.operation_id = prepared.operation_id;
        return self.decision;
    }
};

pub const Process = struct {
    input: Bytes,
    stdout_bytes: []const u8,
    stderr_bytes: []const u8,
    stdout_offset: usize = 0,
    stderr_offset: usize = 0,
    input_closed: bool = false,
    terminated: bool = false,
    released: bool = false,

    pub fn interface(self: *Process) foo.io.Child {
        return .{
            .context = self,
            .stdin = .{ .context = self, .write_fn = write },
            .stdout = .{ .context = self, .read_fn = readOut },
            .stderr = .{ .context = self, .read_fn = readErr },
            .close_stdin_fn = closeInput,
            .terminate_fn = terminate,
            .wait_fn = wait,
            .release_fn = release,
        };
    }

    fn write(context: *anyopaque, operation: foo.io.Context, bytes: []const u8) foo.io.Error!void {
        const self: *Process = @ptrCast(@alignCast(context));
        if (self.input_closed or self.released) return error.Unavailable;
        try self.input.interface().write(operation, bytes);
    }

    fn readOut(context: *anyopaque, operation: foo.io.Context, buffer: []u8) foo.io.Error!usize {
        const self: *Process = @ptrCast(@alignCast(context));
        return self.read(operation, buffer, self.stdout_bytes, &self.stdout_offset);
    }

    fn readErr(context: *anyopaque, operation: foo.io.Context, buffer: []u8) foo.io.Error!usize {
        const self: *Process = @ptrCast(@alignCast(context));
        return self.read(operation, buffer, self.stderr_bytes, &self.stderr_offset);
    }

    fn read(self: *Process, operation: foo.io.Context, buffer: []u8, bytes: []const u8, offset: *usize) foo.io.Error!usize {
        try operation.check();
        if (self.released) return error.Unavailable;
        if (buffer.len == 0) return error.InvalidInput;
        const count = @min(buffer.len, bytes.len - offset.*);
        @memcpy(buffer[0..count], bytes[offset.*..][0..count]);
        offset.* += count;
        return count;
    }

    fn closeInput(context: *anyopaque, operation: foo.io.Context) foo.io.Error!void {
        const self: *Process = @ptrCast(@alignCast(context));
        try operation.check();
        self.input_closed = true;
    }

    fn terminate(context: *anyopaque, operation: foo.io.Context) foo.io.Error!void {
        const self: *Process = @ptrCast(@alignCast(context));
        try operation.check();
        self.terminated = true;
    }

    fn wait(context: *anyopaque, operation: foo.io.Context) foo.io.Error!foo.io.ProcessExit {
        const self: *Process = @ptrCast(@alignCast(context));
        try operation.check();
        if (!self.terminated and !self.input_closed) return error.Unavailable;
        return .{ .exited = if (self.terminated) 1 else 0 };
    }

    fn release(context: *anyopaque, operation: foo.io.Context) foo.io.Error!void {
        const self: *Process = @ptrCast(@alignCast(context));
        try operation.check();
        self.input_closed = true;
        self.terminated = true;
        self.released = true;
    }
};
