const std = @import("std");
const foo = @import("foo");
const Schema = @import("schema.zig").Schema;

pub const exec = @import("exec.zig");

pub const backend = "executable";

pub const Descriptor = struct {
    name: []const u8,
    description: []const u8,
    schema_json: []const u8,
    argv: []const []const u8,
    environment: []const foo.io.Environment = &.{},
    inherit_environment: bool = false,
    timeout_ms: u64 = 30_000,
};

pub const Options = struct {
    spawner: foo.io.Spawner,
    session: foo.events.SessionId,
    run: foo.events.RunId,
    generation: u64,
    permissions: ?foo.host.PermissionHandler = null,
    cleanup_ms: u64 = 2_000,
    spool: ?exec.Spool = null,
};

pub const Registry = struct {
    const Entry = struct {
        schema: Schema,
        argv: []const []const u8,
        environment: []const foo.io.Environment,
        inherit_environment: bool,
        timeout_ms: u64,
        revoked: std.atomic.Value(bool) = .init(false),
    };
    const NameIndex = std.StringHashMapUnmanaged(usize);

    arena: std.heap.ArenaAllocator,
    declarations: []const foo.tool.Declaration,
    entries: []Entry,
    names: NameIndex,
    cwd: []const u8,
    limits: foo.config.Limits,
    permission_mode: foo.config.PermissionMode,
    options: Options,
    next_operation_id: std.atomic.Value(u64) = .init(1),

    pub fn init(
        allocator: std.mem.Allocator,
        settings: foo.config.Resolved,
        descriptors: []const Descriptor,
        options: Options,
    ) foo.io.Error!Registry {
        settings.validate() catch return error.InvalidInput;
        if (options.generation == 0 or options.cleanup_ms == 0 or containsNul(settings.cwd))
            return error.InvalidInput;
        const enabled = settings.enabled_tools;
        const limits = settings.limits;
        if (enabled.len > limits.catalog_bytes / @sizeOf(foo.tool.Declaration))
            return error.LimitExceeded;

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        var temp = std.heap.ArenaAllocator.init(allocator);
        defer temp.deinit();
        const selected = try temp.allocator().alloc(?Descriptor, enabled.len);
        @memset(selected, null);
        var names: NameIndex = .empty;
        const declarations = try owned.alloc(foo.tool.Declaration, enabled.len);
        const entries = try owned.alloc(Entry, enabled.len);
        for (enabled, declarations, 0..) |name, *decl, index| {
            if (!validName(name)) return error.InvalidInput;
            const key = try owned.dupe(u8, name);
            const slot = try names.getOrPut(owned, key);
            if (slot.found_existing) return error.InvalidInput;
            slot.value_ptr.* = index;
            decl.* = .{
                .identity = .{ .backend = backend, .name = key },
                .spec = .{ .name = key, .description = "", .schema_json = "" },
                .generation = options.generation,
            };
        }
        for (descriptors) |descriptor| {
            const index = names.get(descriptor.name) orelse continue;
            if (selected[index] != null) return error.InvalidInput;
            selected[index] = descriptor;
        }

        var budget: foo.io.Budget = .{ .limit = limits.catalog_bytes };
        for (selected, declarations, entries) |maybe_descriptor, *decl, *entry| {
            const descriptor = maybe_descriptor orelse return error.InvalidInput;
            try budget.take(@sizeOf(foo.tool.Declaration) +| backend.len +| (decl.spec.name.len *| 2) +|
                descriptor.description.len +| descriptor.schema_json.len);
            try validateDescriptor(descriptor);
            var schema_scratch = std.heap.ArenaAllocator.init(allocator);
            defer schema_scratch.deinit();
            const schema = try Schema.compile(owned, schema_scratch.allocator(), descriptor.schema_json, .{
                .max_bytes = limits.catalog_bytes,
                .max_depth = limits.json_depth,
            });
            decl.spec.description = try owned.dupe(u8, descriptor.description);
            decl.spec.schema_json = try owned.dupe(u8, descriptor.schema_json);

            const argv = try owned.alloc([]const u8, descriptor.argv.len);
            for (descriptor.argv, argv) |arg, *copy| copy.* = try owned.dupe(u8, arg);
            const environment = try owned.alloc(foo.io.Environment, descriptor.environment.len);
            for (descriptor.environment, environment) |item, *copy| copy.* = .{
                .name = try owned.dupe(u8, item.name),
                .value = try owned.dupe(u8, item.value),
            };
            entry.* = .{
                .schema = schema,
                .argv = argv,
                .environment = environment,
                .inherit_environment = descriptor.inherit_environment,
                .timeout_ms = descriptor.timeout_ms,
            };
        }

        const cwd = try owned.dupe(u8, settings.cwd);
        return .{
            .arena = arena,
            .declarations = declarations,
            .entries = entries,
            .names = names,
            .cwd = cwd,
            .limits = limits,
            .permission_mode = settings.permissions,
            .options = options,
        };
    }

    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn interface(self: *Registry) foo.tool.Registry {
        return .{ .context = self, .declarations = self.declarations, .invoke_fn = invoke };
    }

    pub fn revoke(self: *Registry, name: []const u8) bool {
        const index = self.names.get(name) orelse return false;
        self.entries[index].revoked.store(true, .release);
        return true;
    }

    fn invoke(
        opaque_context: *anyopaque,
        allocator: std.mem.Allocator,
        operation: foo.io.Context,
        invocation: foo.tool.Invocation,
    ) foo.io.Error!foo.tool.Result {
        const self: *Registry = @ptrCast(@alignCast(opaque_context));
        var call = invocation.call;
        const index = self.names.get(call.name) orelse
            return self.rejected(allocator, call.id, .catalog_changed, "Tool is absent from the run catalog");
        const entry = &self.entries[index];
        const declaration = self.declarations[index];
        if (!matches(declaration, invocation.declaration) or entry.revoked.load(.acquire))
            return self.rejected(allocator, call.id, .catalog_changed, "Tool declaration changed or was revoked");
        operation.check() catch
            return self.rejected(allocator, call.id, .cancelled, "Tool cancelled before dispatch");
        if (call.id.len == 0)
            return self.rejected(allocator, call.id, .failure, "Tool call ID is empty");
        const argument_limit = "Tool arguments exceed the byte or depth limit";
        if (call.arguments_json.len > self.limits.tool_argument_bytes)
            return self.rejected(allocator, call.id, .failure, argument_limit);

        const admitted_id = try allocator.dupe(u8, call.id);
        defer allocator.free(admitted_id);
        const admitted_input = allocator.dupe(u8, call.arguments_json) catch
            return self.rejected(allocator, call.id, .failure, "Tool arguments could not be retained");
        defer allocator.free(admitted_input);
        call = .{ .id = admitted_id, .name = declaration.spec.name, .arguments_json = admitted_input };
        entry.schema.validate(allocator, call.arguments_json, .{
            .max_bytes = self.limits.tool_argument_bytes,
            .max_depth = self.limits.json_depth,
        }) catch |err| return switch (err) {
            error.LimitExceeded => self.rejected(allocator, call.id, .failure, argument_limit),
            error.OutOfMemory => self.rejected(allocator, call.id, .failure, "Tool arguments could not be validated"),
            else => self.rejected(allocator, call.id, .failure, "Tool arguments do not match the declared JSON schema"),
        };
        operation.check() catch
            return self.rejected(allocator, call.id, .cancelled, "Tool cancelled before dispatch");

        switch (self.permission_mode) {
            .allow => {},
            .deny => return self.rejected(allocator, call.id, .denied, "Tool permission denied"),
            .ask => {
                const handler = self.options.permissions orelse
                    return self.rejected(allocator, call.id, .denied, "Tool permission handler is unavailable");
                const decision = handler.decide_fn(handler.context, operation, .{
                    .session = self.options.session,
                    .run = self.options.run,
                    .operation_id = self.next_operation_id.fetchAdd(1, .monotonic),
                    .invocation = .{ .declaration = declaration, .call = call },
                    .targets = &.{entry.argv[0]},
                }) catch |err| return switch (err) {
                    error.Cancelled, error.DeadlineExceeded => self.rejected(allocator, call.id, .cancelled, "Tool permission request cancelled"),
                    else => self.rejected(allocator, call.id, .denied, "Tool permission could not be obtained"),
                };
                switch (decision) {
                    .allow_once => {},
                    .deny_once => return self.rejected(allocator, call.id, .denied, "Tool permission denied"),
                    .cancelled => return self.rejected(allocator, call.id, .cancelled, "Tool permission request cancelled"),
                }
            },
        }
        if (entry.revoked.load(.acquire))
            return self.rejected(allocator, call.id, .catalog_changed, "Tool declaration was revoked");
        operation.check() catch
            return self.rejected(allocator, call.id, .cancelled, "Tool cancelled before dispatch");

        return exec.run(allocator, operation, call.id, .{ .argv = entry.argv, .input = call.arguments_json }, .{
            .spawner = self.options.spawner,
            .cwd = self.cwd,
            .environment = entry.environment,
            .inherit_environment = entry.inherit_environment,
            .timeout_ms = entry.timeout_ms,
            .cleanup_ms = self.options.cleanup_ms,
            .output_bytes = self.limits.tool_output_bytes,
            .spool = self.options.spool,
        });
    }

    fn rejected(self: *const Registry, allocator: std.mem.Allocator, call_id: []const u8, status: foo.tool.Status, message: []const u8) foo.io.Error!foo.tool.Result {
        const id = try allocator.dupe(u8, call_id);
        errdefer allocator.free(id);
        const length = @min(message.len, self.limits.tool_output_bytes);
        return .{
            .call_id = id,
            .status = status,
            .effect = .not_started,
            .content = try allocator.dupe(u8, message[0..length]),
            .truncated = length < message.len,
        };
    }
};

fn matches(expected: foo.tool.Declaration, actual: foo.tool.Declaration) bool {
    return actual.generation == expected.generation and actual.identity.server == null and
        eql(expected.identity.backend, actual.identity.backend) and eql(expected.identity.name, actual.identity.name) and
        eql(expected.spec.name, actual.spec.name) and eql(expected.spec.description, actual.spec.description) and
        eql(expected.spec.schema_json, actual.spec.schema_json);
}

fn validateDescriptor(descriptor: Descriptor) foo.io.Error!void {
    if (descriptor.argv.len == 0 or descriptor.argv[0].len == 0 or descriptor.timeout_ms == 0 or
        !std.unicode.utf8ValidateSlice(descriptor.description)) return error.InvalidInput;
    for (descriptor.argv) |arg| if (containsNul(arg)) return error.InvalidInput;
    for (descriptor.environment) |item| {
        if (item.name.len == 0 or containsNul(item.name) or containsNul(item.value) or
            std.mem.indexOfScalar(u8, item.name, '=') != null) return error.InvalidInput;
    }
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

fn containsNul(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0) != null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
