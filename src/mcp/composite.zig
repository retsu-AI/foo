const std = @import("std");
const foo = @import("foo");

pub const Error = foo.io.Error || error{AliasCollision};

pub const RegistrySet = struct {
    const Route = struct {
        invoke: @FieldType(foo.tool.Registry, "invoke_fn"),
        context: *anyopaque,
    };

    allocator: std.mem.Allocator,
    declarations: []foo.tool.Declaration,
    routes: []Route,
    aliases: std.StringHashMapUnmanaged(usize),

    /// The backing registries and their immutable declarations outlive this set.
    pub fn init(allocator: std.mem.Allocator, registries: []const foo.tool.Registry, catalog_bytes: usize) Error!RegistrySet {
        var count: usize = 0;
        var budget: foo.io.Budget = .{ .limit = catalog_bytes };
        for (registries) |registry| {
            try budget.take(registry.declarations.len *| (@sizeOf(foo.tool.Declaration) + @sizeOf(Route)));
            count += registry.declarations.len;
        }
        const declarations = try allocator.alloc(foo.tool.Declaration, count);
        errdefer allocator.free(declarations);
        const routes = try allocator.alloc(Route, count);
        errdefer allocator.free(routes);
        var aliases: std.StringHashMapUnmanaged(usize) = .empty;
        errdefer aliases.deinit(allocator);

        var index: usize = 0;
        for (registries) |registry| {
            for (registry.declarations) |item| {
                if (item.spec.name.len == 0 or item.identity.name.len == 0 or item.identity.backend.len == 0 or
                    item.generation == 0) return error.InvalidInput;
                try budget.take(item.spec.name.len +| item.spec.description.len +| item.spec.schema_json.len +|
                    item.identity.name.len +| item.identity.backend.len +| (if (item.identity.server) |id| id.len else 0));
                const slot = try aliases.getOrPut(allocator, item.spec.name);
                if (slot.found_existing) return error.AliasCollision;
                slot.value_ptr.* = index;
                declarations[index] = item;
                routes[index] = .{ .context = registry.context, .invoke = registry.invoke_fn };
                index += 1;
            }
        }
        return .{ .allocator = allocator, .declarations = declarations, .routes = routes, .aliases = aliases };
    }

    pub fn deinit(self: *RegistrySet) void {
        self.allocator.free(self.routes);
        self.allocator.free(self.declarations);
        self.aliases.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn interface(self: *RegistrySet) foo.tool.Registry {
        return .{ .context = self, .declarations = self.declarations, .invoke_fn = invoke };
    }

    fn invoke(context: *anyopaque, allocator: std.mem.Allocator, operation: foo.io.Context, invocation: foo.tool.Invocation) foo.io.Error!foo.tool.Result {
        const self: *RegistrySet = @ptrCast(@alignCast(context));
        if (self.aliases.get(invocation.call.name)) |index| {
            if (matches(self.declarations[index], invocation.declaration)) {
                const route = self.routes[index];
                return route.invoke(route.context, allocator, operation, invocation);
            }
        }
        return .{
            .call_id = try allocator.dupe(u8, invocation.call.id),
            .status = .catalog_changed,
            .effect = .not_started,
            .content = "Tool declaration is absent from the run catalog",
        };
    }
};

fn matches(a: foo.tool.Declaration, b: foo.tool.Declaration) bool {
    return a.generation == b.generation and
        eql(a.identity.backend, b.identity.backend) and
        eql(a.identity.name, b.identity.name) and
        (if (a.identity.server) |server| if (b.identity.server) |other| eql(server, other) else false else b.identity.server == null) and
        eql(a.spec.name, b.spec.name) and eql(a.spec.description, b.spec.description) and eql(a.spec.schema_json, b.spec.schema_json);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
