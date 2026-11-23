const std = @import("std");
const foo = @import("foo");
const core = @import("core");
const support = @import("support");

pub const model: foo.config.Model = .{
    .family = .openai_responses,
    .endpoint = "https://example.invalid",
    .id = "test-model",
};
pub const declaration: foo.tool.Declaration = .{
    .identity = .{ .backend = "fixture", .name = "echo" },
    .spec = .{ .name = "echo", .description = "Echo", .schema_json = "{\"type\":\"object\"}" },
    .generation = 1,
};
pub const prompt: foo.provider.Message = .{ .role = .user, .blocks = &.{.{ .text = "hello" }} };
pub const answer: foo.provider.Response = .{
    .message = .{ .role = .assistant, .blocks = &.{.{ .text = "done" }} },
    .stop = .end_turn,
    .usage = .{ .input_tokens = 3, .output_tokens = 2 },
};

pub fn call(id: []const u8, name: []const u8, arguments: []const u8) foo.provider.Block {
    return .{ .tool_call = .{ .id = id, .name = name, .arguments_json = arguments } };
}

pub fn batch(blocks: []const foo.provider.Block) foo.provider.Response {
    return .{
        .message = .{ .role = .assistant, .blocks = blocks },
        .stop = .tool_use,
        .usage = .{ .input_tokens = 5, .output_tokens = 4, .cache_read_tokens = 0 },
    };
}

pub const Step = struct {
    response: foo.provider.Response = answer,
    deltas: []const foo.provider.Delta = &.{},
    failure: ?foo.provider.Error = null,
};

pub const ToolStep = struct {
    status: foo.tool.Status = .success,
    effect: foo.tool.Effect = .observed,
    content: []const u8 = "echoed",
    failure: ?foo.io.Error = null,
    returned_id: ?[]const u8 = null,
};

const wake_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } };

pub const Point = enum {
    load,
    user_record,
    user_event,
    prepare,
    request,
    delta,
    assistant_record,
    assistant_event,
    intent,
    invoke,
    effect,
    result_record,
    result_event,
    terminal_record,
    terminal_event,
};

pub const Fixture = struct {
    captured: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.testing.allocator),
    engine: core.Engine = .{},
    cancel: foo.io.Cancellation = .{},
    clock: support.Clock = .{},
    steps: []const Step,
    tools: []const ToolStep = &.{},
    messages: []const foo.provider.Message = &.{prompt},
    limits: foo.config.Limits = .{},
    use_store: bool = true,
    prepared: ?[]const foo.provider.Message = null,
    recovery: foo.session.Recovery = .{
        .messages = &.{},
        .last_sequence = 0,
        .interrupted = false,
        .uncertain_call_ids = &.{},
    },
    deadline: ?u64 = null,
    cancel_at: ?Point = null,
    expire_at: ?Point = null,
    fail_commit: ?Point = null,
    fail_event: ?Point = null,
    reenter_at: ?Point = null,
    blocked_at: ?Point = null,
    blocked: std.Io.Event = .unset,
    woken: std.Io.Event = .unset,
    busy_error: ?foo.io.Error = null,
    sequence: ?u64 = null,
    pending_id: ?[]const u8 = null,
    uncertain_id: ?[]const u8 = null,
    trace: std.ArrayList(Point) = .empty,
    requests: std.ArrayList(foo.provider.Request) = .empty,
    invocations: std.ArrayList([]const u8) = .empty,
    results: std.ArrayList(foo.tool.Result) = .empty,
    published_results: std.ArrayList(foo.tool.Result) = .empty,
    messages_published: std.ArrayList(foo.provider.Message) = .empty,
    sequences: std.ArrayList(u64) = .empty,
    delta_text: std.ArrayList(u8) = .empty,
    terminal_outcomes: std.ArrayList(foo.events.Outcome) = .empty,
    journal_outcomes: std.ArrayList(foo.events.Outcome) = .empty,
    effects: usize = 0,

    pub fn deinit(self: *Fixture) void {
        self.captured.deinit();
    }

    pub fn execute(self: *Fixture) !core.Report {
        return self.executeWith(std.testing.allocator);
    }

    pub fn executeWith(self: *Fixture, allocator: std.mem.Allocator) !core.Report {
        return self.engine.run(allocator, self.operation(), self.input(), self.sink());
    }

    pub fn executeRunner(self: *Fixture) !foo.events.Outcome {
        const runner = self.engine.runner();
        return runner.run_fn(runner.context, std.testing.allocator, self.operation(), self.input(), self.sink());
    }

    fn operation(self: *Fixture) foo.io.Context {
        return .{
            .io = std.testing.io,
            .cancellation = &self.cancel,
            .clock = self.clock.interface(),
            .deadline_ms = self.deadline,
        };
    }

    fn input(self: *Fixture) foo.host.RunInput {
        return .{
            .session = @fromBackingInt(@intCast(1)),
            .run = @fromBackingInt(@intCast(2)),
            .settings = .{ .model = model, .cwd = ".", .limits = self.limits },
            .messages = self.messages,
            .tools = .{ .context = self, .declarations = &.{declaration}, .invoke_fn = invoke },
            .services = .{
                .provider = .{ .context = self, .stream_fn = stream },
                .store = if (self.use_store) .{ .context = self, .commit_fn = commit, .load_fn = load } else null,
                .preparation = if (self.prepared != null) .{ .context = self, .prepare_fn = prepare } else null,
            },
        };
    }

    fn sink(self: *Fixture) foo.events.Sink {
        return .{ .context = self, .emit_fn = emit };
    }

    pub fn enableWake(self: *Fixture) void {
        self.cancel.wake_context = self;
        self.cancel.wake_fn = wake;
    }

    fn wake(context: ?*anyopaque) void {
        const self: *Fixture = @ptrCast(@alignCast(context.?));
        self.woken.set(std.testing.io);
    }

    pub fn cancelWhenBlocked(self: *Fixture) void {
        self.blocked.waitTimeout(std.testing.io, wake_timeout) catch return;
        self.cancel.request();
    }

    fn hit(self: *Fixture, point: Point) foo.io.Error!void {
        const allocator = self.captured.allocator();
        try self.trace.append(allocator, point);
        if (self.cancel_at == point) self.cancel.request();
        if (self.expire_at == point) self.clock.time_ms = self.deadline.?;
        if (self.reenter_at == point) {
            self.reenter_at = null;
            const runner = self.engine.runner();
            _ = runner.run_fn(runner.context, std.testing.allocator, self.operation(), self.input(), self.sink()) catch |err| {
                self.busy_error = err;
            };
        }
        if (self.blocked_at == point) {
            self.blocked.set(std.testing.io);
            self.woken.waitTimeout(std.testing.io, wake_timeout) catch return error.DeadlineExceeded;
        }
    }

    fn copyResult(self: *Fixture, original: foo.tool.Result) foo.io.Error!foo.tool.Result {
        const allocator = self.captured.allocator();
        var result = original;
        result.call_id = try allocator.dupe(u8, original.call_id);
        result.content = try allocator.dupe(u8, original.content);
        return result;
    }

    fn prepare(context: *anyopaque, _: std.mem.Allocator, op: foo.io.Context, request: foo.provider.Request) foo.io.Error!foo.provider.Request {
        const self: *Fixture = @ptrCast(@alignCast(context));
        try op.check();
        try self.hit(.prepare);
        var replacement = request;
        replacement.messages = self.prepared.?;
        replacement.model.id = "cannot-change-model";
        replacement.limits.model_turns = 1;
        replacement.tools = &.{};
        return replacement;
    }

    fn stream(context: *anyopaque, allocator: std.mem.Allocator, op: foo.io.Context, request: foo.provider.Request, output: foo.provider.Sink, delivery: *foo.io.Delivery) foo.provider.Error!foo.provider.Response {
        const self: *Fixture = @ptrCast(@alignCast(context));
        try op.check();
        delivery.* = .possibly_sent;

        const step_index = self.requests.items.len;
        const capture = self.captured.allocator();
        var captured = request;
        const messages = try capture.alloc(foo.provider.Message, request.messages.len);
        for (request.messages, messages) |source, *dest| dest.* = try foo.provider.copyMessage(capture, source);
        captured.messages = messages;
        captured.tools = try capture.dupe(foo.provider.ToolSpec, request.tools);
        try self.requests.append(capture, captured);
        try self.hit(.request);
        try op.check();

        if (step_index >= self.steps.len) return error.Protocol;
        const step = self.steps[step_index];
        for (step.deltas) |delta| try output.emit(op, delta);
        if (step.failure) |err| return err;

        var response = step.response;
        response.message = try foo.provider.copyMessage(allocator, response.message);
        return response;
    }

    fn invoke(context: *anyopaque, allocator: std.mem.Allocator, op: foo.io.Context, invocation: foo.tool.Invocation) foo.io.Error!foo.tool.Result {
        const self: *Fixture = @ptrCast(@alignCast(context));
        try op.check();
        if (invocation.declaration.generation != declaration.generation or
            !std.mem.eql(u8, invocation.call.name, declaration.spec.name)) return error.InvalidInput;
        if (self.use_store and !std.mem.eql(u8, self.pending_id orelse return error.InvalidInput, invocation.call.id))
            return error.InvalidInput;
        const step_index = self.invocations.items.len;
        const capture = self.captured.allocator();
        try self.invocations.append(capture, try capture.dupe(u8, invocation.call.id));
        try self.hit(.invoke);
        try op.check();
        const step: ToolStep = if (step_index < self.tools.len) self.tools[step_index] else .{};
        if (step.effect != .not_started) {
            self.effects += 1;
            try self.hit(.effect);
        }
        if (step.failure) |err| return err;
        return .{
            .call_id = try allocator.dupe(u8, step.returned_id orelse invocation.call.id),
            .status = step.status,
            .effect = step.effect,
            .content = try allocator.dupe(u8, step.content),
        };
    }

    fn load(context: *anyopaque, allocator: std.mem.Allocator, op: foo.io.Context) foo.session.Error!foo.session.Recovery {
        const self: *Fixture = @ptrCast(@alignCast(context));
        try op.check();
        try self.hit(.load);
        var recovery = self.recovery;
        if (self.pending_id orelse self.uncertain_id) |id| {
            const ids = try allocator.alloc([]const u8, 1);
            ids[0] = try allocator.dupe(u8, id);
            recovery.uncertain_call_ids = ids;
            recovery.interrupted = true;
        }
        recovery.last_sequence = self.sequence orelse recovery.last_sequence;
        return recovery;
    }

    fn commit(context: *anyopaque, op: foo.io.Context, record: foo.session.Record) foo.session.Error!u64 {
        const self: *Fixture = @ptrCast(@alignCast(context));
        try op.check();
        const point: Point = switch (record) {
            .header => return error.InvalidInput,
            .message => |message| if (message.role == .user) .user_record else .assistant_record,
            .dispatch_intent => .intent,
            .tool_result => .result_record,
            .nested_tool => return error.InvalidInput,
            .finished => .terminal_record,
        };
        try self.hit(point);
        if (self.fail_commit == point) return error.CommitFailed;
        const allocator = self.captured.allocator();
        switch (record) {
            .dispatch_intent => |invocation| {
                if (self.pending_id != null) return error.CorruptHistory;
                self.pending_id = try allocator.dupe(u8, invocation.call.id);
            },
            .tool_result => |result| {
                if (self.pending_id) |id| {
                    if (!std.mem.eql(u8, id, result.call_id)) return error.CorruptHistory;
                } else if (result.effect != .not_started) return error.CorruptHistory;
                if (result.effect == .uncertain) self.uncertain_id = try allocator.dupe(u8, result.call_id);
                self.pending_id = null;
                try self.results.append(allocator, try self.copyResult(result));
            },
            .finished => |outcome| try self.journal_outcomes.append(allocator, outcome),
            else => {},
        }
        self.sequence = (self.sequence orelse self.recovery.last_sequence) + 1;
        return self.sequence.?;
    }

    fn emit(context: *anyopaque, op: foo.io.Context, event: foo.events.Event) foo.io.Error!void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        try op.check();
        if (event.run != @as(foo.events.RunId, @fromBackingInt(@intCast(2)))) return error.InvalidInput;
        const point: Point = switch (event.data) {
            .delta => .delta,
            .message_committed => |message| if (message.message.role == .user) .user_event else .assistant_event,
            .tool_committed => .result_event,
            .finished => .terminal_event,
        };
        try self.hit(point);
        if (self.fail_event == point) return error.Disconnected;
        const allocator = self.captured.allocator();
        switch (event.data) {
            .delta => |delta| if (delta == .text) try self.delta_text.appendSlice(allocator, delta.text),
            .message_committed => |message| {
                try self.sequences.append(allocator, message.sequence);
                try self.messages_published.append(allocator, try foo.provider.copyMessage(allocator, message.message));
            },
            .tool_committed => |result| {
                try self.sequences.append(allocator, result.sequence);
                try self.published_results.append(allocator, try self.copyResult(result.result));
            },
            .finished => |outcome| try self.terminal_outcomes.append(allocator, outcome),
        }
    }

    pub fn expectTerminal(self: *const Fixture, reason: foo.events.Stop, report: core.Report) !void {
        try std.testing.expectEqual(reason, report.outcome.reason);
        try std.testing.expectEqual(1, self.terminal_outcomes.items.len);
        try std.testing.expectEqual(report.outcome, self.terminal_outcomes.items[0]);
        if (self.use_store and self.fail_commit == null and self.journal_outcomes.items.len != 0) {
            try std.testing.expectEqual(1, self.journal_outcomes.items.len);
            try std.testing.expectEqual(report.outcome, self.journal_outcomes.items[0]);
        }
    }
};
