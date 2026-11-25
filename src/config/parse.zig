const std = @import("std");
const foo = @import("foo");
const root = @import("root.zig");
const cfg = foo.config;
const Value = std.json.Value;
const Error = root.Error;
const Self = @This();
const Catalog = @import("catalog.zig");

a: std.mem.Allocator,
operation: foo.io.Context,
diagnostic: *?root.Diagnostic,
base: []const u8,
source: cfg.Source = .defaults,
location: ?[]const u8 = null,
settings: root.Effective,
provenance: std.ArrayList(cfg.Provenance) = .empty,
catalog: Catalog = .{},
path_bytes_remaining: usize = root.max_effective_bytes,

pub fn report(self: *Self, path_name: []const u8, reason: @FieldType(root.Diagnostic, "reason")) void {
    self.diagnostic.* = .{ .path = path_name, .source = self.source, .location = self.location, .reason = reason };
}
pub fn fail(self: *Self, path_name: []const u8, reason: @FieldType(root.Diagnostic, "reason")) Error {
    self.report(path_name, reason);
    return error.InvalidConfiguration;
}
pub fn limit(self: *Self, path_name: []const u8) Error {
    self.report(path_name, .limit_exceeded);
    return error.LimitExceeded;
}
pub fn mark(self: *Self, key: []const u8) Error!void {
    for (self.provenance.items) |*entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            entry.source = self.source;
            entry.location = self.location;
            return;
        }
    }
    try self.provenance.append(self.a, .{ .key = key, .source = self.source, .location = self.location });
}
pub fn provenanceFor(self: *Self, key: []const u8) cfg.Provenance {
    return .{ .key = key, .source = self.source, .location = self.location };
}
pub fn useOrigin(self: *Self, entry: cfg.Provenance) void {
    self.source = entry.source;
    self.location = entry.location;
}
fn origin(self: *Self, key: []const u8) void {
    for (self.provenance.items) |entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            self.useOrigin(entry);
            return;
        }
    }
}
pub fn join(self: *Self, parent: []const u8, key: []const u8) Error![]const u8 {
    if (parent.len == 0) return key;
    try self.takePathBytes(parent.len + 1 + key.len);
    return std.mem.concat(self.a, u8, &.{ parent, ".", key });
}
fn index(self: *Self, parent: []const u8, n: usize) Error![]const u8 {
    const len = parent.len + 2 + std.fmt.count("{d}", .{n});
    try self.takePathBytes(len);
    const buffer = try self.a.alloc(u8, len);
    return std.fmt.bufPrint(buffer, "{s}[{d}]", .{ parent, n }) catch unreachable;
}
fn takePathBytes(self: *Self, bytes: usize) Error!void {
    if (bytes > self.path_bytes_remaining) return self.limit("$");
    self.path_bytes_remaining -= bytes;
}
pub fn object(self: *Self, value: Value, path_name: []const u8, allowed: []const []const u8) Error!std.json.ObjectMap {
    if (value != .object) return self.fail(if (path_name.len == 0) "$" else path_name, .invalid_value);
    for (value.object.keys()) |key| {
        for (allowed) |known| {
            if (std.mem.eql(u8, key, known)) break;
        } else {
            var safe = key.len > 0 and key.len <= 64;
            for (key) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') {
                safe = false;
            };
            return self.fail(try self.join(path_name, if (safe) key else "<unknown>"), .unknown_key);
        }
    }
    return value.object;
}
fn required(self: *Self, obj: std.json.ObjectMap, key: []const u8, parent: []const u8) Error!Value {
    return obj.get(key) orelse return self.fail(try self.join(parent, key), .missing_value);
}
pub fn string(self: *Self, value: Value, path_name: []const u8, empty: bool) Error![]const u8 {
    if (value != .string) return self.fail(path_name, .invalid_value);
    if ((!empty and value.string.len == 0) or std.mem.indexOfScalar(u8, value.string, 0) != null) return self.fail(path_name, .invalid_value);
    return value.string;
}
pub fn integer(self: *Self, comptime T: type, value: Value, path_name: []const u8, zero: bool) Error!T {
    if (value != .number_string) return self.fail(path_name, .invalid_value);
    for (value.number_string) |c| if (!std.ascii.isDigit(c)) return self.fail(path_name, .invalid_value);
    const result = std.fmt.parseInt(T, value.number_string, 10) catch return self.fail(path_name, .invalid_value);
    if (!zero and result == 0) return self.fail(path_name, .invalid_value);
    return result;
}
pub fn enumeration(self: *Self, comptime T: type, value: Value, path_name: []const u8) Error!T {
    const name = try self.string(value, path_name, false);
    return std.meta.stringToEnum(T, name) orelse return self.fail(path_name, .invalid_value);
}
fn boolean(self: *Self, value: Value, path_name: []const u8) Error!bool {
    if (value != .bool) return self.fail(path_name, .invalid_value);
    return value.bool;
}
fn array(self: *Self, value: Value, path_name: []const u8) Error![]const Value {
    if (value != .array) return self.fail(path_name, .invalid_value);
    return value.array.items;
}
fn strings(self: *Self, value: Value, path_name: []const u8, unique: bool) Error![]const []const u8 {
    const list = try self.array(value, path_name);
    const result = try self.a.alloc([]const u8, list.len);
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(self.a);
    for (list, 0..) |entry, i| {
        const p = try self.index(path_name, i);
        result[i] = try self.string(entry, p, false);
        if (unique) {
            const found = try names.getOrPut(self.a, result[i]);
            if (found.found_existing) return self.fail(p, .invalid_value);
        }
    }
    return result;
}
fn argvList(self: *Self, value: Value, path_name: []const u8) Error![]const []const u8 {
    const list = try self.array(value, path_name);
    if (list.len == 0) return self.fail(path_name, .invalid_value);
    const result = try self.a.alloc([]const u8, list.len);
    for (list, 0..) |entry, i| result[i] = try self.string(entry, try self.index(path_name, i), i != 0);
    return result;
}
pub fn envName(self: *Self, value: Value, path_name: []const u8) Error![]const u8 {
    const name = try self.string(value, path_name, false);
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return self.fail(path_name, .invalid_value);
    for (name[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return self.fail(path_name, .invalid_value);
    return name;
}
pub fn secret(self: *Self, value: Value, path_name: []const u8) Error!cfg.SecretRef {
    if (value == .null) return .none;
    const obj = try self.object(value, path_name, &.{ "environment", "literal", "auth" });
    if (obj.count() != 1) return self.fail(path_name, .invalid_value);
    if (obj.get("literal")) |v| {
        const p = try self.join(path_name, "literal");
        const key = try self.string(v, p, false);
        for (key) |c| if ((c < 32 and c != '\t') or c == 127) return self.fail(p, .invalid_value);
        return .{ .literal = key };
    }
    if (obj.get("auth")) |v| return .{ .auth = try Catalog.identifier(self, v, try self.join(path_name, "auth"), .provider) };
    return .{ .environment = try self.envName(obj.get("environment").?, try self.join(path_name, "environment")) };
}
fn referencedValue(self: *Self, value: Value, path_name: []const u8) Error!cfg.Value {
    if (value == .string) return .{ .literal = try self.string(value, path_name, true) };
    const obj = try self.object(value, path_name, &.{"environment"});
    return .{ .environment = try self.envName(try self.required(obj, "environment", path_name), try self.join(path_name, "environment")) };
}
pub fn headers(self: *Self, value: Value, path_name: []const u8) Error![]const cfg.Header {
    const entries = try self.array(value, path_name);
    const result = try self.a.alloc(cfg.Header, entries.len);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(self.a);
    for (entries, 0..) |entry, i| {
        const p = try self.index(path_name, i);
        const obj = try self.object(entry, p, &.{ "name", "value" });
        const name_path = try self.join(p, "name");
        const name = try self.string(try self.required(obj, "name", p), name_path, false);
        for (name) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return self.fail(name_path, .invalid_value);
        const lower = try self.a.dupe(u8, name);
        for (lower) |*c| c.* = std.ascii.toLower(c.*);
        const prior = try seen.getOrPut(self.a, lower);
        if (prior.found_existing) return self.fail(name_path, .invalid_value);
        const value_path = try self.join(p, "value");
        const v = try self.referencedValue(try self.required(obj, "value", p), value_path);
        if (v == .literal) for (v.literal) |c| {
            if (c == '\r' or c == '\n' or (c < 32 and c != '\t') or c == 127) return self.fail(value_path, .invalid_value);
        };
        result[i] = .{ .name = name, .value = v };
    }
    return result;
}
fn environment(self: *Self, value: Value, path_name: []const u8) Error![]const cfg.Environment {
    const entries = try self.array(value, path_name);
    const result = try self.a.alloc(cfg.Environment, entries.len);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(self.a);
    for (entries, 0..) |entry, i| {
        const p = try self.index(path_name, i);
        const obj = try self.object(entry, p, &.{ "name", "value" });
        const name_path = try self.join(p, "name");
        const name = try self.envName(try self.required(obj, "name", p), name_path);
        const lower = try self.a.dupe(u8, name);
        for (lower) |*c| c.* = std.ascii.toLower(c.*);
        const prior = try seen.getOrPut(self.a, lower);
        if (prior.found_existing) return self.fail(name_path, .invalid_value);
        result[i] = .{ .name = name, .value = try self.referencedValue(try self.required(obj, "value", p), try self.join(p, "value")) };
    }
    return result;
}
pub fn path(self: *Self, value: []const u8, path_name: []const u8) Error![]const u8 {
    if (!root.validPath(value)) return self.fail(path_name, .invalid_value);
    return std.fs.path.resolve(self.a, &.{ self.base, value });
}
pub fn url(self: *Self, value: Value, path_name: []const u8) Error![]const u8 {
    const text = try self.string(value, path_name, false);
    for (text) |c| if (c <= 32 or c == 127 or c == '\\') return self.fail(path_name, .invalid_value);
    const parsed = std.Uri.parse(text) catch return self.fail(path_name, .invalid_value);
    const scheme = if (std.ascii.eqlIgnoreCase(parsed.scheme, "https"))
        "https"
    else if (std.ascii.eqlIgnoreCase(parsed.scheme, "http"))
        "http"
    else
        return self.fail(path_name, .invalid_value);
    if (parsed.host == null or parsed.host.?.percent_encoded.len == 0 or
        parsed.user != null or parsed.password != null or parsed.fragment != null or parsed.port == 0)
        return self.fail(path_name, .invalid_value);
    if (std.mem.eql(u8, parsed.scheme, scheme)) return text;
    return std.mem.concat(self.a, u8, &.{ scheme, text[parsed.scheme.len..] });
}
pub fn sameOrigin(a: []const u8, b: []const u8) bool {
    const left = std.Uri.parse(a) catch return false;
    const right = std.Uri.parse(b) catch return false;
    const left_port = left.port orelse (if (std.ascii.eqlIgnoreCase(left.scheme, "https")) @as(u16, 443) else 80);
    const right_port = right.port orelse (if (std.ascii.eqlIgnoreCase(right.scheme, "https")) @as(u16, 443) else 80);
    return std.ascii.eqlIgnoreCase(left.scheme, right.scheme) and left.host != null and right.host != null and
        std.ascii.eqlIgnoreCase(left.host.?.percent_encoded, right.host.?.percent_encoded) and left_port == right_port;
}

pub fn defaults(self: *Self) Error!void {
    for ([_][]const u8{ "cwd", "system_prompt", "enabled_tools", "mcp_servers", "retry_attempts", "files_backend", "process_backend", "permissions", "session.directory", "custom_tools" }) |key| try self.mark(key);
    try self.defaultFields(cfg.Limits, "limits");
    inline for (@typeInfo(root.Process).@"struct".field_names) |key| {
        try self.mark(try self.join("process", key));
    }
    try self.defaultFields(root.SessionLimits, "session.limits");
    try self.defaultFields(@FieldType(root.Tui, "keys"), "tui.keys");
    try self.defaultFields(@FieldType(root.Tui, "colors"), "tui.colors");
}
fn defaultFields(self: *Self, comptime T: type, prefix: []const u8) Error!void {
    inline for (@typeInfo(T).@"struct".field_names) |key| try self.mark(try self.join(prefix, key));
}
fn mergeSimple(self: *Self, comptime T: type, target: *T, value: Value, prefix: []const u8) Error!void {
    const names = @typeInfo(T).@"struct".field_names;
    const allowed: [names.len][]const u8 = comptime blk: {
        var out: [names.len][]const u8 = undefined;
        for (names, 0..) |name, i| out[i] = name;
        break :blk out;
    };
    const obj = try self.object(value, prefix, &allowed);
    inline for (names) |key| {
        if (obj.get(key)) |v| {
            const p = try self.join(prefix, key);
            const F = @FieldType(T, key);
            @field(target, key) = switch (@typeInfo(F)) {
                .int => try self.integer(F, v, p, false),
                .@"enum" => try self.enumeration(F, v, p),
                else => @compileError("unsupported leaf type"),
            };
            try self.mark(p);
        }
    }
}

pub fn apply(self: *Self, value: Value) Error!void {
    const obj = try self.object(value, "", &.{ "version", "providers", "model", "cwd", "system_prompt", "enabled_tools", "mcp_servers", "limits", "retry_attempts", "files_backend", "process_backend", "permissions", "process", "session", "tui", "custom_tools" });
    if (obj.get("version")) |v| {
        if (try self.integer(u32, v, "version", true) != 1) {
            self.report("version", .unsupported_version);
            return error.UnsupportedVersion;
        }
    }
    if (obj.get("providers")) |v| try self.catalog.apply(self, v);
    if (obj.get("model")) |v| try self.catalog.select(self, v);
    if (obj.get("cwd")) |v| {
        self.settings.runtime.cwd = try self.path(try self.string(v, "cwd", false), "cwd");
        try self.mark("cwd");
    }
    if (obj.get("system_prompt")) |v| try self.prompt(v);
    if (obj.get("enabled_tools")) |v| {
        self.settings.runtime.enabled_tools = try self.strings(v, "enabled_tools", true);
        try self.mark("enabled_tools");
    }
    if (obj.get("mcp_servers")) |v| {
        self.settings.runtime.mcp_servers = try self.servers(v);
        try self.mark("mcp_servers");
    }
    if (obj.get("limits")) |v| try self.mergeSimple(cfg.Limits, &self.settings.runtime.limits, v, "limits");
    if (obj.get("retry_attempts")) |v| {
        self.settings.runtime.retry_attempts = try self.integer(u32, v, "retry_attempts", true);
        try self.mark("retry_attempts");
    }
    inline for (.{ "files_backend", "process_backend", "permissions" }) |key| {
        if (obj.get(key)) |v| {
            @field(self.settings.runtime, key) = try self.enumeration(@FieldType(cfg.Resolved, key), v, key);
            try self.mark(key);
        }
    }
    if (obj.get("custom_tools")) |v| {
        self.settings.launch.custom_tools = try self.customTools(v);
        try self.mark("custom_tools");
    }
    if (obj.get("process")) |v| try self.process(v);
    if (obj.get("session")) |v| try self.session(v);
    if (obj.get("tui")) |v| {
        const t = try self.object(v, "tui", &.{ "keys", "colors" });
        if (t.get("keys")) |keys| try self.mergeSimple(@FieldType(root.Tui, "keys"), &self.settings.launch.tui.keys, keys, "tui.keys");
        if (t.get("colors")) |colors| try self.mergeSimple(@FieldType(root.Tui, "colors"), &self.settings.launch.tui.colors, colors, "tui.colors");
    }
}
fn prompt(self: *Self, value: Value) Error!void {
    const obj = try self.object(value, "system_prompt", &.{ "text", "append_files" });
    self.settings.runtime.system_prompt = if (obj.get("text")) |v| try self.string(v, "system_prompt.text", true) else "";
    const paths = if (obj.get("append_files")) |v| try self.strings(v, "system_prompt.append_files", false) else &.{};
    const resolved = try self.a.alloc([]const u8, paths.len);
    for (paths, 0..) |p, i| resolved[i] = try self.path(p, try self.index("system_prompt.append_files", i));
    self.settings.prompt_files = resolved;
    try self.mark("system_prompt");
}
fn servers(self: *Self, value: Value) Error![]const cfg.McpServer {
    const entries = try self.array(value, "mcp_servers");
    const result = try self.a.alloc(cfg.McpServer, entries.len);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(self.a);
    for (entries, 0..) |entry, i| {
        const p = try self.index("mcp_servers", i);
        const obj = try self.object(entry, p, &.{ "id", "revision", "transport" });
        const id_path = try self.join(p, "id");
        const id = try self.string(try self.required(obj, "id", p), id_path, false);
        const prior = try seen.getOrPut(self.a, id);
        if (prior.found_existing) return self.fail(id_path, .invalid_value);
        const revision: ?cfg.McpRevision = if (obj.get("revision")) |v| (if (v == .null) null else try self.enumeration(cfg.McpRevision, v, try self.join(p, "revision"))) else null;
        const tp = try self.join(p, "transport");
        const t = try self.object(try self.required(obj, "transport", p), tp, &.{ "stdio", "http" });
        if (t.count() != 1) return self.fail(tp, .invalid_value);
        if (t.get("stdio")) |v| {
            const sp = try self.join(tp, "stdio");
            const s = try self.object(v, sp, &.{ "argv", "environment" });
            const ap = try self.join(sp, "argv");
            const argv = try self.argvList(try self.required(s, "argv", sp), ap);
            result[i] = .{ .id = id, .revision = revision, .transport = .{ .stdio = .{
                .argv = argv,
                .environment = if (s.get("environment")) |env| try self.environment(env, try self.join(sp, "environment")) else &.{},
            } } };
        } else {
            const hp = try self.join(tp, "http");
            const h = try self.object(t.get("http").?, hp, &.{ "url", "headers" });
            result[i] = .{ .id = id, .revision = revision, .transport = .{ .http = .{
                .url = try self.url(try self.required(h, "url", hp), try self.join(hp, "url")),
                .headers = if (h.get("headers")) |hs| try self.headers(hs, try self.join(hp, "headers")) else &.{},
            } } };
        }
    }
    return result;
}
fn process(self: *Self, value: Value) Error!void {
    const obj = try self.object(value, "process", &.{ "file_bytes", "environment", "inherit_environment", "timeout_ms", "cleanup_ms" });
    const p = &self.settings.launch.process;
    if (obj.get("environment")) |v| {
        p.environment = try self.environment(v, "process.environment");
        try self.mark("process.environment");
    }
    if (obj.get("inherit_environment")) |v| {
        p.inherit_environment = try self.boolean(v, "process.inherit_environment");
        try self.mark("process.inherit_environment");
    }
    inline for (.{ "file_bytes", "timeout_ms", "cleanup_ms" }) |key| {
        if (obj.get(key)) |v| {
            const path_name = try self.join("process", key);
            @field(p, key) = try self.integer(@FieldType(root.Process, key), v, path_name, false);
            try self.mark(path_name);
        }
    }
}
fn session(self: *Self, value: Value) Error!void {
    const obj = try self.object(value, "session", &.{ "directory", "limits" });
    if (obj.get("directory")) |v| {
        self.settings.launch.session.directory = if (v == .null) null else try self.path(try self.string(v, "session.directory", false), "session.directory");
        try self.mark("session.directory");
    }
    if (obj.get("limits")) |v| try self.mergeSimple(root.SessionLimits, &self.settings.launch.session.limits, v, "session.limits");
}

pub fn readFile(self: *Self, filename: []const u8, path_name: []const u8, bound: usize) (Error || error{FileNotFound})![]const u8 {
    try self.operation.check();
    const io = self.operation.io;
    const stat = std.Io.Dir.cwd().statFile(io, filename, .{}) catch |err| {
        if (err == error.FileNotFound) return error.FileNotFound;
        return self.fileError(path_name, err);
    };
    if (stat.kind != .file) return self.fail(path_name, .invalid_value);
    if (stat.size > bound) return self.limit(path_name);
    const file = std.Io.Dir.cwd().openFile(io, filename, .{ .allow_directory = false }) catch |err| {
        if (err == error.FileNotFound) return error.FileNotFound;
        return self.fileError(path_name, err);
    };
    defer file.close(io);
    const actual = file.stat(io) catch |err| return self.fileError(path_name, err);
    if (actual.kind != .file) return self.fail(path_name, .invalid_value);
    if (actual.size > bound) return self.limit(path_name);
    var bytes: std.ArrayList(u8) = .empty;
    var chunk: [8192]u8 = undefined;
    while (true) {
        try self.operation.check();
        const n = file.readPositional(io, &.{&chunk}, bytes.items.len) catch |err| return self.fileError(path_name, err);
        if (n == 0) break;
        if (n > bound - bytes.items.len) return self.limit(path_name);
        try bytes.appendSlice(self.a, chunk[0..n]);
    }
    try self.operation.check();
    return bytes.toOwnedSlice(self.a);
}
pub fn fileError(self: *Self, path_name: []const u8, err: anyerror) Error {
    if (err == error.Canceled) return error.Cancelled;
    if (err == error.OutOfMemory) return error.OutOfMemory;
    self.report(path_name, .file_io);
    return error.IoFailure;
}

pub fn finish(self: *Self, patch: root.ModelPatch) Error!void {
    try self.catalog.finish(self, patch);
    const runtime = &self.settings.runtime;
    const keys = self.settings.launch.tui.keys;
    const names = @typeInfo(@TypeOf(keys)).@"struct".field_names;
    inline for (names, 0..) |key, i| {
        inline for (names[0..i]) |prior| {
            if (@field(keys, key) == @field(keys, prior)) {
                self.origin("tui.keys." ++ key);
                return self.fail("tui.keys." ++ key, .invalid_value);
            }
        }
    }
    self.origin("system_prompt");
    if (runtime.system_prompt.len > root.max_prompt_bytes) return self.limit("system_prompt");
    var prompt_text: std.ArrayList(u8) = .empty;
    try prompt_text.appendSlice(self.a, runtime.system_prompt);
    for (self.settings.prompt_files, 0..) |file, i| {
        const p = try self.index("system_prompt.append_files", i);
        const bytes = self.readFile(file, p, root.max_prompt_bytes - prompt_text.items.len) catch |err| switch (err) {
            error.FileNotFound => return self.fileError(p, err),
            else => |shared| return shared,
        };
        if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null) return self.fail(p, .invalid_value);
        const separator: usize = if (prompt_text.items.len != 0 and bytes.len != 0) 1 else 0;
        if (bytes.len + separator > root.max_prompt_bytes - prompt_text.items.len) return self.limit(p);
        if (separator != 0) try prompt_text.append(self.a, '\n');
        try prompt_text.appendSlice(self.a, bytes);
    }
    runtime.system_prompt = try prompt_text.toOwnedSlice(self.a);
    runtime.provenance = try self.provenance.toOwnedSlice(self.a);
}

fn customTools(self: *Self, value: Value) Error![]const root.CustomTool {
    const entries = try self.array(value, "custom_tools");
    const result = try self.a.alloc(root.CustomTool, entries.len);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(self.a);
    for (entries, 0..) |entry, i| {
        const p = try self.index("custom_tools", i);
        const obj = try self.object(entry, p, &.{ "name", "description", "schema", "argv", "environment", "inherit_environment", "timeout_ms" });
        const np = try self.join(p, "name");
        const name = try self.string(try self.required(obj, "name", p), np, false);
        if (name.len > 64) return self.fail(np, .invalid_value);
        for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return self.fail(np, .invalid_value);
        for (root.coding_tools) |builtin| if (std.mem.eql(u8, builtin, name)) return self.fail(np, .invalid_value);
        const prior = try seen.getOrPut(self.a, name);
        if (prior.found_existing) return self.fail(np, .invalid_value);
        const ap = try self.join(p, "argv");
        const argv = try self.argvList(try self.required(obj, "argv", p), ap);
        const schema = try self.required(obj, "schema", p);
        if (schema != .object) return self.fail(try self.join(p, "schema"), .invalid_value);
        result[i] = .{
            .name = name,
            .description = try self.string(try self.required(obj, "description", p), try self.join(p, "description"), true),
            .schema_json = try std.json.Stringify.valueAlloc(self.a, schema, .{}),
            .argv = argv,
            .environment = if (obj.get("environment")) |env| try self.environment(env, try self.join(p, "environment")) else &.{},
            .inherit_environment = if (obj.get("inherit_environment")) |v| try self.boolean(v, try self.join(p, "inherit_environment")) else false,
            .timeout_ms = if (obj.get("timeout_ms")) |v| try self.integer(u64, v, try self.join(p, "timeout_ms"), false) else 30_000,
        };
    }
    return result;
}
