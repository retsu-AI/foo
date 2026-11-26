const std = @import("std");
const foo = @import("foo");
const builtins = @import("builtins");
const storage = @import("store.zig");
pub const oauth = @import("oauth.zig");
const openai_codex = @import("openai_codex.zig");
const xai = @import("xai.zig");
const meta = @import("meta.zig");

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

pub const flows: []const Flow = &.{ openai_codex.flow, xai.flow, meta.flow };

comptime {
    for (flows) |flow| if (builtins.find(flow.provider) == null) @compileError("auth flow " ++ flow.provider ++ " has no built-in record");
}

pub fn findFlow(registry: []const Flow, provider: []const u8) ?Flow {
    for (registry) |flow| if (std.mem.eql(u8, flow.provider, provider)) return flow;
    return null;
}

/// The variables a built-in reads when nothing is stored for it, in lookup order.
pub fn fallbackVariables(provider: []const u8) []const []const u8 {
    const builtin = builtins.find(provider) orelse return &.{};
    return builtin.record.env;
}

/// The first of a built-in's variables that holds a usable key, for `auth list` and the
/// resolver. The same predicate as `foo auth login` uses, so a padded or blank-looking
/// value counts as unset and never wins the zero-config pick.
pub fn availableVariable(environment: ?*const std.process.Environ.Map, provider: []const u8) ?[]const u8 {
    for (fallbackVariables(provider)) |name| {
        if (environmentValue(environment, name) != null) return name;
    }
    return null;
}

/// What `foo models`, `auth list`, and the zero-config pick see: one store read, no network,
/// no refresh. An OAuth entry counts when it is unexpired or carries a refresh token.
pub const Availability = union(enum) {
    stored_key,
    oauth: i64,
    environment: []const u8,
    missing,
};

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

    pub fn availability(self: *const Resolver, a: std.mem.Allocator, operation: foo.io.Context, reference: foo.config.SecretRef) Error!Availability {
        try operation.check();
        switch (reference) {
            .none => return .missing,
            .literal => return .stored_key,
            .environment => |name| return if (environmentValue(self.environment, name) != null) .{ .environment = name } else .missing,
            .auth => |provider| {
                if (self.store) |store| {
                    var snapshot = try store.read(a, operation);
                    defer snapshot.deinit();
                    if (snapshot.entries.get(provider)) |entry| switch (entry) {
                        .api_key => return .stored_key,
                        .oauth => |token| {
                            const now_ms = std.Io.Timestamp.now(operation.io, .real).toMilliseconds();
                            return if (token.expires_ms > now_ms or token.refresh != null) .{ .oauth = token.expires_ms } else .missing;
                        },
                    };
                }
                if (availableVariable(self.environment, provider)) |name| return .{ .environment = name };
                return .missing;
            },
        }
    }

    /// A stored entry owns the slot, including an expired one that cannot be renewed. Only an
    /// absent entry falls through to the built-in's environment variables.
    fn resolve(raw: *const anyopaque, a: std.mem.Allocator, operation: foo.io.Context, reference: foo.config.SecretRef) Error!Credential {
        const self: *const Resolver = @ptrCast(@alignCast(raw));
        if (reference != .auth) return direct(self.environment, reference);
        const provider = reference.auth;
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const stored: ?Entry = if (self.store) |store| (try store.read(scratch.allocator(), operation)).entries.get(provider) else null;
        const entry = stored orelse {
            for (fallbackVariables(provider)) |name| {
                if (environmentValue(self.environment, name)) |value| return .{ .api_key = value };
            }
            return error.Authentication;
        };
        var current = switch (entry) {
            .api_key => |key| return .{ .api_key = try a.dupe(u8, key) },
            .oauth => |value| value,
        };
        const flow = findFlow(self.registry, provider);
        if (flow) |registered| {
            const now_ms = std.Io.Timestamp.now(operation.io, .real).toMilliseconds();
            if (current.expires_ms -| now_ms < refresh_window_ms) {
                // A token that has not expired yet stays usable when the refresh endpoint fails.
                const renewed = self.renew(scratch.allocator(), operation, registered, current) catch |err| switch (err) {
                    error.Cancelled, error.OutOfMemory => |e| return e,
                    else => if (current.expires_ms > now_ms) null else return err,
                };
                if (renewed) |latest| current = latest;
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
        var updated = refresh_fn(.{ .a = arena, .operation = operation, .http = http, .current = current }) catch |err| switch (err) {
            error.Cancelled, error.OutOfMemory => |e| return e,
            // Another process may have spent this refresh token on a rotating issuer and saved the result.
            else => return try newerEntry(arena, operation, store, flow.provider, current) orelse err,
        };
        if (updated.account == null) updated.account = current.account;
        if (try store.replaceOAuth(arena, operation, flow.provider, current, updated)) return updated;
        const latest = try store.read(arena, operation);
        const entry = latest.entries.get(flow.provider) orelse return null;
        return if (entry == .oauth) entry.oauth else null;
    }

    fn newerEntry(arena: std.mem.Allocator, operation: foo.io.Context, store: Store, provider: []const u8, current: OAuth) Error!?OAuth {
        const latest = try store.read(arena, operation);
        const entry = latest.entries.get(provider) orelse return null;
        if (entry != .oauth or std.mem.eql(u8, entry.oauth.access, current.access)) return null;
        return entry.oauth;
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

/// A set variable counts as unset when it holds nothing `foo auth login` would store: empty,
/// padded with spaces, or carrying control bytes. `FOO_API_KEY= foo run` falls through.
fn environmentValue(environment: ?*const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const value = (environment orelse return null).get(name) orelse return null;
    return if (storage.validSecret(value)) value else null;
}

pub fn validHeaderValue(bytes: []const u8) bool {
    for (bytes) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return false;
    return true;
}
