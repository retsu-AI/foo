const std = @import("std");
const foo = @import("foo");
const storage = @import("store.zig");
pub const oauth = @import("oauth.zig");
const openai_codex = @import("openai_codex.zig");

pub const Store = storage.Store;
pub const Entry = storage.Entry;
pub const OAuth = storage.OAuth;
pub const validProviderId = storage.validProviderId;
pub const max_secret_bytes = storage.max_secret_bytes;
pub const Error = storage.Error || error{Authentication};

pub const Credential = union(enum) {
    api_key: []const u8,
    bearer: Bearer,

    pub const Bearer = struct { token: []const u8, account: ?Account = null };
    pub const Account = struct { header: []const u8, value: []const u8 };

    pub fn valid(self: Credential) bool {
        return switch (self) {
            .api_key => |key| key.len != 0 and validHeaderValue(key),
            .bearer => |bearer| storage.validSecret(bearer.token) and
                (if (bearer.account) |account| account.header.len != 0 and storage.validSecret(account.value) else true),
        };
    }
};

pub const CredentialSource = struct {
    context: *const anyopaque,
    resolve_fn: *const fn (*const anyopaque, std.mem.Allocator, foo.io.Context, foo.config.SecretRef) Error!Credential,
    refresh_fn: ?*const fn (*const anyopaque, std.mem.Allocator, foo.io.Context, foo.config.SecretRef, Credential.Bearer) Error!bool = null,

    /// Direct and environment values may borrow the caller's config or environment.
    /// Stored credentials are copied into the caller's allocator.
    pub fn resolve(self: CredentialSource, a: std.mem.Allocator, operation: foo.io.Context, reference: foo.config.SecretRef) Error!Credential {
        try operation.check();
        const credential = try self.resolve_fn(self.context, a, operation, reference);
        if (!credential.valid()) return error.Authentication;
        return credential;
    }

    pub fn refresh(self: CredentialSource, a: std.mem.Allocator, operation: foo.io.Context, reference: foo.config.SecretRef, bearer: Credential.Bearer) Error!bool {
        try operation.check();
        const refresh_fn = self.refresh_fn orelse return false;
        return refresh_fn(self.context, a, operation, reference, bearer);
    }
};

pub const Notice = union(enum) {
    url: []const u8,
    device_code: struct { uri: []const u8, code: []const u8 },
};

pub const Prompt = struct {
    context: *anyopaque,
    show_fn: *const fn (*anyopaque, foo.io.Context, Notice) Error!void,

    pub fn show(self: Prompt, operation: foo.io.Context, notice: Notice) Error!void {
        try operation.check();
        return self.show_fn(self.context, operation, notice);
    }
};

pub const Login = struct {
    a: std.mem.Allocator,
    operation: foo.io.Context,
    http: foo.io.HttpTransport,
    prompt: Prompt,
};

pub const Refresh = struct {
    a: std.mem.Allocator,
    operation: foo.io.Context,
    http: foo.io.HttpTransport,
    current: OAuth,
};

pub const Flow = struct {
    provider: []const u8,
    browser: ?*const fn (Login) Error!OAuth = null,
    device: ?*const fn (Login) Error!OAuth = null,
    refresh: ?*const fn (Refresh) Error!OAuth = null,
    account_header: ?[]const u8 = null,
};

pub const flows: []const Flow = &.{openai_codex.flow};

pub fn findFlow(registry: []const Flow, provider: []const u8) ?Flow {
    for (registry) |flow| if (std.mem.eql(u8, flow.provider, provider)) return flow;
    return null;
}

const refresh_window_ms = 60_000;

pub const Resolver = struct {
    environment: ?*const std.process.Environ.Map = null,
    store: ?Store = null,
    registry: []const Flow = flows,
    /// Enables refresh. Without it, stored tokens are returned as they are.
    http: ?foo.io.HttpTransport = null,

    pub fn interface(self: *const Resolver) CredentialSource {
        return .{ .context = self, .resolve_fn = resolve, .refresh_fn = refresh };
    }

    fn resolve(raw: *const anyopaque, a: std.mem.Allocator, operation: foo.io.Context, reference: foo.config.SecretRef) Error!Credential {
        const self: *const Resolver = @ptrCast(@alignCast(raw));
        if (reference != .auth) return direct(self.environment, reference);
        const provider = reference.auth;
        const store = self.store orelse return error.Authentication;
        var snapshot = try store.read(a, operation);
        defer snapshot.deinit();
        const entry = snapshot.entries.get(provider) orelse return error.Authentication;
        var current = switch (entry) {
            .api_key => |key| return .{ .api_key = try a.dupe(u8, key) },
            .oauth => |value| value,
        };
        const flow = findFlow(self.registry, provider);
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        if (flow) |registered| {
            const now_ms = std.Io.Timestamp.now(operation.io, .real).toMilliseconds();
            if (current.expires_ms -| now_ms < refresh_window_ms) {
                if (try self.renew(scratch.allocator(), operation, registered, current)) |latest| current = latest;
            }
        }
        const token = try a.dupe(u8, current.access);
        errdefer a.free(token);
        const header = if (flow) |registered| registered.account_header else null;
        return .{ .bearer = .{
            .token = token,
            .account = if (header) |name| if (current.account) |account| .{ .header = name, .value = try a.dupe(u8, account) } else null else null,
        } };
    }

    fn refresh(raw: *const anyopaque, a: std.mem.Allocator, operation: foo.io.Context, reference: foo.config.SecretRef, attempted: Credential.Bearer) Error!bool {
        const self: *const Resolver = @ptrCast(@alignCast(raw));
        if (reference != .auth) return false;
        const flow = findFlow(self.registry, reference.auth) orelse return false;
        const store = self.store orelse return false;
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const snapshot = try store.read(scratch.allocator(), operation);
        const entry = snapshot.entries.get(reference.auth) orelse return false;
        if (entry != .oauth) return false;
        if (!std.mem.eql(u8, entry.oauth.access, attempted.token)) return true;
        const latest = try self.renew(scratch.allocator(), operation, flow, entry.oauth) orelse return false;
        return !std.mem.eql(u8, latest.access, attempted.token);
    }

    /// Returns the entry current after the refresh, which another process may have written.
    fn renew(self: *const Resolver, arena: std.mem.Allocator, operation: foo.io.Context, flow: Flow, current: OAuth) Error!?OAuth {
        const refresh_fn = flow.refresh orelse return null;
        const http = self.http orelse return null;
        const store = self.store orelse return null;
        if (current.refresh == null) return null;
        var updated = try refresh_fn(.{ .a = arena, .operation = operation, .http = http, .current = current });
        if (updated.account == null) updated.account = current.account;
        if (try store.replaceOAuth(arena, operation, flow.provider, current, updated)) return updated;
        const latest = try store.read(arena, operation);
        const entry = latest.entries.get(flow.provider) orelse return null;
        return if (entry == .oauth) entry.oauth else null;
    }
};

fn direct(environment: ?*const std.process.Environ.Map, reference: foo.config.SecretRef) Error!Credential {
    const value: foo.config.Value = switch (reference) {
        .literal => |text| .{ .literal = text },
        .environment => |name| .{ .environment = name },
        .auth, .none => return error.Authentication,
    };
    return .{ .api_key = resolveValue(environment, value) catch return error.Authentication };
}

pub fn resolveValue(environment: ?*const std.process.Environ.Map, value: foo.config.Value) error{Unavailable}![]const u8 {
    return switch (value) {
        .literal => |text| text,
        .environment => |name| (environment orelse return error.Unavailable).get(name) orelse error.Unavailable,
    };
}

pub fn validHeaderValue(bytes: []const u8) bool {
    for (bytes) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return false;
    return true;
}
