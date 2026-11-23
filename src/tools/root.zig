const std = @import("std");
const foo = @import("foo");
const Schema = @import("schema.zig").Schema;

pub const exec = @import("exec.zig");
pub const builtin_tools = @import("builtin.zig");
pub const files = @import("files.zig");

pub const backend = "executable";
pub const coding_preset: []const []const u8 = &.{ "read", "edit", "write", "exec" };

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
    builtins: ?BuiltinOptions = null,
};

pub const BuiltinOptions = struct {
    file_bytes: usize = 8 * 1024 * 1024,
    environment: []const foo.io.Environment = &.{},
    inherit_environment: bool = false,
    timeout_ms: u64 = 30_000,
};

pub const Registry = struct {
    const Executable = struct {
        argv: []const []const u8,
        environment: []const foo.io.Environment,
        inherit_environment: bool,
        timeout_ms: u64,
    };
    const Action = union(enum) {
        executable: Executable,
        builtin: builtin_tools.Kind,
    };
    const Entry = struct {
        schema: Schema,
        action: Action,
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
    writer_lock: std.Io.Mutex = .init,
    active_commands: std.atomic.Value(usize) = .init(0),
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
            const kind = if (maybe_descriptor == null and options.builtins != null)
                std.meta.stringToEnum(builtin_tools.Kind, decl.spec.name)
            else
                null;
            const action: Action = if (kind) |builtin_kind| builtins: {
                if (builtin_kind == .exec) {
                    if (settings.process_backend != .local) return error.Unavailable;
                } else if (settings.files_backend != .local) return error.Unavailable;
                decl.identity.backend = "builtin";
                decl.spec = builtin_tools.spec(builtin_kind);
                break :builtins .{ .builtin = builtin_kind };
            } else configured: {
                const descriptor = maybe_descriptor orelse return error.InvalidInput;
                if (settings.process_backend != .local) return error.Unavailable;
                try validateDescriptor(descriptor);
                try chargeCommand(&budget, descriptor.argv, descriptor.environment);
                decl.spec.description = try owned.dupe(u8, descriptor.description);
                decl.spec.schema_json = try owned.dupe(u8, descriptor.schema_json);
                const argv = try owned.alloc([]const u8, descriptor.argv.len);
                for (descriptor.argv, argv) |arg, *copy| copy.* = try owned.dupe(u8, arg);
                break :configured .{ .executable = .{
                    .argv = argv,
                    .environment = try copyEnvironment(owned, descriptor.environment),
                    .inherit_environment = descriptor.inherit_environment,
                    .timeout_ms = descriptor.timeout_ms,
                } };
            };
            try budget.take(@sizeOf(foo.tool.Declaration) +| decl.identity.backend.len +|
                (decl.spec.name.len *| 2) +| decl.spec.description.len +| decl.spec.schema_json.len);
            var schema_scratch = std.heap.ArenaAllocator.init(allocator);
            defer schema_scratch.deinit();
            const schema = try Schema.compile(owned, schema_scratch.allocator(), decl.spec.schema_json, .{
                .max_bytes = limits.catalog_bytes,
                .max_depth = limits.json_depth,
            });
            entry.* = .{ .schema = schema, .action = action };
        }

        const cwd = try owned.dupe(u8, settings.cwd);
        var owned_options = options;
        if (owned_options.builtins) |*profile| {
            if (profile.file_bytes == 0 or profile.timeout_ms == 0 or !files.absolute(cwd)) return error.InvalidInput;
            try chargeCommand(&budget, &.{}, profile.environment);
            profile.environment = try copyEnvironment(owned, profile.environment);
        }
        return .{
            .arena = arena,
            .declarations = declarations,
            .entries = entries,
            .names = names,
            .cwd = cwd,
            .limits = limits,
            .permission_mode = settings.permissions,
            .options = owned_options,
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

        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const prepared = switch (entry.action) {
            .executable => null,
            .builtin => |kind| builtin_tools.prepare(kind, scratch.allocator(), self.cwd, call.arguments_json, self.options.builtins.?.file_bytes) catch |err|
                return self.rejected(allocator, call.id, .failure, @errorName(err)),
        };
        const target = if (prepared) |builtin_call| builtin_call.target() else entry.action.executable.argv[0];
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
                    .targets = &.{target},
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

        const starts_process = switch (entry.action) {
            .executable => true,
            .builtin => |kind| kind == .exec,
        };
        if (starts_process and !self.admitCommand())
            return self.rejected(allocator, call.id, .failure, "Active command limit reached");
        defer if (starts_process) {
            _ = self.active_commands.fetchSub(1, .release);
        };
        var execution: exec.Options = .{
            .spawner = self.options.spawner,
            .cwd = self.cwd,
            .cleanup_ms = self.options.cleanup_ms,
            .output_bytes = self.limits.tool_output_bytes,
            .spool = self.options.spool,
        };
        if (prepared) |builtin_call| {
            const profile = self.options.builtins.?;
            execution.environment = profile.environment;
            execution.inherit_environment = profile.inherit_environment;
            execution.timeout_ms = profile.timeout_ms;
            return builtin_call.run(allocator, scratch.allocator(), operation, call.id, profile.file_bytes, execution.output_bytes, &self.writer_lock, execution);
        }
        const command = entry.action.executable;
        execution.environment = command.environment;
        execution.inherit_environment = command.inherit_environment;
        execution.timeout_ms = command.timeout_ms;
        return exec.run(allocator, operation, call.id, .{ .argv = command.argv, .input = call.arguments_json }, execution);
    }

    fn admitCommand(self: *Registry) bool {
        var active = self.active_commands.load(.acquire);
        while (active < self.limits.active_commands) {
            active = self.active_commands.cmpxchgWeak(active, active + 1, .acq_rel, .acquire) orelse return true;
        }
        return false;
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
}

fn chargeCommand(budget: *foo.io.Budget, argv: []const []const u8, environment: []const foo.io.Environment) foo.io.Error!void {
    for (argv) |arg| try budget.take(@sizeOf([]const u8) +| arg.len);
    for (environment) |item| {
        if (item.name.len == 0 or containsNul(item.name) or containsNul(item.value) or
            std.mem.indexOfScalar(u8, item.name, '=') != null) return error.InvalidInput;
        try budget.take(@sizeOf(foo.io.Environment) +| item.name.len +| item.value.len);
    }
}

fn copyEnvironment(allocator: std.mem.Allocator, source: []const foo.io.Environment) error{OutOfMemory}![]const foo.io.Environment {
    const environment = try allocator.alloc(foo.io.Environment, source.len);
    for (source, environment) |item, *copy| copy.* = .{
        .name = try allocator.dupe(u8, item.name),
        .value = try allocator.dupe(u8, item.value),
    };
    return environment;
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
