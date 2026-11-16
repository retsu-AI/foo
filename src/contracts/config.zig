pub const Family = enum { openai_responses, openai_chat, anthropic_messages };
pub const McpRevision = enum { @"2026-07-28", @"2025-11-25" };
pub const acp_version: u32 = 1;

pub const Limits = struct {
    wire_message_bytes: usize = 8 * 1024 * 1024,
    json_depth: usize = 64,
    pending_requests: usize = 64,
    pending_events: usize = 64,
    active_commands: usize = 16,
    server_stderr_bytes: usize = 256 * 1024,
    catalog_pages: usize = 128,
    catalog_bytes: usize = 16 * 1024 * 1024,
    tool_argument_bytes: usize = 1024 * 1024,
    tool_output_bytes: usize = 64 * 1024,
    transcript_bytes: usize = 32 * 1024 * 1024,
    model_turns: u32 = 100,
    tool_calls: u32 = 1000,
};
pub const Source = enum { defaults, preset, file, environment, command_line };
pub const precedence = [_]Source{ .defaults, .preset, .file, .environment, .command_line };
pub const Provenance = struct { key: []const u8, source: Source, location: ?[]const u8 = null };
pub const SecretRef = union(enum) { none, environment: []const u8 };
pub const Value = union(enum) { literal: []const u8, environment: []const u8 };
pub const Header = struct { name: []const u8, value: Value };
pub const Model = struct {
    family: Family,
    endpoint: []const u8,
    id: []const u8,
    credential: SecretRef = .none,
    headers: []const Header = &.{},
    options_json: []const u8 = "{}",
    max_output_tokens: u32 = 4096,
};
pub const Backend = enum { local, client };
pub const PermissionMode = enum { allow, ask, deny };
pub const Environment = struct { name: []const u8, value: Value };
pub const McpServer = struct {
    id: []const u8,
    revision: ?McpRevision = null,
    transport: union(enum) {
        stdio: struct { argv: []const []const u8, environment: []const Environment = &.{} },
        http: struct { url: []const u8, headers: []const Header = &.{} },
    },
};

/// Immutable resolved settings, borrowed through run teardown.
pub const Resolved = struct {
    model: Model,
    cwd: []const u8,
    system_prompt: []const u8 = "",
    limits: Limits = .{},
    retry_attempts: u32 = 0,
    enabled_tools: []const []const u8 = &.{},
    mcp_servers: []const McpServer = &.{},
    files_backend: Backend = .local,
    process_backend: Backend = .local,
    permissions: PermissionMode = .deny,
    provenance: []const Provenance = &.{},

    pub fn validate(self: Resolved) error{InvalidConfiguration}!void {
        if (self.model.id.len == 0 or self.model.endpoint.len == 0 or self.cwd.len == 0)
            return error.InvalidConfiguration;
        inline for (@typeInfo(Limits).@"struct".field_names) |name| {
            if (@field(self.limits, name) == 0) return error.InvalidConfiguration;
        }
        if (self.model.max_output_tokens == 0) return error.InvalidConfiguration;
        for (self.mcp_servers) |server| {
            if (server.id.len == 0) return error.InvalidConfiguration;
            switch (server.transport) {
                .stdio => |v| if (v.argv.len == 0 or v.argv[0].len == 0) return error.InvalidConfiguration,
                .http => |v| if (v.url.len == 0) return error.InvalidConfiguration,
            }
        }
    }
};
