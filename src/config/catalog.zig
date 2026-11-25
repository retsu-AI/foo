const std = @import("std");
const cfg = @import("foo").config;
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
    auth_reset: ?cfg.Provenance = null,
    credential_required: ?cfg.Provenance = null,

    fn clearAuth(self: *Provider, origin: cfg.Provenance, origin_changed: bool) void {
        if (origin_changed) {
            if (self.credential) |credential| {
                if (credential.value != .none) self.credential_required = origin;
            }
        }
        self.credential = null;
        self.headers = null;
        self.auth_reset = origin;
    }

    fn setFamily(self: *Provider, family: Field(cfg.Family)) void {
        if (self.family) |prior| {
            if (prior.value != family.value) self.clearAuth(family.origin, false);
        }
        self.family = family;
    }

    fn setBaseUrl(self: *Provider, base_url: Field([]const u8)) void {
        if (self.base_url) |prior| {
            if (!Parse.sameOrigin(prior.value, base_url.value)) self.clearAuth(base_url.origin, true);
        }
        self.base_url = base_url;
    }

    fn complete(self: *const Provider, state: *Parse) Error!cfg.Provider {
        state.useOrigin(self.declaration);
        const family = self.family orelse return state.fail(try state.join(self.declaration.key, "family"), .missing_value);
        const base_url = self.base_url orelse return state.fail(try state.join(self.declaration.key, "base_url"), .missing_value);
        if (self.credential_required) |origin| {
            state.useOrigin(origin);
            return state.fail(try state.join(self.declaration.key, "credential"), .missing_value);
        }
        inline for (.{ "family", "base_url", "credential", "headers", "options" }) |key| {
            if (@field(self, key)) |entry| try state.provenance.append(state.a, entry.origin);
        }
        const models = try state.a.alloc(cfg.ModelEntry, self.models.count());
        for (self.models.keys(), self.models.values(), models) |id, entry, *model| {
            try state.operation.check();
            inline for (.{ "name", "endpoint", "options", "max_output_tokens" }) |key| {
                if (@field(entry, key)) |setting| try state.provenance.append(state.a, setting.origin);
            }
            model.* = .{
                .id = id,
                .name = if (entry.name) |v| v.value else null,
                .endpoint = if (entry.endpoint) |v| v.value else null,
                .options_json = if (entry.options) |v| try optionsJson(state.a, v.value) else "{}",
                .max_output_tokens = if (entry.max_output_tokens) |v| v.value else cfg.default_max_output_tokens,
            };
        }
        return .{
            .family = family.value,
            .base_url = base_url.value,
            .credential = if (self.credential) |v| v.value else .none,
            .headers = if (self.headers) |v| v.value else &.{},
            .options_json = if (self.options) |v| try optionsJson(state.a, v.value) else "{}",
            .models = models,
        };
    }
};

const ModelEntry = struct {
    name: ?Field(?[]const u8) = null,
    endpoint: ?Field(?[]const u8) = null,
    options: ?Field(Options) = null,
    max_output_tokens: ?Field(u32) = null,
};

const IdKind = enum { provider, model };
fn validId(id: []const u8, kind: IdKind) bool {
    if (id.len == 0 or !std.unicode.utf8ValidateSlice(id)) return false;
    for (id) |c| {
        if (c < 32 or c == 127 or (kind == .provider and c == '/')) return false;
    }
    return true;
}

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
        provider.setFamily(field(state, p, try state.enumeration(cfg.Family, v, p)));
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

fn choose(self: *const Catalog, state: *Parse, patch: root.ModelPatch) Error!Field(Selection) {
    if (patch.selection) |text| {
        state.useOrigin(commandLine("--model"));
        if (std.mem.indexOfScalar(u8, text, '/') != null) {
            return field(state, "model", try qualified(state, try state.a.dupe(u8, text)));
        }
        const provider = patch.provider orelse return state.fail("model", .invalid_value);
        if (!validId(provider, .provider)) return state.fail("provider", .invalid_value);
        if (!validId(text, .model)) return state.fail("model", .invalid_value);
        return field(state, "model", Selection{ .provider = provider, .model = try state.a.dupe(u8, text) });
    }
    if (patch.provider) |id| {
        state.useOrigin(commandLine("--provider"));
        if (!validId(id, .provider)) return state.fail("provider", .invalid_value);
        const provider = self.providers.get(id) orelse return state.fail("provider", .invalid_value);
        const keys = provider.models.keys();
        if (keys.len == 0) return state.fail(try state.join(provider.declaration.key, "models"), .missing_value);
        return field(state, "model", Selection{ .provider = id, .model = keys[0] });
    }
    state.useOrigin(.{ .key = "model", .source = .defaults });
    return self.selection orelse return state.fail("model", .missing_value);
}

fn commandLine(location: []const u8) cfg.Provenance {
    return .{ .key = "model", .source = .command_line, .location = location };
}

pub fn finish(self: *Catalog, state: *Parse, patch: root.ModelPatch) Error!void {
    const chosen = try self.choose(state, patch);
    state.useOrigin(chosen.origin);
    const provider = self.providers.getPtr(chosen.value.provider) orelse return state.fail("model", .invalid_value);
    const selected = try provider.models.getOrPut(state.a, chosen.value.model);
    if (!selected.found_existing) {
        if (patch.selection == null) return state.fail("model", .invalid_value);
        selected.value_ptr.* = .{};
    }

    if (patch.family) |family| {
        state.useOrigin(commandLine("--family"));
        provider.setFamily(field(state, try state.join(provider.declaration.key, "family"), family));
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

    var complete: root.ProviderMap = .empty;
    try complete.ensureTotalCapacity(state.a, self.providers.count());
    for (self.providers.keys(), self.providers.values()) |id, entry| {
        try state.operation.check();
        complete.putAssumeCapacity(id, try entry.complete(state));
    }
    state.settings.providers = complete;

    const flattened_provider = complete.get(chosen.value.provider).?;
    const model = flattened_provider.models[selected.index];
    const endpoint = model.endpoint orelse try joinRoute(state.a, flattened_provider.base_url, flattened_provider.family);
    const endpoint_origin = if (model.endpoint != null) selected.value_ptr.endpoint.?.origin else provider.base_url.?.origin;
    const inherit_auth = model.endpoint == null or Parse.sameOrigin(flattened_provider.base_url, endpoint);
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
        .family = flattened_provider.family,
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
