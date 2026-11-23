const std = @import("std");
const foo = @import("foo");
const mcp = @import("mcp");
const catalog = mcp.catalog;
const wire = mcp.link;

pub const modern: foo.config.McpRevision = .@"2026-07-28";
pub const legacy: foo.config.McpRevision = .@"2025-11-25";

pub const Step = struct {
    method: []const u8,
    cursor: ?[]const u8 = null,
    name: ?[]const u8 = null,
    headers: []const foo.io.Header = &.{},
    params_field: ?[]const u8 = null,
    params_json: []const u8 = "",
    reply: union(enum) {
        accepted,
        success: []const u8,
        rpc: i32,
        disconnect,
        deadline,
        unsent,
    },
};

pub const Script = struct {
    revision: foo.config.McpRevision,
    steps: []const Step,
    used: usize = 0,
    requests: usize = 0,
    observer: ?wire.Observer = null,
    capabilities: []const u8 = "{\"tools\":{\"listChanged\":true}}",
    connected: bool = false,

    pub fn client(self: *Script) !mcp.client.Client {
        return mcp.client.Client.init(.{ .context = self, .exchange_fn = exchange, .shutdown_fn = shutdown }, .{
            .server_id = "office.lab",
            .revision = self.revision,
        });
    }

    fn exchange(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        operation: foo.io.Context,
        request: wire.Request,
        observer: ?wire.Observer,
        delivery: *foo.io.Delivery,
    ) wire.Error!wire.Reply {
        const self: *Script = @ptrCast(@alignCast(ctx));
        require(request.revision == self.revision) catch return error.IoFailure;
        const parsed = try self.requestParams(allocator, request);
        if (observer) |watch| self.observer = watch;
        delivery.* = .possibly_sent;
        if (!self.connected) {
            self.requests += 1;
            if (self.revision == modern) {
                try checkString("server/discover", request.method);
                self.connected = true;
                return .{ .success = try std.fmt.allocPrint(allocator, "{{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{s}}}", .{self.capabilities}) };
            }
            if (std.mem.eql(u8, request.method, "initialize")) {
                const value = parsed.get("protocolVersion") orelse return error.IoFailure;
                require(value == .string) catch return error.IoFailure;
                try checkString("2025-11-25", value.string);
                return .{ .success = try std.fmt.allocPrint(allocator, "{{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{s}}}", .{self.capabilities}) };
            }
            try checkString("notifications/initialized", request.method);
            require(request.id == null) catch return error.IoFailure;
            self.connected = true;
            return .accepted;
        }
        try operation.check();
        if (self.used >= self.steps.len) {
            std.debug.print("Unexpected MCP request {s}\n", .{request.method});
            return error.IoFailure;
        }
        const step = self.steps[self.used];
        self.used += 1;
        try checkString(step.method, request.method);
        const cursor = parsed.get("cursor");
        if (step.cursor) |expected| {
            require(cursor != null and cursor.? == .string) catch return error.IoFailure;
            try checkString(expected, cursor.?.string);
        } else require(cursor == null) catch return error.IoFailure;
        if (step.name) |expected| {
            try checkString(expected, request.name orelse return error.IoFailure);
            const value = parsed.get(if (std.mem.eql(u8, request.method, "resources/read")) "uri" else "name") orelse
                return error.IoFailure;
            require(value == .string) catch return error.IoFailure;
            try checkString(expected, value.string);
        } else require(request.name == null) catch return error.IoFailure;
        require(request.headers.len == step.headers.len) catch return error.IoFailure;
        for (step.headers, request.headers) |expected, actual| {
            try checkString(expected.name, actual.name);
            try checkString(expected.value, actual.value);
        }
        if (step.params_field) |field| {
            const value = parsed.get(field) orelse return error.IoFailure;
            const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
            try checkString(step.params_json, bytes);
        }
        return switch (step.reply) {
            .accepted => .accepted,
            .success => |value| .{ .success = try allocator.dupe(u8, value) },
            .rpc => |code| .{ .failure = .{ .code = code, .message = "remote diagnostic" } },
            .disconnect => error.Disconnected,
            .deadline => error.DeadlineExceeded,
            .unsent => {
                delivery.* = .unsent;
                return error.IoFailure;
            },
        };
    }

    fn requestParams(self: *Script, allocator: std.mem.Allocator, request: wire.Request) wire.Error!std.json.ObjectMap {
        const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, request.body, .{ .parse_numbers = false }) catch
            return error.MalformedPeer;
        require(value == .object) catch return error.IoFailure;
        const params = value.object.get("params") orelse return error.MalformedPeer;
        require(params == .object) catch return error.IoFailure;
        const metadata = params.object.get("_meta");
        if (self.revision == modern) {
            require(metadata != null and metadata.? == .object) catch return error.IoFailure;
            const version = metadata.?.object.get("io.modelcontextprotocol/protocolVersion") orelse return error.IoFailure;
            require(version == .string) catch return error.IoFailure;
            try checkString("2026-07-28", version.string);
        } else require(metadata == null) catch return error.IoFailure;
        return params.object;
    }

    fn shutdown(_: *anyopaque, _: foo.io.Context) wire.Error!void {}

    pub fn changed(self: *Script, operation: foo.io.Context) !void {
        const observer = self.observer orelse return error.IoFailure;
        try observer.notify_fn(observer.context, operation, .{ .id = null, .method = "notifications/tools/list_changed" });
    }
};

pub const Op = struct {
    cancellation: foo.io.Cancellation = .{},
    time: u64 = 0,

    pub fn get(self: *Op) foo.io.Context {
        return .{ .io = std.testing.io, .cancellation = &self.cancellation, .clock = .{ .context = self, .now_fn = now } };
    }

    fn now(ctx: *anyopaque) u64 {
        const self: *Op = @ptrCast(@alignCast(ctx));
        return self.time;
    }
};

pub fn options(aliases: []const []const u8) catalog.Options {
    return .{
        .enabled_aliases = aliases,
        .generation = 42,
        .session = @fromBackingInt(@intCast(1)),
        .run = @fromBackingInt(@intCast(5)),
        .permission_mode = .allow,
    };
}

pub fn listStep(result: []const u8) Step {
    return .{ .method = "tools/list", .reply = .{ .success = result } };
}

pub fn callStep(result: []const u8) Step {
    return .{ .method = "tools/call", .name = "lookup.v1", .reply = .{ .success = result } };
}

fn require(value: bool) !void {
    try std.testing.expect(value);
}

fn checkString(expected: []const u8, actual: []const u8) error{IoFailure}!void {
    std.testing.expectEqualStrings(expected, actual) catch return error.IoFailure;
}

fn invoke(
    registry: *catalog.Registry,
    allocator: std.mem.Allocator,
    operation: foo.io.Context,
    declaration: foo.tool.Declaration,
    arguments: []const u8,
) !foo.tool.Result {
    const api = registry.interface();
    return api.invoke_fn(api.context, allocator, operation, .{
        .declaration = declaration,
        .call = .{ .id = "call1", .name = declaration.spec.name, .arguments_json = arguments },
    });
}

const lookup_alias = "mcp_office_lab_lookup_v1";
const lookup = "{\"name\":\"lookup.v1\",\"description\":\"Lookup\",\"inputSchema\":{\"type\":\"object\"}}";
const alternate = "{\"name\":\"alternate\",\"inputSchema\":{\"type\":\"object\"}}";
const lookup_list = "{\"resultType\":\"complete\",\"tools\":[" ++ lookup ++ "]}";
const empty = "{\"resultType\":\"complete\",\"tools\":[]}";
const success = "{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}";
const test_allocator = std.testing.allocator;

test "tools follow an empty continuation cursor and dispatch only the enabled identity in both profiles" {
    for ([_]foo.config.McpRevision{ modern, legacy }) |revision| {
        const complete = if (revision == modern) "\"resultType\":\"complete\"," else "";
        const first = try std.fmt.allocPrint(test_allocator, "{{{s}\"tools\":[{s}],\"nextCursor\":\"\"}}", .{ complete, alternate });
        defer test_allocator.free(first);
        const last = try std.fmt.allocPrint(test_allocator, "{{{s}\"tools\":[{s}]}}", .{ complete, lookup });
        defer test_allocator.free(last);
        const response = try std.fmt.allocPrint(test_allocator, "{{{s}\"content\":[{{\"type\":\"text\",\"text\":\"done\"}}]}}", .{complete});
        defer test_allocator.free(response);
        var script: Script = .{ .revision = revision, .steps = &.{
            listStep(first),
            .{ .method = "tools/list", .cursor = "", .reply = .{ .success = last } },
            callStep(response),
        } };
        var op: Op = .{};
        var client = try script.client();
        var registry = try catalog.Registry.init(test_allocator, op.get(), &client, options(&.{lookup_alias}));
        defer registry.deinit();
        const api = registry.interface();
        try std.testing.expectEqual(@as(usize, 1), api.declarations.len);
        const declaration = api.declarations[0];
        try std.testing.expectEqualStrings("mcp", declaration.identity.backend);
        try std.testing.expectEqualStrings("office.lab", declaration.identity.server.?);
        try std.testing.expectEqualStrings("lookup.v1", declaration.identity.name);
        try std.testing.expectEqualStrings(lookup_alias, declaration.spec.name);
        try std.testing.expectEqual(@as(u64, 42), declaration.generation);
        var result_arena: std.heap.ArenaAllocator = .init(test_allocator);
        defer result_arena.deinit();
        const memory = result_arena.allocator();
        const disabled = try api.invoke_fn(api.context, memory, op.get(), .{
            .declaration = declaration,
            .call = .{ .id = "bad", .name = "mcp_office_lab_alternate", .arguments_json = "{}" },
        });
        try std.testing.expectEqual(.catalog_changed, disabled.status);
        try std.testing.expectEqual(.not_started, disabled.effect);
        var stale = declaration;
        stale.generation += 1;
        try std.testing.expectEqual(.catalog_changed, (try invoke(&registry, memory, op.get(), stale, "{}")).status);
        const result = try invoke(&registry, memory, op.get(), declaration, "{}");
        try std.testing.expectEqual(.success, result.status);
        try std.testing.expectEqual(.observed, result.effect);
        try std.testing.expectEqualStrings("{\"content\":[{\"type\":\"text\",\"text\":\"done\"}],\"isError\":false}", result.content);
        try std.testing.expectEqual(script.steps.len, script.used);
        try std.testing.expectEqual(@as(usize, if (revision == modern) 1 else 2), script.requests);
    }
}

test "tool discovery rejects repeated cursors, empty progress, alias collisions, and bounded refresh exhaustion" {
    const first = "{\"resultType\":\"complete\",\"tools\":[" ++ lookup ++ "],\"nextCursor\":\"\"}";
    const repeats = "{\"resultType\":\"complete\",\"tools\":[" ++ alternate ++ "],\"nextCursor\":\"\"}";
    const repeats_under_new_cursor = "{\"resultType\":\"complete\",\"tools\":[" ++ lookup ++ "],\"nextCursor\":\"new\"}";
    const no_progress = "{\"resultType\":\"complete\",\"tools\":[],\"nextCursor\":\"unused\"}";
    const alias_collision = "{\"resultType\":\"complete\",\"tools\":[" ++ lookup ++ ",{\"name\":\"lookup_v1\",\"inputSchema\":{\"type\":\"object\"}}]}";
    const Case = struct { steps: []const Step, err: catalog.Error, pages: usize = 128, bytes: usize = 16_000, reserved: []const []const u8 = &.{} };
    const cases = [_]Case{
        .{ .steps = &.{ listStep(first), .{ .method = "tools/list", .cursor = "", .reply = .{ .success = repeats } } }, .err = error.MalformedPeer },
        .{ .steps = &.{ listStep(first), .{ .method = "tools/list", .cursor = "", .reply = .{ .success = repeats_under_new_cursor } } }, .err = error.MalformedPeer },
        .{ .steps = &.{listStep(no_progress)}, .err = error.MalformedPeer },
        .{ .steps = &.{listStep(alias_collision)}, .err = error.AliasCollision },
        .{ .steps = &.{listStep(lookup_list)}, .err = error.AliasCollision, .reserved = &.{lookup_alias} },
        .{ .steps = &.{listStep(first)}, .err = error.LimitExceeded, .pages = 1 },
        .{ .steps = &.{listStep(lookup_list)}, .err = error.LimitExceeded, .bytes = 80 },
    };
    for (cases) |item| {
        var script: Script = .{ .revision = modern, .steps = item.steps };
        var op: Op = .{};
        var client = try script.client();
        var config = options(&.{lookup_alias});
        config.limits.catalog_pages = item.pages;
        config.limits.catalog_bytes = item.bytes;
        config.reserved_aliases = item.reserved;
        try std.testing.expectError(item.err, catalog.Registry.init(test_allocator, op.get(), &client, config));
        try std.testing.expectEqual(script.steps.len, script.used);
    }
}

test "long deterministic aliases obey provider limits and distinguish identities with a common prefix" {
    const server = "a-very-long-server.0123456789.0123456789.0123456789.0123456789.0123456789";
    const first = try catalog.providerAlias(test_allocator, server, "search");
    defer test_allocator.free(first);
    const again = try catalog.providerAlias(test_allocator, server, "search");
    defer test_allocator.free(again);
    const second = try catalog.providerAlias(test_allocator, server, "select");
    defer test_allocator.free(second);
    try std.testing.expectEqual(@as(usize, 64), first.len);
    try std.testing.expectEqualStrings(first, again);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    for (first) |char| try std.testing.expect(std.ascii.isAlphanumeric(char) or char == '-' or char == '_');
}

test "tool arguments are validated exactly and nested HTTP header values are mirrored as raw primitives" {
    const tool_spec =
        \\{"resultType":"complete","tools":[{"name":"lookup.v1","inputSchema":{"type":"object","required":["flags","items"],
        \\"additionalProperties":false,"properties":{
        \\"flags":{"type":"object","properties":{"region":{"type":"string","minLength":2,"x-mcp-header":"Region"},
        \\"dry":{"type":"boolean","x-mcp-header":"Dry"},"count":{"type":"integer","minimum":2,"x-mcp-header":"Count"}}},
        \\"items":{"type":"array","minItems":1,"items":{"anyOf":[{"enum":["ready"]},{"const":9007199254740993}]}}}}}]}
    ;
    const expected = "[\"ready\",9007199254740993]";
    const input = "{\"flags\":{\"region\":\" λ \",\"dry\":false,\"count\":2.000e0},\"items\":" ++ expected ++ "}";
    var step = callStep(success);
    step.headers = &.{
        .{ .name = "Mcp-Param-Region", .value = " λ " },
        .{ .name = "Mcp-Param-Dry", .value = "false" },
        .{ .name = "Mcp-Param-Count", .value = "2" },
    };
    step.params_field = "arguments";
    step.params_json = input;
    var script: Script = .{ .revision = modern, .steps = &.{ listStep(tool_spec), step } };
    var op: Op = .{};
    var client = try script.client();
    var registry = try catalog.Registry.init(test_allocator, op.get(), &client, options(&.{lookup_alias}));
    defer registry.deinit();
    const declaration = registry.interface().declarations[0];
    var arena: std.heap.ArenaAllocator = .init(test_allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    for ([_][]const u8{
        "{}",
        "{\"flags\":{},\"items\":[]}",
        "{\"flags\":{},\"items\":[9007199254740992]}",
        "{\"flags\":{\"region\":\"λ\"},\"items\":[\"ready\"]}",
        "{\"flags\":{\"count\":9007199254740992},\"items\":[\"ready\"]}",
        "{\"flags\":{\"count\":1.999999999999999999},\"items\":[\"ready\"]}",
        "{\"flags\":{},\"items\":[\"ready\"],\"items\":[\"ready\"]}",
        "{\"flags\":{},\"items\":[\"ready\"],\"extra\":true}",
    }) |candidate| {
        const result = try invoke(&registry, memory, op.get(), declaration, candidate);
        try std.testing.expectEqual(.failure, result.status);
        try std.testing.expectEqual(.not_started, result.effect);
    }
    try std.testing.expectEqual(@as(usize, 1), script.used);
    const result = try invoke(&registry, memory, op.get(), declaration, input);
    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqual(script.steps.len, script.used);
}

test "an invalid modern header declaration is excluded and unknown validating keywords fail closed" {
    var op: Op = .{};
    const invalid =
        "{\"resultType\":\"complete\",\"tools\":[" ++ lookup ++ ",{\"name\":\"bad\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"number\",\"x-mcp-header\":\"Unsafe\"}}}}]}";
    var script: Script = .{ .revision = modern, .steps = &.{listStep(invalid)} };
    var client = try script.client();
    var registry = try catalog.Registry.init(test_allocator, op.get(), &client, options(&.{ lookup_alias, "mcp_office_lab_bad" }));
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 1), registry.interface().declarations.len);

    const unsupported =
        "{\"resultType\":\"complete\",\"tools\":[{\"name\":\"lookup.v1\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"q\":{\"pattern\":\"x\"}}}}]}";
    var other: Script = .{ .revision = modern, .steps = &.{listStep(unsupported)} };
    var other_client = try other.client();
    try std.testing.expectError(error.UnsupportedSchema, catalog.Registry.init(test_allocator, op.get(), &other_client, options(&.{lookup_alias})));
}

const Approval = struct {
    script: *Script,
    registry: ?*catalog.Registry = null,
    op: *Op,
    change: enum { notify, refresh, revoke, cancel, deny },
    asked: usize = 0,

    fn handler(self: *Approval) foo.host.PermissionHandler {
        return .{ .context = self, .decide_fn = decide };
    }

    fn decide(ctx: *anyopaque, operation: foo.io.Context, prepared: foo.host.PreparedOperation) foo.io.Error!foo.host.Decision {
        const self: *Approval = @ptrCast(@alignCast(ctx));
        self.asked += 1;
        require(prepared.session == @as(foo.events.SessionId, @fromBackingInt(@intCast(1)))) catch return error.IoFailure;
        require(prepared.run == @as(foo.events.RunId, @fromBackingInt(@intCast(5)))) catch return error.IoFailure;
        require(prepared.operation_id == 1) catch return error.IoFailure;
        try checkString(lookup_alias, prepared.invocation.call.name);
        try checkString("{}", prepared.invocation.call.arguments_json);
        try checkString("office.lab", prepared.targets[0]);
        try checkString("lookup.v1", prepared.targets[1]);
        switch (self.change) {
            .notify => self.script.changed(operation) catch return error.IoFailure,
            .refresh => self.registry.?.refresh(operation) catch return error.IoFailure,
            .revoke => require(self.registry.?.revoke(lookup_alias)) catch return error.IoFailure,
            .cancel => self.op.cancellation.request(),
            .deny => return .deny_once,
        }
        return .allow_once;
    }
};

test "permission approval cannot dispatch a removed, replaced, revoked, or cancelled tool" {
    const replaced =
        "{\"resultType\":\"complete\",\"tools\":[{\"name\":\"lookup.v1\",\"inputSchema\":{\"type\":\"object\",\"required\":[\"new\"]}}]}";
    const Case = struct { change: @FieldType(Approval, "change"), next: ?Step = null, status: foo.tool.Status = .catalog_changed };
    for ([_]Case{
        .{ .change = .notify, .next = listStep(replaced) },
        .{ .change = .refresh, .next = listStep(empty) },
        .{ .change = .revoke },
        .{ .change = .cancel, .status = .cancelled },
        .{ .change = .deny, .status = .denied },
    }) |item| {
        const steps = [_]Step{ listStep(lookup_list), item.next orelse listStep(empty) };
        var script: Script = .{ .revision = modern, .steps = steps[0..if (item.next != null) 2 else 1] };
        var op: Op = .{};
        var client = try script.client();
        var approval: Approval = .{ .script = &script, .op = &op, .change = item.change };
        var config = options(&.{lookup_alias});
        config.permission_mode = .ask;
        config.permissions = approval.handler();
        var registry = try catalog.Registry.init(test_allocator, op.get(), &client, config);
        defer registry.deinit();
        approval.registry = &registry;
        const declaration = registry.interface().declarations[0];
        var arena: std.heap.ArenaAllocator = .init(test_allocator);
        defer arena.deinit();
        const result = try invoke(&registry, arena.allocator(), op.get(), declaration, "{}");
        try std.testing.expectEqual(item.status, result.status);
        try std.testing.expectEqual(.not_started, result.effect);
        try std.testing.expectEqual(@as(usize, 1), approval.asked);
        try std.testing.expectEqualStrings("{\"type\":\"object\"}", registry.interface().declarations[0].spec.schema_json);
        try std.testing.expectEqual(script.steps.len, script.used);
    }
}

test "catalog refresh keeps unchanged declarations active and defers additions to a new run" {
    const addition = "{\"resultType\":\"complete\",\"tools\":[" ++ alternate ++ "," ++ lookup ++ "]}";
    var script: Script = .{ .revision = modern, .steps = &.{
        listStep(lookup_list),
        listStep(addition),
        callStep(success),
        listStep(addition),
    } };
    var op: Op = .{};
    var client = try script.client();
    var config = options(&.{ lookup_alias, "mcp_office_lab_alternate" });
    var registry = try catalog.Registry.init(test_allocator, op.get(), &client, config);
    defer registry.deinit();
    var arena: std.heap.ArenaAllocator = .init(test_allocator);
    defer arena.deinit();
    const declaration = registry.interface().declarations[0];
    try script.changed(op.get());
    try std.testing.expectEqual(.success, (try invoke(&registry, arena.allocator(), op.get(), declaration, "{}")).status);
    try std.testing.expectEqual(@as(usize, 1), registry.interface().declarations.len);
    config.generation += 1;
    var next = try catalog.Registry.init(test_allocator, op.get(), &client, config);
    defer next.deinit();
    try std.testing.expectEqual(@as(usize, 2), next.interface().declarations.len);
    try std.testing.expectEqual(script.steps.len, script.used);
}

test "tool results preserve mixed content and exact JSON while separating tool errors from RPC and lost effects" {
    const mixed =
        \\{"resultType":"complete","content":[{"type":"text","text":"a"},{"type":"image","mimeType":"image/png","data":"Yg=="},
        \\{"type":"audio","mimeType":"audio/wav","data":"Yw=="},{"type":"resource_link","uri":"https://example.test/asset","name":"asset"},
        \\{"type":"resource","resource":{"uri":"file:///x","mimeType":"text/plain","text":"x"}}],
        \\"structuredContent":{"sequence":9007199254740993,"payload":[false,null]}}
    ;
    const is_error = "{\"resultType\":\"complete\",\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"failed\"}]}";
    var script: Script = .{ .revision = modern, .steps = &.{
        listStep(lookup_list),
        callStep(mixed),
        callStep(is_error),
        callStep("{\"resultType\":\"input_required\",\"inputRequests\":[],\"requestState\":\"opaque-sensitive-state\"}"),
        .{ .method = "tools/call", .name = "lookup.v1", .reply = .{ .rpc = -32603 } },
        .{ .method = "tools/call", .name = "lookup.v1", .reply = .disconnect },
        .{ .method = "tools/call", .name = "lookup.v1", .reply = .deadline },
        .{ .method = "tools/call", .name = "lookup.v1", .reply = .unsent },
    } };
    var op: Op = .{};
    var client = try script.client();
    var registry = try catalog.Registry.init(test_allocator, op.get(), &client, options(&.{lookup_alias}));
    defer registry.deinit();
    var arena: std.heap.ArenaAllocator = .init(test_allocator);
    defer arena.deinit();
    const declaration = registry.interface().declarations[0];
    const memory = arena.allocator();
    const response = try invoke(&registry, memory, op.get(), declaration, "{}");
    try std.testing.expectEqual(.success, response.status);
    try std.testing.expectEqual(.observed, response.effect);
    for ([_][]const u8{ "image/png", "audio/wav", "https://example.test/asset", "file:///x", "9007199254740993" }) |data|
        try std.testing.expect(std.mem.indexOf(u8, response.content, data) != null);
    const failed = try invoke(&registry, memory, op.get(), declaration, "{}");
    try std.testing.expectEqual(.failure, failed.status);
    try std.testing.expectEqual(.observed, failed.effect);
    try std.testing.expect(std.mem.indexOf(u8, failed.content, "\"isError\":true") != null);
    const unsupported = try invoke(&registry, memory, op.get(), declaration, "{}");
    try std.testing.expectEqual(.failure, unsupported.status);
    try std.testing.expectEqual(.uncertain, unsupported.effect);
    try std.testing.expectEqualStrings("MCP tool request requires an unsupported capability", unsupported.content);
    const rpc = try invoke(&registry, memory, op.get(), declaration, "{}");
    try std.testing.expectEqual(.failure, rpc.status);
    try std.testing.expectEqual(.uncertain, rpc.effect);
    try std.testing.expect(std.mem.indexOf(u8, rpc.content, "JSON-RPC error") != null);
    try std.testing.expectEqual(.uncertain, (try invoke(&registry, memory, op.get(), declaration, "{}")).effect);
    const timed_out = try invoke(&registry, memory, op.get(), declaration, "{}");
    try std.testing.expectEqual(.cancelled, timed_out.status);
    try std.testing.expectEqual(.uncertain, timed_out.effect);
    try std.testing.expectEqual(.not_started, (try invoke(&registry, memory, op.get(), declaration, "{}")).effect);
    try std.testing.expectEqual(script.steps.len, script.used);
}

test "tool output honors the provider limit without returning partial JSON" {
    var op: Op = .{};
    var script: Script = .{ .revision = modern, .steps = &.{ listStep(lookup_list), callStep(success) } };
    var client = try script.client();
    var config = options(&.{lookup_alias});
    config.limits.tool_output_bytes = 18;
    var registry = try catalog.Registry.init(test_allocator, op.get(), &client, config);
    defer registry.deinit();
    var arena: std.heap.ArenaAllocator = .init(test_allocator);
    defer arena.deinit();
    const result = try invoke(&registry, arena.allocator(), op.get(), registry.interface().declarations[0], "{}");
    try std.testing.expectEqual(.observed, result.effect);
    try std.testing.expect(result.truncated);
    try std.testing.expectEqualStrings("{\"truncated\":true}", result.content);
}
