const std = @import("std");
const foo = @import("foo");
const wire = foo.wire;
const Parse = @import("parse.zig");
const cfg = foo.config;

pub const max_config_bytes = 1024 * 1024;
pub const max_total_config_bytes = 8 * 1024 * 1024;
pub const max_prompt_bytes = 1024 * 1024;
pub const max_effective_bytes = 16 * 1024 * 1024;
pub const max_layers = 64;
pub const max_json_depth = 64;
pub const Error = foo.io.Error || error{ InvalidConfiguration, InvalidJson, UnsupportedVersion };
pub const Diagnostic = struct {
    path: []const u8,
    source: cfg.Source,
    location: ?[]const u8 = null,
    reason: enum { invalid_value, unknown_key, missing_value, invalid_json, unsupported_version, limit_exceeded, file_io, invalid_layer },
};
pub const Layer = struct {
    source: cfg.Source,
    location: ?[]const u8 = null,
    data: union(enum) { json: []const u8, file: []const u8 },
};
pub const Input = struct {
    cwd: []const u8,
    preset: enum { none, coding } = .none,
    layers: []const Layer = &.{},
};
pub const Process = struct {
    file_bytes: usize = 8 * 1024 * 1024,
    environment: []const cfg.Environment = &.{},
    inherit_environment: bool = false,
    timeout_ms: u64 = 30_000,
    cleanup_ms: u64 = 2_000,
};
pub const SessionLimits = struct {
    max_record_bytes: usize = 8 * 1024 * 1024,
    max_journal_bytes: u64 = 256 * 1024 * 1024,
    max_context_bytes: usize = 32 * 1024 * 1024,
    max_artifact_bytes: u64 = 64 * 1024 * 1024,
    max_artifacts: usize = 1024,
};
pub const Session = struct { directory: ?[]const u8 = null, limits: SessionLimits = .{} };
pub const Key = enum { enter, @"alt+enter", @"ctrl+enter", @"ctrl+c", @"ctrl+d", @"ctrl+j", @"ctrl+q", escape };
pub const Color = enum { default, black, red, green, yellow, blue, magenta, cyan, white, bright_black, bright_red, bright_green, bright_yellow, bright_blue, bright_magenta, bright_cyan, bright_white };
pub const Tui = struct {
    keys: struct { submit: Key = .enter, newline: Key = .@"alt+enter", cancel: Key = .@"ctrl+c", quit: Key = .@"ctrl+d" } = .{},
    colors: struct { assistant: Color = .default, tool: Color = .cyan, @"error": Color = .red, status: Color = .bright_black } = .{},
};
pub const CustomTool = struct {
    name: []const u8,
    description: []const u8,
    schema_json: []const u8,
    argv: []const []const u8,
    environment: []const cfg.Environment = &.{},
    inherit_environment: bool = false,
    timeout_ms: u64 = 30_000,
};
pub const Launch = struct { process: Process = .{}, session: Session = .{}, tui: Tui = .{}, custom_tools: []const CustomTool = &.{} };
pub const Effective = struct {
    runtime: cfg.Resolved,
    launch: Launch = .{},
    prompt_files: []const []const u8 = &.{},
};
pub const coding_prompt = "Help with the requested coding task. Inspect relevant files before editing, keep changes focused, and report what you verified.";
pub const coding_tools: []const []const u8 = &.{ "read", "edit", "write", "exec" };

pub fn resolve(a: std.mem.Allocator, operation: foo.io.Context, input: Input, diagnostic: *?Diagnostic) Error!Effective {
    diagnostic.* = null;
    try operation.check();
    var state: Parse = .{ .a = a, .operation = operation, .diagnostic = diagnostic, .base = input.cwd, .settings = .{
        .runtime = .{ .model = .{ .family = .openai_responses, .endpoint = "", .id = "" }, .cwd = "" },
    } };
    if (!validPath(input.cwd) or !std.fs.path.isAbsolute(input.cwd)) return state.fail("cwd", .invalid_value);
    state.settings.runtime.cwd = try std.fs.path.resolve(a, &.{input.cwd});
    state.base = state.settings.runtime.cwd;
    if (input.layers.len > max_layers) return state.limit("layers");
    try state.defaults();
    if (input.preset == .coding) {
        state.source = .preset;
        state.settings.runtime.system_prompt = coding_prompt;
        state.settings.runtime.enabled_tools = coding_tools;
        try state.mark("system_prompt");
        try state.mark("enabled_tools");
    }
    for (input.layers) |layer| {
        if (layer.source == .defaults or layer.source == .preset or (layer.source != .file and layer.data == .file)) {
            state.source = layer.source;
            state.location = if (layer.location) |v| try a.dupe(u8, v) else null;
            return state.fail("layers", .invalid_layer);
        }
    }
    var total_bytes: usize = 0;
    for (cfg.precedence[2..]) |source| {
        for (input.layers) |layer| {
            if (layer.source != source) continue;
            try operation.check();
            state.source = source;
            state.location = if (layer.location) |v| try a.dupe(u8, v) else null;
            state.base = input.cwd;
            const bytes = switch (layer.data) {
                .json => |bytes| blk: {
                    if (source == .file) {
                        if (layer.location) |path| {
                            const absolute = try state.path(path, "$file");
                            state.base = std.fs.path.dirname(absolute) orelse input.cwd;
                        }
                    }
                    break :blk bytes;
                },
                .file => |path| blk: {
                    const absolute = try state.path(path, "$file");
                    state.location = absolute;
                    state.base = std.fs.path.dirname(absolute) orelse input.cwd;
                    break :blk try state.readFile(absolute, "$", max_config_bytes);
                },
            };
            if (bytes.len > max_config_bytes or bytes.len > max_total_config_bytes - total_bytes) return state.limit("$");
            total_bytes += bytes.len;
            wire.json.validate(bytes, .{ .max_bytes = max_config_bytes, .max_depth = max_json_depth }) catch |err| switch (err) {
                error.MessageTooLarge, error.NestingTooDeep => return state.limit("$"),
                error.InvalidJson => {
                    state.report("$", .invalid_json);
                    return error.InvalidJson;
                },
            };
            const tree = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error", .parse_numbers = false }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    state.report("$", .invalid_json);
                    return error.InvalidJson;
                },
            };
            try state.apply(tree);
        }
    }
    try state.finish();
    try operation.check();
    return state.settings;
}

pub fn effectiveJson(a: std.mem.Allocator, settings: Effective) Error![]const u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var safe = settings;
    safe.runtime.model.endpoint = try redactedUrl(scratch, safe.runtime.model.endpoint);
    safe.runtime.model.headers = try redactedHeaders(scratch, safe.runtime.model.headers);
    safe.runtime.model.options_json = if (std.mem.eql(u8, safe.runtime.model.options_json, "{}")) "{}" else "\"<redacted>\"";
    const servers = try scratch.dupe(cfg.McpServer, safe.runtime.mcp_servers);
    for (servers) |*server| switch (server.transport) {
        .stdio => |*v| v.environment = try redactedEnvironment(scratch, v.environment),
        .http => |*v| {
            v.headers = try redactedHeaders(scratch, v.headers);
            v.url = try redactedUrl(scratch, v.url);
        },
    };
    safe.runtime.mcp_servers = servers;
    safe.launch.process.environment = try redactedEnvironment(scratch, safe.launch.process.environment);
    const custom_tools = try scratch.dupe(CustomTool, safe.launch.custom_tools);
    for (custom_tools) |*tool| tool.environment = try redactedEnvironment(scratch, tool.environment);
    safe.launch.custom_tools = custom_tools;
    var counting_buffer: [256]u8 = undefined;
    var counter = std.Io.Writer.Discarding.init(&counting_buffer);
    std.json.Stringify.value(safe, .{ .whitespace = .indent_2 }, &counter.writer) catch return error.LimitExceeded;
    const size = std.math.cast(usize, counter.fullCount()) orelse return error.LimitExceeded;
    if (size > max_effective_bytes) return error.LimitExceeded;
    const buffer = try a.alloc(u8, size);
    errdefer a.free(buffer);
    var writer: std.Io.Writer = .fixed(buffer);
    std.json.Stringify.value(safe, .{ .whitespace = .indent_2 }, &writer) catch return error.LimitExceeded;
    return writer.buffered();
}

fn redactedHeaders(a: std.mem.Allocator, entries: []const cfg.Header) Error![]const cfg.Header {
    const result = try a.dupe(cfg.Header, entries);
    for (result) |*entry| if (entry.value == .literal) {
        entry.value = .{ .literal = "<redacted>" };
    };
    return result;
}
fn redactedEnvironment(a: std.mem.Allocator, entries: []const cfg.Environment) Error![]const cfg.Environment {
    const result = try a.dupe(cfg.Environment, entries);
    for (result) |*entry| if (entry.value == .literal) {
        entry.value = .{ .literal = "<redacted>" };
    };
    return result;
}
pub fn validPath(value: []const u8) bool {
    return value.len != 0 and std.mem.indexOfScalar(u8, value, 0) == null;
}

fn redactedUrl(a: std.mem.Allocator, url: []const u8) Error![]const u8 {
    const query = std.mem.indexOfScalar(u8, url, '?') orelse return url;
    return std.fmt.allocPrint(a, "{s}?<redacted>", .{url[0..query]});
}
