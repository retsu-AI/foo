const std = @import("std");
const builtin = @import("builtin");
const foo = @import("foo");
const auth = @import("auth");
const config = @import("configuration");

pub const max_prompt_bytes = 1024 * 1024;

pub const SessionMode = enum { fresh, @"resume" };
pub const Prompt = union(enum) { argument: []const u8, stdin };
pub const McpCommand = struct {
    kind: foo.tool.ContextKind,
    server: []const u8,
    selection: union(enum) {
        list,
        get: struct { id: []const u8, arguments_json: []const u8 = "" },
    },
};
pub const AuthCommand = union(enum) {
    list,
    /// `foo auth login` with no PROVIDER lists the built-in providers.
    providers,
    login: struct { provider: []const u8, method: LoginMethod = .auto },
    logout: []const u8,
};
pub const LoginMethod = enum { auto, browser, device, api_key };
/// A PROVIDER positional filters the rows and selects like `--provider`, so `*` marks what
/// `foo run` would use with the same flags.
pub const ModelsCommand = struct { provider: ?[]const u8 = null, all: bool = false };
pub const Action = union(enum) {
    help,
    version,
    run: Prompt,
    rpc,
    tui,
    acp,
    mcp: McpCommand,
    auth: AuthCommand,
    models: ModelsCommand,
    check,
    show,
};
pub const Command = struct {
    action: Action,
    session: SessionMode = .fresh,
    config: config.Input,
};

const Mode = enum { run, rpc, tui, acp, mcp, config, auth, models };
const ConfigMode = enum { check, show };
const McpMode = enum { list, get };
const Flag = enum {
    @"--approve",
    @"--config",
    @"--preset",
    @"--model",
    @"--endpoint",
    @"--provider",
    @"--family",
    @"--credential-env",
    @"--cwd",
    @"--prompt",
    @"--stdin",
    @"--resume",
    @"--arguments",
    @"--all",
};

const Error = error{ InvalidArguments, LimitExceeded, OutOfMemory };

pub fn parse(a: std.mem.Allocator, argv: []const []const u8, cwd: []const u8, environment: ?[]const u8) Error!Command {
    return parseWithDiscovery(a, argv, cwd, environment, null);
}

pub fn parseWithDiscovery(
    a: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
    environment: ?[]const u8,
    environ: ?*const std.process.Environ.Map,
) Error!Command {
    var input: config.Input = .{ .cwd = cwd };
    if (argv.len == 0) return .{ .action = .help, .config = input };
    if (argv.len == 1 and std.mem.eql(u8, argv[0], "--version")) return .{ .action = .version, .config = input };
    // Help is recognized where a flag may stand, never inside a value such as `--prompt --help`.
    if (isHelp(argv[0]) or (argv.len >= 2 and isHelp(argv[1]))) return .{ .action = .help, .config = input };
    const mode = std.meta.stringToEnum(Mode, argv[0]) orelse return error.InvalidArguments;
    var offset: usize = 1;
    if (mode == .auth) {
        // `auth` takes no option values, so any help token is a flag.
        for (argv[1..]) |arg| if (isHelp(arg)) return .{ .action = .help, .config = input };
        return .{ .action = .{ .auth = try parseAuth(argv[1..]) }, .config = input };
    }
    const config_mode: ?ConfigMode = if (mode == .config) blk: {
        if (offset == argv.len) return error.InvalidArguments;
        offset += 1;
        break :blk std.meta.stringToEnum(ConfigMode, argv[1]) orelse return error.InvalidArguments;
    } else null;

    var mcp_command = if (mode == .mcp) try parseMcp(argv, &offset) else null;
    var models_command: ModelsCommand = .{};
    var layers: std.ArrayList(config.Layer) = .empty;
    var used: std.EnumSet(Flag) = .empty;
    var cwd_override: ?[]const u8 = null;
    var prompt: ?Prompt = null;
    var session: SessionMode = .fresh;
    while (offset < argv.len) {
        if (isHelp(argv[offset])) return .{ .action = .help, .config = input };
        const flag = std.meta.stringToEnum(Flag, argv[offset]) orelse {
            // `foo models` takes one PROVIDER positional anywhere among its flags.
            if (mode != .models or models_command.provider != null or isOption(argv[offset])) return error.InvalidArguments;
            models_command.provider = try value(argv, &offset, config.max_config_bytes);
            if (!foo.config.validId(models_command.provider.?, .provider)) return error.InvalidArguments;
            continue;
        };
        offset += 1;
        if (flag != .@"--config" and used.contains(flag)) return error.InvalidArguments;
        used.insert(flag);
        switch (flag) {
            .@"--approve" => if (environ == null) return error.InvalidArguments,
            .@"--all" => {
                if (mode != .models) return error.InvalidArguments;
                models_command.all = true;
            },
            .@"--stdin", .@"--prompt" => {
                if (mode != .run or prompt != null) return error.InvalidArguments;
                prompt = if (flag == .@"--stdin")
                    .stdin
                else
                    .{ .argument = try value(argv, &offset, max_prompt_bytes) };
            },
            .@"--resume" => {
                if (mode != .run and mode != .rpc and mode != .tui) return error.InvalidArguments;
                session = .@"resume";
            },
            .@"--arguments" => {
                if (mcp_command == null or mcp_command.?.selection != .get) return error.InvalidArguments;
                mcp_command.?.selection.get.arguments_json = try value(argv, &offset, config.max_config_bytes);
            },
            .@"--config" => try addLayer(a, &layers, .{
                .source = .file,
                .data = .{ .file = try value(argv, &offset, config.max_config_bytes) },
            }),
            .@"--preset" => {
                const name = try value(argv, &offset, config.max_config_bytes);
                if (!std.mem.eql(u8, name, "coding")) return error.InvalidArguments;
                input.preset = .coding;
            },
            .@"--model" => input.model_patch.selection = try value(argv, &offset, config.max_config_bytes),
            .@"--endpoint" => input.model_patch.endpoint = try value(argv, &offset, config.max_config_bytes),
            .@"--provider" => input.model_patch.provider = try value(argv, &offset, config.max_config_bytes),
            .@"--family" => input.model_patch.family = std.meta.stringToEnum(
                foo.config.Family,
                try value(argv, &offset, config.max_config_bytes),
            ) orelse return error.InvalidArguments,
            .@"--credential-env" => input.model_patch.credential_env = try value(argv, &offset, config.max_config_bytes),
            .@"--cwd" => cwd_override = try value(argv, &offset, config.max_config_bytes),
        }
    }

    if (environment) |json| try addLayer(a, &layers, .{
        .source = .environment,
        .data = .{ .json = json },
    });
    input.model_patch.filter = models_command.provider;
    if (cwd_override) |path| {
        const patch_json = try std.json.Stringify.valueAlloc(a, .{ .cwd = path }, .{});
        if (patch_json.len > config.max_config_bytes) return error.LimitExceeded;
        try addLayer(a, &layers, .{
            .source = .command_line,
            .data = .{ .json = patch_json },
        });
    }
    if (environ) |variables| {
        if (used.contains(.@"--approve")) {
            try prependFile(a, &layers, try std.fs.path.join(a, &.{ cwd, ".foo", "config.json" }));
        }
        if (try userConfigDirectory(a, variables)) |directory| {
            defer a.free(directory);
            try prependFile(a, &layers, try std.fs.path.join(a, &.{ directory, "config.json" }));
        }
    }
    input.layers = layers.items;
    return .{
        .action = switch (mode) {
            .run => .{ .run = prompt orelse return error.InvalidArguments },
            .rpc => .rpc,
            .tui => .tui,
            .acp => .acp,
            .mcp => .{ .mcp = mcp_command.? },
            .models => .{ .models = models_command },
            .auth => unreachable,
            .config => switch (config_mode.?) {
                .check => .check,
                .show => .show,
            },
        },
        .session = session,
        .config = input,
    };
}

pub fn userConfigDirectory(a: std.mem.Allocator, environ: *const std.process.Environ.Map) Error!?[]const u8 {
    const path = std.fs.path;
    if (absoluteDirectory(environ.get("FOO_CONFIG_DIR"))) |directory| {
        return try a.dupe(u8, directory);
    }
    if (builtin.os.tag == .windows) {
        const app_data = absoluteDirectory(environ.get("APPDATA")) orelse return null;
        return try path.join(a, &.{ app_data, "foo" });
    }
    if (absoluteDirectory(environ.get("XDG_CONFIG_HOME"))) |directory| {
        return try path.join(a, &.{ directory, "foo" });
    }
    const home = absoluteDirectory(environ.get("HOME")) orelse return null;
    return try path.join(a, &.{ home, ".config", "foo" });
}

fn absoluteDirectory(value_or_null: ?[]const u8) ?[]const u8 {
    const directory = value_or_null orelse return null;
    if (builtin.os.tag == .windows) return switch (std.fs.path.getWin32PathType(u8, directory)) {
        .drive_absolute, .unc_absolute, .local_device => directory,
        else => null,
    };
    return if (std.fs.path.isAbsolute(directory)) directory else null;
}

fn prependFile(a: std.mem.Allocator, layers: *std.ArrayList(config.Layer), path: []const u8) Error!void {
    if (layers.items.len == config.max_layers) return error.LimitExceeded;
    try layers.insert(a, 0, .{ .source = .file, .data = .{ .optional_file = path } });
}

fn parseAuth(args: []const []const u8) Error!AuthCommand {
    if (args.len == 0) return error.InvalidArguments;
    const action = std.meta.stringToEnum(enum { list, login, logout }, args[0]) orelse return error.InvalidArguments;
    if (action == .list) return if (args.len == 1) .list else error.InvalidArguments;
    if (action == .login and args.len == 1) return .providers;
    // A PROVIDER never starts with `-`, so `auth login --api-key` is a missing PROVIDER, not a name.
    if (args.len < 2 or isOption(args[1]) or !auth.validProviderId(args[1])) return error.InvalidArguments;
    return switch (action) {
        .list => unreachable,
        .logout => if (args.len == 2) .{ .logout = args[1] } else error.InvalidArguments,
        .login => .{ .login = .{
            .provider = args[1],
            .method = switch (args.len) {
                2 => .auto,
                3 => switch (std.meta.stringToEnum(enum { @"--browser", @"--device", @"--api-key" }, args[2]) orelse return error.InvalidArguments) {
                    .@"--browser" => .browser,
                    .@"--device" => .device,
                    .@"--api-key" => .api_key,
                },
                else => return error.InvalidArguments,
            },
        } },
    };
}

fn parseMcp(argv: []const []const u8, offset: *usize) Error!McpCommand {
    const mode = std.meta.stringToEnum(McpMode, try value(argv, offset, config.max_config_bytes)) orelse return error.InvalidArguments;
    const kind = std.meta.stringToEnum(foo.tool.ContextKind, try value(argv, offset, config.max_config_bytes)) orelse return error.InvalidArguments;
    return .{
        .kind = kind,
        .server = try value(argv, offset, config.max_config_bytes),
        .selection = switch (mode) {
            .list => .list,
            .get => .{ .get = .{ .id = try value(argv, offset, config.max_config_bytes) } },
        },
    };
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn isOption(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "-");
}

fn value(argv: []const []const u8, offset: *usize, max: usize) Error![]const u8 {
    if (offset.* == argv.len) return error.InvalidArguments;
    const arg = argv[offset.*];
    offset.* += 1;
    if (arg.len > max) return error.LimitExceeded;
    if (arg.len == 0) return error.InvalidArguments;
    return arg;
}

fn addLayer(a: std.mem.Allocator, layers: *std.ArrayList(config.Layer), layer: config.Layer) Error!void {
    if (layers.items.len == config.max_layers) return error.LimitExceeded;
    try layers.append(a, layer);
}

test "help wins before any subcommand validation" {
    const cases = [_][]const []const u8{
        &.{ "auth", "login", "--help" },
        &.{ "auth", "login", "-h" },
        &.{ "auth", "login", "anthropic", "--help" },
        &.{ "auth", "logout", "--help" },
        &.{ "auth", "logout", "-h" },
        &.{ "auth", "list", "--help" },
        &.{ "models", "--help" },
        &.{ "models", "zai", "--help" },
        &.{ "models", "--all", "--help" },
        &.{ "config", "show", "--help" },
        &.{ "run", "--prompt", "x", "--help" },
    };
    for (cases) |argv| {
        const command = try parse(std.testing.allocator, argv, "/cwd", null);
        try std.testing.expectEqual(Action.help, command.action);
    }
}

test "a help token inside an option value is the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "--help", "-h" }) |text| {
        const run = try parse(a, &.{ "run", "--prompt", text }, "/cwd", null);
        try std.testing.expectEqualStrings(text, run.action.run.argument);
        const mcp = try parse(a, &.{ "mcp", "get", "prompt", "server", "id", "--arguments", text }, "/cwd", null);
        try std.testing.expectEqualStrings(text, mcp.action.mcp.selection.get.arguments_json);
    }
}

test "a provider id never starts with a dash" {
    const usage = [_][]const []const u8{
        &.{ "auth", "login", "--api-key" },
        &.{ "auth", "login", "--bogus" },
        &.{ "auth", "login", "-x" },
        &.{ "auth", "logout", "-x" },
        &.{ "auth", "logout", "--api-key" },
        &.{ "auth", "login", "zai", "--bogus" },
        &.{ "models", "-x" },
        &.{ "models", "zai", "deepseek" },
        &.{ "models", "zai", "--all", "--all" },
        &.{ "models", "--all", "--all" },
    };
    for (usage) |argv| try std.testing.expectError(error.InvalidArguments, parse(std.testing.allocator, argv, "/cwd", null));
    const key = try parse(std.testing.allocator, &.{ "auth", "login", "mygateway", "--api-key" }, "/cwd", null);
    try std.testing.expectEqualStrings("mygateway", key.action.auth.login.provider);
    try std.testing.expectEqual(LoginMethod.api_key, key.action.auth.login.method);
}

test "foo models takes PROVIDER anywhere among its flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const []const u8{
        &.{ "models", "zai", "--all" },
        &.{ "models", "--all", "zai" },
        &.{ "models", "--config", "/x.json", "zai", "--all" },
        &.{ "models", "--all", "--config", "/x.json", "zai" },
    }) |argv| {
        const command = try parse(a, argv, "/cwd", null);
        try std.testing.expectEqualStrings("zai", command.action.models.provider.?);
        try std.testing.expect(command.action.models.all);
    }
    const bare = try parse(a, &.{"models"}, "/cwd", null);
    try std.testing.expectEqual(null, bare.action.models.provider);
    try std.testing.expect(!bare.action.models.all);
}
