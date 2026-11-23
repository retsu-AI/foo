const std = @import("std");
const foo = @import("foo");
const validation = @import("validation.zig");
const events = foo.events;
const host = foo.host;
const io = foo.io;
const provider = foo.provider;
const session = foo.session;
const tool = foo.tool;

const cleanup_timeout_ms = 1000;

pub const Limit = enum {
    model_turns,
    tool_calls,
    wire_message_bytes,
    transcript_bytes,
    max_output_tokens,
    catalog_bytes,
};

pub const Report = struct {
    outcome: events.Outcome = .{ .reason = .completed },
    usage: provider.Usage = .{},
    model_turns: u32 = 0,
    tool_calls: u32 = 0,
    limit: ?Limit = null,
    output_error: ?io.Error = null,
};

pub const Engine = struct {
    active: std.atomic.Value(bool) = .init(false),

    pub fn runner(self: *Engine) host.Runner {
        return .{ .context = self, .run_fn = runHost };
    }

    pub fn run(self: *Engine, allocator: std.mem.Allocator, operation: io.Context, input: host.RunInput, sink: events.Sink) io.Error!Report {
        if (self.active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.Unavailable;
        defer self.active.store(false, .release);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var run_state: Run = .{
            .operation = operation,
            .input = input,
            .sink = sink,
            .retained = arena.allocator(),
            .scratch = allocator,
        };
        run_state.execute() catch |err| switch (err) {
            error.Stopped => {},
            error.OutOfMemory => if (!run_state.storage_failed) {
                run_state.report.outcome.reason = .host_error;
            },
        };
        run_state.finish();
        return run_state.report;
    }

    fn runHost(context: *anyopaque, allocator: std.mem.Allocator, operation: io.Context, input: host.RunInput, sink: events.Sink) io.Error!events.Outcome {
        const self: *Engine = @ptrCast(@alignCast(context));
        return (try self.run(allocator, operation, input, sink)).outcome;
    }
};

const RunError = error{ Stopped, OutOfMemory };

const Run = struct {
    operation: io.Context,
    input: host.RunInput,
    sink: events.Sink,
    retained: std.mem.Allocator,
    scratch: std.mem.Allocator,
    cleanup_cancellation: io.Cancellation = .{},
    report: Report = .{},
    messages: std.ArrayList(provider.Message) = .empty,
    call_ids: validation.CallIds = .empty,
    declarations: std.StringHashMapUnmanaged(tool.Declaration) = .empty,
    specs: []const provider.ToolSpec = &.{},
    transcript_bytes: usize = 0,
    last_sequence: u64 = 0,
    user_committed: bool = false,
    storage_failed: bool = false,
    usage_seen: bool = false,

    fn execute(self: *Run) RunError!void {
        try self.checkOperation();
        self.input.settings.validate() catch return self.stop(.host_error);
        const input = self.input.messages;
        if (input.len == 0 or input[input.len - 1].role != .user) return self.stop(.host_error);
        try self.load();

        self.transcript_bytes = try self.validateContext(self.retained, input, &self.call_ids);
        try self.pinTools();
        const prompt = self.input.settings.system_prompt;
        if (prompt.len != 0 and !hasSystemMessage(input)) {
            try self.chargeTranscript(validation.block_overhead +| prompt.len);
            const block = try self.retained.create(provider.Block);
            block.* = .{ .text = prompt };
            try self.messages.append(self.retained, .{ .role = .system, .blocks = block[0..1] });
        }
        try self.messages.appendSlice(self.retained, input);

        try self.checkOperation();
        const user = input[input.len - 1];
        const sequence = try self.commit(self.operation, .{ .message = user });
        self.user_committed = true;
        try self.publish(self.operation, .{ .message_committed = .{ .sequence = sequence, .message = user } });

        while (true) {
            try self.checkOperation();
            if (self.report.model_turns == self.input.settings.limits.model_turns) return self.reach(.model_turns);
            self.report.outcome.provider_stop = null;
            const turn_result = try self.turn();
            self.publish(self.operation, .{ .message_committed = .{
                .sequence = turn_result.sequence,
                .message = turn_result.message,
            } }) catch |err| {
                self.skipCalls(turn_result.message.blocks);
                return err;
            };
            switch (turn_result.stop) {
                .tool_use => try self.runTools(turn_result.message.blocks),
                .end_turn => return self.checkOperation(),
                .refusal => {
                    try self.checkOperation();
                    return self.stop(.provider_error);
                },
                .output_limit => unreachable,
            }
        }
    }

    fn load(self: *Run) RunError!void {
        const store = self.input.services.store orelse return;
        var arena = std.heap.ArenaAllocator.init(self.scratch);
        defer arena.deinit();
        const recovery = store.load_fn(store.context, arena.allocator(), self.operation) catch |err|
            return self.stop(ioStop(err, .storage_error));
        self.last_sequence = recovery.last_sequence;
        if (recovery.uncertain_call_ids.len != 0) {
            self.report.outcome.uncertain_effects = true;
            return self.stop(.interrupted);
        }
    }

    fn pinTools(self: *Run) RunError!void {
        const declarations = self.input.tools.declarations;
        const limits = self.input.settings.limits;
        var budget: io.Budget = .{ .limit = limits.catalog_bytes };
        for (declarations) |decl| {
            const spec = decl.spec;
            const identity = decl.identity;
            budget.take(@sizeOf(tool.Declaration) +| spec.name.len +| spec.description.len +| spec.schema_json.len +|
                identity.backend.len +| identity.name.len +| (if (identity.server) |server| server.len else 0)) catch
                return self.reach(.catalog_bytes);
            if (spec.name.len == 0 or identity.backend.len == 0 or identity.name.len == 0) return self.stop(.host_error);
            if (!try validation.jsonObject(self.scratch, spec.schema_json, limits.json_depth)) return self.stop(.host_error);
            const entry = try self.declarations.getOrPut(self.retained, spec.name);
            if (entry.found_existing) return self.stop(.host_error);
            entry.value_ptr.* = decl;
        }
        const specs = try self.retained.alloc(provider.ToolSpec, declarations.len);
        for (declarations, specs) |decl, *spec| spec.* = decl.spec;
        self.specs = specs;
    }

    fn validateContext(self: *Run, allocator: std.mem.Allocator, messages: []const provider.Message, ids: *validation.CallIds) RunError!usize {
        return validation.context(allocator, messages, self.input.settings.model, self.input.settings.limits.transcript_bytes, ids) catch |err|
            return switch (err) {
                error.LimitExceeded => self.reach(.transcript_bytes),
                error.OutOfMemory => error.OutOfMemory,
                error.IncompatibleReplay => self.stop(.provider_error),
                error.InvalidInput => self.stop(.host_error),
            };
    }

    const CommittedTurn = struct { sequence: u64, message: provider.Message, stop: provider.Stop };

    fn turn(self: *Run) RunError!CommittedTurn {
        var arena = std.heap.ArenaAllocator.init(self.scratch);
        defer arena.deinit();
        const temporary = arena.allocator();
        const settings = self.input.settings;
        var request: provider.Request = .{
            .model = settings.model,
            .messages = self.messages.items,
            .tools = self.specs,
            .limits = settings.limits,
        };
        var prepared_ids: validation.CallIds = .empty;
        if (self.input.services.preparation) |prep| {
            const prepared = prep.prepare_fn(prep.context, temporary, self.operation, request) catch |err|
                return self.stop(ioStop(err, .host_error));
            try self.checkOperation();
            _ = try self.validateContext(temporary, prepared.messages, &prepared_ids);
            request.messages = prepared.messages;
        }

        try self.checkOperation();
        var stream: Stream = .{ .run = self, .budget = .{ .limit = settings.limits.wire_message_bytes } };
        var delivery: io.Delivery = .unsent;
        self.report.model_turns += 1;
        const adapter = self.input.services.provider;
        const result = adapter.stream_fn(adapter.context, temporary, self.operation, request, .{
            .context = &stream,
            .emit_fn = Stream.emit,
        }, &delivery);
        if (result) |response| {
            self.addUsage(response.usage);
            self.report.outcome.provider_stop = response.stop;
        } else |_| {
            if (delivery == .possibly_sent) self.addUsage(.{});
        }
        if (stream.failure != null) return error.Stopped;
        try self.checkOperation();
        const response = result catch |err| return switch (err) {
            error.LimitExceeded => self.reach(.wire_message_bytes),
            else => self.stop(ioStop(err, .provider_error)),
        };
        if (response.stop == .output_limit) return self.reach(.max_output_tokens);
        if (response.message.role != .assistant) return self.stop(.provider_error);
        if (validation.payloadBytes(response.message) > settings.limits.wire_message_bytes) return self.reach(.wire_message_bytes);
        try self.chargeTranscript(validation.messageBytes(response.message));

        var new_ids: std.StringHashMapUnmanaged(void) = .empty;
        var result_overhead: usize = 0;
        for (response.message.blocks) |block| {
            validation.checkBlock(.assistant, block, settings.model) catch return self.stop(.provider_error);
            if (block != .tool_call) continue;
            const id = block.tool_call.id;
            if (self.call_ids.contains(id) or prepared_ids.contains(id)) return self.stop(.provider_error);
            const entry = try new_ids.getOrPut(temporary, id);
            if (entry.found_existing) return self.stop(.provider_error);
            result_overhead +|= validation.block_overhead +| id.len;
        }
        const count = new_ids.count();
        if ((response.stop == .tool_use) != (count != 0)) return self.stop(.provider_error);
        if (count > settings.limits.tool_calls - self.report.tool_calls) return self.reach(.tool_calls);
        try self.chargeTranscript(result_overhead);
        try self.call_ids.ensureUnusedCapacity(self.retained, count);
        try self.messages.ensureUnusedCapacity(self.retained, @as(usize, count) + 1);
        const assistant = try provider.copyMessage(self.retained, response.message);

        try self.checkOperation();
        const sequence = try self.commit(self.operation, .{ .message = assistant });
        self.messages.appendAssumeCapacity(assistant);
        for (assistant.blocks) |block| {
            if (block == .tool_call) self.call_ids.putAssumeCapacity(block.tool_call.id, .completed);
        }
        self.report.tool_calls += count;
        return .{ .sequence = sequence, .message = assistant, .stop = response.stop };
    }

    fn runTools(self: *Run, blocks: []const provider.Block) RunError!void {
        for (blocks, 0..) |block, index| {
            if (block != .tool_call) continue;
            self.checkOperation() catch |err| {
                self.skipCalls(blocks[index..]);
                return err;
            };
            var arena = std.heap.ArenaAllocator.init(self.scratch);
            defer arena.deinit();
            self.runTool(arena.allocator(), block.tool_call) catch |err| {
                if (err == error.OutOfMemory) self.report.outcome.reason = .host_error;
                self.skipCalls(blocks[index + 1 ..]);
                return err;
            };
        }
        try self.checkOperation();
    }

    fn runTool(self: *Run, temporary: std.mem.Allocator, call: provider.ToolCall) RunError!void {
        const limits = self.input.settings.limits;
        const declaration = self.declarations.get(call.name) orelse
            return self.finishTool(rejected(call.id, .failure, "Tool is unavailable"), false);
        if (call.arguments_json.len > limits.tool_argument_bytes)
            return self.finishTool(rejected(call.id, .failure, "Tool arguments exceed the byte limit"), false);
        const valid = validation.jsonObject(temporary, call.arguments_json, limits.json_depth) catch {
            try self.finishTool(rejected(call.id, .failure, "Tool arguments could not be validated"), false);
            return error.OutOfMemory;
        };
        if (!valid) return self.finishTool(rejected(call.id, .failure, "Tool arguments must be a JSON object within the depth limit"), false);

        self.operation.check() catch |err| {
            try self.finishTool(rejected(call.id, .cancelled, "Tool was cancelled before dispatch"), false);
            return self.stop(ioStop(err, .host_error));
        };
        const invocation: tool.Invocation = .{ .declaration = declaration, .call = call };
        _ = try self.commit(self.operation, .{ .dispatch_intent = invocation });

        self.operation.check() catch |err| {
            try self.finishTool(rejected(call.id, .cancelled, "Tool was cancelled before dispatch"), true);
            return self.stop(ioStop(err, .host_error));
        };
        const registry = self.input.tools;
        var result = registry.invoke_fn(registry.context, temporary, self.operation, invocation) catch |err| {
            var uncertain = rejected(call.id, if (err == error.Cancelled or err == error.DeadlineExceeded) .cancelled else .failure, "Tool effect could not be confirmed");
            uncertain.effect = .uncertain;
            self.report.outcome.uncertain_effects = true;
            try self.finishTool(uncertain, true);
            return self.stop(ioStop(err, .interrupted));
        };
        if (!std.mem.eql(u8, call.id, result.call_id)) {
            var uncertain = rejected(call.id, .failure, "Tool returned a mismatched call ID");
            uncertain.effect = .uncertain;
            self.report.outcome.uncertain_effects = true;
            try self.finishTool(uncertain, true);
            return self.stop(.interrupted);
        }
        result.call_id = call.id;
        if (result.effect == .uncertain) self.report.outcome.uncertain_effects = true;
        try self.finishTool(result, true);
        if (result.effect == .uncertain) return self.stop(.interrupted);
    }

    fn finishTool(self: *Run, original: tool.Result, intent_committed: bool) RunError!void {
        const cleanup = self.cleanupContext();
        const result = self.excerpt(original);
        const sequence = self.commit(cleanup, .{ .tool_result = result }) catch |err| {
            if (intent_committed) self.report.outcome.uncertain_effects = true;
            return err;
        };
        const output_operation = if (self.operation.check()) |_| self.operation else |_| cleanup;
        try self.publish(output_operation, .{ .tool_committed = .{ .sequence = sequence, .result = result } });

        try self.checkOperation();
        if (result.effect == .uncertain) return;
        const artifact_bytes = if (result.artifact) |artifact| @sizeOf(tool.Artifact) +| artifact.relative_path.len else 0;
        try self.chargeTranscript(result.content.len +| artifact_bytes);
        const block = try self.retained.create(provider.Block);
        block.* = .{ .tool_result = .{
            .call_id = result.call_id,
            .content = try self.retained.dupe(u8, result.content),
            .is_error = result.status != .success,
        } };
        self.messages.appendAssumeCapacity(.{ .role = .tool, .blocks = block[0..1] });
    }

    fn skipCalls(self: *Run, blocks: []const provider.Block) void {
        if (self.storage_failed) return;
        const cleanup = self.cleanupContext();
        const operation_stopped = if (self.operation.check()) |_| false else |_| true;
        const cancelled = self.report.outcome.reason == .cancelled or operation_stopped;
        const status: tool.Status = if (cancelled) .cancelled else .failure;
        for (blocks) |block| {
            if (block != .tool_call) continue;
            const result = self.excerpt(rejected(block.tool_call.id, status, "Tool was skipped before dispatch"));
            const sequence = self.commit(cleanup, .{ .tool_result = result }) catch return;
            if (self.report.output_error == null) {
                self.emit(cleanup, .{ .tool_committed = .{ .sequence = sequence, .result = result } }) catch |err| {
                    self.report.output_error = err;
                };
            }
        }
    }

    fn excerpt(self: *const Run, original: tool.Result) tool.Result {
        var result = original;
        var end = self.input.settings.limits.tool_output_bytes;
        if (result.content.len <= end) return result;
        while (end > 0 and result.content[end] & 0xc0 == 0x80) end -= 1;
        result.content = result.content[0..end];
        result.truncated = true;
        return result;
    }

    fn chargeTranscript(self: *Run, additional: usize) RunError!void {
        if (additional > self.input.settings.limits.transcript_bytes - self.transcript_bytes) return self.reach(.transcript_bytes);
        self.transcript_bytes += additional;
    }

    fn addUsage(self: *Run, usage: provider.Usage) void {
        if (!self.usage_seen) {
            self.report.usage = usage;
            self.usage_seen = true;
            return;
        }
        inline for (@typeInfo(provider.Usage).@"struct".field_names) |field| {
            const accumulated = @field(self.report.usage, field);
            const increment = @field(usage, field);
            @field(self.report.usage, field) = if (accumulated != null and increment != null)
                std.math.add(u64, accumulated.?, increment.?) catch null
            else
                null;
        }
    }

    fn commit(self: *Run, operation: io.Context, record: session.Record) error{Stopped}!u64 {
        const sequence = if (self.input.services.store) |store|
            store.commit_fn(store.context, operation, record) catch |err| {
                self.storage_failed = true;
                return self.stop(if (operation.cancellation == &self.cleanup_cancellation)
                    .storage_error
                else
                    ioStop(err, .storage_error));
            }
        else
            self.last_sequence +| 1;
        if (sequence <= self.last_sequence) {
            self.storage_failed = true;
            return self.stop(.storage_error);
        }
        self.last_sequence = sequence;
        return sequence;
    }

    fn finish(self: *Run) void {
        if (self.user_committed and !self.storage_failed) {
            _ = self.commit(self.cleanupContext(), .{ .finished = self.report.outcome }) catch {};
        }
        self.emit(self.cleanupContext(), .{ .finished = self.report.outcome }) catch |err| {
            if (self.report.output_error == null) self.report.output_error = err;
        };
    }

    fn emit(self: *Run, operation: io.Context, data: @FieldType(events.Event, "data")) io.Error!void {
        try self.sink.emit_fn(self.sink.context, operation, .{ .run = self.input.run, .data = data });
    }

    fn publish(self: *Run, operation: io.Context, data: @FieldType(events.Event, "data")) error{Stopped}!void {
        self.emit(operation, data) catch |err| {
            self.report.output_error = err;
            return self.stop(ioStop(err, .host_error));
        };
    }

    fn checkOperation(self: *Run) error{Stopped}!void {
        self.operation.check() catch |err| return self.stop(ioStop(err, .host_error));
    }

    fn cleanupContext(self: *Run) io.Context {
        var operation = self.operation;
        operation.cancellation = &self.cleanup_cancellation;
        operation.deadline_ms = operation.clock.now() +| cleanup_timeout_ms;
        return operation;
    }

    fn stop(self: *Run, reason: events.Stop) error{Stopped} {
        self.report.outcome.reason = reason;
        return error.Stopped;
    }

    fn reach(self: *Run, limit: Limit) error{Stopped} {
        self.report.limit = limit;
        return self.stop(.limit_reached);
    }
};

const Stream = struct {
    run: *Run,
    budget: io.Budget,
    failure: ?io.Error = null,

    fn emit(context: *anyopaque, _: io.Context, delta: provider.Delta) io.Error!void {
        const self: *Stream = @ptrCast(@alignCast(context));
        if (self.failure) |err| return err;
        const run = self.run;
        run.operation.check() catch |err| {
            self.failure = err;
            run.report.outcome.reason = ioStop(err, .host_error);
            return err;
        };
        const bytes = switch (delta) {
            .text, .reasoning => |data| data.len,
            .tool_arguments => |args| args.call_id.len +| args.bytes.len,
        };
        self.budget.take(@max(1, bytes)) catch |err| {
            self.failure = err;
            run.report.limit = .wire_message_bytes;
            run.report.outcome.reason = .limit_reached;
            return err;
        };
        run.emit(run.operation, .{ .delta = delta }) catch |err| {
            self.failure = err;
            run.report.output_error = err;
            run.report.outcome.reason = ioStop(err, .host_error);
            return err;
        };
    }
};

fn ioStop(err: anyerror, fallback: events.Stop) events.Stop {
    return switch (err) {
        error.Cancelled => .cancelled,
        error.DeadlineExceeded => .interrupted,
        else => fallback,
    };
}

fn hasSystemMessage(messages: []const provider.Message) bool {
    for (messages) |message| if (message.role == .system) return true;
    return false;
}

fn rejected(id: []const u8, status: tool.Status, content: []const u8) tool.Result {
    return .{ .call_id = id, .status = status, .content = content, .effect = .not_started };
}
