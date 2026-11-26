//! Rows for `foo models`. Merges user `models` over the built-in catalog in one place, so the TUI
//! `/model` picker can reuse it.
const std = @import("std");
const foo = @import("foo");
const auth = @import("auth");
const config = @import("configuration");
const builtins = @import("builtins");
const cfg = foo.config;

pub const Status = union(enum) {
    ready,
    needs_login,
    needs_env: []const u8,
    needs_login_or_env: []const u8,
    /// The model's endpoint is on another origin, so a run sends it without the provider credential.
    no_credential,

    pub fn format(self: Status, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .ready => try writer.writeAll("ready"),
            .needs_login => try writer.writeAll("needs login"),
            .needs_env => |name| try writer.print("needs {s}", .{name}),
            .needs_login_or_env => |name| try writer.print("needs login or {s}", .{name}),
            .no_credential => try writer.writeAll("no credential"),
        }
    }
};

pub const Row = struct {
    provider: []const u8,
    id: []const u8,
    name: []const u8,
    context: ?u32,
    status: Status,
    selected: bool,
};

pub const Filter = struct { provider: ?[]const u8 = null, all: bool = false };

pub const Listing = struct {
    rows: []const Row,
    /// Providers hidden because they have no credential. Zero when `all` or a provider is given.
    hidden_providers: usize,
};

pub const Error = auth.Error;

/// Built-ins in registry order, then user providers in layer order. Within a provider, catalog
/// models by id with any user name applied, then user declared models that are not in the
/// catalog. A provider without a credential is hidden unless `all` or `provider` names it, or
/// it holds the selected model. Each row's status follows the credential a run of that model
/// would send, so a model routed to another origin never claims the provider's credential.
pub fn list(a: std.mem.Allocator, operation: foo.io.Context, effective: config.Effective, resolver: *const auth.Resolver, filter: Filter) Error!Listing {
    var rows: std.ArrayList(Row) = .empty;
    var hidden: usize = 0;
    var order: std.ArrayList([]const u8) = .empty;
    for (builtins.all) |builtin| if (effective.providers.contains(builtin.record.id)) try order.append(a, builtin.record.id);
    for (effective.providers.keys()) |id| if (builtins.find(id) == null) try order.append(a, id);
    if (filter.provider) |id| {
        order.clearRetainingCapacity();
        try order.append(a, id);
    }
    for (order.items) |id| {
        const provider = effective.providers.get(id).?;
        const status = try statusOf(a, operation, resolver, provider.credential);
        const selected_here = std.mem.eql(u8, id, effective.selected.provider);
        if (status != .ready and !filter.all and filter.provider == null and !selected_here) {
            hidden += 1;
            continue;
        }
        for (provider.catalog) |model| {
            const declared = declaredName(provider, model.id);
            try rows.append(a, .{
                .provider = id,
                .id = model.id,
                .name = declared orelse model.name,
                .context = model.context_limit,
                .status = try rowStatus(a, operation, resolver, effective, provider, id, model.id, status),
                .selected = selected_here and std.mem.eql(u8, model.id, effective.selected.model),
            });
        }
        for (provider.models) |model| {
            if (builtins.model(provider.catalog, model.id) != null) continue;
            try rows.append(a, .{
                .provider = id,
                .id = model.id,
                .name = model.name orelse model.id,
                .context = null,
                .status = try rowStatus(a, operation, resolver, effective, provider, id, model.id, status),
                .selected = selected_here and std.mem.eql(u8, model.id, effective.selected.model),
            });
        }
    }
    return .{ .rows = rows.items, .hidden_providers = hidden };
}

fn declaredName(provider: cfg.Provider, id: []const u8) ?[]const u8 {
    for (provider.models) |model| if (std.mem.eql(u8, model.id, id)) return model.name;
    return null;
}

/// The provider's status applies to a model only when a run of it would send the provider's
/// credential. The selected model reads the credential the run resolved, which includes
/// `--credential-env`. A model with `credential: none` on its provider is `ready` either way.
fn rowStatus(a: std.mem.Allocator, operation: foo.io.Context, resolver: *const auth.Resolver, effective: config.Effective, provider: cfg.Provider, provider_id: []const u8, id: []const u8, provider_status: Status) Error!Status {
    const selected = std.mem.eql(u8, provider_id, effective.selected.provider) and std.mem.eql(u8, id, effective.selected.model);
    const credential = if (selected) effective.runtime.model.credential else config.modelCredential(provider, id);
    if (credential == .none) return if (provider.credential == .none) .ready else .no_credential;
    if (!selected) return provider_status;
    return statusOf(a, operation, resolver, credential);
}

fn statusOf(a: std.mem.Allocator, operation: foo.io.Context, resolver: *const auth.Resolver, credential: cfg.SecretRef) auth.Error!Status {
    switch (try resolver.availability(a, operation, credential)) {
        .stored_key, .oauth, .environment => return .ready,
        .missing => {},
    }
    return switch (credential) {
        .none => .ready,
        .literal => .ready,
        .environment => |name| .{ .needs_env = name },
        .auth => |id| blk: {
            const variables = auth.fallbackVariables(id);
            break :blk if (variables.len == 0) .needs_login else .{ .needs_login_or_env = variables[0] };
        },
    };
}

/// 1048576 -> "1M", 200000 -> "200K", 32768 -> "32K".
pub fn humanize(buffer: []u8, tokens: u32) []const u8 {
    if (tokens >= 1_000_000) return std.fmt.bufPrint(buffer, "{d}M", .{(tokens + 500_000) / 1_000_000}) catch unreachable;
    if (tokens >= 1_000) return std.fmt.bufPrint(buffer, "{d}K", .{(tokens + 500) / 1_000}) catch unreachable;
    return std.fmt.bufPrint(buffer, "{d}", .{tokens}) catch unreachable;
}

test "context windows are humanized" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1M", humanize(&buffer, 1_048_576));
    try std.testing.expectEqualStrings("1M", humanize(&buffer, 1_000_000));
    try std.testing.expectEqualStrings("200K", humanize(&buffer, 200_000));
    try std.testing.expectEqualStrings("33K", humanize(&buffer, 32_768));
    try std.testing.expectEqualStrings("512", humanize(&buffer, 512));
}
