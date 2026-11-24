const std = @import("std");
const builtin = @import("builtin");
const foo = @import("foo");
const tools = @import("tools");
const support = @import("support");

const testing = std.testing;
const cwd = if (builtin.os.tag == .windows) "C:\\editor" else "/editor";
const path = if (builtin.os.tag == .windows) "C:\\editor\\buffer.txt" else "/editor/buffer.txt";
const session: foo.events.SessionId = @fromBackingInt(3);
const run: foo.events.RunId = @fromBackingInt(4);
const terminal: foo.host.CommandId = @fromBackingInt(5);

const Editor = struct {
    clock: support.Clock = .{},
    cancellation: foo.io.Cancellation = .{},
    approved: bool = false,
    ask: usize = 0,
    reads: usize = 0,
    writes: usize = 0,
    launches: usize = 0,
    releases: usize = 0,
    disconnect_write: bool = false,
    cancel_wait: bool = false,
    disconnect_release: bool = false,

    fn operation(self: *Editor) foo.io.Context {
        return .{ .io = testing.io, .clock = self.clock.interface(), .cancellation = &self.cancellation };
    }

    fn options(self: *Editor) tools.Options {
        return .{
            .spawner = .{ .context = self, .spawn_fn = unexpectedSpawn },
            .session = session,
            .run = run,
            .generation = 1,
            .host = .{
                .capabilities = .{ .read_file = true, .write_file = true, .terminal = true },
                .files = .{ .context = self, .read_fn = read, .write_fn = write },
                .processes = .{ .context = self, .start_fn = start, .output_fn = output, .wait_fn = wait, .kill_fn = kill, .release_fn = release },
                .permissions = .{ .context = self, .decide_fn = decide },
            },
            .builtins = .{ .environment = &.{.{ .name = "MODE", .value = "fixed" }}, .file_bytes = 256 },
        };
    }

    fn unexpectedSpawn(_: *anyopaque, _: std.mem.Allocator, _: foo.io.Context, _: foo.io.Spawn) foo.io.Error!foo.io.Child {
        @panic("client command reached the local spawner");
    }

    fn decide(raw: *anyopaque, op: foo.io.Context, prepared: foo.host.PreparedOperation) foo.io.Error!foo.host.Decision {
        try op.check();
        const self: *Editor = @ptrCast(@alignCast(raw));
        self.ask += 1;
        if (prepared.session != session or prepared.run != run or prepared.targets.len != 1) return error.InvalidInput;
        const expected_target = if (std.mem.eql(u8, prepared.invocation.call.name, "exec")) "fixture" else path;
        if (!std.mem.eql(u8, expected_target, prepared.targets[0])) return error.InvalidInput;
        return if (self.approved) .allow_once else .deny_once;
    }

    fn read(raw: *anyopaque, allocator: std.mem.Allocator, op: foo.io.Context, id: foo.events.SessionId, file: []const u8, max_bytes: usize) foo.io.Error![]const u8 {
        try op.check();
        const self: *Editor = @ptrCast(@alignCast(raw));
        self.reads += 1;
        if (id != session or max_bytes != 256 or !std.mem.eql(u8, file, path)) return error.InvalidInput;
        return allocator.dupe(u8, "unsaved editor text");
    }

    fn write(raw: *anyopaque, op: foo.io.Context, id: foo.events.SessionId, file: []const u8, content: []const u8) foo.io.Error!void {
        try op.check();
        const self: *Editor = @ptrCast(@alignCast(raw));
        self.writes += 1;
        if (id != session or !std.mem.eql(u8, file, path) or !std.mem.eql(u8, content, "replacement")) return error.InvalidInput;
        if (self.disconnect_write) return error.Disconnected;
    }

    fn start(raw: *anyopaque, op: foo.io.Context, command: foo.host.Command) foo.io.Error!foo.host.CommandId {
        try op.check();
        const self: *Editor = @ptrCast(@alignCast(raw));
        self.launches += 1;
        if (op.deadline_ms == null or !std.mem.eql(u8, command.cwd, cwd) or command.argv.len != 2 or
            !std.mem.eql(u8, command.argv[0], "fixture") or !std.mem.eql(u8, command.argv[1], "with spaces") or
            command.environment.len != 1 or !std.mem.eql(u8, command.environment[0].name, "MODE") or
            !std.mem.eql(u8, command.environment[0].value, "fixed")) return error.InvalidInput;
        return terminal;
    }

    fn wait(raw: *anyopaque, op: foo.io.Context, id: foo.host.CommandId) foo.io.Error!foo.host.CommandStatus {
        const self: *Editor = @ptrCast(@alignCast(raw));
        if (id != terminal) return error.InvalidInput;
        if (self.cancel_wait) self.cancellation.request();
        try op.check();
        return .{ .exited = 0 };
    }

    fn output(_: *anyopaque, allocator: std.mem.Allocator, op: foo.io.Context, id: foo.host.CommandId, offset: u64, max_bytes: usize) foo.io.Error!foo.host.CommandOutput {
        try op.check();
        if (id != terminal or offset != 0 or max_bytes < 12) return error.InvalidInput;
        return .{ .bytes = try allocator.dupe(u8, "editor output"), .truncated = true };
    }

    fn kill(_: *anyopaque, _: foo.io.Context, _: foo.host.CommandId) foo.io.Error!void {
        return error.Unavailable;
    }

    fn release(raw: *anyopaque, op: foo.io.Context, id: foo.host.CommandId) foo.io.Error!void {
        try op.check();
        const self: *Editor = @ptrCast(@alignCast(raw));
        if (id != terminal or op.cancellation == &self.cancellation or op.deadline_ms == null) return error.InvalidInput;
        self.releases += 1;
        if (self.disconnect_release) return error.Disconnected;
    }
};

fn settings(enabled: []const []const u8) foo.config.Resolved {
    return .{
        .model = .{ .family = .openai_chat, .id = "fixture", .endpoint = "http://fixture" },
        .cwd = cwd,
        .permissions = .ask,
        .files_backend = .client,
        .process_backend = .client,
        .enabled_tools = enabled,
        .limits = .{ .tool_output_bytes = 512 },
    };
}

fn invoke(editor: *Editor, registry: *tools.Registry, a: std.mem.Allocator, name: []const u8, arguments: []const u8) !foo.tool.Result {
    const api = registry.interface();
    for (api.declarations) |decl| {
        if (std.mem.eql(u8, name, decl.spec.name)) return api.invoke_fn(api.context, a, editor.operation(), .{
            .declaration = decl,
            .call = .{ .id = "client-call", .name = name, .arguments_json = arguments },
        });
    }
    return error.MissingTool;
}

test "client file tools validate and authorize before operating on editor content" {
    var editor: Editor = .{};
    var registry = try tools.Registry.init(testing.allocator, settings(&.{ "read", "write" }), &.{}, editor.options());
    defer registry.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const denied = try invoke(&editor, &registry, a, "read", "{\"path\":\"buffer.txt\"}");
    try testing.expectEqual(.denied, denied.status);
    try testing.expectEqual(0, editor.reads);
    const invalid = try invoke(&editor, &registry, a, "write", "{\"path\":\"buffer.txt\",\"content\":null}");
    try testing.expectEqual(.failure, invalid.status);
    try testing.expectEqual(1, editor.ask);
    try testing.expectEqual(0, editor.writes);

    editor.approved = true;
    const read = try invoke(&editor, &registry, a, "read", "{\"path\":\"buffer.txt\",\"offset\":8,\"max_bytes\":6}");
    try testing.expectEqual(.success, read.status);
    try testing.expectEqual(.observed, read.effect);
    try testing.expect(read.truncated);
    const parsed = try std.json.parseFromSliceLeaky(struct { content: []const u8, total_bytes: usize, sha256: []const u8 }, a, read.content, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("editor", parsed.content);
    try testing.expectEqual(19, parsed.total_bytes);
    try testing.expectEqualStrings("c3276b1ca2031f24c08cc2316e2563aaf39df72860bac12d24c768c02a499903", parsed.sha256);

    const input = "{\"path\":\"buffer.txt\",\"content\":\"replacement\"}";
    const written = try invoke(&editor, &registry, a, "write", input);
    try testing.expectEqual(.success, written.status);
    try testing.expectEqual(.observed, written.effect);
    editor.disconnect_write = true;
    const disconnected = try invoke(&editor, &registry, a, "write", input);
    try testing.expectEqual(.failure, disconnected.status);
    try testing.expectEqual(.uncertain, disconnected.effect);
    try testing.expectEqual(2, editor.writes);
}

test "client terminal preserves argv and releases on success cancellation and disconnect" {
    var editor: Editor = .{ .approved = true };
    var registry = try tools.Registry.init(testing.allocator, settings(&.{"exec"}), &.{}, editor.options());
    defer registry.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = "{\"argv\":[\"fixture\",\"with spaces\"]}";

    const succeeded = try invoke(&editor, &registry, a, "exec", input);
    try testing.expectEqual(.success, succeeded.status);
    try testing.expectEqual(.observed, succeeded.effect);
    try testing.expect(succeeded.truncated);
    try testing.expect(succeeded.content.len <= 512);
    try testing.expect(std.mem.indexOf(u8, succeeded.content, "editor output") != null);
    editor.disconnect_release = true;
    const disconnected = try invoke(&editor, &registry, a, "exec", input);
    try testing.expectEqual(.failure, disconnected.status);
    try testing.expectEqual(.uncertain, disconnected.effect);
    editor.disconnect_release = false;
    editor.cancel_wait = true;
    const cancelled = try invoke(&editor, &registry, a, "exec", input);
    try testing.expectEqual(.cancelled, cancelled.status);
    try testing.expectEqual(.uncertain, cancelled.effect);
    try testing.expectEqual(3, editor.launches);
    try testing.expectEqual(3, editor.releases);
}

test "unsupported client tools cannot be enabled and disabled tools require no adapters" {
    var editor: Editor = .{};
    var no_backend = editor.options();
    no_backend.host = .{};
    try testing.expectError(error.Unavailable, tools.Registry.init(testing.allocator, settings(&.{"read"}), &.{}, no_backend));
    try testing.expectError(error.Unavailable, tools.Registry.init(testing.allocator, settings(&.{"edit"}), &.{}, editor.options()));
    try testing.expectError(error.Unavailable, tools.Registry.init(testing.allocator, settings(&.{"custom"}), &.{.{
        .name = "custom",
        .description = "",
        .schema_json = "{\"type\":\"object\"}",
        .argv = &.{"fixture"},
    }}, editor.options()));
    var inherited = editor.options();
    inherited.builtins.?.inherit_environment = true;
    try testing.expectError(error.Unavailable, tools.Registry.init(testing.allocator, settings(&.{"exec"}), &.{}, inherited));
    var registry = try tools.Registry.init(testing.allocator, settings(&.{}), &.{}, no_backend);
    defer registry.deinit();
    try testing.expectEqual(0, registry.interface().declarations.len);
}
