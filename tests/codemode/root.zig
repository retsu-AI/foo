const std = @import("std");
const foo = @import("foo");
const codemode = @import("codemode");
const tools = @import("tools");
const session = @import("session");
const core = @import("core");
const testing = std.testing;
const io = testing.io;

const settings_default: foo.config.Resolved = .{
    .model = .{ .family = .openai_responses, .endpoint = "test", .id = "model" },
    .cwd = ".",
};
const empty: []const foo.tool.Declaration = &.{};
const demo: foo.tool.Declaration = .{
    .generation = 3,
    .identity = .{ .backend = "fixture", .name = "invoke" },
    .spec = .{ .name = "invoke", .description = "A fixture tool", .schema_json = "{\"type\":\"object\"}" },
};

const Fixture = struct {
    arena: std.heap.ArenaAllocator = .init(testing.allocator),
    token: foo.io.Cancellation = .{},
    effects: usize = 0,
    verdict: enum { success, denied, uncertain, incorrect_id } = .success,

    fn mutable(self: *Fixture) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
    }

    fn operation(self: *Fixture) foo.io.Context {
        return .{ .io = io, .cancellation = &self.token, .clock = .{ .context = self, .now_fn = now } };
    }

    fn now(_: *anyopaque) u64 {
        return @intCast(std.Io.Clock.awake.now(io).toMilliseconds());
    }

    fn script(self: *Fixture, mode: *codemode.Registry, code: []const u8) !foo.tool.Result {
        const registry = mode.interface();
        const declaration = registry.declarations[registry.declarations.len - 1];
        const arguments = try std.json.Stringify.valueAlloc(self.mutable(), .{ .code = code }, .{});
        const result = try registry.invoke_fn(registry.context, self.mutable(), self.operation(), .{
            .declaration = declaration,
            .call = .{ .name = codemode.name, .id = "parent", .arguments_json = arguments },
        });
        return result;
    }

    fn backend(self: *Fixture, declarations: []const foo.tool.Declaration) foo.tool.Registry {
        return .{ .context = self, .declarations = declarations, .invoke_fn = invoke };
    }

    fn invoke(context: *anyopaque, allocator: std.mem.Allocator, op: foo.io.Context, invocation: foo.tool.Invocation) foo.io.Error!foo.tool.Result {
        const self: *Fixture = @ptrCast(@alignCast(context));
        try op.check();
        if (self.verdict != .denied) self.effects += 1;
        return .{
            .call_id = try allocator.dupe(u8, if (self.verdict == .incorrect_id) "other" else invocation.call.id),
            .status = if (self.verdict == .denied) .denied else .success,
            .effect = switch (self.verdict) {
                .denied => .not_started,
                .uncertain => .uncertain,
                else => .observed,
            },
            .content = "verified",
        };
    }
};

test "Pi-style await, return, discovery, and sealed catalog use the underlying registry" {
    var f: Fixture = .{};
    defer f.deinit();
    var mode = try codemode.Registry.init(testing.allocator, f.backend(&.{demo}), .{ .generation = 1 });
    defer mode.deinit();
    const result = try f.script(&mode,
        \\if (Object.getPrototypeOf(tools) !== null ||
        \\    ALL_TOOLS.length !== 1 || ALL_TOOLS[0].name !== 'invoke' ||
        \\    typeof tools.codemode !== 'undefined') throw Error('catalog');
        \\text((await tools.invoke({})).content);
        \\return '雪';
    );
    try testing.expectEqual(.success, result.status);
    try testing.expectEqual(.observed, result.effect);
    try testing.expectEqualStrings("verified\n雪", result.content);
    try testing.expectEqual(@as(usize, 1), f.effects);
}

test "an observed effect survives a later script exception" {
    var f: Fixture = .{};
    defer f.deinit();
    var mode = try codemode.Registry.init(testing.allocator, f.backend(&.{demo}), .{ .generation = 1 });
    defer mode.deinit();
    const result = try f.script(&mode, "await tools.invoke({}); throw Error('late');");
    try testing.expectEqual(.failure, result.status);
    try testing.expectEqual(.observed, result.effect);
    try testing.expectEqual(@as(usize, 1), f.effects);
}

test "an uncertain child stops subsequent effects even if JavaScript catches the error" {
    for ([_]@FieldType(Fixture, "verdict"){ .uncertain, .incorrect_id }) |verdict| {
        var f: Fixture = .{ .verdict = verdict };
        defer f.deinit();
        var mode = try codemode.Registry.init(testing.allocator, f.backend(&.{demo}), .{ .generation = 1 });
        defer mode.deinit();
        const result = try f.script(&mode, "try { await tools.invoke({}); } catch {} await tools.invoke({});");
        try testing.expect(result.status != .success);
        try testing.expectEqual(.uncertain, result.effect);
        try testing.expectEqual(@as(usize, 1), f.effects);
    }
}

test "denial and explicit absence reach no underlying effects" {
    var f: Fixture = .{ .verdict = .denied };
    defer f.deinit();
    var mode = try codemode.Registry.init(testing.allocator, f.backend(&.{demo}), .{ .generation = 1 });
    defer mode.deinit();
    const denied = try f.script(&mode, "return (await tools.invoke({})).status;");
    try testing.expectEqual(.success, denied.status);
    try testing.expectEqual(.not_started, denied.effect);
    try testing.expectEqualStrings("denied", denied.content);
    const absent = try f.script(&mode, "return tools.write({path:'no',content:'no'});");
    try testing.expectEqual(.failure, absent.status);
    try testing.expectEqual(.not_started, absent.effect);
    try testing.expectEqual(@as(usize, 0), f.effects);
}

test "outer, nested, and ordinary calls share a bounded run budget" {
    var f: Fixture = .{};
    defer f.deinit();
    var mode = try codemode.Registry.init(testing.allocator, f.backend(&.{demo}), .{
        .generation = 1,
        .run_limits = .{ .tool_calls = 4 },
    });
    defer mode.deinit();
    const registry = mode.interface();
    const direct: foo.tool.Invocation = .{ .declaration = demo, .call = .{ .id = "direct", .name = demo.spec.name, .arguments_json = "{}" } };
    try testing.expectEqual(.success, (try registry.invoke_fn(registry.context, f.mutable(), f.operation(), direct)).status);
    const nested = try f.script(&mode, "await tools.invoke({}); await tools.invoke({}); await tools.invoke({});");
    try testing.expectEqual(.failure, nested.status);
    try testing.expectEqual(.observed, nested.effect);
    try testing.expectEqual(@as(usize, 3), f.effects);
    try testing.expectEqual(.not_started, (try registry.invoke_fn(registry.context, f.mutable(), f.operation(), direct)).effect);
    try testing.expectEqual(@as(usize, 3), f.effects);
}

test "CPU deadline, heap, pending jobs, output and cancellation are bounded" {
    var f: Fixture = .{};
    defer f.deinit();
    var mode = try codemode.Registry.init(testing.allocator, f.backend(empty), .{
        .generation = 1,
        .limits = .{ .timeout_ms = 750, .memory_bytes = 2 * 1024 * 1024, .max_jobs = 12 },
        .run_limits = .{ .tool_output_bytes = 64 },
    });
    defer mode.deinit();
    for ([_][]const u8{
        "await new Promise(() => {});",
        "for (;;) await Promise.resolve();",
        "const a = []; for(let i=0;i<4_000_000;i++) a.push(i);",
        "function loop() { loop(); } loop();",
    }) |code| {
        const result = try f.script(&mode, code);
        try testing.expectEqual(.failure, result.status);
        try testing.expectEqual(.not_started, result.effect);
    }
    const spin = try f.script(&mode, "while (true) {}");
    try testing.expectEqual(.cancelled, spin.status);
    try testing.expectEqual(.not_started, spin.effect);
    const output = try f.script(&mode, "return '雪'.repeat(1000);");
    try testing.expect(output.truncated);
    try testing.expect(output.content.len <= 64);
    try testing.expect(std.unicode.utf8ValidateSlice(output.content));
    f.token.request();
    try testing.expectEqual(.cancelled, (try f.script(&mode, "text('never');")).status);
}

test "realm has no ambient I/O and does not carry state to the next invocation" {
    var f: Fixture = .{};
    defer f.deinit();
    var mode = try codemode.Registry.init(testing.allocator, f.backend(empty), .{ .generation = 1 });
    defer mode.deinit();
    const first = try f.script(&mode,
        \\for (const name of ['process','require','std','os','fetch','XMLHttpRequest','setTimeout','WebAssembly'])
        \\  if (globalThis[name] !== undefined) throw Error(name);
        \\globalThis.marker = 1;
        \\return 'done';
    );
    try testing.expectEqual(.success, first.status);
    try testing.expectEqualStrings("done", first.content);
    try testing.expectEqualStrings("undefined", (try f.script(&mode, "return typeof globalThis.marker;")).content);
    const imported = try f.script(&mode, "await import('os');");
    try testing.expectEqual(.failure, imported.status);
}

test "serialization hooks and detached jobs cannot dispatch unexpected effects" {
    var f: Fixture = .{};
    defer f.deinit();
    var mode = try codemode.Registry.init(testing.allocator, f.backend(&.{demo}), .{ .generation = 1 });
    defer mode.deinit();
    const serialization = try f.script(&mode,
        \\try { return tools.invoke({ toJSON() { tools.invoke({}); return {}; } }); } catch {}
    );
    try testing.expectEqual(.not_started, serialization.effect);
    const detached = try f.script(&mode, "Promise.resolve().then(() => tools.invoke({})); return 'done';");
    try testing.expectEqual(.success, detached.status);
    try testing.expectEqualStrings("done", detached.content);
    try testing.expectEqual(@as(usize, 0), f.effects);
}

test "Code Mode name collision fails before any tool can be dispatched" {
    var f: Fixture = .{};
    defer f.deinit();
    var collision = demo;
    collision.spec.name = codemode.name;
    try testing.expectError(error.InvalidInput, codemode.Registry.init(testing.allocator, f.backend(&.{collision}), .{ .generation = 1 }));
    try testing.expectEqual(@as(usize, 0), f.effects);
}

const Compose = struct {
    args: []const u8,
    calls: usize = 0,
    permissions: usize = 0,
    outputs: usize = 0,

    fn spawn(_: *anyopaque, _: std.mem.Allocator, _: foo.io.Context, _: foo.io.Spawn) foo.io.Error!foo.io.Child {
        return error.Unavailable;
    }

    fn decide(context: *anyopaque, operation: foo.io.Context, request: foo.host.PreparedOperation) foo.io.Error!foo.host.Decision {
        const self: *Compose = @ptrCast(@alignCast(context));
        try operation.check();
        if (request.operation_id != self.permissions + 1 or request.invocation.call.id.len != 64 or request.targets.len != 1)
            return error.InvalidInput;
        self.permissions += 1;
        return .allow_once;
    }

    fn stream(context: *anyopaque, allocator: std.mem.Allocator, operation: foo.io.Context, request: foo.provider.Request, _: foo.provider.Sink, delivery: *foo.io.Delivery) foo.provider.Error!foo.provider.Response {
        const self: *Compose = @ptrCast(@alignCast(context));
        try operation.check();
        self.calls += 1;
        delivery.* = .possibly_sent;
        if (self.calls == 1) {
            if (request.tools.len != 3) return error.Protocol;
            const assistant: foo.provider.Message = .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{
                .name = codemode.name,
                .id = "outer",
                .arguments_json = self.args,
            } }} };
            return .{ .message = try foo.provider.copyMessage(allocator, assistant), .stop = .tool_use };
        }
        if (self.calls != 2 or request.messages.len != 3) return error.Protocol;
        const last = request.messages[2];
        if (last.role != .tool or last.blocks.len != 1 or last.blocks[0] != .tool_result) return error.Protocol;
        const result = last.blocks[0].tool_result;
        if (result.is_error or !std.mem.eql(u8, result.call_id, "outer") or !std.mem.eql(u8, result.content, "sum=7"))
            return error.Protocol;
        return .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = "complete" }} }, .stop = .end_turn };
    }

    fn observe(context: *anyopaque, _: foo.io.Context, event: foo.events.Event) foo.io.Error!void {
        const self: *Compose = @ptrCast(@alignCast(context));
        if (event.data == .tool_committed) {
            const result = event.data.tool_committed.result;
            if (!std.mem.eql(u8, result.call_id, "outer") or result.effect != .observed) return error.InvalidInput;
            self.outputs += 1;
        }
    }
};

test "real file tools compose through the core with exact permissions and durable nested records" {
    var f: Fixture = .{};
    defer f.deinit();
    const a = f.mutable();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const cwd = try tmp.parent_dir.realPathFileAlloc(io, &tmp.sub_path, a);
    try tmp.dir.writeFile(io, .{ .sub_path = "left.txt", .data = "left=3\r\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "right.txt", .data = "4" });
    const args = try std.json.Stringify.valueAlloc(a, .{ .code =
        \\const left = JSON.parse((await tools.read({path:'left.txt'})).content);
        \\const right = JSON.parse((await tools.read({path:'right.txt'})).content);
        \\const total = Number(left.content.split('=')[1]) + Number(right.content);
        \\const result = await tools.edit({path:'left.txt', expected_sha256:left.sha256,
        \\  replacements:[{old:'left=3',new:'left=' + total}]});
        \\if (result.status !== 'success') throw Error(result.content);
        \\return 'sum=' + total;
    }, .{});
    var compose: Compose = .{ .args = args };
    var settings = settings_default;
    settings.cwd = cwd;
    settings.enabled_tools = &.{ "read", "edit" };
    settings.permissions = .ask;
    var base = try tools.Registry.init(testing.allocator, settings, &.{}, .{
        .spawner = .{ .context = &compose, .spawn_fn = Compose.spawn },
        .session = @fromBackingInt(@intCast(1)),
        .run = @fromBackingInt(@intCast(1)),
        .generation = 11,
        .permissions = .{ .context = &compose, .decide_fn = Compose.decide },
        .builtins = .{},
    });
    defer base.deinit();
    {
        var store = try session.Store.create(testing.allocator, io, tmp.dir, "code-mode-fixture", .{});
        defer store.deinit();
        var mode = try codemode.Registry.init(testing.allocator, base.interface(), .{
            .generation = 12,
            .store = store.interface(),
        });
        defer mode.deinit();
        var engine: core.Engine = .{};
        const result = try engine.run(testing.allocator, f.operation(), .{
            .session = @fromBackingInt(@intCast(1)),
            .run = @fromBackingInt(@intCast(1)),
            .settings = settings,
            .messages = &.{.{ .role = .user, .blocks = &.{.{ .text = "Sum the files." }} }},
            .tools = mode.interface(),
            .services = .{ .provider = .{ .context = &compose, .stream_fn = Compose.stream }, .store = store.interface() },
        }, .{ .context = &compose, .emit_fn = Compose.observe });
        try testing.expectEqual(.completed, result.outcome.reason);
    }
    try testing.expectEqual(@as(usize, 3), compose.permissions);
    try testing.expectEqual(@as(usize, 1), compose.outputs);
    try testing.expectEqual(@as(usize, 2), compose.calls);
    try testing.expectEqualStrings("left=7\r\n", try tmp.dir.readFileAlloc(io, "left.txt", a, .limited(64)));

    var reopened = try session.Store.open(testing.allocator, io, tmp.dir, "code-mode-fixture", .{});
    defer reopened.deinit();
    const recovered = try reopened.load(a, f.operation());
    try testing.expectEqual(@as(usize, 4), recovered.messages.len);
    try testing.expectEqual(@as(usize, 0), recovered.uncertain_call_ids.len);
    try testing.expectEqual(@as(u64, 13), recovered.last_sequence);
    const journal = try tmp.dir.readFileAlloc(io, "journal.jsonl", a, .limited(64 * 1024));
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, journal, "\"nested_tool\""));
}
