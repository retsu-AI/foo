const std = @import("std");
const foo = @import("foo");
const storage = @import("store.zig");

pub const Store = storage.Store;
pub const Entry = storage.Entry;
pub const OAuth = storage.OAuth;
pub const validProviderId = storage.validProviderId;
pub const max_secret_bytes = storage.max_secret_bytes;
pub const Error = storage.Error || error{Authentication};

pub const Credential = union(enum) {
    api_key: []const u8,
    bearer: Bearer,

    pub const Bearer = struct { token: []const u8, account: ?[]const u8 };

    pub fn valid(self: Credential) bool {
        return switch (self) {
            .api_key => |key| key.len != 0 and validHeaderValue(key),
            .bearer => |bearer| storage.validSecret(bearer.token) and
                (if (bearer.account) |account| storage.validSecret(account) else true),
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

pub const Flow = struct {
    provider: []const u8,
    login_fn: *const fn (std.mem.Allocator, foo.io.Context) Error!OAuth,
    refresh_fn: ?*const fn (std.mem.Allocator, foo.io.Context, OAuth, []const u8) Error!OAuth = null,
};

pub const flows: []const Flow = &.{};

pub fn findFlow(registry: []const Flow, provider: []const u8) ?Flow {
    for (registry) |flow| if (std.mem.eql(u8, flow.provider, provider)) return flow;
    return null;
}

pub const Resolver = struct {
    environment: ?*const std.process.Environ.Map = null,
    store: ?Store = null,
    registry: []const Flow = flows,

    pub fn interface(self: *const Resolver) CredentialSource {
        return .{ .context = self, .resolve_fn = resolve, .refresh_fn = refresh };
    }

    fn resolve(raw: *const anyopaque, a: std.mem.Allocator, operation: foo.io.Context, reference: foo.config.SecretRef) Error!Credential {
        const self: *const Resolver = @ptrCast(@alignCast(raw));
        if (reference != .auth) return direct(self.environment, reference);
        const store = self.store orelse return error.Authentication;
        var snapshot = try store.read(a, operation);
        defer snapshot.deinit();
        const entry = snapshot.entries.get(reference.auth) orelse return error.Authentication;
        return switch (entry) {
            .api_key => |key| .{ .api_key = try a.dupe(u8, key) },
            .oauth => |oauth| blk: {
                const token = try a.dupe(u8, oauth.access);
                errdefer a.free(token);
                break :blk .{ .bearer = .{
                    .token = token,
                    .account = if (oauth.account) |account| try a.dupe(u8, account) else null,
                } };
            },
        };
    }

    fn refresh(raw: *const anyopaque, a: std.mem.Allocator, operation: foo.io.Context, reference: foo.config.SecretRef, attempted: Credential.Bearer) Error!bool {
        const self: *const Resolver = @ptrCast(@alignCast(raw));
        if (reference != .auth) return false;
        const provider = reference.auth;
        const flow = findFlow(self.registry, provider) orelse return false;
        const refresh_fn = flow.refresh_fn orelse return false;
        const store = self.store orelse return false;
        var snapshot = try store.read(a, operation);
        defer snapshot.deinit();
        const entry = snapshot.entries.get(provider) orelse return false;
        if (entry != .oauth) return false;
        const oauth = entry.oauth;
        const token = oauth.refresh orelse return false;
        if (!std.mem.eql(u8, oauth.access, attempted.token)) return true;
        const updated = try refresh_fn(a, operation, oauth, token);
        if (try store.replaceOAuth(a, operation, provider, oauth, updated)) return true;

        var latest = try store.read(a, operation);
        defer latest.deinit();
        const current = latest.entries.get(provider) orelse return false;
        return current == .oauth and !std.mem.eql(u8, current.oauth.access, attempted.token);
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
