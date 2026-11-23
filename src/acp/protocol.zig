const std = @import("std");
const foo = @import("foo");

pub const Limits = struct {
    frame_bytes: usize = 128 * 1024,
    json_depth: usize = 32,
    request_id_bytes: usize = 256,
    queued_frames: usize = 64,
    queued_bytes: usize = 512 * 1024,
    sessions: usize = 8,
    history_bytes: usize = 2 * 1024 * 1024,
    prompt_blocks: usize = 64,
    editor_servers: usize = 16,
    terminals: usize = 8,
    terminal_bytes: usize = 16 * 1024,
    reverse_ms: u64 = 30_000,
    turn_ms: u64 = 120_000,
    shutdown_ms: u64 = 2_000,
    write_ms: u64 = 5_000,

    pub fn validate(self: Limits) !void {
        inline for (@typeInfo(Limits).@"struct".field_names) |name| {
            if (@field(self, name) == 0) return error.InvalidInput;
        }
        if (self.frame_bytes < 1024 or self.frame_bytes == std.math.maxInt(usize) or
            self.terminal_bytes > self.frame_bytes or self.json_depth < 12 or
            self.json_depth > foo.wire.json.max_supported_depth)
            return error.InvalidInput;
    }

    pub fn json(self: Limits) foo.wire.json.Limits {
        return .{ .max_bytes = self.frame_bytes, .max_depth = self.json_depth };
    }
};

pub const Initialize = struct {
    protocolVersion: u16,
    clientCapabilities: struct {
        fs: struct {
            readTextFile: bool = false,
            writeTextFile: bool = false,
        } = .{},
        terminal: bool = false,
    } = .{},
};

pub const initialize_result =
    "{\"protocolVersion\":1,\"agentCapabilities\":{},\"authMethods\":[],\"agentInfo\":{\"name\":\"foo\",\"version\":\"" ++ foo.version ++ "\"}}";

pub const SessionRef = struct { sessionId: []const u8 };
pub const SessionInput = struct {
    cwd: []const u8,
    mcp_servers: []const foo.config.McpServer,
};

const Env = struct { name: []const u8, value: []const u8 };
const Stdio = struct {
    type: ?[]const u8 = null,
    name: []const u8,
    command: []const u8,
    args: ?[]const []const u8,
    env: ?[]const Env,
};
const New = struct {
    cwd: []const u8,
    mcpServers: ?[]const Stdio,
    additionalDirectories: ?[]const []const u8 = null,
    systemPrompt: ?std.json.Value = null,
};
const Prompt = struct {
    sessionId: []const u8,
    prompt: []const struct {
        type: enum { text, resource_link },
        text: ?[]const u8 = null,
        name: ?[]const u8 = null,
        uri: ?[]const u8 = null,
    },
};

pub fn parse(comptime T: type, allocator: std.mem.Allocator, raw: []const u8) foo.io.Error!T {
    return std.json.parseFromSliceLeaky(T, allocator, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidInput,
    };
}

pub fn newSession(allocator: std.mem.Allocator, raw: []const u8, limits: Limits) foo.io.Error!SessionInput {
    const input = try parse(New, allocator, raw);
    if (!absolutePath(input.cwd) or input.systemPrompt != null) return error.InvalidInput;
    if (input.additionalDirectories) |roots| if (roots.len != 0) return error.InvalidInput;

    const servers: []const Stdio = input.mcpServers orelse &.{};
    if (servers.len > limits.editor_servers) return error.LimitExceeded;
    const result = try allocator.alloc(foo.config.McpServer, servers.len);
    for (servers, 0..) |server, index| {
        if (server.type) |tag| if (!std.mem.eql(u8, tag, "stdio")) return error.InvalidInput;
        if (server.name.len == 0 or server.name.len > 256 or !noNul(server.name) or
            (server.command.len == 0 or server.command.len > 4096 or !noNul(server.command))) return error.InvalidInput;
        for (result[0..index]) |prev| {
            if (std.mem.eql(u8, prev.id, server.name)) return error.InvalidInput;
        }
        const args: []const []const u8 = server.args orelse &.{};
        const env: []const Env = server.env orelse &.{};
        if (args.len > 256 or env.len > 128) return error.LimitExceeded;

        const argv = try allocator.alloc([]const u8, args.len + 1);
        argv[0] = server.command;
        for (argv[1..], args) |*dest, value| {
            if (!noNul(value)) return error.InvalidInput;
            dest.* = value;
        }
        const environment = try allocator.alloc(foo.config.Environment, env.len);
        for (env, 0..) |variable, env_index| {
            if (!environmentName(variable.name) or !noNul(variable.value)) return error.InvalidInput;
            for (environment[0..env_index]) |prior| {
                if (std.ascii.eqlIgnoreCase(prior.name, variable.name)) return error.InvalidInput;
            }
            environment[env_index] = .{ .name = variable.name, .value = .{ .literal = variable.value } };
        }
        result[index] = .{ .id = server.name, .transport = .{ .stdio = .{ .argv = argv, .environment = environment } } };
    }
    return .{ .cwd = input.cwd, .mcp_servers = result };
}

pub fn prompt(allocator: std.mem.Allocator, raw: []const u8, limits: Limits) foo.io.Error!struct {
    session: []const u8,
    message: foo.provider.Message,
} {
    const input = try parse(Prompt, allocator, raw);
    if (input.prompt.len == 0 or input.prompt.len > limits.prompt_blocks) return error.InvalidInput;
    const blocks = try allocator.alloc(foo.provider.Block, input.prompt.len);
    for (input.prompt, blocks) |value, *block| {
        const text = switch (value.type) {
            .text => value.text orelse return error.InvalidInput,
            .resource_link => link: {
                const name = value.name orelse return error.InvalidInput;
                const uri = value.uri orelse return error.InvalidInput;
                if (name.len == 0 or uri.len == 0 or !noNul(name) or !noNul(uri))
                    return error.InvalidInput;
                break :link try std.fmt.allocPrint(allocator, "Resource {s}\n{s}", .{ name, uri });
            },
        };
        block.* = .{ .text = text };
    }
    return .{ .session = input.sessionId, .message = .{ .role = .user, .blocks = blocks } };
}

pub fn cancelId(allocator: std.mem.Allocator, raw: []const u8) foo.io.Error!foo.jsonrpc.Id {
    const input = try parse(struct { requestId: std.json.Value }, allocator, raw);
    return switch (input.requestId) {
        .string => |value| .{ .string = value },
        .integer => |value| .{ .number = value },
        else => error.InvalidInput,
    };
}

pub fn noNul(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, 0) == null;
}

pub fn absolutePath(value: []const u8) bool {
    return value.len <= 4096 and noNul(value) and std.unicode.utf8ValidateSlice(value) and
        std.fs.path.isAbsolute(value);
}

pub fn environmentName(value: []const u8) bool {
    return value.len > 0 and noNul(value) and std.mem.indexOfScalar(u8, value, '=') == null;
}

pub fn stringify(buffer: []u8, value: anytype) foo.io.Error![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &writer) catch return error.LimitExceeded;
    return writer.buffered();
}

pub const ToolIdBuffer = [1024]u8;

pub fn toolId(buffer: *ToolIdBuffer, run: foo.events.RunId, source: []const u8) foo.io.Error![]const u8 {
    return std.fmt.bufPrint(buffer, "{d}:{s}", .{ @backingInt(run), source }) catch error.LimitExceeded;
}
