const std = @import("std");
const foo = @import("foo");
const tools = @import("tools");
const support = @import("support");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const echo: tools.Descriptor = .{
    .name = "echo",
    .description = "Echo text",
    .schema_json =
    \\{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}
    ,
    .argv = &.{ "fixture-tool", "--literal" },
};
const default_settings: foo.config.Resolved = .{
    .model = .{ .family = .openai_responses, .id = "fixture", .endpoint = "http://fixture" },
    .cwd = "run-cwd",
};
const enabled = [_][]const u8{"echo"};

const MockSpawner = struct {
    launches: usize = 0,
    argument_error: bool = false,
    stdin: [4096]u8 = undefined,
    stdin_len: usize = 0,
    stdout_offset: usize = 0,
    stdin_closed: bool = false,
    released: bool = false,
    expected_environment: []const foo.io.Environment = &.{},

    fn interface(self: *MockSpawner) foo.io.Spawner {
        return .{ .context = self, .spawn_fn = spawn };
    }

    fn spawn(context: *anyopaque, _: std.mem.Allocator, op: foo.io.Context, params: foo.io.Spawn) foo.io.Error!foo.io.Child {
        try op.check();
        const self: *MockSpawner = @ptrCast(@alignCast(context));
        self.launches += 1;
        self.stdin_len = 0;
        self.stdout_offset = 0;
        self.stdin_closed = false;
        self.released = false;
        self.argument_error = params.argv.len != 2 or !std.mem.eql(u8, params.argv[0], echo.argv[0]) or
            !std.mem.eql(u8, params.argv[1], echo.argv[1]) or !std.mem.eql(u8, params.cwd, default_settings.cwd) or
            params.inherit_environment or params.environment.len != self.expected_environment.len;
        if (!self.argument_error) {
            for (params.environment, self.expected_environment) |actual, expected| {
                if (!std.mem.eql(u8, actual.name, expected.name) or !std.mem.eql(u8, actual.value, expected.value))
                    self.argument_error = true;
            }
        }
        return .{
            .context = self,
            .stdin = .{ .context = self, .write_fn = writeInput },
            .stdout = .{ .context = self, .read_fn = readOutput },
            .stderr = .{ .context = self, .read_fn = empty },
            .close_stdin_fn = closeInput,
            .terminate_fn = terminate,
            .wait_fn = wait,
            .release_fn = release,
        };
    }

    fn writeInput(context: *anyopaque, op: foo.io.Context, bytes: []const u8) foo.io.Error!void {
        try op.check();
        const self: *MockSpawner = @ptrCast(@alignCast(context));
        if (bytes.len > self.stdin.len - self.stdin_len) return error.LimitExceeded;
        @memcpy(self.stdin[self.stdin_len..][0..bytes.len], bytes);
        self.stdin_len += bytes.len;
    }

    fn readOutput(context: *anyopaque, op: foo.io.Context, buffer: []u8) foo.io.Error!usize {
        try op.check();
        const self: *MockSpawner = @ptrCast(@alignCast(context));
        const reply = "{\"content\":\"accepted\",\"is_error\":false}";
        const size = @min(reply.len - self.stdout_offset, buffer.len);
        @memcpy(buffer[0..size], reply[self.stdout_offset..][0..size]);
        self.stdout_offset += size;
        return size;
    }

    fn empty(_: *anyopaque, _: foo.io.Context, _: []u8) foo.io.Error!usize {
        return 0;
    }

    fn closeInput(context: *anyopaque, _: foo.io.Context) foo.io.Error!void {
        const self: *MockSpawner = @ptrCast(@alignCast(context));
        self.stdin_closed = true;
    }

    fn terminate(_: *anyopaque, _: foo.io.Context) foo.io.Error!void {}

    fn wait(_: *anyopaque, _: foo.io.Context) foo.io.Error!foo.io.ProcessExit {
        return .{ .exited = 0 };
    }

    fn release(context: *anyopaque, _: foo.io.Context) foo.io.Error!void {
        const self: *MockSpawner = @ptrCast(@alignCast(context));
        self.released = true;
    }
};

const Fixture = struct {
    spawner: MockSpawner = .{},
    cancellation: foo.io.Cancellation = .{},
    clock: support.Clock = .{},

    fn options(self: *Fixture) tools.Options {
        return .{
            .spawner = self.spawner.interface(),
            .session = @fromBackingInt(@intCast(10)),
            .run = @fromBackingInt(@intCast(20)),
            .generation = 3,
        };
    }

    fn operation(self: *Fixture) foo.io.Context {
        return .{ .io = std.testing.io, .clock = self.clock.interface(), .cancellation = &self.cancellation };
    }

    fn invoke(self: *Fixture, registry: foo.tool.Registry, request: foo.tool.Invocation, status: foo.tool.Status) !void {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const result = try registry.invoke_fn(registry.context, arena.allocator(), self.operation(), request);
        try expectEqual(status, result.status);
        const effect: foo.tool.Effect = if (status == .success) .observed else .not_started;
        try expectEqual(effect, result.effect);
        try expectEqualStrings(request.call.id, result.call_id);
        if (status == .success) try expectEqualStrings("accepted", result.content);
    }
};

fn settings(mode: foo.config.PermissionMode) foo.config.Resolved {
    var resolved = default_settings;
    resolved.enabled_tools = &enabled;
    resolved.permissions = mode;
    return resolved;
}

fn invocation(declaration: foo.tool.Declaration, arguments_json: []const u8) foo.tool.Invocation {
    return .{
        .declaration = declaration,
        .call = .{ .id = "call-1", .name = declaration.spec.name, .arguments_json = arguments_json },
    };
}

test "the default catalog is empty and only selected descriptors can dispatch" {
    var fixture: Fixture = .{};
    var empty = try tools.Registry.init(std.testing.allocator, default_settings, &.{echo}, fixture.options());
    defer empty.deinit();
    try expectEqual(0, empty.interface().declarations.len);

    var other = echo;
    other.name = "other";
    var registry = try tools.Registry.init(std.testing.allocator, settings(.allow), &.{ other, echo }, fixture.options());
    defer registry.deinit();
    const interface = registry.interface();
    try expectEqual(1, interface.declarations.len);
    const declaration = interface.declarations[0];
    try expectEqualStrings(tools.backend, declaration.identity.backend);
    try expectEqual(null, declaration.identity.server);
    try expectEqualStrings(echo.name, declaration.identity.name);
    try expectEqualStrings(echo.name, declaration.spec.name);
    try expectEqualStrings(echo.description, declaration.spec.description);
    try expectEqualStrings(echo.schema_json, declaration.spec.schema_json);
    try expectEqual(@as(u64, 3), declaration.generation);
    try fixture.invoke(empty.interface(), invocation(declaration, "{}"), .catalog_changed);
    var disabled_call = invocation(declaration, "{}");
    disabled_call.call.name = other.name;
    try fixture.invoke(interface, disabled_call, .catalog_changed);
    try expect(!registry.revoke(other.name));
    try expectEqual(0, fixture.spawner.launches);
}

test "valid JSON reaches executable stdin exactly and launch parameters stay pinned" {
    var fixture: Fixture = .{};
    fixture.spawner.expected_environment = &.{.{ .name = "MODE", .value = "fixed" }};
    var cwd = default_settings.cwd[0..default_settings.cwd.len].*;
    var name = echo.name[0..echo.name.len].*;
    var argv1 = echo.argv[1][0..echo.argv[1].len].*;
    var env_value = "fixed".*;
    var schema_json = echo.schema_json[0..echo.schema_json.len].*;
    var descriptor = echo;
    descriptor.name = &name;
    descriptor.argv = &.{ echo.argv[0], &argv1 };
    descriptor.environment = &.{.{ .name = "MODE", .value = &env_value }};
    descriptor.schema_json = &schema_json;
    var resolved = settings(.allow);
    resolved.cwd = &cwd;
    var registry = try tools.Registry.init(std.testing.allocator, resolved, &.{descriptor}, fixture.options());
    defer registry.deinit();
    cwd[0] = 'z';
    name[0] = 'z';
    argv1[0] = 'z';
    env_value[0] = 'z';
    schema_json[0] = 'z';

    const interface = registry.interface();
    const args =
        \\{ "text" : "a quoted \"item\"; $(literal) & | * \\ \u2603" }
    ++ "\n";
    try fixture.invoke(interface, invocation(interface.declarations[0], args), .success);
    try expectEqual(1, fixture.spawner.launches);
    try expectEqualStrings(args, fixture.spawner.stdin[0..fixture.spawner.stdin_len]);
    try expect(!fixture.spawner.argument_error);
    try expect(fixture.spawner.stdin_closed);
    try expect(fixture.spawner.released);
}

test "missing malformed invalid oversized and too-deep arguments never start or request permission" {
    var fixture: Fixture = .{};
    var permission: Permission = .{};
    var options = fixture.options();
    options.permissions = permission.interface();
    var resolved = settings(.ask);
    resolved.limits.tool_argument_bytes = 80;
    resolved.limits.json_depth = 4;
    var registry = try tools.Registry.init(std.testing.allocator, resolved, &.{echo}, options);
    defer registry.deinit();
    const interface = registry.interface();

    for ([_][]const u8{
        "",                                              "{}",
        "[]",                                            "{",
        "{\"text\":false}",                              "{\"text\":\"\xff\"}",
        "{\"text\":\"present\",\"text\":\"duplicate\"}", "{\"text\":\"ok\",\"other\":1}",
        "{\"text\":\"ok\",\"extra\":[[[[{}]]]]}",        "{\"text\":\"" ++ "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++ "\"}",
    }) |args| try fixture.invoke(interface, invocation(interface.declarations[0], args), .failure);

    var missing_id = invocation(interface.declarations[0], "{\"text\":\"valid\"}");
    missing_id.call.id = "";
    try fixture.invoke(interface, missing_id, .failure);
    try expectEqual(0, permission.calls);
    try expectEqual(0, fixture.spawner.launches);
}

test "nested object and array rules validate exact integer values and open properties" {
    var fixture: Fixture = .{};
    var descriptor = echo;
    descriptor.schema_json =
        \\{
        \\    "type":"object",
        \\    "description":"Counts and flags",
        \\    "properties":{
        \\        "items":{"type":"array","items":{"type":"object","properties":{"count":{"type":"integer"},"enabled":{"type":"boolean"},"note":{"type":"null"},"weight":{"type":"number"}},"required":["count","enabled","note","weight"],"additionalProperties":false}}
        \\    },
        \\    "required":["items"]
        \\}
    ;
    var registry = try tools.Registry.init(std.testing.allocator, settings(.allow), &.{descriptor}, fixture.options());
    defer registry.deinit();
    const interface = registry.interface();
    const declaration = interface.declarations[0];
    try fixture.invoke(interface, invocation(declaration,
        \\{"items":[{"count":1.0,"enabled":false,"note":null,"weight":0.3},{"count":-1.23E+2,"enabled":true,"note":null,"weight":1.1E-1},{"count":-10e-1,"enabled":true,"note":null,"weight":1e8888888888888888888888888888888888888888},{"count":0e-8888888888888888888888888888888888888888,"enabled":true,"note":null,"weight":1}],"extra":"allowed"}
    ), .success);
    for ([_][]const u8{
        \\{"items":[{"count":1.230,"enabled":false,"note":null,"weight":1}]}
        ,
        \\{"items":[{"count":1e-8888888888888888888888888888888888888888,"enabled":false,"note":null,"weight":1}]}
        ,
        \\{"items":[{"count":1,"enabled":"false","note":null,"weight":1}]}
        ,
        \\{"items":[{"count":1,"enabled":false,"note":null,"weight":"1"}]}
        ,
        \\{"items":[{"count":1,"enabled":false,"note":null,"weight":1,"extra":null}]}
        ,
        \\{"items":[{"count":1,"enabled":false,"weight":1}]}
        ,
        \\{"items":{}}
        ,
    }) |args| try fixture.invoke(interface, invocation(declaration, args), .failure);
    try expectEqual(1, fixture.spawner.launches);
}

test "invalid configuration rejects unknown names duplicate names and unsupported schemas" {
    var fixture: Fixture = .{};
    const allocator = std.testing.allocator;
    const options = fixture.options();
    var resolved = settings(.allow);
    try expectError(error.InvalidInput, tools.Registry.init(allocator, resolved, &.{}, options));
    try expectError(error.InvalidInput, tools.Registry.init(allocator, resolved, &.{ echo, echo }, options));
    resolved.enabled_tools = &.{ "echo", "echo" };
    try expectError(error.InvalidInput, tools.Registry.init(allocator, resolved, &.{echo}, options));
    resolved = settings(.allow);
    resolved.limits.catalog_bytes = 32;
    try expectError(error.LimitExceeded, tools.Registry.init(allocator, resolved, &.{echo}, options));
    resolved = settings(.allow);
    for ([_][]const u8{
        \\{"type":"object","$ref":"https://untrusted.example/schema"}
        ,
        \\{"type":"object","properties":{"name":{"type":"string","pattern":"a"}}}
        ,
        \\{"type":"object","properties":{"name":{"type":["string","null"]}}}
        ,
        \\{"type":"object","additionalProperties":{"type":"string"}}
        ,
        \\{"type":"object","type":"object"}
        ,
        \\{"type":"object","required":["missing"]}
        ,
        \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name","name"]}
        ,
        \\{"type":"array","items":{"type":"string"}}
        ,
    }) |schema_json| {
        var descriptor = echo;
        descriptor.schema_json = schema_json;
        try expectError(error.InvalidInput, tools.Registry.init(allocator, resolved, &.{descriptor}, options));
    }
    var descriptor = echo;
    descriptor.argv = &.{ "fixture-tool", "embedded\x00nul" };
    try expectError(error.InvalidInput, tools.Registry.init(allocator, resolved, &.{descriptor}, options));
    try expectEqual(0, fixture.spawner.launches);
}

test "changed identity or declaration generation and revoked entries reject before launch" {
    var fixture: Fixture = .{};
    var registry = try tools.Registry.init(std.testing.allocator, settings(.allow), &.{echo}, fixture.options());
    defer registry.deinit();
    const interface = registry.interface();
    const declaration = interface.declarations[0];
    const args = "{\"text\":\"valid\"}";
    var changed = declaration;
    changed.identity.backend = "mcp";
    try fixture.invoke(interface, invocation(changed, args), .catalog_changed);
    changed = declaration;
    changed.identity.server = "different";
    try fixture.invoke(interface, invocation(changed, args), .catalog_changed);
    changed = declaration;
    changed.identity.name = "different";
    try fixture.invoke(interface, invocation(changed, args), .catalog_changed);
    changed = declaration;
    changed.spec.schema_json = "{\"type\":\"object\"}";
    try fixture.invoke(interface, invocation(changed, args), .catalog_changed);

    var options = fixture.options();
    options.generation += 1;
    var replacement = try tools.Registry.init(std.testing.allocator, settings(.allow), &.{echo}, options);
    defer replacement.deinit();
    try fixture.invoke(replacement.interface(), invocation(declaration, args), .catalog_changed);
    try expect(registry.revoke("echo"));
    try expectEqual(1, interface.declarations.len);
    try fixture.invoke(interface, invocation(declaration, args), .catalog_changed);
    try expectEqual(0, fixture.spawner.launches);
}

const Permission = struct {
    calls: u64 = 0,
    decision: foo.host.Decision = .deny_once,
    prepared: ?foo.host.PreparedOperation = null,
    id_buffer: [32]u8 = undefined,
    arguments_buffer: [128]u8 = undefined,
    source_input: ?[]u8 = null,
    revoking: ?*tools.Registry = null,
    cancellation: ?*foo.io.Cancellation = null,

    fn interface(self: *Permission) foo.host.PermissionHandler {
        return .{ .context = self, .decide_fn = decide };
    }

    fn decide(context: *anyopaque, _: foo.io.Context, prepared: foo.host.PreparedOperation) foo.io.Error!foo.host.Decision {
        const self: *Permission = @ptrCast(@alignCast(context));
        if (prepared.targets.len != 1 or !std.mem.eql(u8, prepared.targets[0], "fixture-tool"))
            return error.InvalidInput;
        self.calls += 1;
        const call = prepared.invocation.call;
        if (call.id.len > self.id_buffer.len or call.arguments_json.len > self.arguments_buffer.len)
            return error.LimitExceeded;
        @memcpy(self.id_buffer[0..call.id.len], call.id);
        @memcpy(self.arguments_buffer[0..call.arguments_json.len], call.arguments_json);
        self.prepared = prepared;
        self.prepared.?.targets = &.{};
        self.prepared.?.invocation.call.id = self.id_buffer[0..call.id.len];
        self.prepared.?.invocation.call.arguments_json = self.arguments_buffer[0..call.arguments_json.len];
        if (self.source_input) |input| input[0] = '!';
        if (self.revoking) |registry| {
            if (!registry.revoke(prepared.invocation.call.name)) return error.InvalidInput;
        }
        if (self.cancellation) |token| token.request();
        return self.decision;
    }
};

test "host permission is per invocation and a revocation during approval stops launch" {
    var fixture: Fixture = .{};
    var permission: Permission = .{};
    var options = fixture.options();
    options.permissions = permission.interface();
    var registry = try tools.Registry.init(std.testing.allocator, settings(.ask), &.{echo}, options);
    defer registry.deinit();
    const interface = registry.interface();
    const declaration = interface.declarations[0];
    const first = invocation(declaration, "{\"text\":\"first\"}");
    try fixture.invoke(interface, first, .denied);
    try expectEqual(0, fixture.spawner.launches);
    try expectEqual(options.session, permission.prepared.?.session);
    try expectEqual(options.run, permission.prepared.?.run);
    try expectEqual(options.generation, permission.prepared.?.invocation.declaration.generation);
    try expectEqualStrings(first.call.id, permission.prepared.?.invocation.call.id);
    try expectEqualStrings(first.call.arguments_json, permission.prepared.?.invocation.call.arguments_json);
    const first_id = permission.prepared.?.operation_id;

    const second_args = "{\"text\":\"second\"}";
    var original_input = second_args.*;
    var second = invocation(declaration, &original_input);
    second.call.id = "call-2";
    permission.source_input = &original_input;
    permission.decision = .allow_once;
    try fixture.invoke(interface, second, .success);
    try expectEqual(1, fixture.spawner.launches);
    try expect(first_id != permission.prepared.?.operation_id);
    try expectEqualStrings(second.call.id, permission.prepared.?.invocation.call.id);
    try expectEqual('!', original_input[0]);
    try expectEqualStrings(second_args, permission.prepared.?.invocation.call.arguments_json);
    try expectEqualStrings(second_args, fixture.spawner.stdin[0..fixture.spawner.stdin_len]);

    var third = invocation(declaration, "{\"text\":\"third\"}");
    third.call.id = "call-3";
    permission.revoking = &registry;
    try fixture.invoke(interface, third, .catalog_changed);
    try expectEqual(1, fixture.spawner.launches);
    try expectEqual(3, permission.calls);
}

test "deny ask without a handler and cancellation stop before spawning" {
    var fixture: Fixture = .{};
    for ([_]foo.config.PermissionMode{ .deny, .ask }) |mode| {
        var registry = try tools.Registry.init(std.testing.allocator, settings(mode), &.{echo}, fixture.options());
        defer registry.deinit();
        const interface = registry.interface();
        try fixture.invoke(interface, invocation(interface.declarations[0], "{\"text\":\"valid\"}"), .denied);
    }

    var permission: Permission = .{ .decision = .allow_once, .cancellation = &fixture.cancellation };
    var options = fixture.options();
    options.permissions = permission.interface();
    var registry = try tools.Registry.init(std.testing.allocator, settings(.ask), &.{echo}, options);
    defer registry.deinit();
    const interface = registry.interface();
    const call = invocation(interface.declarations[0], "{\"text\":\"valid\"}");
    try fixture.invoke(interface, call, .cancelled);
    try expectEqual(1, permission.calls);
    try fixture.invoke(interface, call, .cancelled);
    try expectEqual(1, permission.calls);
    try expectEqual(0, fixture.spawner.launches);
}

test "an explicitly installed builtin and a custom descriptor share one catalog" {
    var fixture: Fixture = .{};
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try directory.dir.realPath(std.testing.io, &cwd_buffer);
    var resolved = settings(.allow);
    resolved.cwd = cwd_buffer[0..cwd_len];
    resolved.enabled_tools = &.{ "write", "echo" };
    const no_preset = fixture.options();
    try expectError(error.InvalidInput, tools.Registry.init(allocator, resolved, &.{echo}, no_preset));
    var options = no_preset;
    options.builtins = .{};
    var registry = try tools.Registry.init(allocator, resolved, &.{echo}, options);
    defer registry.deinit();

    const interface = registry.interface();
    try expectEqual(2, interface.declarations.len);
    try expectEqualStrings("builtin", interface.declarations[0].identity.backend);
    try expectEqualStrings(tools.backend, interface.declarations[1].identity.backend);
    const result = try interface.invoke_fn(interface.context, allocator, fixture.operation(), invocation(
        interface.declarations[0],
        "{\"path\":\"new file.txt\",\"content\":\"hello\\r\\n\"}",
    ));
    try expectEqual(.success, result.status);
    try expectEqual(.observed, result.effect);
    const bytes = try directory.dir.readFileAlloc(std.testing.io, "new file.txt", allocator, .limited(16));
    try expectEqualStrings("hello\r\n", bytes);
    try expectEqual(0, fixture.spawner.launches);

    resolved.files_backend = .client;
    try expectError(error.Unavailable, tools.Registry.init(allocator, resolved, &.{echo}, options));
}
