const std = @import("std");
const foo = @import("foo");
const cli = @import("cli");
const configuration = @import("configuration");
const core = @import("core");
const journal = @import("journal");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(init.gpa);
    while (args.next()) |argument| try values.append(init.gpa, argument);
    const cwd = try std.process.currentPathAlloc(init.io, init.gpa);
    defer init.gpa.free(cwd);
    const cancellation: foo.io.Cancellation = .{};
    var clock = init.io;
    const operation: foo.io.Context = .{
        .io = init.io,
        .cancellation = &cancellation,
        .clock = .{ .context = &clock, .now_fn = now },
    };
    var engine: core.Engine = .{};
    var fixture: Fixture = .{ .marker = init.environ_map.get("FOO_CLI_TEST_MARKER") };
    const config_directory = try cli.arguments.userConfigDirectory(init.gpa, init.environ_map);
    defer if (config_directory) |directory| init.gpa.free(directory);
    const exit = cli.executeProcess(init.gpa, operation, values.items, .{
        .cwd = cwd,
        .environ = init.environ_map,
        .runtime = .{ .context = &fixture, .runner = engine.runner(), .bind_fn = Fixture.bind },
        .authentication = .{
            .environment = init.environ_map,
            .store = if (config_directory) |directory| .{ .directory = directory } else null,
        },
    });
    std.process.exit(@backingInt(exit));
}

fn now(context: *anyopaque) u64 {
    const io: *std.Io = @ptrCast(@alignCast(context));
    return @intCast(@max(0, std.Io.Clock.awake.now(io.*).toMilliseconds()));
}

const LocalSession = struct {
    directory: std.Io.Dir,
    store: journal.Store,

    fn close(context: *anyopaque, io: std.Io) void {
        const self: *LocalSession = @ptrCast(@alignCast(context));
        self.store.deinit();
        self.directory.close(io);
    }
};

const Fixture = struct {
    marker: ?[]const u8,

    fn bind(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        operation: foo.io.Context,
        effective: configuration.Effective,
        mode: cli.SessionMode,
    ) cli.BindError!cli.Binding {
        var binding: cli.Binding = .{
            .session = @fromBackingInt(@intCast(1)),
            .tools = .{ .context = context, .declarations = &.{}, .invoke_fn = unexpectedTool },
            .services = .{ .provider = .{ .context = context, .stream_fn = reply } },
        };
        if (effective.launch.session.directory) |path| {
            const dir = std.Io.Dir.openDirAbsolute(operation.io, path, .{
                .iterate = true,
            }) catch return error.SessionUnavailable;
            errdefer dir.close(operation.io);
            const storage = try allocator.create(LocalSession);
            const identity = effective.runtime.model.id;
            const store = switch (mode) {
                .fresh => journal.Store.create(allocator, operation.io, dir, identity, .{}),
                .@"resume" => journal.Store.open(allocator, operation.io, dir, identity, .{}),
            };
            storage.* = .{ .directory = dir, .store = store catch return error.SessionUnavailable };
            binding.services.store = storage.store.interface();
            binding.release = .{ .context = storage, .close_fn = LocalSession.close };
        }
        return binding;
    }

    fn unexpectedTool(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: foo.io.Context,
        _: foo.tool.Invocation,
    ) foo.io.Error!foo.tool.Result {
        return error.InvalidInput;
    }

    fn note(self: *const Fixture, io: std.Io, bytes: []const u8) void {
        const filename = self.marker orelse return;
        const previous = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(previous);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = filename, .data = bytes }) catch @panic("fixture marker write failed");
    }

    fn streamPressure(
        self: *const Fixture,
        operation: foo.io.Context,
        sink: foo.provider.Sink,
    ) foo.provider.Error {
        const payload: [16 * 1024]u8 = @splat('x');
        self.note(operation.io, "started");
        while (true) {
            sink.emit(operation, .{ .text = &payload }) catch |err| {
                self.note(operation.io, "stopped");
                return err;
            };
        }
    }

    fn reply(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        operation: foo.io.Context,
        request: foo.provider.Request,
        sink: foo.provider.Sink,
        delivery: *foo.io.Delivery,
    ) foo.provider.Error!foo.provider.Response {
        const self: *Fixture = @ptrCast(@alignCast(context));
        const prompt = request.messages[request.messages.len - 1].blocks[0].text;
        delivery.* = .possibly_sent;
        if (std.mem.eql(u8, prompt, "pressure")) return self.streamPressure(operation, sink);
        if (std.mem.eql(u8, prompt, "hold")) {
            self.note(operation.io, "started");
            try sink.emit(operation, .{ .text = "ready" });
            while (true) {
                operation.check() catch |err| {
                    self.note(operation.io, "stopped");
                    return err;
                };
                std.Io.sleep(operation.io, .fromMilliseconds(10), .awake) catch {
                    self.note(operation.io, "stopped");
                    return error.Cancelled;
                };
            }
        }
        if (std.mem.eql(u8, prompt, "provider-error")) {
            try sink.emit(operation, .{ .text = "provisional only" });
            return error.Rejected;
        }
        if (std.mem.eql(u8, prompt, "unauthorized")) {
            if (sink.failure) |failure| failure.status = 401;
            return error.Authentication;
        }
        if (std.mem.eql(u8, prompt, "rate-limited")) {
            if (sink.failure) |failure| failure.* = .{ .status = 429, .retry_after_ms = 1500 };
            return error.RateLimited;
        }
        if (std.mem.eql(u8, prompt, "output-limit")) {
            return .{ .message = .{ .role = .assistant, .blocks = &.{} }, .stop = .output_limit };
        }
        if (std.mem.eql(u8, prompt, "replay")) {
            const blocks = try allocator.dupe(foo.provider.Block, &.{
                .{ .text = "visible" },
                .{ .replay = .{
                    .family = request.model.family,
                    .endpoint = request.model.endpoint,
                    .model = request.model.id,
                    .bytes = "fixture-private-replay",
                } },
            });
            return .{ .message = .{ .role = .assistant, .blocks = blocks }, .stop = .end_turn };
        }
        const answer = try std.fmt.allocPrint(allocator, "{s}{s}", .{
            if (request.messages.len > 1) "resumed: " else "answer: ",
            prompt,
        });
        try sink.emit(operation, .{ .text = answer });
        const blocks = try allocator.dupe(foo.provider.Block, &.{.{ .text = answer }});
        return .{ .message = .{ .role = .assistant, .blocks = blocks }, .stop = .end_turn };
    }
};
