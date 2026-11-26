//! Built-in providers: hand-written records joined with the generated models.dev catalog.
const std = @import("std");
const cfg = @import("foo").config;
const records = @import("records.zig");
const generated = @import("catalog.zig");

pub const Record = records.Record;
/// The models.dev generator, exported so tests can run it in-process.
pub const generate = @import("generate.zig");
pub const Builtin = struct {
    record: Record,
    /// Generated models plus `extra_models`, sorted by id.
    catalog: []const cfg.CatalogModel,
};

/// Catalog models are capped here unless the user sets `max_output_tokens`.
pub const output_cap: u32 = 32_000;

pub const all: []const Builtin = &build();

pub fn find(id: []const u8) ?*const Builtin {
    for (all) |*builtin| if (std.mem.eql(u8, builtin.record.id, id)) return builtin;
    return null;
}

pub fn model(catalog: []const cfg.CatalogModel, id: []const u8) ?*const cfg.CatalogModel {
    var low: usize = 0;
    var high: usize = catalog.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, catalog[mid].id, id)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return &catalog[mid],
        }
    }
    return null;
}

pub fn outputTokens(entry: cfg.CatalogModel) u32 {
    return @max(1, @min(entry.output_limit, output_cap));
}

fn build() [records.list.len]Builtin {
    @setEvalBranchQuota(200_000);
    var result: [records.list.len]Builtin = undefined;
    for (&records.list, 0..) |*record, i| {
        const source: []const cfg.CatalogModel = if (record.modelsDevId()) |id|
            @field(generated, id)
        else
            &.{};
        if (validate(record.*, source, records.list[0..i])) |message| @compileError(message);
        result[i] = .{ .record = record.*, .catalog = merged(source, record.extra_models) };
    }
    return result;
}

fn merged(comptime source: []const cfg.CatalogModel, comptime extras: []const cfg.CatalogModel) []const cfg.CatalogModel {
    comptime {
        var out: [source.len + extras.len]cfg.CatalogModel = undefined;
        var i: usize = 0;
        var j: usize = 0;
        while (i < source.len or j < extras.len) {
            const take_extra = i == source.len or (j < extras.len and std.mem.order(u8, extras[j].id, source[i].id) == .lt);
            out[i + j] = if (take_extra) extras[j] else source[i];
            if (take_extra) j += 1 else i += 1;
        }
        const final = out;
        return &final;
    }
}

/// Returns the first rule a record breaks, or null. The build calls this at comptime for
/// every record; tests call it with bad records.
pub fn validate(record: Record, source: []const cfg.CatalogModel, earlier: []const Record) ?[]const u8 {
    if (!cfg.validId(record.id, .provider)) return "built-in provider id is invalid";
    for (earlier) |prior| if (std.mem.eql(u8, prior.id, record.id)) return "built-in provider id is duplicated";
    if (record.name.len == 0) return "built-in provider has no name";
    if (!sorted(source)) return "generated catalog is not sorted by id";
    if (!sorted(record.extra_models)) return "extra_models are not sorted by id";
    for (record.extra_models) |extra| {
        if (!cfg.validId(extra.id, .model)) return "extra model id is invalid";
        if (model(source, extra.id) != null) return "extra model is already in the models.dev catalog";
    }
    if (model(source, record.default_model) == null and model(record.extra_models, record.default_model) == null)
        return "default_model is not in the catalog";
    for (record.env) |name| if (!validEnvName(name)) return "environment variable name is invalid";
    return null;
}

fn sorted(catalog: []const cfg.CatalogModel) bool {
    for (catalog, 0..) |entry, i| {
        if (i != 0 and std.mem.order(u8, catalog[i - 1].id, entry.id) != .lt) return false;
    }
    return true;
}

fn validEnvName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}
