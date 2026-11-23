const std = @import("std");
const foo = @import("foo");
const protocol = @import("client.zig");
const context = @import("context.zig");
const schema = @import("schema.zig");

const Allocator = std.mem.Allocator;
const Object = std.json.ObjectMap;
const Value = std.json.Value;
const ToolResult = foo.tool.Result;

pub const backend = "mcp";
pub const Error = schema.Error || error{AliasCollision};

pub const Options = struct {
    enabled_aliases: []const []const u8 = &.{},
    reserved_aliases: []const []const u8 = &.{},
    generation: u64,
    session: foo.events.SessionId,
    run: foo.events.RunId,
    limits: foo.config.Limits = .{},
    permission_mode: foo.config.PermissionMode = .deny,
    permissions: ?foo.host.PermissionHandler = null,
    operation_ids: ?*std.atomic.Value(u64) = null,
};

const Remote = struct {
    name: []const u8,
    description: []const u8,
    input: Value,
    output: ?Value,
};

const Entry = struct {
    input: schema.Schema,
    output: ?schema.Schema,
    available: std.atomic.Value(bool) = .init(true),
};

const Catalog = std.StringArrayHashMapUnmanaged(Remote);

pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    client: *protocol.Client,
    context_source: context.Source,
    options: Options,
    enabled: std.StringHashMapUnmanaged(void),
    reserved: std.StringHashMapUnmanaged(void),
    declarations: []const foo.tool.Declaration,
    entries: []Entry,
    names: std.StringHashMapUnmanaged(usize),
    guard: std.Io.Mutex = .init,
    current_epoch: ?u64,
    next_operation_id: std.atomic.Value(u64) = .init(1),

    /// Establish the client before starting subscriptions or using it from other tasks.
    pub fn init(allocator: Allocator, operation: foo.io.Context, client: *protocol.Client, options: Options) Error!Registry {
        try operation.check();
        if (options.generation == 0 or options.limits.catalog_pages == 0 or options.limits.catalog_bytes == 0 or
            options.limits.wire_message_bytes == 0 or options.limits.json_depth == 0 or
            options.limits.tool_argument_bytes == 0 or options.limits.tool_output_bytes == 0) return error.InvalidInput;
        var registry: Registry = .{
            .arena = .init(allocator),
            .client = client,
            .options = options,
            .context_source = undefined,
            .enabled = .empty,
            .reserved = .empty,
            .declarations = &.{},
            .entries = &.{},
            .names = .empty,
            .current_epoch = null,
        };
        errdefer registry.deinit();
        const owned = registry.arena.allocator();
        var budget: foo.io.Budget = .{ .limit = options.limits.catalog_bytes };
        try copyAliases(owned, &registry.enabled, options.enabled_aliases, &budget);
        try copyAliases(owned, &registry.reserved, options.reserved_aliases, &budget);
        registry.options.enabled_aliases = &.{};
        registry.options.reserved_aliases = &.{};

        const server = if (client.options.server_id.len <= options.limits.catalog_bytes)
            try owned.dupe(u8, client.options.server_id)
        else
            return error.LimitExceeded;
        const profile = try client.connect(allocator, operation);
        registry.context_source = .{
            .client = client,
            .server_id = server,
            .limits = options.limits,
            .capabilities = profile.capabilities,
        };

        if (registry.enabled.count() == 0) return registry;
        const epoch = client.epoch();
        const discovered = try registry.discover(owned, operation, profile);
        const declarations = try owned.alloc(foo.tool.Declaration, discovered.count());
        const entries = try owned.alloc(Entry, discovered.count());
        const mirror = profile.revision == .@"2026-07-28";
        var count: usize = 0;
        for (discovered.keys(), discovered.values()) |alias, remote| {
            if (registry.reserved.contains(alias)) return error.AliasCollision;
            const input = schema.Schema.compile(owned, remote.input, true, mirror) catch |err| switch (err) {
                error.InvalidHeaderSchema => continue,
                else => return err,
            };
            const output = if (remote.output) |value| try schema.Schema.compile(owned, value, false, false) else null;
            const spec = try context.boundedJson(owned, options.limits.catalog_bytes, remote.input);
            declarations[count] = .{
                .identity = .{ .backend = backend, .server = server, .name = remote.name },
                .spec = .{ .name = alias, .description = remote.description, .schema_json = spec },
                .generation = options.generation,
            };
            entries[count] = .{ .input = input, .output = output };
            try registry.names.put(owned, alias, count);
            count += 1;
        }
        registry.declarations = declarations[0..count];
        registry.entries = entries[0..count];
        try operation.check();
        if (client.epoch() != epoch) return error.Unavailable;
        registry.current_epoch = epoch;
        return registry;
    }

    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn interface(self: *Registry) foo.tool.Registry {
        return .{ .context = self, .declarations = self.declarations, .invoke_fn = invoke };
    }

    pub fn source(self: *Registry) foo.tool.ContextSource {
        return self.context_source.interface();
    }

    pub fn revoke(self: *Registry, alias: []const u8) bool {
        const index = self.names.get(alias) orelse return false;
        return self.entries[index].available.swap(false, .acq_rel);
    }

    pub fn refresh(self: *Registry, operation: foo.io.Context) Error!void {
        self.guard.lock(operation.io) catch return error.Cancelled;
        defer self.guard.unlock(operation.io);
        try self.refreshLocked(operation);
    }

    fn refreshLocked(self: *Registry, operation: foo.io.Context) Error!void {
        self.current_epoch = null;
        try operation.check();
        var snapshot: std.heap.ArenaAllocator = .init(self.arena.child_allocator);
        defer snapshot.deinit();
        const allocator = snapshot.allocator();
        const profile = self.client.profile orelse return error.Unavailable;
        const epoch = self.client.epoch();
        const next = try self.discover(allocator, operation, profile);
        try operation.check();
        if (epoch != self.client.epoch()) return error.Unavailable;
        for (self.declarations, self.entries) |declaration, *entry| {
            if (!entry.available.load(.acquire)) continue;
            const same = if (next.get(declaration.spec.name)) |remote|
                eql(remote.name, declaration.identity.name) and schema.equal(remote.input, entry.input.value) and
                    optionalSchemaEqual(remote.output, entry.output)
            else
                false;
            if (!same) entry.available.store(false, .release);
        }
        self.current_epoch = epoch;
    }

    fn discover(self: *const Registry, allocator: Allocator, operation: foo.io.Context, profile: protocol.Profile) Error!Catalog {
        var found: Catalog = .empty;
        if (!profile.capabilities.tools or self.enabled.count() == 0) return found;
        const backing = self.arena.child_allocator;
        var discovery: std.heap.ArenaAllocator = .init(backing);
        defer discovery.deinit();
        const temp = discovery.allocator();
        var aliases: std.StringHashMapUnmanaged([]const u8) = .empty;
        var budget: foo.io.Budget = .{ .limit = self.options.limits.catalog_bytes };
        var reader = try context.PageReader.init(backing, self.client, operation, self.options.limits, "tools/list", "tools", null);
        defer reader.deinit();
        while (true) {
            var page_arena: std.heap.ArenaAllocator = .init(backing);
            defer page_arena.deinit();
            const page_allocator = page_arena.allocator();
            const page = (try reader.next(page_allocator)) orelse break;
            const fields = try schema.parseObject(page_allocator, page.completion.raw, .{
                .max_bytes = self.options.limits.wire_message_bytes,
                .max_depth = self.options.limits.json_depth,
            }, error.MalformedPeer);
            for (try context.array(fields, "tools")) |value| {
                if (value != .object) return error.MalformedPeer;
                const name = try context.string(value.object, "name");
                if (name.len == 0) return error.MalformedPeer;
                const input = value.object.get("inputSchema") orelse return error.MalformedPeer;
                const alias = try providerAlias(temp, self.context_source.server_id, name);
                try budget.take((@sizeOf([]const u8) * 2) +| alias.len +| name.len);
                if (aliases.get(alias)) |previous| return if (eql(previous, name)) error.MalformedPeer else error.AliasCollision;
                try aliases.put(temp, alias, try temp.dupe(u8, name));
                if (!self.enabled.contains(alias)) continue;
                const retained_json = try context.boundedJson(allocator, self.options.limits.catalog_bytes, value);
                const remote = try schema.parseObject(allocator, retained_json, .{
                    .max_bytes = self.options.limits.catalog_bytes,
                    .max_depth = self.options.limits.json_depth,
                }, error.MalformedPeer);
                const description = if (remote.contains("description")) try context.string(remote, "description") else "";
                const output = remote.get("outputSchema");
                if (input != .object or (output != null and output.? != .object)) return error.MalformedPeer;
                try found.put(allocator, try allocator.dupe(u8, alias), .{
                    .name = try context.string(remote, "name"),
                    .description = description,
                    .input = remote.get("inputSchema").?,
                    .output = output,
                });
            }
        }
        return found;
    }

    fn fresh(self: *Registry, operation: foo.io.Context, index: usize) Error!?u64 {
        if (!self.entries[index].available.load(.acquire)) return null;
        self.guard.lock(operation.io) catch return error.Cancelled;
        defer self.guard.unlock(operation.io);
        try operation.check();
        if (self.current_epoch == null or self.current_epoch.? != self.client.epoch()) {
            try self.refreshLocked(operation);
        }
        return if (self.entries[index].available.load(.acquire)) self.current_epoch else null;
    }

    fn invoke(
        opaque_context: *anyopaque,
        allocator: Allocator,
        operation: foo.io.Context,
        invocation: foo.tool.Invocation,
    ) foo.io.Error!ToolResult {
        const self: *Registry = @ptrCast(@alignCast(opaque_context));
        const call = invocation.call;
        const index = self.names.get(call.name) orelse
            return self.result(allocator, call.id, .catalog_changed, .not_started, "MCP tool is absent from the run catalog");
        const declaration = self.declarations[index];
        const entry = &self.entries[index];
        if (!matches(declaration, invocation.declaration))
            return self.result(allocator, call.id, .catalog_changed, .not_started, "MCP tool declaration changed");
        if ((self.fresh(operation, index) catch |err| return self.failure(allocator, call.id, err, .unsent)) == null)
            return self.result(allocator, call.id, .catalog_changed, .not_started, "MCP tool declaration changed or was revoked");
        if (call.id.len == 0)
            return self.result(allocator, call.id, .failure, .not_started, "MCP tool call ID is empty");

        var scratch: std.heap.ArenaAllocator = .init(allocator);
        defer scratch.deinit();
        const temp = scratch.allocator();
        if (call.arguments_json.len > self.options.limits.tool_argument_bytes)
            return self.failure(allocator, call.id, error.LimitExceeded, .unsent);
        const immutable_call: foo.provider.ToolCall = .{
            .id = try temp.dupe(u8, call.id),
            .name = declaration.spec.name,
            .arguments_json = try temp.dupe(u8, call.arguments_json),
        };
        const arguments = schema.parseObject(temp, immutable_call.arguments_json, .{
            .max_bytes = self.options.limits.tool_argument_bytes,
            .max_depth = self.options.limits.json_depth,
        }, error.InvalidInput) catch |err| return self.failure(allocator, immutable_call.id, err, .unsent);
        if (!entry.input.accepts(.{ .object = arguments }))
            return self.result(allocator, immutable_call.id, .failure, .not_started, "MCP tool arguments do not match the pinned input schema");
        const headers = entry.input.headers(temp, arguments) catch |err|
            return self.failure(allocator, immutable_call.id, err, .unsent);
        operation.check() catch |err| return self.failure(allocator, immutable_call.id, err, .unsent);
        const server = declaration.identity.server.?;
        const name = declaration.identity.name;
        switch (self.options.permission_mode) {
            .allow => {},
            .deny => return self.result(allocator, immutable_call.id, .denied, .not_started, "MCP tool permission denied"),
            .ask => {
                const handler = self.options.permissions orelse
                    return self.result(allocator, immutable_call.id, .denied, .not_started, "MCP tool permission handler is unavailable");
                const ids = self.options.operation_ids orelse &self.next_operation_id;
                const decision = handler.decide_fn(handler.context, operation, .{
                    .session = self.options.session,
                    .run = self.options.run,
                    .operation_id = ids.fetchAdd(1, .monotonic),
                    .invocation = .{ .declaration = declaration, .call = immutable_call },
                    .targets = &.{ server, name },
                }) catch |err| switch (err) {
                    error.Cancelled, error.DeadlineExceeded => return self.failure(allocator, immutable_call.id, err, .unsent),
                    else => return self.result(allocator, immutable_call.id, .denied, .not_started, "MCP tool permission could not be obtained"),
                };
                switch (decision) {
                    .allow_once => {},
                    .deny_once => return self.result(allocator, immutable_call.id, .denied, .not_started, "MCP tool permission denied"),
                    .cancelled => return self.failure(allocator, immutable_call.id, error.Cancelled, .unsent),
                }
            },
        }

        var params: Object = .empty;
        try params.put(temp, "name", .{ .string = name });
        try params.put(temp, "arguments", .{ .object = arguments });
        const epoch = (self.fresh(operation, index) catch |err|
            return self.failure(allocator, immutable_call.id, err, .unsent)) orelse
            return self.result(allocator, immutable_call.id, .catalog_changed, .not_started, "MCP tool declaration changed or was revoked");
        if (self.client.epoch() != epoch or !entry.available.load(.acquire))
            return self.result(allocator, immutable_call.id, .catalog_changed, .not_started, "MCP tool catalog changed before dispatch");

        var delivery: foo.io.Delivery = .unsent;
        const completion = self.client.request(
            temp,
            operation,
            "tools/call",
            params,
            .{ .name = name, .headers = headers },
            &delivery,
        ) catch |err| return self.failure(allocator, immutable_call.id, err, delivery);
        if (completion.kind != .complete) return self.failure(allocator, immutable_call.id, error.UnsupportedCapability, delivery);
        return self.projectResult(allocator, temp, immutable_call.id, entry, completion) catch |err|
            return self.failure(allocator, immutable_call.id, err, delivery);
    }

    fn projectResult(
        self: *const Registry,
        allocator: Allocator,
        scratch: Allocator,
        id: []const u8,
        entry: *const Entry,
        completion: protocol.Completion,
    ) Error!ToolResult {
        const fields = try schema.parseObject(scratch, completion.raw, .{
            .max_bytes = self.options.limits.wire_message_bytes,
            .max_depth = self.options.limits.json_depth,
        }, error.MalformedPeer);
        const items = try context.array(fields, "content");
        const is_error = if (fields.get("isError")) |value| read: {
            if (value != .bool) return error.MalformedPeer;
            break :read value.bool;
        } else false;
        const structured = fields.get("structuredContent");
        if (!is_error) if (entry.output) |output| {
            if (!output.accepts(structured orelse return error.MalformedPeer)) return error.MalformedPeer;
        };
        for (items) |item| {
            context.verifyBlock(item) catch |err| return switch (err) {
                error.UnsupportedCapability => self.result(allocator, id, .failure, .observed, "MCP tool returned an unsupported content type"),
                else => err,
            };
        }
        const status: foo.tool.Status = if (is_error) .failure else .success;
        const encoded = context.boundedJson(scratch, self.options.limits.tool_output_bytes, .{
            .content = fields.get("content").?,
            .structuredContent = structured,
            .isError = is_error,
        }) catch |err| switch (err) {
            error.LimitExceeded => {
                const truncated = "{\"truncated\":true}";
                const marker = if (self.options.limits.tool_output_bytes >= truncated.len)
                    truncated
                else if (self.options.limits.tool_output_bytes >= 2)
                    "{}"
                else
                    "0";
                var output = try self.result(allocator, id, status, .observed, marker);
                output.truncated = true;
                return output;
            },
            else => return err,
        };
        return self.result(allocator, id, status, .observed, encoded);
    }

    fn failure(self: *const Registry, allocator: Allocator, id: []const u8, err: Error, delivery: foo.io.Delivery) foo.io.Error!ToolResult {
        const effect: foo.tool.Effect = if (delivery == .possibly_sent) .uncertain else .not_started;
        const status: foo.tool.Status = switch (err) {
            error.Cancelled, error.DeadlineExceeded => .cancelled,
            else => .failure,
        };
        const message = switch (err) {
            error.Cancelled, error.DeadlineExceeded => "MCP tool operation cancelled or timed out",
            error.RpcFailure => "MCP tool request returned a JSON-RPC error",
            error.UnsupportedCapability => "MCP tool request requires an unsupported capability",
            error.SessionExpired => "MCP server session expired",
            error.UnsupportedAuthentication => "MCP server requires unsupported authentication",
            error.MalformedPeer => "MCP server returned an invalid message",
            error.LimitExceeded => "MCP tool operation exceeded a configured limit",
            error.InvalidInput => "MCP tool arguments or header values are invalid",
            error.AliasCollision => "MCP tool aliases collide",
            error.UnsupportedSchema, error.InvalidHeaderSchema => "MCP tool schema uses an unsupported feature",
            else => "MCP tool operation could not be completed",
        };
        return self.result(allocator, id, status, effect, message);
    }

    fn result(
        self: *const Registry,
        allocator: Allocator,
        id: []const u8,
        status: foo.tool.Status,
        effect: foo.tool.Effect,
        message: []const u8,
    ) foo.io.Error!ToolResult {
        const call_id = try allocator.dupe(u8, id);
        errdefer allocator.free(call_id);
        const bounded = context.utf8Prefix(message, self.options.limits.tool_output_bytes);
        return .{
            .call_id = call_id,
            .status = status,
            .effect = effect,
            .content = try allocator.dupe(u8, bounded),
            .truncated = bounded.len != message.len,
        };
    }
};

pub fn providerAlias(allocator: Allocator, server: []const u8, remote: []const u8) error{ InvalidInput, OutOfMemory }![]const u8 {
    if (server.len == 0 or remote.len == 0) return error.InvalidInput;
    const limit = 64;
    const length = 5 +| server.len +| remote.len;
    const alias = try allocator.alloc(u8, @min(length, limit));
    @memcpy(alias[0..4], "mcp_");
    const stem_limit = if (length > limit) limit - 17 else alias.len;
    var index: usize = 4;
    for (server) |char| {
        if (index == stem_limit) break;
        alias[index] = providerChar(char);
        index += 1;
    }
    if (index < stem_limit) {
        alias[index] = '_';
        index += 1;
    }
    for (remote) |char| {
        if (index == stem_limit) break;
        alias[index] = providerChar(char);
        index += 1;
    }
    if (length > limit) {
        var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
        var size: [8]u8 = undefined;
        std.mem.writeInt(u64, &size, server.len, .big);
        hash.update(&size);
        hash.update(server);
        hash.update(remote);
        const digest = hash.finalResult();
        const hex = std.fmt.bytesToHex(digest[0..8], .lower);
        alias[stem_limit] = '_';
        @memcpy(alias[stem_limit + 1 ..][0..hex.len], &hex);
    }
    return alias;
}

fn providerChar(char: u8) u8 {
    return if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_') char else '_';
}

fn copyAliases(
    allocator: Allocator,
    target: *std.StringHashMapUnmanaged(void),
    aliases: []const []const u8,
    budget: *foo.io.Budget,
) Error!void {
    for (aliases) |alias| {
        if (alias.len == 0 or alias.len > 64) return error.InvalidInput;
        for (alias) |char| if (providerChar(char) != char) return error.InvalidInput;
        if (target.contains(alias)) return error.InvalidInput;
        try budget.take(@sizeOf([]const u8) + alias.len);
        try target.put(allocator, try allocator.dupe(u8, alias), {});
    }
}

fn optionalSchemaEqual(remote: ?Value, pinned: ?schema.Schema) bool {
    return if (remote) |value| if (pinned) |old| schema.equal(value, old.value) else false else pinned == null;
}

fn matches(a: foo.tool.Declaration, b: foo.tool.Declaration) bool {
    return a.generation == b.generation and eql(a.identity.backend, b.identity.backend) and
        eql(a.identity.server.?, b.identity.server orelse return false) and eql(a.identity.name, b.identity.name) and
        eql(a.spec.name, b.spec.name) and eql(a.spec.description, b.spec.description) and eql(a.spec.schema_json, b.spec.schema_json);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
