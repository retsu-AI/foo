const std = @import("std");
const foo = @import("foo");
const builtins = @import("builtins");
const generate = builtins.generate;
const cfg = foo.config;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const same = std.testing.expectEqualStrings;

const sorted_models: []const cfg.CatalogModel = &.{
    .{ .id = "a-model", .name = "A", .output_limit = 1, .context_limit = 2 },
    .{ .id = "b-model", .name = "B", .output_limit = 1, .context_limit = 2 },
};

test "every built-in has a unique id, a listed default model, and a sorted catalog" {
    try expect(builtins.all.len >= 14);
    for (builtins.all, 0..) |entry, i| {
        for (builtins.all[0..i]) |prior| try expect(!std.mem.eql(u8, prior.record.id, entry.record.id));
        try expect(builtins.model(entry.catalog, entry.record.default_model) != null);
        try expect(entry.catalog.len != 0);
        for (entry.catalog, 0..) |model, j| {
            if (j != 0) try expect(std.mem.order(u8, entry.catalog[j - 1].id, model.id) == .lt);
            try expect(builtins.outputTokens(model) <= builtins.output_cap);
            if (model.route) |route| {
                try expect(route.family != entry.record.family);
                try expect(route.base_path[0] == '/');
            }
        }
        try expect(builtins.find(entry.record.id) == &builtins.all[i]);
    }
    try equal(null, builtins.find("nope"));
    try same("anthropic", builtins.all[0].record.id);
    for ([_][]const u8{ "openai-codex", "xai", "opencode", "opencode-go" }) |id| try expect(builtins.find(id) != null);
    try equal(null, builtins.find("openai-codex").?.record.modelsDevId());
    try same("kimi-code-plan-global", builtins.find("kimi-coding").?.record.modelsDevId().?);
    try expect(builtins.model(builtins.find("opencode").?.catalog, "claude-sonnet-5-5").?.route != null);
}

test "record validation names the first broken rule" {
    const good: builtins.Record = .{ .id = "good", .name = "Good", .family = .openai_chat, .base_url = "https://good.invalid/v1", .default_model = "a-model" };
    try equal(null, builtins.validate(good, sorted_models, &.{}));
    const cases = [_]struct { record: builtins.Record, source: []const cfg.CatalogModel = sorted_models, earlier: []const builtins.Record = &.{}, message: []const u8 }{
        .{ .record = .{ .id = "bad/id", .name = "x", .family = .openai_chat, .base_url = "https://x.invalid", .default_model = "a-model" }, .message = "built-in provider id is invalid" },
        .{ .record = good, .earlier = &.{good}, .message = "built-in provider id is duplicated" },
        .{ .record = .{ .id = "x", .name = "", .family = .openai_chat, .base_url = "https://x.invalid", .default_model = "a-model" }, .message = "built-in provider has no name" },
        .{ .record = good, .source = &.{ sorted_models[1], sorted_models[0] }, .message = "generated catalog is not sorted by id" },
        .{ .record = .{ .id = "x", .name = "x", .family = .openai_chat, .base_url = "https://x.invalid", .default_model = "a-model", .extra_models = &.{ sorted_models[1], sorted_models[0] } }, .source = &.{}, .message = "extra_models are not sorted by id" },
        .{ .record = .{ .id = "x", .name = "x", .family = .openai_chat, .base_url = "https://x.invalid", .default_model = "a-model", .extra_models = &.{sorted_models[0]} }, .message = "extra model is already in the models.dev catalog" },
        .{ .record = .{ .id = "x", .name = "x", .family = .openai_chat, .base_url = "https://x.invalid", .default_model = "missing" }, .message = "default_model is not in the catalog" },
        .{ .record = .{ .id = "x", .name = "x", .family = .openai_chat, .base_url = "https://x.invalid", .default_model = "a-model", .env = &.{"1BAD"} }, .message = "environment variable name is invalid" },
    };
    for (cases) |case| try same(case.message, builtins.validate(case.record, case.source, case.earlier).?);
}

test "the generator turns a models.dev snapshot into the checked-in catalog shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    var log: std.Io.Writer.Allocating = .init(a);
    try generate.generate(a, @embedFile("fixtures/api.json"), &out.writer, &log.writer);
    try same(@embedFile("fixtures/catalog.zig"), out.written());
    const diagnostics = log.written();
    for ([_][]const u8{
        "anthropic: skip claude-opus-4-5 (deprecated)",
        "anthropic: skip claude-alpha (alpha)",
        "openai: skip gpt-image (not a chat model)",
        "openai: skip gpt-notools (no tool calls)",
        "opencode: skip gemini-4-carbon (no codec for @ai-sdk/google)",
        "anthropic: 1 models, 2 skipped",
        "opencode: 3 models, 1 skipped",
    }) |line| try expect(std.mem.indexOf(u8, diagnostics, line) != null);
    try expect(std.mem.indexOf(u8, diagnostics, "default_model") == null);
    try expect(std.mem.indexOf(u8, diagnostics, "models.dev names") == null);

    const renamed = try std.mem.replaceOwned(u8, a, @embedFile("fixtures/api.json"), "\"DEEPSEEK_API_KEY\"", "\"DEEPSEEK_TOKEN\"");
    var warned: std.Io.Writer.Allocating = .init(a);
    var ignored: std.Io.Writer.Allocating = .init(a);
    try generate.generate(a, renamed, &ignored.writer, &warned.writer);
    try expect(std.mem.indexOf(u8, warned.written(), "deepseek: models.dev names DEEPSEEK_TOKEN; the record keeps DEEPSEEK_API_KEY") != null);

    const dropped = try std.mem.replaceOwned(u8, a, @embedFile("fixtures/api.json"), "\"id\": \"grok-4.7\"", "\"id\": \"grok-4.8\"");
    var noted: std.Io.Writer.Allocating = .init(a);
    try generate.generate(a, dropped, &ignored.writer, &noted.writer);
    try expect(std.mem.indexOf(u8, noted.written(), "xai: default_model grok-4.7 is not in the catalog") != null);

    var again: std.Io.Writer.Allocating = .init(a);
    var quiet: std.Io.Writer.Allocating = .init(a);
    try generate.generate(a, @embedFile("fixtures/api.json"), &again.writer, &quiet.writer);
    try same(out.written(), again.written());
}

test "the generator refuses a missing provider, a missing limit, and a route on another origin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = @embedFile("fixtures/api.json");
    const cases = [_]struct { find: []const u8, replace: []const u8, message: []const u8 }{
        .{ .find = "\"deepseek\": {", .replace = "\"deepseek-renamed\": {", .message = "deepseek: provider deepseek is missing from api.json" },
        .{ .find = "\"output\": 128000", .replace = "\"outputs\": 128000", .message = "has an unexpected shape" },
        .{ .find = "https://opencode.ai/inference/anthropic/v1", .replace = "https://elsewhere.invalid/anthropic/v1", .message = "opencode: claude-sonnet-5-5 is served from https://elsewhere.invalid/anthropic/v1, not the record origin https://opencode.ai/inference/openai/v1" },
        .{ .find = "{", .replace = "", .message = "api.json is not valid JSON" },
    };
    for (cases) |case| {
        const broken = try std.mem.replaceOwned(u8, a, fixture, case.find, case.replace);
        var out: std.Io.Writer.Allocating = .init(a);
        var log: std.Io.Writer.Allocating = .init(a);
        try std.testing.expectError(error.InvalidInput, generate.generate(a, broken, &out.writer, &log.writer));
        try expect(std.mem.indexOf(u8, log.written(), case.message) != null);
    }
}
