const std = @import("std");
const foo = @import("foo");

pub const name = "codemode";
pub const spec: foo.provider.ToolSpec = .{
    .name = name,
    .description = "Run a short JavaScript script over the enabled tools. Call tools[name](args), use await or return, and use text(value) for output. ALL_TOOLS lists tool names and their input schemas. Child tool calls run in order.",
    .schema_json =
    \\{"type":"object","properties":{"code":{"type":"string"}},"required":["code"],"additionalProperties":false}
    ,
};

pub const Limits = struct {
    source_bytes: usize = 64 * 1024,
    memory_bytes: usize = 16 * 1024 * 1024,
    stack_bytes: usize = 512 * 1024,
    max_jobs: usize = 1024,
    timeout_ms: u64 = 30_000,
    cleanup_ms: u64 = 2_000,
    calls_per_script: u32 = 32,
};

pub const Options = struct {
    generation: u64,
    limits: Limits = .{},
    run_limits: foo.config.Limits = .{},
    store: ?foo.session.Store = null,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    base: foo.tool.Registry,
    declarations: []foo.tool.Declaration,
    catalog_json: []u8,
    names: std.StringHashMapUnmanaged(usize),
    options: Options,
    admitted: std.atomic.Value(u32) = .init(0),
    evaluating: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, base: foo.tool.Registry, options: Options) foo.io.Error!Registry {
        if (options.generation == 0 or options.run_limits.tool_calls == 0 or
            options.run_limits.tool_output_bytes == 0 or options.run_limits.tool_argument_bytes == 0)
            return error.InvalidInput;
        inline for (@typeInfo(Limits).@"struct".field_names) |field| {
            if (@field(options.limits, field) == 0) return error.InvalidInput;
        }
        var budget: foo.io.Budget = .{ .limit = options.run_limits.catalog_bytes };
        try budget.take((base.declarations.len +| 1) *| @sizeOf(foo.tool.Declaration));
        const declarations = try allocator.alloc(foo.tool.Declaration, base.declarations.len + 1);
        errdefer allocator.free(declarations);
        @memcpy(declarations[0..base.declarations.len], base.declarations);
        declarations[base.declarations.len] = .{
            .spec = spec,
            .identity = .{ .backend = name, .name = name },
            .generation = options.generation,
        };

        var names: std.StringHashMapUnmanaged(usize) = .empty;
        errdefer names.deinit(allocator);
        const tool_specs = try allocator.alloc(foo.provider.ToolSpec, base.declarations.len);
        defer allocator.free(tool_specs);
        for (base.declarations, tool_specs, 0..) |declaration, *tool_spec, index| {
            const tool_name = declaration.spec.name;
            if (tool_name.len == 0 or std.mem.eql(u8, tool_name, name) or declaration.generation == 0)
                return error.InvalidInput;
            const slot = try names.getOrPut(allocator, tool_name);
            if (slot.found_existing) return error.InvalidInput;
            slot.value_ptr.* = index;
            try budget.take(tool_name.len +| declaration.spec.description.len +| declaration.spec.schema_json.len);
            tool_spec.* = declaration.spec;
        }
        var json: std.Io.Writer.Allocating = .init(allocator);
        defer json.deinit();
        std.json.Stringify.value(tool_specs, .{}, &json.writer) catch return error.OutOfMemory;
        if (json.written().len > options.run_limits.catalog_bytes) return error.LimitExceeded;
        return .{
            .allocator = allocator,
            .base = base,
            .declarations = declarations,
            .catalog_json = try json.toOwnedSlice(),
            .names = names,
            .options = options,
        };
    }

    pub fn deinit(self: *Registry) void {
        self.names.deinit(self.allocator);
        self.allocator.free(self.declarations);
        self.allocator.free(self.catalog_json);
        self.* = undefined;
    }

    pub fn interface(self: *Registry) foo.tool.Registry {
        return .{ .context = self, .declarations = self.declarations, .invoke_fn = invoke };
    }

    fn admit(self: *Registry) bool {
        var count = self.admitted.load(.acquire);
        while (count < self.options.run_limits.tool_calls) {
            count = self.admitted.cmpxchgWeak(count, count + 1, .acq_rel, .acquire) orelse return true;
        }
        return false;
    }

    fn invoke(context: *anyopaque, allocator: std.mem.Allocator, operation: foo.io.Context, invocation: foo.tool.Invocation) foo.io.Error!foo.tool.Result {
        const self: *Registry = @ptrCast(@alignCast(context));
        const call = invocation.call;
        if (!self.admit())
            return self.result(allocator, call.id, .failure, .not_started, "Run tool call limit reached", false);
        if (!std.mem.eql(u8, call.name, name))
            return self.base.invoke_fn(self.base.context, allocator, operation, invocation);
        const expected = self.declarations[self.declarations.len - 1];
        const supplied = invocation.declaration;
        if (expected.generation != supplied.generation or supplied.identity.server != null or
            !std.mem.eql(u8, supplied.identity.backend, name) or !std.mem.eql(u8, supplied.identity.name, name) or
            !std.mem.eql(u8, supplied.spec.name, name) or
            !std.mem.eql(u8, supplied.spec.description, spec.description) or
            !std.mem.eql(u8, supplied.spec.schema_json, spec.schema_json))
            return self.result(allocator, call.id, .catalog_changed, .not_started, "Code Mode declaration changed", false);
        operation.check() catch
            return self.result(allocator, call.id, .cancelled, .not_started, "Code Mode cancelled before evaluation", false);

        const limits = self.options.limits;
        const run_limits = self.options.run_limits;
        const parse_limits: foo.wire.json.Limits = .{ .max_bytes = run_limits.tool_argument_bytes, .max_depth = run_limits.json_depth };
        foo.wire.json.validate(call.arguments_json, parse_limits) catch
            return self.result(allocator, call.id, .failure, .not_started, "Invalid Code Mode arguments", false);
        const parsed = std.json.parseFromSlice(struct { code: []const u8 }, allocator, call.arguments_json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.result(allocator, call.id, .failure, .not_started, "Code Mode expects a code string", false),
        };
        defer parsed.deinit();
        if (call.id.len == 0 or parsed.value.code.len > limits.source_bytes)
            return self.result(allocator, call.id, .failure, .not_started, "Code Mode source or call ID is invalid", false);
        if (self.evaluating.swap(true, .acq_rel))
            return self.result(allocator, call.id, .failure, .not_started, "Another Code Mode script is active", false);
        defer self.evaluating.store(false, .release);

        var eval: Evaluation = .{
            .owner = self,
            .allocator = allocator,
            .parent_id = call.id,
            .operation = operation,
        };
        defer eval.output.deinit(allocator);
        defer if (eval.reply) |reply| allocator.free(reply);
        eval.operation.deadline_ms = @min(operation.deadline_ms orelse std.math.maxInt(u64), operation.clock.now() +| limits.timeout_ms);
        const options: VmOptions = .{
            .userdata = &eval,
            .interrupt = Evaluation.interrupt,
            .invoke = Evaluation.invoke,
            .text = Evaluation.emit,
            .memory_bytes = limits.memory_bytes,
            .stack_bytes = limits.stack_bytes,
            .max_jobs = limits.max_jobs,
        };
        var diagnostic: [256:0]u8 = @splat(0);
        const vm_status = foo_vm_run(&options, Bytes.from(parsed.value.code), Bytes.from(self.catalog_json), &diagnostic, diagnostic.len);
        const stop = eval.stop orelse switch (vm_status) {
            0 => null,
            1 => Stop{ .message = "JavaScript evaluation failed" },
            2 => Stop{ .status = .cancelled, .message = "Code Mode interrupted" },
            3 => Stop{ .message = "Code Mode job limit reached" },
            4 => Stop{ .message = "Code Mode script did not settle" },
            5 => Stop{ .message = "Code Mode host callback failed" },
            else => Stop{ .message = "Code Mode VM resource limit reached" },
        };
        if (stop) |reason| {
            eval.addOutput(reason.message) catch {};
            if (vm_status == 1 and diagnostic[0] != 0) eval.addOutput(std.mem.sliceTo(&diagnostic, 0)) catch {};
        }
        return self.result(allocator, call.id, if (stop) |reason| reason.status else .success, eval.effect, eval.output.items, eval.truncated);
    }

    fn result(self: *const Registry, allocator: std.mem.Allocator, id: []const u8, status: foo.tool.Status, effect: foo.tool.Effect, content: []const u8, truncated: bool) foo.io.Error!foo.tool.Result {
        const bounded = textPrefix(content, self.options.run_limits.tool_output_bytes);
        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);
        return .{
            .call_id = owned_id,
            .status = status,
            .effect = effect,
            .content = try allocator.dupe(u8, bounded),
            .truncated = truncated or bounded.len != content.len,
        };
    }
};

const Stop = struct {
    status: foo.tool.Status = .failure,
    message: []const u8,
};

const Evaluation = struct {
    owner: *Registry,
    allocator: std.mem.Allocator,
    parent_id: []const u8,
    operation: foo.io.Context,
    child_count: u32 = 0,
    effect: foo.tool.Effect = .not_started,
    stop: ?Stop = null,
    reply: ?[]u8 = null,
    output: std.ArrayList(u8) = .empty,
    truncated: bool = false,

    fn interrupt(context: *anyopaque) callconv(.c) c_int {
        const self: *Evaluation = @ptrCast(@alignCast(context));
        if (self.stop != null) return 1;
        self.operation.check() catch {
            self.stop = .{ .status = .cancelled, .message = "Code Mode cancelled or exceeded its deadline" };
            return 1;
        };
        self.operation.io.checkCancel() catch {
            self.stop = .{ .status = .cancelled, .message = "Code Mode cancelled" };
            return 1;
        };
        return 0;
    }

    fn emit(context: *anyopaque, value: Bytes) callconv(.c) c_int {
        const self: *Evaluation = @ptrCast(@alignCast(context));
        if (interrupt(context) != 0) return 1;
        self.addOutput(value.slice()) catch |err| {
            self.stop = .{ .message = if (err == error.OutOfMemory) "Code Mode output allocation failed" else "Code Mode output limit reached" };
            return 1;
        };
        return 0;
    }

    fn addOutput(self: *Evaluation, value: []const u8) error{ OutOfMemory, LimitExceeded }!void {
        const limit = self.owner.options.run_limits.tool_output_bytes;
        if (self.output.items.len != 0 and self.output.items.len < limit)
            try self.output.append(self.allocator, '\n');
        const bounded = textPrefix(value, limit - self.output.items.len);
        try self.output.appendSlice(self.allocator, bounded);
        if (bounded.len != value.len) {
            self.truncated = true;
            return error.LimitExceeded;
        }
    }

    fn invoke(context: *anyopaque, tool_name: Bytes, args: Bytes, reply: *Bytes) callconv(.c) c_int {
        const self: *Evaluation = @ptrCast(@alignCast(context));
        if (interrupt(context) != 0) return 1;
        const owner = self.owner;
        const index = owner.names.get(tool_name.slice()) orelse {
            self.stop = .{ .message = "Tool is absent from the enabled catalog" };
            return 1;
        };
        if (self.child_count == owner.options.limits.calls_per_script or !owner.admit()) {
            self.stop = .{ .message = "Code Mode tool call limit reached" };
            return 1;
        }
        const run_limits = owner.options.run_limits;
        foo.wire.json.validate(args.slice(), .{ .max_bytes = run_limits.tool_argument_bytes, .max_depth = run_limits.json_depth }) catch {
            self.stop = .{ .message = "Nested tool arguments exceed the JSON limits" };
            return 1;
        };
        const ordinal = self.child_count + 1;
        const id = childId(self.parent_id, ordinal);
        const declaration = owner.declarations[index];
        const invocation: foo.tool.Invocation = .{
            .declaration = declaration,
            .call = .{ .id = &id, .name = declaration.spec.name, .arguments_json = args.slice() },
        };

        if (owner.options.store) |store| {
            _ = store.commit_fn(store.context, self.operation, .{ .nested_tool = .{
                .parent_call_id = self.parent_id,
                .ordinal = ordinal,
                .data = .{ .dispatch_intent = invocation },
            } }) catch {
                self.stop = .{ .message = "Could not commit nested tool intent" };
                return 1;
            };
        }
        self.child_count = ordinal;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var result: foo.tool.Result = if (interrupt(context) != 0)
            .{ .call_id = &id, .status = .cancelled, .effect = .not_started, .content = "Nested tool cancelled before dispatch" }
        else
            owner.base.invoke_fn(owner.base.context, scratch.allocator(), self.operation, invocation) catch |err|
                uncertain(&id, err == error.Cancelled or err == error.DeadlineExceeded);
        if (!std.mem.eql(u8, result.call_id, &id)) result = uncertain(&id, false);
        const bounded = textPrefix(result.content, run_limits.tool_output_bytes);
        result.truncated = result.truncated or bounded.len != result.content.len;
        result.content = bounded;
        if (@backingInt(result.effect) > @backingInt(self.effect)) self.effect = result.effect;

        if (owner.options.store) |store| {
            var token: foo.io.Cancellation = .{};
            var cleanup = self.operation;
            cleanup.cancellation = &token;
            cleanup.deadline_ms = cleanup.clock.now() +| owner.options.limits.cleanup_ms;
            _ = store.commit_fn(store.context, cleanup, .{ .nested_tool = .{
                .parent_call_id = self.parent_id,
                .ordinal = ordinal,
                .data = .{ .tool_result = result },
            } }) catch {
                self.effect = .uncertain;
                self.stop = .{ .message = "Could not commit nested tool result" };
                return 1;
            };
        }
        if (result.effect == .uncertain) {
            self.stop = .{ .status = if (result.status == .cancelled) .cancelled else .failure, .message = "Nested tool effect could not be confirmed" };
            return 1;
        }
        if (interrupt(context) != 0) return 1;
        const encoded = std.json.Stringify.valueAlloc(self.allocator, result, .{}) catch {
            self.stop = .{ .message = "Could not encode nested tool result" };
            return 1;
        };
        if (self.reply) |old| self.allocator.free(old);
        self.reply = encoded;
        reply.* = Bytes.from(encoded);
        return 0;
    }
};

fn uncertain(id: []const u8, cancelled: bool) foo.tool.Result {
    return .{
        .call_id = id,
        .status = if (cancelled) .cancelled else .failure,
        .effect = .uncertain,
        .content = "Nested tool effect could not be confirmed",
    };
}

fn childId(parent: []const u8, ordinal: u32) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("foo.codemode.child\x00");
    hash.update(parent);
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, ordinal, .big);
    hash.update(&bytes);
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}

fn textPrefix(value: []const u8, limit: usize) []const u8 {
    var end = @min(value.len, limit);
    while (end != 0 and end < value.len and value[end] & 0xc0 == 0x80) end -= 1;
    return value[0..end];
}

const Bytes = extern struct {
    ptr: [*]const u8,
    len: usize,

    fn from(value: []const u8) Bytes {
        return .{ .ptr = value.ptr, .len = value.len };
    }

    fn slice(self: Bytes) []const u8 {
        return self.ptr[0..self.len];
    }
};

const VmOptions = extern struct {
    userdata: *anyopaque,
    interrupt: *const fn (*anyopaque) callconv(.c) c_int,
    invoke: *const fn (*anyopaque, Bytes, Bytes, *Bytes) callconv(.c) c_int,
    text: *const fn (*anyopaque, Bytes) callconv(.c) c_int,
    memory_bytes: usize,
    stack_bytes: usize,
    max_jobs: usize,
};

extern "c" fn foo_vm_run(*const VmOptions, Bytes, Bytes, [*]u8, usize) c_int;
