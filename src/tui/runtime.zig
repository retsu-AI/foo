const std = @import("std");
const foo = @import("foo");
const terminal = @import("terminal");

const message_overhead = @sizeOf(foo.provider.Message) + @sizeOf(foo.provider.Block);
const shared_allocator = std.heap.smp_allocator;

pub const Stored = struct {
    arena: std.heap.ArenaAllocator,
    message: foo.provider.Message,
    result: ?foo.tool.Result = null,

    pub fn deinit(self: *Stored) void {
        self.arena.deinit();
    }
};

pub fn messageBytes(message: foo.provider.Message) usize {
    var count = @sizeOf(foo.provider.Message) +| message.blocks.len *| @sizeOf(foo.provider.Block);
    for (message.blocks) |block| count +|= switch (block) {
        .text => |value| value.len,
        .reasoning => |value| value.text.len +| if (value.signature) |signature| signature.len else 0,
        .tool_call => |value| value.id.len +| value.name.len +| value.arguments_json.len,
        .tool_result => |value| value.call_id.len +| value.content.len,
        .replay => |value| value.endpoint.len +| value.model.len +| value.bytes.len,
    };
    return count;
}

pub fn promptBytes(length: usize) usize {
    return length +| message_overhead;
}

pub const Update = union(enum) {
    text: struct { bytes: [1024]u8 = undefined, length: usize },
    committed: Stored,

    fn deinit(self: *Update) void {
        if (self.* == .committed) self.committed.deinit();
    }
};

pub const Run = struct {
    cancellation: foo.io.Cancellation = .{},
    done: std.atomic.Value(bool) = .init(false),
    future: std.Io.Future(void) = undefined,
    input_buffer: []foo.provider.Message,
    prompt: []const u8,
    finished: ?foo.events.Outcome = null,
    outcome: foo.events.Outcome = undefined,
    receive_error: ?foo.io.Error = null,
    budget: foo.io.Budget,
    order: foo.events.Order = .{},
    queue: std.Io.Queue(Update) = undefined,
    buffer: [8]Update = undefined,
    block: foo.provider.Block,

    pub fn start(
        a: std.mem.Allocator,
        operation: foo.io.Context,
        runner: foo.host.Runner,
        input: foo.host.RunInput,
        text: []const u8,
        budget: foo.io.Budget,
    ) foo.io.Error!*Run {
        const self = try a.create(Run);
        errdefer a.destroy(self);
        const prompt = try a.dupe(u8, text);
        errdefer a.free(prompt);
        const messages = try a.alloc(foo.provider.Message, input.messages.len + 1);
        errdefer a.free(messages);
        @memcpy(messages[0..input.messages.len], input.messages);
        self.* = .{ .prompt = prompt, .input_buffer = messages, .block = .{ .text = prompt }, .budget = budget };
        messages[input.messages.len] = .{ .role = .user, .blocks = (&self.block)[0..1] };
        self.queue = .init(&self.buffer);
        var invocation = input;
        invocation.messages = messages;
        var context = operation;
        context.cancellation = &self.cancellation;
        self.future = operation.io.concurrent(work, .{ self, runner, context, invocation }) catch return error.Unavailable;
        return self;
    }

    pub fn end(self: *Run, a: std.mem.Allocator, io: std.Io) void {
        self.queue.close(io);
        if (self.done.load(.acquire)) {
            self.future.await(io);
        } else {
            self.cancellation.request();
            self.future.cancel(io);
        }
        while (true) {
            var update: Update = undefined;
            const count = self.queue.getUncancelable(io, (&update)[0..1], 0) catch break;
            if (count == 0) break;
            update.deinit();
        }
        a.free(self.input_buffer);
        a.free(self.prompt);
        a.destroy(self);
    }

    fn work(self: *Run, runner: foo.host.Runner, operation: foo.io.Context, input: foo.host.RunInput) void {
        var allocator = std.heap.DebugAllocator(.{ .thread_safe = true }){};
        defer self.done.store(true, .release);
        defer _ = allocator.deinit();
        const outcome = runner.run_fn(runner.context, allocator.allocator(), operation, input, .{
            .context = self,
            .emit_fn = emit,
        }) catch |err| failure(err);
        self.outcome = if (self.receive_error) |err| failure(err) else self.finished orelse outcome;
    }

    fn emit(context: *anyopaque, operation: foo.io.Context, event: foo.events.Event) foo.io.Error!void {
        const self: *Run = @ptrCast(@alignCast(context));
        self.record(operation, event) catch |err| {
            if (event.data != .delta and err != error.Cancelled)
                self.receive_error = err;
            return err;
        };
    }

    fn record(self: *Run, operation: foo.io.Context, event: foo.events.Event) foo.io.Error!void {
        self.order.accept(event) catch return error.InvalidInput;
        switch (event.data) {
            .delta => |delta| {
                if (delta != .text) return;
                var bytes = delta.text;
                while (bytes.len != 0) {
                    try operation.check();
                    var update: Update = .{ .text = .{ .length = @min(bytes.len, 1024) } };
                    @memcpy(update.text.bytes[0..update.text.length], bytes[0..update.text.length]);
                    self.queue.putOne(operation.io, update) catch return error.Cancelled;
                    bytes = bytes[update.text.length..];
                }
            },
            .message_committed, .tool_committed => {
                var stored = try retain(&self.budget, event);
                errdefer stored.deinit();
                self.queue.putOneUncancelable(operation.io, .{ .committed = stored }) catch return error.Cancelled;
            },
            .finished => |outcome| self.finished = outcome,
        }
    }
};

fn retain(budget: *foo.io.Budget, event: foo.events.Event) foo.io.Error!Stored {
    var arena = std.heap.ArenaAllocator.init(shared_allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    switch (event.data) {
        .message_committed => |value| {
            try budget.take(messageBytes(value.message));
            const message = try foo.provider.copyMessage(a, value.message);
            return .{ .arena = arena, .message = message };
        },
        .tool_committed => |value| {
            var result = value.result;
            try budget.take(message_overhead +| result.call_id.len +| result.content.len +|
                if (result.artifact) |artifact| @sizeOf(foo.tool.Artifact) +| artifact.relative_path.len else 0);
            result.call_id = try a.dupe(u8, result.call_id);
            result.content = try a.dupe(u8, result.content);
            if (result.artifact) |*artifact| artifact.relative_path = try a.dupe(u8, artifact.relative_path);
            const block = try a.create(foo.provider.Block);
            block.* = .{ .tool_result = .{ .call_id = result.call_id, .content = result.content, .is_error = result.status != .success } };
            return .{ .arena = arena, .message = .{ .role = .tool, .blocks = block[0..1] }, .result = result };
        },
        else => unreachable,
    }
}

pub fn failure(err: foo.io.Error) foo.events.Outcome {
    return .{ .reason = switch (err) {
        error.Cancelled => .cancelled,
        error.DeadlineExceeded => .interrupted,
        error.LimitExceeded => .limit_reached,
        else => .host_error,
    } };
}

pub const Writer = struct {
    queue: std.Io.Queue([]const u8) = undefined,
    buffer: [1][]const u8 = undefined,
    status: std.atomic.Value(enum(u8) { idle, pending, failed }) = .init(.idle),

    pub fn start(self: *Writer, io: std.Io, native: *terminal.Terminal) foo.io.Error!std.Io.Future(void) {
        self.queue = .init(&self.buffer);
        return io.concurrent(work, .{ self, io, native }) catch error.Unavailable;
    }

    pub fn send(self: *Writer, io: std.Io, bytes: []const u8) void {
        self.status.store(.pending, .release);
        self.queue.putOneUncancelable(io, bytes) catch unreachable;
    }

    fn work(self: *Writer, io: std.Io, native: *terminal.Terminal) void {
        while (true) {
            const frame = self.queue.getOne(io) catch return;
            native.write(frame) catch {
                self.status.store(.failed, .release);
                return;
            };
            self.status.store(.idle, .release);
        }
    }
};
