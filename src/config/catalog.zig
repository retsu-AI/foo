const std = @import("std");
const cfg = @import("foo").config;
const builtins = @import("builtins");
const root = @import("root.zig");
const Parse = @import("parse.zig");
const Value = std.json.Value;
const Options = std.json.ObjectMap;
const Error = root.Error;
const Catalog = @This();

providers: std.StringArrayHashMapUnmanaged(Provider) = .empty,
selection: ?Field(Selection) = null,

const Selection = struct { provider: []const u8, model: []const u8 };

fn Field(comptime T: type) type {
    return struct {
        value: T,
        origin: cfg.Provenance,
    };
}

fn field(state: *Parse, path: []const u8, value: anytype) Field(@TypeOf(value)) {
    return .{ .value = value, .origin = state.provenanceFor(path) };
}

const Provider = struct {
    declaration: cfg.Provenance,
    family: ?Field(cfg.Family) = null,
    base_url: ?Field([]const u8) = null,
    credential: ?Field(cfg.SecretRef) = null,
    headers: ?Field([]const cfg.Header) = null,
    options: ?Field(Options) = null,
    models: std.StringArrayHashMapUnmanaged(ModelEntry) = .empty,
    /// Built-in models. Empty for user providers and for a built-in moved to another origin,
    /// because the catalog describes the models of the original server.
    catalog: []const cfg.CatalogModel = &.{},
    default_model: ?[]const u8 = null,
    auth_reset: ?cfg.Provenance = null,
    credential_required: ?cfg.Provenance = null,
    /// A moved built-in that is never selected sends nothing, so it needs no credential.
    builtin_credential_cleared: bool = false,

    /// A secret is bound to an origin, so only an origin change drops it. The catalog and
    /// default model describe the old server and go with it.
    fn moveOrigin(self: *Provider, origin: cfg.Provenance) void {
        if (self.credential) |credential| {
            if (credential.value != .none) {
                self.credential_required = origin;
                self.builtin_credential_cleared = credential.origin.source == .defaults;
            }
        }
        self.catalog = &.{};
        self.default_model = null;
        self.credential = null;
        self.headers = null;
        self.auth_reset = origin;
    }

    fn setBaseUrl(self: *Provider, base_url: Field([]const u8)) void {
        if (self.base_url) |prior| {
            if (!Parse.sameOrigin(prior.value, base_url.value)) self.moveOrigin(base_url.origin);
        }
        self.base_url = base_url;
    }

    fn builtin(self: *const Provider) bool {
        return self.catalog.len != 0;
    }

    /// A user-set family asks for one protocol, so per-model routes no longer apply.
    fn route(self: *const Provider, entry: cfg.CatalogModel) ?cfg.CatalogModel.Route {
        const family = self.family orelse return null;
        return if (family.origin.source == .defaults) entry.route else null;
    }

    fn complete(self: *const Provider, state: *Parse, selected: bool) Error!cfg.Provider {
        state.useOrigin(self.declaration);
        const family = self.family orelse return state.fail(try state.join(self.declaration.key, "family"), .missing_value);
        const base_url = self.base_url orelse return state.fail(try state.join(self.declaration.key, "base_url"), .missing_value);
        if (self.credential_required) |origin| if (selected or !self.builtin_credential_cleared) {
            state.useOrigin(origin);
            return state.fail(try state.join(self.declaration.key, "credential"), .missing_value);
        };
        inline for (.{ "family", "base_url", "credential", "headers", "options" }) |key| {
            if (@field(self, key)) |entry| try state.provenance.append(state.a, entry.origin);
        }
        const models = try state.a.alloc(cfg.ModelEntry, self.models.count());
        for (self.models.keys(), self.models.values(), models) |id, entry, *model| {
            try state.operation.check();
            inline for (.{ "name", "endpoint", "options", "max_output_tokens" }) |key| {
                if (@field(entry, key)) |setting| try state.provenance.append(state.a, setting.origin);
            }
            const listed = builtins.model(self.catalog, id);
            model.* = .{
                .id = id,
                .name = if (entry.name) |v| v.value else if (listed) |v| v.name else null,
                .endpoint = if (entry.endpoint) |v| v.value else null,
                .options_json = if (entry.options) |v| try optionsJson(state.a, v.value) else "{}",
                .max_output_tokens = if (entry.max_output_tokens) |v| v.value else if (listed) |v| builtins.outputTokens(v.*) else cfg.default_max_output_tokens,
            };
        }
        return .{
            .family = family.value,
            .base_url = base_url.value,
            .credential = if (self.credential) |v| v.value else .none,
            .headers = if (self.headers) |v| v.value else &.{},
            .options_json = if (self.options) |v| try optionsJson(state.a, v.value) else "{}",
            .models = models,
            .catalog = self.catalog,
            .default_model = self.default_model,
        };
    }
};

const ModelEntry = struct {
    name: ?Field(?[]const u8) = null,
    endpoint: ?Field(?[]const u8) = null,
    options: ?Field(Options) = null,
    max_output_tokens: ?Field(u32) = null,
};

const IdKind = cfg.IdKind;
const validId = cfg.validId;

pub fn identifier(state: *Parse, value: Value, path: []const u8, kind: IdKind) Error![]const u8 {
    const id = try state.string(value, path, false);
    if (!validId(id, kind)) return state.fail(path, .invalid_value);
    return id;
}

fn qualified(state: *Parse, text: []const u8) Error!Selection {
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse return state.fail("model", .invalid_value);
    const parts: Selection = .{ .provider = text[0..slash], .model = text[slash + 1 ..] };
    if (!validId(parts.provider, .provider) or !validId(parts.model, .model)) return state.fail("model", .invalid_value);
    return parts;
}

pub fn select(self: *Catalog, state: *Parse, value: Value) Error!void {
    if (value == .object) {
        state.report("model", .invalid_value);
        state.diagnostic.*.?.message = "model is a string \"provider/id\"; define providers under \"providers\"";
        return error.InvalidConfiguration;
    }
    self.selection = field(state, "model", try qualified(state, try state.string(value, "model", false)));
}

/// The defaults layer. Every field gets provenance `providers.<id>.<field>` with source
/// `.defaults`, the same shape a JSON defaults layer produced, without parsing JSON.
pub fn seed(self: *Catalog, state: *Parse, registry: []const builtins.Builtin) Error!void {
    try self.providers.ensureTotalCapacity(state.a, registry.len);
    for (registry) |builtin| {
        const record = builtin.record;
        const path = try state.join("providers", record.id);
        const options = if (std.mem.eql(u8, record.options_json, "{}")) Options{} else (std.json.parseFromSliceLeaky(Value, state.a, record.options_json, .{ .parse_numbers = false }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        }).object;
        self.providers.putAssumeCapacityNoClobber(record.id, .{
            .declaration = state.provenanceFor(path),
            .family = field(state, try state.join(path, "family"), record.family),
            .base_url = field(state, try state.join(path, "base_url"), record.base_url),
            .credential = field(state, try state.join(path, "credential"), cfg.SecretRef{ .auth = record.id }),
            .headers = if (record.headers.len != 0) field(state, try state.join(path, "headers"), record.headers) else null,
            .options = if (options.count() != 0) field(state, try state.join(path, "options"), options) else null,
            .catalog = builtin.catalog,
            .default_model = record.default_model,
        });
    }
}

pub fn apply(self: *Catalog, state: *Parse, value: Value) Error!void {
    if (value != .object) return state.fail("providers", .invalid_value);
    for (value.object.keys(), value.object.values()) |id, entry| {
        try state.operation.check();
        if (!validId(id, .provider)) return state.fail("providers", .invalid_value);
        if (entry == .null) {
            _ = self.providers.orderedRemove(id);
            continue;
        }
        const path = try state.join("providers", id);
        const provider = try self.providers.getOrPut(state.a, id);
        if (!provider.found_existing) provider.value_ptr.* = .{ .declaration = state.provenanceFor(path) };
        try applyProvider(state, provider.value_ptr, path, entry);
    }
}

fn applyProvider(state: *Parse, provider: *Provider, path: []const u8, value: Value) Error!void {
    const obj = try state.object(value, path, &.{ "family", "base_url", "credential", "headers", "options", "models" });
    if (obj.get("base_url")) |v| {
        const p = try state.join(path, "base_url");
        provider.setBaseUrl(field(state, p, try state.url(v, p)));
    }
    if (obj.get("family")) |v| {
        const p = try state.join(path, "family");
        provider.family = field(state, p, try state.enumeration(cfg.Family, v, p));
    }
    if (obj.get("credential")) |v| {
        const p = try state.join(path, "credential");
        provider.credential = field(state, p, try state.secret(v, p));
        provider.credential_required = null;
    }
    if (obj.get("headers")) |v| {
        const p = try state.join(path, "headers");
        provider.headers = field(state, p, try state.headers(v, p));
    }
    if (obj.get("options")) |v| {
        const p = try state.join(path, "options");
        if (v != .object) return state.fail(p, .invalid_value);
        provider.options = field(state, p, v.object);
    }
    if (obj.get("models")) |v| {
        const p = try state.join(path, "models");
        if (v != .object) return state.fail(p, .invalid_value);
        for (v.object.keys(), v.object.values()) |id, entry| {
            try state.operation.check();
            if (!validId(id, .model)) return state.fail(p, .invalid_value);
            if (entry == .null) {
                _ = provider.models.orderedRemove(id);
                continue;
            }
            const model = try provider.models.getOrPut(state.a, id);
            if (!model.found_existing) model.value_ptr.* = .{};
            if (entry == .object and entry.object.count() == 0) continue;
            try applyModel(state, model.value_ptr, try state.join(p, id), entry);
        }
    }
}

fn applyModel(state: *Parse, entry: *ModelEntry, path: []const u8, value: Value) Error!void {
    const obj = try state.object(value, path, &.{ "name", "endpoint", "options", "max_output_tokens" });
    if (obj.get("name")) |v| {
        const p = try state.join(path, "name");
        const name: ?[]const u8 = if (v == .null) null else try state.string(v, p, false);
        entry.name = field(state, p, name);
    }
    if (obj.get("endpoint")) |v| {
        const p = try state.join(path, "endpoint");
        const endpoint: ?[]const u8 = if (v == .null) null else try state.url(v, p);
        entry.endpoint = field(state, p, endpoint);
    }
    if (obj.get("options")) |v| {
        const p = try state.join(path, "options");
        if (v != .object) return state.fail(p, .invalid_value);
        entry.options = field(state, p, v.object);
    }
    if (obj.get("max_output_tokens")) |v| {
        const p = try state.join(path, "max_output_tokens");
        entry.max_output_tokens = field(state, p, try state.integer(u32, v, p, false));
    }
}

fn choose(self: *const Catalog, state: *Parse, input: root.Input) Error!Field(Selection) {
    var patch = input.model_patch;
    var provider_flag: []const u8 = "--provider";
    if (patch.filter) |id| {
        state.useOrigin(commandLine("PROVIDER"));
        if (!validId(id, .provider)) return state.fail("provider", .invalid_value);
        if (patch.provider) |flagged| if (!std.mem.eql(u8, flagged, id)) {
            state.useOrigin(commandLine("--provider"));
            state.report("provider", .invalid_value);
            state.diagnostic.*.?.message = try std.fmt.allocPrint(state.a, "--provider {s} conflicts with PROVIDER {s}", .{ flagged, id });
            return error.InvalidConfiguration;
        };
        if (patch.provider == null) provider_flag = "PROVIDER";
        patch.provider = id;
    }
    if (patch.provider) |id| {
        state.useOrigin(commandLine(provider_flag));
        if (!validId(id, .provider)) return state.fail("provider", .invalid_value);
    }
    if (patch.selection) |text| {
        state.useOrigin(commandLine("--model"));
        if (std.mem.indexOfScalar(u8, text, '/') != null) {
            const chosen = try qualified(state, try state.a.dupe(u8, text));
            if (patch.provider) |id| if (!std.mem.eql(u8, id, chosen.provider)) {
                state.report("provider", .invalid_value);
                state.diagnostic.*.?.message = try std.fmt.allocPrint(state.a, "{s} {s} conflicts with --model {s}", .{ provider_flag, id, text });
                return error.InvalidConfiguration;
            };
            return field(state, "model", chosen);
        }
        if (!validId(text, .model)) return state.fail("model", .invalid_value);
        const provider = patch.provider orelse if (self.selection) |configured|
            configured.value.provider
        else
            (try self.ready(state, input)).provider;
        state.useOrigin(commandLine("--model"));
        return field(state, "model", Selection{ .provider = provider, .model = try state.a.dupe(u8, text) });
    }
    if (patch.provider) |id| {
        const provider = self.providers.get(id) orelse return state.fail("provider", .invalid_value);
        if (provider.default_model) |default| {
            const configured = if (self.selection) |configured| if (std.mem.eql(u8, configured.value.provider, id)) configured.value.model else null else null;
            return field(state, "model", Selection{ .provider = id, .model = configured orelse default });
        }
        const keys = provider.models.keys();
        if (keys.len == 0) return state.fail(try state.join(provider.declaration.key, "models"), .missing_value);
        return field(state, "model", Selection{ .provider = id, .model = keys[0] });
    }
    if (self.selection) |configured| return configured;
    state.useOrigin(.{ .key = "model", .source = .defaults });
    return field(state, "model", try self.ready(state, input));
}

/// The zero-config pick: the first built-in in registry order whose credential is available.
fn ready(self: *const Catalog, state: *Parse, input: root.Input) Error!Selection {
    if (input.readiness) |readiness| {
        for (builtins.all) |builtin| {
            const provider = self.providers.get(builtin.record.id) orelse continue;
            const default = provider.default_model orelse continue;
            const credential = if (provider.credential) |v| v.value else continue;
            try state.operation.check();
            if (try readiness.ready_fn(readiness.context, credential)) return .{ .provider = builtin.record.id, .model = default };
        }
    }
    state.useOrigin(.{ .key = "model", .source = .defaults });
    state.report("model", .missing_value);
    state.diagnostic.*.?.message = "no model selected and no provider has a credential. Run foo auth login PROVIDER or set \"model\" in config";
    return error.InvalidConfiguration;
}

fn commandLine(location: []const u8) cfg.Provenance {
    return .{ .key = "model", .source = .command_line, .location = location };
}

pub fn finish(self: *Catalog, state: *Parse, input: root.Input) Error!void {
    const patch = input.model_patch;
    const chosen = self.choose(state, input) catch |err| {
        if (err == error.InvalidConfiguration and input.model_optional and state.diagnostic.*.?.reason == .missing_value and std.mem.eql(u8, state.diagnostic.*.?.path, "model")) {
            state.diagnostic.* = null;
            _ = try self.completeAll(state, null);
            return;
        }
        return err;
    };
    state.useOrigin(chosen.origin);
    const provider = self.providers.getPtr(chosen.value.provider) orelse return state.fail("model", .invalid_value);
    const listed = builtins.model(provider.catalog, chosen.value.model);
    const selected = try provider.models.getOrPut(state.a, chosen.value.model);
    if (!selected.found_existing) {
        // A built-in accepts any id, so a catalog refresh never breaks a working `model` line.
        if (patch.selection == null and listed == null and !provider.builtin()) return state.fail("model", .invalid_value);
        selected.value_ptr.* = .{};
    }

    if (patch.family) |family| {
        state.useOrigin(commandLine("--family"));
        provider.family = field(state, try state.join(provider.declaration.key, "family"), family);
    }
    if (patch.endpoint) |text| {
        state.useOrigin(commandLine("--endpoint"));
        const models = try state.join(provider.declaration.key, "models");
        const path = try state.join(try state.join(models, chosen.value.model), "endpoint");
        const endpoint: ?[]const u8 = try state.url(.{ .string = try state.a.dupe(u8, text) }, path);
        selected.value_ptr.endpoint = field(state, path, endpoint);
    }
    if (patch.credential_env) |text| {
        state.useOrigin(commandLine("--credential-env"));
        const path = try state.join(provider.declaration.key, "credential");
        const name = try state.envName(.{ .string = try state.a.dupe(u8, text) }, path);
        provider.credential = field(state, path, cfg.SecretRef{ .environment = name });
        provider.credential_required = null;
    }

    const complete = try self.completeAll(state, chosen.value.provider);
    state.settings.selected = .{ .provider = chosen.value.provider, .model = chosen.value.model };

    const flattened_provider = complete.get(chosen.value.provider).?;
    const model = flattened_provider.models[selected.index];
    const route = if (listed) |entry| provider.route(entry.*) else null;
    const family = if (route) |r| r.family else flattened_provider.family;
    const endpoint = model.endpoint orelse if (route) |r|
        try joinRoute(state.a, try originWithPath(state.a, flattened_provider.base_url, r.base_path), family)
    else
        try joinRoute(state.a, flattened_provider.base_url, family);
    const endpoint_origin = if (model.endpoint != null) selected.value_ptr.endpoint.?.origin else provider.base_url.?.origin;
    const inherit_auth = root.inheritsAuth(flattened_provider, model.id);
    const use_credential = inherit_auth or patch.credential_env != null;
    const provider_options = if (provider.options) |entry| entry.value else Options{};
    const model_options = if (selected.value_ptr.options) |entry| entry.value else Options{};
    const options_json = if (model_options.count() == 0)
        flattened_provider.options_json
    else if (provider_options.count() == 0)
        model.options_json
    else
        try mergedOptionsJson(state.a, provider_options, model_options);
    state.settings.runtime.model = .{
        .family = family,
        .endpoint = endpoint,
        .id = model.id,
        .credential = if (use_credential) flattened_provider.credential else .none,
        .headers = if (inherit_auth) flattened_provider.headers else &.{},
        .options_json = options_json,
        .max_output_tokens = model.max_output_tokens,
    };

    try state.provenance.append(state.a, chosen.origin);
    try derived(state, "model.id", chosen.origin);
    try derived(state, "model.family", provider.family.?.origin);
    try derived(state, "model.endpoint", endpoint_origin);
    try derived(state, "model.credential", if (use_credential) originOf(provider.credential) orelse provider.auth_reset else endpoint_origin);
    try derived(state, "model.headers", if (inherit_auth) originOf(provider.headers) orelse provider.auth_reset else endpoint_origin);
    try derived(state, "model.options", if (model_options.count() != 0)
        selected.value_ptr.options.?.origin
    else
        originOf(provider.options) orelse originOf(selected.value_ptr.options));
    try derived(state, "model.max_output_tokens", originOf(selected.value_ptr.max_output_tokens));
}

fn completeAll(self: *Catalog, state: *Parse, selected_provider: ?[]const u8) Error!root.ProviderMap {
    var complete: root.ProviderMap = .empty;
    try complete.ensureTotalCapacity(state.a, self.providers.count());
    for (self.providers.keys(), self.providers.values()) |id, entry| {
        try state.operation.check();
        const selected = if (selected_provider) |chosen| std.mem.eql(u8, id, chosen) else false;
        complete.putAssumeCapacity(id, try entry.complete(state, selected));
    }
    state.settings.providers = complete;
    return complete;
}

/// The route path replaces the base URL's path. Scheme, host, and port stay, so a routed model
/// can never leave the provider's origin.
fn originWithPath(a: std.mem.Allocator, base: []const u8, path: []const u8) Error![]const u8 {
    const uri = std.Uri.parse(base) catch unreachable;
    var out: std.Io.Writer.Allocating = .init(a);
    uri.writeToStream(&out.writer, .{ .scheme = true, .authority = true }) catch return error.OutOfMemory;
    out.writer.writeAll(path) catch return error.OutOfMemory;
    return out.written();
}

fn originOf(entry: anytype) ?cfg.Provenance {
    return if (entry) |v| v.origin else null;
}

fn derived(state: *Parse, key: []const u8, origin: ?cfg.Provenance) Error!void {
    const fallback: cfg.Provenance = .{ .key = key, .source = .defaults };
    var result = origin orelse fallback;
    if (origin != null) result.input_key = result.key;
    result.key = key;
    try state.provenance.append(state.a, result);
}

fn joinRoute(a: std.mem.Allocator, base: []const u8, family: cfg.Family) Error![]const u8 {
    const route = switch (family) {
        .openai_responses => "/responses",
        .openai_chat => "/chat/completions",
        .anthropic_messages => "/messages",
    };
    const split = std.mem.indexOfScalar(u8, base, '?') orelse base.len;
    return std.mem.concat(a, u8, &.{ std.mem.trimEnd(u8, base[0..split], "/"), route, base[split..] });
}

fn optionsJson(a: std.mem.Allocator, options: Options) Error![]const u8 {
    if (options.count() == 0) return "{}";
    return std.json.Stringify.valueAlloc(a, Value{ .object = options }, .{});
}

fn mergedOptionsJson(a: std.mem.Allocator, provider: Options, model: Options) Error![]const u8 {
    var merged = try provider.clone(a);
    defer merged.deinit(a);
    for (model.keys(), model.values()) |key, value| try merged.put(a, key, value);
    return optionsJson(a, merged);
}
