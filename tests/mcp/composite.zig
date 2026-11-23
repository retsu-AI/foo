const std = @import("std");
const foo = @import("foo");
const mcp = @import("mcp");
const t = std.testing;

const local: foo.tool.Declaration = .{
    .identity = .{ .backend = "builtin", .name = "read" },
    .spec = .{ .name = "read", .description = "", .schema_json = "{}" },
    .generation = 1,
};
const remote: foo.tool.Declaration = .{
    .identity = .{ .backend = "mcp", .server = "example", .name = "read" },
    .spec = .{ .name = "mcp_example_read", .description = "Read from the remote service", .schema_json = "{}" },
    .generation = 2,
};

const Backend = struct {
    declarations: []const foo.tool.Declaration,
    outputs: []const u8,
    calls: usize = 0,

    fn interface(self: *Backend) foo.tool.Registry {
        return .{ .context = self, .declarations = self.declarations, .invoke_fn = invoke };
    }

    fn invoke(context: *anyopaque, a: std.mem.Allocator, op: foo.io.Context, invocation: foo.tool.Invocation) foo.io.Error!foo.tool.Result {
        try op.check();
        const self: *Backend = @ptrCast(@alignCast(context));
        self.calls += 1;
        return .{
            .call_id = try a.dupe(u8, invocation.call.id),
            .status = .success,
            .effect = .observed,
            .content = try a.dupe(u8, self.outputs),
        };
    }
};

test "local and remote calls share one pinned catalog without crossing identities" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    var first: Backend = .{ .declarations = &.{local}, .outputs = "local" };
    var second: Backend = .{ .declarations = &.{remote}, .outputs = "remote" };
    var set = try mcp.RegistrySet.init(t.allocator, &.{ first.interface(), second.interface() }, 4096);
    defer set.deinit();
    const registry = set.interface();
    var token: foo.io.Cancellation = .{};
    const op: foo.io.Context = .{
        .io = t.io,
        .cancellation = &token,
        .clock = .{ .context = &token, .now_fn = struct {
            fn now(_: *anyopaque) u64 {
                return 0;
            }
        }.now },
    };
    try t.expectEqual(@as(usize, 2), registry.declarations.len);
    for (registry.declarations, [_][]const u8{ "local", "remote" }) |decl, expected| {
        const result = try registry.invoke_fn(registry.context, a.allocator(), op, .{
            .declaration = decl,
            .call = .{ .id = "call", .name = decl.spec.name, .arguments_json = "{}" },
        });
        try t.expectEqualStrings(expected, result.content);
    }
    var forged = remote;
    forged.identity.server = "other";
    const invalid = try registry.invoke_fn(registry.context, a.allocator(), op, .{
        .declaration = forged,
        .call = .{ .id = "forged", .name = remote.spec.name, .arguments_json = "{}" },
    });
    try t.expectEqual(.catalog_changed, invalid.status);
    try t.expectEqual(.not_started, invalid.effect);
    try t.expectEqual(@as(usize, 1), first.calls);
    try t.expectEqual(@as(usize, 1), second.calls);
}

test "registry composition rejects aliases that shadow another backend" {
    var collision = remote;
    collision.spec.name = local.spec.name;
    var first: Backend = .{ .declarations = &.{local}, .outputs = "local" };
    var second: Backend = .{ .declarations = &.{collision}, .outputs = "remote" };
    try t.expectError(error.AliasCollision, mcp.RegistrySet.init(t.allocator, &.{ first.interface(), second.interface() }, 4096));
    try t.expectEqual(@as(usize, 0), first.calls + second.calls);
}

test "effectful connection setup resolves only explicit credentials" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    var env = std.process.Environ.Map.init(a.allocator());
    try env.put("MCP_TOKEN", "fixture-token");
    try env.put("UNRELATED", "not-for-child");
    const server: foo.config.McpServer = .{
        .id = "fixture",
        .transport = .{ .stdio = .{
            .argv = &.{ "/fixture", "arg" },
            .environment = &.{.{ .name = "TOKEN", .value = .{ .environment = "MCP_TOKEN" } }},
        } },
    };
    const launch = try mcp.connection_config.resolve(a.allocator(), server, "/workspace", &env);
    try t.expectEqual(@as(usize, 1), launch.stdio.environment.len);
    try t.expectEqualStrings("TOKEN", launch.stdio.environment[0].name);
    try t.expectEqualStrings("fixture-token", launch.stdio.environment[0].value);
    try t.expect(!launch.stdio.inherit_environment);
    var missing = server;
    missing.transport.stdio.environment = &.{.{ .name = "TOKEN", .value = .{ .environment = "MISSING" } }};
    try t.expectError(error.Unavailable, mcp.connection_config.resolve(a.allocator(), missing, "/workspace", &env));
}
