const std = @import("std");
const foo = @import("foo");
const acp = @import("acp");
const io = foo.io;
const host = foo.host;
const provider = foo.provider;
const events = foo.events;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var factory: Fixture = .{};
    var limits: acp.Limits = .{};
    for (args[1..]) |arg| {
        if (same(arg, "--short")) {
            limits.reverse_ms = 150;
            limits.shutdown_ms = 350;
        } else if (same(arg, "--short-turn")) {
            limits.turn_ms = 250;
        } else if (same(arg, "--small")) {
            limits.frame_bytes = 4096;
            limits.terminal_bytes = 1024;
            limits.history_bytes = 4096;
            limits.sessions = 2;
        } else if (same(arg, "--slow-open")) {
            factory.slow_open = true;
        } else if (same(arg, "--auth")) {
            factory.auth_required = true;
        } else return error.InvalidArguments;
    }
    const report = try acp.serveStdio(init.gpa, init.io, .{
        .factory = .{ .context = &factory, .open_fn = Fixture.open },
        .limits = limits,
    });
    if (report.remote_cleanup_unconfirmed != 0) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "unconfirmed remote terminal cleanup\n");
    }
}

const Fixture = struct {
    slow_open: bool = false,
    auth_required: bool = false,

    fn open(context: *anyopaque, allocator: std.mem.Allocator, op: io.Context, args: acp.OpenInput) acp.OpenError!acp.Runtime {
        const self: *Fixture = @ptrCast(@alignCast(context));
        try op.check();
        if (self.auth_required) return error.AuthenticationRequired;
        if (self.slow_open) try pause(op);
        if (args.editor_servers.len != 0) {
            if (args.editor_servers.len != 1) return error.InvalidInput;
            const descriptor = args.editor_servers[0];
            if (descriptor.transport != .stdio or !same(descriptor.id, "fixture")) return error.InvalidInput;
            const stdio = descriptor.transport.stdio;
            if (stdio.argv.len != 2 or !same(stdio.argv[0], "mock-mcp") or !same(stdio.argv[1], "--mock"))
                return error.InvalidInput;
        }
        const session = try allocator.create(FakeSession);
        session.* = .{ .host = args.client, .mcp = args.editor_servers.len != 0 };
        return .{
            .context = session,
            .runner = .{ .context = session, .run_fn = FakeSession.run },
            .settings = .{
                .cwd = args.cwd,
                .model = .{ .family = .openai_responses, .endpoint = "fixture", .id = "fixture" },
                .files_backend = .client,
                .process_backend = .client,
            },
            .prepare_fn = FakeSession.prepare,
        };
    }
};

const FakeSession = struct {
    host: host.Host,
    mcp: bool,

    fn prepare(context: *anyopaque, _: std.mem.Allocator, op: io.Context, _: events.RunId) io.Error!acp.RunServices {
        try op.check();
        const self: *FakeSession = @ptrCast(@alignCast(context));
        return .{
            .tools = .{ .context = self, .declarations = &.{}, .invoke_fn = unusedTool },
            .services = .{ .host = self.host, .provider = .{ .context = self, .stream_fn = unusedProvider } },
        };
    }

    fn run(context: *anyopaque, allocator: std.mem.Allocator, op: io.Context, input: host.RunInput, sink: events.Sink) io.Error!events.Outcome {
        const self: *FakeSession = @ptrCast(@alignCast(context));
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const temporary = arena.allocator();
        var turn: Turn = .{ .op = op, .input = input, .sink = sink };
        const latest = input.messages[input.messages.len - 1];
        try turn.commit(latest);
        const prompt = latest.blocks[0].text;
        if (same(prompt, "wait")) {
            try turn.delta("ready");
            try pause(op);
        } else if (same(prompt, "history")) {
            var count: usize = 0;
            for (input.messages[0 .. input.messages.len - 1]) |message| {
                if (message.role == .user) count += 1;
            }
            try turn.text(try std.fmt.allocPrint(temporary, "history {d}", .{count}));
        } else if (same(prompt, "resource-link")) {
            if (latest.blocks.len != 2) return error.InvalidInput;
            try turn.text(latest.blocks[1].text);
        } else if (same(prompt, "tools")) {
            try turn.toolStart(.{ .id = "tool-1", .name = "test", .arguments_json = "{}" });
            try turn.toolEnd("tool-1", .success, "done");
        } else if (same(prompt, "permission")) {
            const path = try std.fs.path.join(temporary, &.{ input.settings.cwd, "note.txt" });
            const call: provider.ToolCall = .{
                .id = "permission-1",
                .name = "exec",
                .arguments_json = "{\"argv\":[\"fake-command\",\"--check\"]}",
            };
            try turn.toolStart(call);
            const permission = input.services.host.permissions.?;
            const decision = permission.decide_fn(permission.context, op, .{
                .session = input.session,
                .run = input.run,
                .operation_id = @backingInt(input.run),
                .invocation = .{
                    .declaration = .{
                        .identity = .{ .backend = "builtin", .name = "exec" },
                        .generation = 1,
                        .spec = .{ .name = "exec", .description = "", .schema_json = "{}" },
                    },
                    .call = call,
                },
                .targets = &.{ "fake-command", path },
            }) catch |err| if (err == error.Cancelled) .cancelled else return err;
            try turn.toolEnd(call.id, switch (decision) {
                .allow_once => .success,
                .deny_once => .denied,
                .cancelled => .cancelled,
            }, switch (decision) {
                .allow_once => "approved",
                .deny_once => "denied",
                .cancelled => "cancelled",
            });
        } else if (same(prompt, "read") or same(prompt, "write")) {
            const files = input.services.host.files orelse return error.Unavailable;
            const path = try std.fs.path.join(temporary, &.{ input.settings.cwd, "note.txt" });
            if (same(prompt, "read")) {
                const contents = try files.read_fn(files.context, temporary, op, input.session, path, 1024);
                try turn.text(contents);
            } else {
                try files.write_fn(files.context, op, input.session, path, "edited 世界");
            }
        } else if (same(prompt, "terminal") or same(prompt, "terminal-offset")) {
            const shell = input.services.host.processes orelse return error.Unavailable;
            const id = try shell.start_fn(shell.context, op, .{ .argv = &.{ "fake-command", "--check" }, .cwd = input.settings.cwd });
            var offset: u64 = 0;
            if (same(prompt, "terminal-offset")) {
                const prefix = try shell.output_fn(shell.context, temporary, op, id, 0, 6);
                try turn.text(prefix.bytes);
                offset = prefix.bytes.len;
            }
            const output = try shell.output_fn(shell.context, temporary, op, id, offset, 1024);
            const status = try shell.wait_fn(shell.context, op, id);
            if (status != .exited or status.exited != 0) return error.IoFailure;
            try shell.release_fn(shell.context, op, id);
            try turn.text(output.bytes);
        } else if (same(prompt, "refusal")) {
            return turn.finish(.{ .reason = .provider_error, .provider_stop = .refusal });
        } else if (same(prompt, "limit")) {
            return turn.finish(.{ .reason = .limit_reached, .provider_stop = .output_limit });
        } else if (same(prompt, "other-limit")) {
            return turn.finish(.{ .reason = .limit_reached });
        } else if (same(prompt, "mcp")) {
            try turn.text(if (self.mcp) "editor MCP delegated" else "no editor MCP");
        } else if (same(prompt, "spam")) {
            var payload: [2048]u8 = undefined;
            @memset(&payload, 'A');
            for (0..500) |_| try turn.delta(&payload);
        } else {
            try turn.text("hello 世界");
        }

        return turn.finish(if (op.cancellation.requested.load(.acquire))
            .{ .reason = .cancelled }
        else
            .{ .reason = .completed, .provider_stop = .end_turn });
    }
};

const Turn = struct {
    op: io.Context,
    input: host.RunInput,
    sink: events.Sink,
    sequence: u64 = 0,

    fn emit(self: *Turn, data: @FieldType(events.Event, "data")) io.Error!void {
        try self.sink.emit_fn(self.sink.context, self.op, .{ .run = self.input.run, .data = data });
    }

    fn commit(self: *Turn, message: provider.Message) io.Error!void {
        self.sequence += 1;
        try self.emit(.{ .message_committed = .{ .sequence = self.sequence, .message = message } });
    }

    fn delta(self: *Turn, value: []const u8) io.Error!void {
        try self.emit(.{ .delta = .{ .text = value } });
    }

    fn text(self: *Turn, value: []const u8) io.Error!void {
        try self.delta(value);
        try self.commit(.{ .role = .assistant, .blocks = &.{.{ .text = value }} });
    }

    fn toolStart(self: *Turn, call: provider.ToolCall) io.Error!void {
        try self.commit(.{ .role = .assistant, .blocks = &.{.{ .tool_call = call }} });
    }

    fn toolEnd(self: *Turn, id: []const u8, status: foo.tool.Status, content: []const u8) io.Error!void {
        self.sequence += 1;
        try self.emit(.{ .tool_committed = .{ .sequence = self.sequence, .result = .{
            .call_id = id,
            .status = status,
            .content = content,
            .effect = if (status == .success) .observed else .not_started,
        } } });
    }

    fn finish(self: *Turn, outcome: events.Outcome) io.Error!events.Outcome {
        try self.emit(.{ .finished = outcome });
        return outcome;
    }
};

fn pause(op: io.Context) io.Error!void {
    try op.check();
    op.io.sleep(.fromSeconds(60), .awake) catch return error.Cancelled;
    try op.check();
}

fn same(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

fn unusedTool(_: *anyopaque, _: std.mem.Allocator, _: io.Context, _: foo.tool.Invocation) io.Error!foo.tool.Result {
    return error.Unavailable;
}

fn unusedProvider(_: *anyopaque, _: std.mem.Allocator, _: io.Context, _: provider.Request, _: provider.Sink, _: *io.Delivery) provider.Error!provider.Response {
    return error.Unavailable;
}
