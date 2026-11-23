const std = @import("std");
const foo = @import("foo");
const config = @import("configuration");

pub const max_prompt_bytes = 1024 * 1024;

pub const SessionMode = enum { fresh, @"resume" };
pub const Prompt = union(enum) { argument: []const u8, stdin };
pub const Action = union(enum) {
    help,
    version,
    run: Prompt,
    rpc,
    check,
    show,
};
pub const Command = struct {
    action: Action,
    session: SessionMode = .fresh,
    config: config.Input,
};

const Mode = enum { run, rpc, config };
const ConfigMode = enum { check, show };
const Flag = enum {
    @"--config",
    @"--preset",
    @"--model",
    @"--endpoint",
    @"--provider",
    @"--credential-env",
    @"--cwd",
    @"--prompt",
    @"--stdin",
    @"--resume",
};

const ModelPatch = struct {
    id: ?[]const u8 = null,
    endpoint: ?[]const u8 = null,
    family: ?foo.config.Family = null,
    credential: ?struct { environment: []const u8 } = null,
};

const Error = error{ InvalidArguments, LimitExceeded, OutOfMemory };

pub fn parse(a: std.mem.Allocator, argv: []const []const u8, cwd: []const u8, environment: ?[]const u8) Error!Command {
    var input: config.Input = .{ .cwd = cwd };
    if (argv.len == 0) return .{ .action = .help, .config = input };
    if (argv.len == 1) {
        if (isHelp(argv[0])) return .{ .action = .help, .config = input };
        if (std.mem.eql(u8, argv[0], "--version")) return .{ .action = .version, .config = input };
    }
    const mode = std.meta.stringToEnum(Mode, argv[0]) orelse return error.InvalidArguments;
    var offset: usize = 1;
    const config_mode: ?ConfigMode = if (mode == .config) blk: {
        if (offset == argv.len) return error.InvalidArguments;
        if (argv.len == 2 and isHelp(argv[1])) return .{ .action = .help, .config = input };
        offset += 1;
        break :blk std.meta.stringToEnum(ConfigMode, argv[1]) orelse return error.InvalidArguments;
    } else null;
    if (argv.len == offset + 1 and isHelp(argv[offset])) return .{ .action = .help, .config = input };

    var layers: std.ArrayList(config.Layer) = .empty;
    var used: std.EnumSet(Flag) = .empty;
    var patch: ModelPatch = .{};
    var cwd_override: ?[]const u8 = null;
    var prompt: ?Prompt = null;
    var session: SessionMode = .fresh;
    while (offset < argv.len) {
        const flag = std.meta.stringToEnum(Flag, argv[offset]) orelse return error.InvalidArguments;
        offset += 1;
        if (flag != .@"--config" and used.contains(flag)) return error.InvalidArguments;
        used.insert(flag);
        switch (flag) {
            .@"--stdin", .@"--prompt" => {
                if (mode != .run or prompt != null) return error.InvalidArguments;
                prompt = if (flag == .@"--stdin")
                    .stdin
                else
                    .{ .argument = try value(argv, &offset, max_prompt_bytes) };
            },
            .@"--resume" => {
                if (mode == .config) return error.InvalidArguments;
                session = .@"resume";
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
            .@"--model" => patch.id = try value(argv, &offset, config.max_config_bytes),
            .@"--endpoint" => patch.endpoint = try value(argv, &offset, config.max_config_bytes),
            .@"--provider" => patch.family = std.meta.stringToEnum(
                foo.config.Family,
                try value(argv, &offset, config.max_config_bytes),
            ) orelse return error.InvalidArguments,
            .@"--credential-env" => patch.credential = .{ .environment = try value(argv, &offset, config.max_config_bytes) },
            .@"--cwd" => cwd_override = try value(argv, &offset, config.max_config_bytes),
        }
    }

    if (environment) |json| try addLayer(a, &layers, .{
        .source = .environment,
        .data = .{ .json = json },
    });
    const has_model = patch.id != null or patch.endpoint != null or patch.family != null or patch.credential != null;
    if (has_model or cwd_override != null) {
        const patch_json = try std.json.Stringify.valueAlloc(a, .{
            .model = if (has_model) patch else null,
            .cwd = cwd_override,
        }, .{ .emit_null_optional_fields = false });
        if (patch_json.len > config.max_config_bytes) return error.LimitExceeded;
        try addLayer(a, &layers, .{
            .source = .command_line,
            .data = .{ .json = patch_json },
        });
    }
    input.layers = layers.items;
    return .{
        .action = switch (mode) {
            .run => .{ .run = prompt orelse return error.InvalidArguments },
            .rpc => .rpc,
            .config => switch (config_mode.?) {
                .check => .check,
                .show => .show,
            },
        },
        .session = session,
        .config = input,
    };
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
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
