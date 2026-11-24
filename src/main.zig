const std = @import("std");
const foo = @import("foo");
const cli = @import("cli");
const configuration = @import("configuration");
const tui = @import("tui");
const acp = @import("acp");
const runtime = @import("contracts/runtime/session.zig");

pub fn main(init: std.process.Init) void {
    const status = run(init) catch |err| status: {
        report(init.io, @errorName(err));
        break :status .host;
    };
    if (status != .success) std.process.exit(@backingInt(status));
}

fn run(init: std.process.Init) !cli.Exit {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(init.gpa);
    while (args.next()) |arg| try values.append(init.gpa, arg);

    if (values.items.len == 0 or (values.items.len == 1 and isHelp(values.items[0]))) {
        try std.Io.File.stdout().writeStreamingAll(init.io, cli.help);
        return .success;
    }
    if (values.items.len == 1 and eql(values.items[0], "--version")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "foo " ++ foo.version ++ "\n");
        return .success;
    }

    const cwd = try std.process.currentPathAlloc(init.io, init.gpa);
    defer init.gpa.free(cwd);
    var io = init.io;
    const cancellation: foo.io.Cancellation = .{};
    const operation: foo.io.Context = .{
        .io = io,
        .clock = .{ .context = &io, .now_fn = now },
        .cancellation = &cancellation,
    };
    var app: runtime.App = .{
        .allocator = init.gpa,
        .environ = init.environ_map,
        .native = .{ .environ = init.minimal.environ },
    };
    defer app.deinit();
    const environment_json = init.environ_map.get("FOO_CONFIG_JSON");
    const command = values.items[0];
    if (eql(command, "tui") or eql(command, "acp")) {
        return cli.withProcessSignals(operation, otherFrontend, .{ &app, cwd, values.items, environment_json });
    }
    return cli.executeProcess(init.gpa, operation, values.items, .{
        .cwd = cwd,
        .environ = init.environ_map,
        .environment_json = environment_json,
        .runtime = app.cliRuntime(),
    });
}

fn otherFrontend(operation: foo.io.Context, app: *runtime.App, cwd: []const u8, argv: []const []const u8, environment_json: ?[]const u8) cli.Exit {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const command = cli.arguments.parse(allocator, argv, cwd, environment_json) catch |err| {
        report(operation.io, @errorName(err));
        return switch (err) {
            error.InvalidArguments => .usage,
            error.LimitExceeded => .limit,
            error.OutOfMemory => .host,
        };
    };
    if (command.action == .help) {
        std.Io.File.stdout().writeStreamingAll(operation.io, cli.help) catch return .host;
        return .success;
    }
    if (command.action == .acp) return runAcp(app, operation, command.config);

    var diagnostic: ?configuration.Diagnostic = null;
    const settings = configuration.resolve(allocator, operation, command.config, &diagnostic) catch |err| {
        if (diagnostic) |detail| {
            var message: [1024]u8 = undefined;
            report(operation.io, std.fmt.bufPrint(&message, "config {s} from {s} at {s}", .{
                @tagName(detail.reason), @tagName(detail.source), detail.path,
            }) catch "configuration is invalid");
        } else report(operation.io, @errorName(err));
        return switch (err) {
            error.InvalidConfiguration, error.InvalidJson, error.UnsupportedVersion => .usage,
            else => |shared| cli.Exit.fromError(shared),
        };
    };
    return runTui(app, operation, settings, command.session);
}

fn runTui(app: *runtime.App, operation: foo.io.Context, settings: configuration.Effective, mode: cli.SessionMode) cli.Exit {
    if (cli.missingCredential(settings.runtime.model, app.environ) != null) {
        report(operation.io, "missing or invalid configured model credential");
        return .usage;
    }
    if (mode == .@"resume" and settings.launch.session.directory == null) {
        report(operation.io, "--resume requires a configured session directory");
        return .usage;
    }
    const session = runtime.Session.open(app, operation, settings, @fromBackingInt(1), .{}, switch (mode) {
        .fresh => .fresh,
        .@"resume" => .@"resume",
    }) catch |err| {
        report(operation.io, @errorName(err));
        return switch (err) {
            error.SessionUnavailable => .storage,
            else => |shared| cli.Exit.fromError(shared),
        };
    };
    defer session.closeAfter(operation);
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    var history: []const foo.provider.Message = &.{};
    if (mode == .@"resume") {
        const store = &session.local.?.store;
        const recovery = store.load(arena.allocator(), operation) catch |err| {
            report(operation.io, @errorName(err));
            return switch (err) {
                error.Cancelled => .cancelled,
                error.DeadlineExceeded => .limit,
                else => .storage,
            };
        };
        if (recovery.uncertain_call_ids.len != 0) {
            report(operation.io, "unresolved tool effects");
            return .interrupted;
        }
        history = recovery.messages;
    }
    const result = cli.waitForOperation(operation, tui.run, .{ app.allocator, operation, tui.Options{
        .runner = session.runner(),
        .input = .{
            .session = session.id,
            .run = @fromBackingInt(1),
            .settings = settings.runtime,
            .messages = history,
            .tools = session.emptyRegistry(),
            .services = session.services(),
        },
        .settings = settings.launch.tui,
        .environ = app.environ,
    } }) catch |err| {
        report(operation.io, @errorName(err));
        return cli.Exit.fromError(err);
    };
    return if (result) |outcome| cli.Exit.fromOutcome(outcome) else .success;
}

fn runAcp(app: *runtime.App, operation: foo.io.Context, input: configuration.Input) cli.Exit {
    var factory = AcpFactory{ .app = app, .input = input };
    const result = cli.waitForOperation(operation, AcpFactory.serve, .{ &factory, operation.io }) catch |err| {
        report(operation.io, @errorName(err));
        return cli.Exit.fromError(err);
    };
    if (result.runtime_cleanup_failures != 0 or result.remote_cleanup_unconfirmed != 0) {
        report(operation.io, "ACP cleanup could not be confirmed");
        return .host;
    }
    return switch (result.reason) {
        .eof => .success,
        .cancelled => .cancelled,
        .invalid_frame, .input_failed, .output_failed, .output_pressure => .host,
    };
}

const AcpFactory = struct {
    app: *runtime.App,
    input: configuration.Input,

    fn serve(self: *AcpFactory, io: std.Io) foo.io.Error!acp.Report {
        return acp.serveStdio(self.app.allocator, io, .{
            .factory = .{ .context = self, .open_fn = open },
            .mcp_http = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.IoFailure,
        };
    }

    fn open(raw: *anyopaque, allocator: std.mem.Allocator, operation: foo.io.Context, input: acp.OpenInput) acp.OpenError!acp.Runtime {
        const self: *AcpFactory = @ptrCast(@alignCast(raw));
        var diagnostic: ?configuration.Diagnostic = null;
        var settings = configuration.resolve(allocator, operation, self.input, &diagnostic) catch |err| return switch (err) {
            error.InvalidConfiguration, error.InvalidJson, error.UnsupportedVersion => error.InvalidInput,
            else => |shared| shared,
        };
        if (cli.missingCredential(settings.runtime.model, self.app.environ) != null) return error.AuthenticationRequired;
        try validateEditorServers(self.app.environ, settings.runtime.mcp_servers, input.editor_servers);
        const launch_cwd = settings.runtime.cwd;
        settings.runtime.cwd = input.cwd;
        const session = runtime.Session.open(self.app, operation, settings, input.session, input.client, .{ .editor = launch_cwd }) catch |err| switch (err) {
            error.SessionUnavailable => return error.IoFailure,
            else => |shared| return shared,
        };
        return .{
            .context = session,
            .runner = session.runner(),
            .settings = settings.runtime,
            .prepare_fn = prepare,
            .close_fn = close,
        };
    }

    fn prepare(raw: *anyopaque, _: std.mem.Allocator, operation: foo.io.Context, _: foo.events.RunId) foo.io.Error!acp.RunServices {
        const session: *runtime.Session = @ptrCast(@alignCast(raw));
        try operation.check();
        return .{ .tools = session.emptyRegistry(), .services = session.services() };
    }

    fn close(raw: *anyopaque, operation: foo.io.Context) foo.io.Error!void {
        const session: *runtime.Session = @ptrCast(@alignCast(raw));
        try session.deinit(operation);
    }
};

fn validateEditorServers(environ: *const std.process.Environ.Map, configured: []const foo.config.McpServer, supplied: []const foo.config.McpServer) foo.io.Error!void {
    for (supplied) |request| {
        for (configured) |trusted| {
            if (eql(request.id, trusted.id) and matchingServer(environ, trusted, request)) break;
        } else return error.InvalidInput;
    }
}

fn matchingServer(environ: *const std.process.Environ.Map, trusted: foo.config.McpServer, supplied: foo.config.McpServer) bool {
    return switch (trusted.transport) {
        .stdio => |expected| supplied.transport == .stdio and
            matchingArgv(expected.argv, supplied.transport.stdio.argv) and
            matchingValues(environ, expected.environment, supplied.transport.stdio.environment, false),
        .http => |expected| supplied.transport == .http and
            eql(expected.url, supplied.transport.http.url) and
            matchingValues(environ, expected.headers, supplied.transport.http.headers, true),
    };
}

fn matchingArgv(trusted: []const []const u8, supplied: []const []const u8) bool {
    if (trusted.len != supplied.len) return false;
    for (trusted, supplied) |expected, actual| if (!eql(expected, actual)) return false;
    return true;
}

fn matchingValues(environ: *const std.process.Environ.Map, trusted: anytype, supplied: @TypeOf(trusted), comptime ignore_case: bool) bool {
    if (trusted.len != supplied.len) return false;
    for (trusted) |expected| {
        const value = runtime.environmentValue(environ, expected.value) catch return false;
        for (supplied) |actual| {
            const same_name = if (ignore_case) std.ascii.eqlIgnoreCase(expected.name, actual.name) else eql(expected.name, actual.name);
            if (same_name and actual.value == .literal and eql(value, actual.value.literal)) break;
        } else return false;
    }
    return true;
}

fn isHelp(arg: []const u8) bool {
    return eql(arg, "--help") or eql(arg, "-h");
}

fn eql(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

fn now(raw: *anyopaque) u64 {
    const io: *std.Io = @ptrCast(@alignCast(raw));
    return @intCast(@max(0, std.Io.Clock.awake.now(io.*).toMilliseconds()));
}

pub fn report(io: std.Io, message: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, "foo: ") catch return;
    std.Io.File.stderr().writeStreamingAll(io, message) catch return;
    std.Io.File.stderr().writeStreamingAll(io, "\n") catch {};
}
