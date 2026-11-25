const std = @import("std");
const foo = @import("foo");
const core = @import("core");
const tui = @import("tui");

pub fn main(init: std.process.Init) !void {
    var arguments = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer arguments.deinit();
    _ = arguments.skip();
    var fixture: Fixture = .{
        .marker = init.environ_map.get("FOO_TUI_TEST_MARKER"),
    };
    const cancellation: foo.io.Cancellation = .{};
    var clock = init.io;
    const context: foo.io.Context = .{
        .io = init.io,
        .cancellation = &cancellation,
        .clock = .{ .context = &clock, .now_fn = now },
    };
    var engine: core.Engine = .{};
    var options: tui.Options = .{
        .runner = engine.runner(),
        .input = .{
            .session = @fromBackingInt(@intCast(1)),
            .run = @fromBackingInt(@intCast(1)),
            .settings = .{
                .model = .{ .family = .openai_responses, .endpoint = "https://fixture.invalid", .id = "fixture" },
                .cwd = ".",
            },
            .messages = &.{},
            .tools = .{ .context = &fixture, .declarations = &declarations, .invoke_fn = Fixture.invoke },
            .services = .{ .provider = .{ .context = &fixture, .stream_fn = Fixture.reply } },
        },
        .environ = init.environ_map,
    };
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--keys")) {
            options.settings.keys = .{ .submit = .@"ctrl+enter", .newline = .enter, .cancel = .@"ctrl+d", .quit = .@"ctrl+c" };
            options.settings.colors = .{ .assistant = .green, .tool = .magenta, .@"error" = .bright_red, .status = .cyan };
        } else if (std.mem.eql(u8, argument, "--plain")) {
            options.plain = true;
        } else if (std.mem.eql(u8, argument, "--no-color")) {
            options.no_color = true;
        } else if (std.mem.eql(u8, argument, "--small-budget")) {
            options.input.settings.limits.transcript_bytes = 1024;
        } else return error.InvalidArgument;
    }
    const outcome = tui.run(init.gpa, context, options) catch |err| switch (err) {
        error.Cancelled => std.process.exit(130),
        error.LimitExceeded => std.process.exit(2),
        else => return err,
    };
    if (options.plain) {
        if (outcome) |result| {
            if (result.reason != .completed) std.process.exit(1);
        }
    }
}

fn now(context: *anyopaque) u64 {
    const io: *std.Io = @ptrCast(@alignCast(context));
    return @intCast(@max(0, std.Io.Clock.awake.now(io.*).toMilliseconds()));
}

const declarations = [_]foo.tool.Declaration{.{
    .identity = .{ .backend = "fixture", .name = "fixture" },
    .spec = .{ .name = "fixture", .description = "Fixture tool", .schema_json = "{}" },
    .generation = 1,
}};

const Fixture = struct {
    marker: ?[]const u8,
    tool_number: usize = 0,

    fn note(self: *const Fixture, io: std.Io, bytes: []const u8) void {
        const path = self.marker orelse return;
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch @panic("fixture marker write failed");
    }

    fn reply(
        context: *anyopaque,
        a: std.mem.Allocator,
        operation: foo.io.Context,
        request: foo.provider.Request,
        sink: foo.provider.Sink,
        delivery: *foo.io.Delivery,
    ) foo.provider.Error!foo.provider.Response {
        const self: *Fixture = @ptrCast(@alignCast(context));
        delivery.* = .possibly_sent;
        const last = request.messages[request.messages.len - 1];
        if (last.role == .tool) return finish(a, operation, sink, "tool complete");
        const prompt = last.blocks[0].text;
        if (std.mem.eql(u8, prompt, "slow")) {
            self.note(operation.io, "started");
            const answer = slow(a, operation, sink) catch |err| {
                self.note(operation.io, "stopped");
                return err;
            };
            self.note(operation.io, "completed");
            return response(a, answer);
        }
        if (std.mem.eql(u8, prompt, "pressure")) {
            self.note(operation.io, "started");
            defer self.note(operation.io, "stopped");
            const chunk = "pressure: 0123456789abcdefghijklmnopqrstuvwxyz\n";
            while (true) {
                try sink.emit(operation, .{ .text = chunk });
                try sleep(operation, 2);
            }
        }
        if (std.mem.eql(u8, prompt, "tools")) {
            self.tool_number += 1;
            const id = if (self.tool_number == 1) "fixture-call" else try std.fmt.allocPrint(a, "fixture-call-{d}", .{self.tool_number});
            const blocks = try a.dupe(foo.provider.Block, &.{.{ .tool_call = .{
                .id = id,
                .name = "fixture",
                .arguments_json = "{}",
            } }});
            return .{ .message = .{ .role = .assistant, .blocks = blocks }, .stop = .tool_use };
        }
        if (std.mem.eql(u8, prompt, "failure")) {
            try sink.emit(operation, .{ .text = "provisional only" });
            try sleep(operation, 200);
            if (sink.failure) |failure| failure.status = 400;
            return error.Rejected;
        }
        if (std.mem.eql(u8, prompt, "controls"))
            return finish(a, operation, sink, "safe-start\x1b]2;fixture-title\x07\xc2\x9b31m\x1b[6nsafe-end");
        if (std.mem.eql(u8, prompt, "long")) {
            var answer: std.ArrayList(u8) = .empty;
            for (0..200) |index| {
                var buf: [40]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "line {d:0>3} 界 é 👩‍💻\n", .{index}) catch unreachable;
                try answer.appendSlice(a, line);
            }
            for (0..96) |_| try answer.appendSlice(a, "界é👩‍💻");
            try answer.appendSlice(a, "\nlong end");
            return finish(a, operation, sink, answer.items);
        }
        if (std.mem.eql(u8, prompt, "history")) {
            var user_count: usize = 0;
            var existing_tools: usize = 0;
            for (request.messages[0 .. request.messages.len - 1]) |message| {
                user_count += @intFromBool(message.role == .user);
                existing_tools += @intFromBool(message.role == .tool);
            }
            const answer = try std.fmt.allocPrint(a, "history: {d} previous prompts, {d} tool results", .{ user_count, existing_tools });
            return finish(a, operation, sink, answer);
        }
        return finish(a, operation, sink, try std.fmt.allocPrint(a, "answer: {s}", .{prompt}));
    }

    fn invoke(_: *anyopaque, _: std.mem.Allocator, operation: foo.io.Context, call: foo.tool.Invocation) foo.io.Error!foo.tool.Result {
        try sleep(operation, 180);
        return .{
            .call_id = call.call.id,
            .status = .success,
            .effect = .observed,
            .content = "fixture output",
        };
    }
};

fn sleep(operation: foo.io.Context, milliseconds: u64) foo.io.Error!void {
    const until = operation.clock.now() +| milliseconds;
    while (operation.clock.now() < until) {
        try operation.check();
        std.Io.sleep(operation.io, .fromMilliseconds(5), .awake) catch return error.Cancelled;
    }
}

fn slow(a: std.mem.Allocator, operation: foo.io.Context, sink: foo.provider.Sink) foo.provider.Error![]const u8 {
    var message: std.ArrayList(u8) = .empty;
    for (1..21) |index| {
        var buf: [40]u8 = undefined;
        const chunk = std.fmt.bufPrint(&buf, "slow chunk {d}\n", .{index}) catch unreachable;
        try sink.emit(operation, .{ .text = chunk });
        try message.appendSlice(a, chunk);
        try sleep(operation, 150);
    }
    return message.items;
}

fn finish(a: std.mem.Allocator, operation: foo.io.Context, sink: foo.provider.Sink, answer: []const u8) foo.provider.Error!foo.provider.Response {
    try sink.emit(operation, .{ .text = answer });
    return response(a, answer);
}

fn response(a: std.mem.Allocator, answer: []const u8) foo.provider.Error!foo.provider.Response {
    const blocks = try a.dupe(foo.provider.Block, &.{.{ .text = answer }});
    return .{ .message = .{ .role = .assistant, .blocks = blocks }, .stop = .end_turn };
}
