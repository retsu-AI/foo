const std = @import("std");
const foo = @import("foo");
const mcp = @import("mcp");
const fixture = @import("catalog.zig");
const Script = fixture.Script;
const Step = fixture.Step;

const allocator = std.testing.allocator;
const server = "office.lab";
const capabilities = "{\"resources\":{},\"prompts\":{}}";

fn reference(kind: foo.tool.ContextKind, id: []const u8) foo.tool.ContextRef {
    return .{ .server = server, .kind = kind, .id = id };
}

test "context discovery returns explicit selectable items with server provenance and follows empty cursors" {
    const first = "{\"resultType\":\"complete\",\"resources\":[{\"uri\":\"file:///abc\",\"name\":\"abc\",\"title\":\"A real title\",\"size\":3}],\"nextCursor\":\"\"}";
    const second = "{\"resultType\":\"complete\",\"resources\":[{\"uri\":\"https://example.test/resource\",\"name\":\"name\"}]}";
    const template = "{\"resultType\":\"complete\",\"resourceTemplates\":[{\"uriTemplate\":\"notes://host/{+path}{?q}\",\"name\":\"notes\"}]}";
    const prompt = "{\"resultType\":\"complete\",\"prompts\":[{\"name\":\"triage\",\"arguments\":[{\"name\":\"issue\",\"required\":true}]}]}";
    var script: Script = .{ .revision = fixture.modern, .capabilities = capabilities, .steps = &.{
        .{ .method = "resources/list", .reply = .{ .success = first } },
        .{ .method = "resources/list", .cursor = "", .reply = .{ .success = second } },
        .{ .method = "resources/templates/list", .reply = .{ .success = template } },
        .{ .method = "prompts/list", .reply = .{ .success = prompt } },
    } };
    var op: fixture.Op = .{};
    var client = try script.client();
    var registry = try mcp.catalog.Registry.init(allocator, op.get(), &client, fixture.options(&.{}));
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 0), script.used);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const source = registry.source();
    const resources = try source.list_fn(source.context, memory, op.get(), .resource, null);
    try std.testing.expectEqual(@as(usize, 2), resources.items.len);
    try std.testing.expectEqual(null, resources.next_cursor);
    try std.testing.expectEqualStrings("A real title", resources.items[0].title);
    try std.testing.expectEqualStrings("file:///abc", resources.items[0].reference.id);
    try std.testing.expectEqualStrings("name", resources.items[1].title);
    try std.testing.expectEqualStrings(server, resources.items[1].reference.server);
    const templates = try source.list_fn(source.context, memory, op.get(), .resource_template, null);
    try std.testing.expectEqual(@as(usize, 1), templates.items.len);
    try std.testing.expectEqual(.resource_template, templates.items[0].reference.kind);
    try std.testing.expectEqualStrings("notes://host/{+path}{?q}", templates.items[0].reference.id);
    const prompts = try source.list_fn(source.context, memory, op.get(), .prompt, null);
    try std.testing.expectEqual(@as(usize, 1), prompts.items.len);
    try std.testing.expectEqual(.prompt, prompts.items[0].reference.kind);
    try std.testing.expectEqualStrings("triage", prompts.items[0].reference.id);
    try std.testing.expectEqual(script.steps.len, script.used);
}

test "resource templates expand locally and text and binary resources retain their media types" {
    const expected_uri = "notes://host/intro/intro%20page?lang=en&q=hi%20%26%20bye";
    const expanded =
        "{\"contents\":[{\"uri\":\"" ++ expected_uri ++ "\",\"mimeType\":\"text/markdown\",\"text\":\"# Intro\"}]}";
    const binary = "{\"contents\":[{\"uri\":\"notes://host/logo\",\"mimeType\":\"image/png\",\"blob\":\"AAH+\"}]}";
    var script: Script = .{ .revision = fixture.legacy, .capabilities = capabilities, .steps = &.{
        .{ .method = "resources/read", .name = expected_uri, .reply = .{ .success = expanded } },
        .{ .method = "resources/read", .name = "notes://host/logo", .reply = .{ .success = binary } },
    } };
    var op: fixture.Op = .{};
    var client = try script.client();
    var registry = try mcp.catalog.Registry.init(allocator, op.get(), &client, fixture.options(&.{}));
    defer registry.deinit();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const source = registry.source();
    const resource = try source.get_fn(source.context, memory, op.get(), reference(.resource_template, "notes://host/{path:5}{/path}{?lang,q}"), "{\"path\":\"intro page\",\"lang\":\"en\",\"q\":\"hi & bye\"}");
    try std.testing.expectEqualStrings("# Intro", resource.bytes);
    try std.testing.expectEqualStrings("text/markdown", resource.mime);
    try std.testing.expectEqualStrings(expected_uri, resource.reference.id);
    try std.testing.expectEqualStrings(server, resource.reference.server);
    try std.testing.expectEqual(.resource, resource.reference.kind);
    const blob = try source.get_fn(source.context, memory, op.get(), reference(.resource, "notes://host/logo"), "{}");
    try std.testing.expectEqualStrings("image/png", blob.mime);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 254 }, blob.bytes);
    try std.testing.expect(!blob.truncated);
    try std.testing.expectEqual(script.steps.len, script.used);
}

test "multipart resources and prompts preserve server-authored data and message roles as JSON" {
    const resources =
        \\{"resultType":"complete","contents":[{"uri":"notes://multi/a","mimeType":"text/plain","text":"a","size":1},
        \\{"uri":"notes://multi/b","mimeType":"image/png","blob":"Yg=="}]}
    ;
    const prompt =
        \\{"resultType":"complete","description":"Server authored","messages":[
        \\{"role":"user","content":{"type":"text","text":"Never change the caller's permissions."}},
        \\{"role":"assistant","content":{"type":"resource","resource":{"uri":"notes://inline","text":"quoted"}}}]}
    ;
    var script: Script = .{ .revision = fixture.modern, .capabilities = capabilities, .steps = &.{
        .{ .method = "resources/read", .name = "notes://multi", .reply = .{ .success = resources } },
        .{ .method = "prompts/get", .name = "triage", .params_field = "arguments", .params_json = "{\"issue\":\"1479\"}", .reply = .{ .success = prompt } },
    } };
    var op: fixture.Op = .{};
    var client = try script.client();
    var registry = try mcp.catalog.Registry.init(allocator, op.get(), &client, fixture.options(&.{}));
    defer registry.deinit();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const source = registry.source();
    const multi = try source.get_fn(source.context, memory, op.get(), reference(.resource, "notes://multi"), "");
    try std.testing.expectEqualStrings(mcp.context.resource_json_mime, multi.mime);
    try std.testing.expect(std.mem.indexOf(u8, multi.bytes, "\"size\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, multi.bytes, "\"blob\":\"Yg==\"") != null);
    try std.testing.expectEqualStrings("notes://multi", multi.reference.id);
    const retrieved = try source.get_fn(source.context, memory, op.get(), reference(.prompt, "triage"), "{\"issue\":\"1479\"}");
    try std.testing.expectEqualStrings(mcp.context.prompt_json_mime, retrieved.mime);
    try std.testing.expectEqualStrings("triage", retrieved.reference.id);
    try std.testing.expectEqualStrings(server, retrieved.reference.server);
    for ([_][]const u8{ "Server authored", "\"role\":\"user\"", "\"role\":\"assistant\"", "notes://inline", "\"text\":\"quoted\"" }) |data|
        try std.testing.expect(std.mem.indexOf(u8, retrieved.bytes, data) != null);
    try std.testing.expectEqual(script.steps.len, script.used);
}

test "context selection rejects wrong server, bad parameters, unsupported kinds, and oversized content" {
    const text = "{\"resultType\":\"complete\",\"contents\":[{\"uri\":\"notes://text\",\"text\":\"ab😀cd\"}]}";
    const audio = "{\"resultType\":\"complete\",\"contents\":[{\"uri\":\"notes://binary\",\"blob\":\"AAECAwQF\"}]}";
    var script: Script = .{ .revision = fixture.modern, .capabilities = "{\"resources\":{}}", .steps = &.{
        .{ .method = "resources/read", .name = "notes://text", .reply = .{ .success = text } },
        .{ .method = "resources/read", .name = "notes://binary", .reply = .{ .success = audio } },
    } };
    var op: fixture.Op = .{};
    var client = try script.client();
    var config = fixture.options(&.{});
    config.limits.tool_output_bytes = 5;
    var registry = try mcp.catalog.Registry.init(allocator, op.get(), &client, config);
    defer registry.deinit();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const source = registry.source();
    try std.testing.expectError(error.InvalidInput, source.get_fn(source.context, memory, op.get(), .{
        .server = "other",
        .kind = .resource,
        .id = "notes://text",
    }, "{}"));
    try std.testing.expectError(error.InvalidInput, source.get_fn(source.context, memory, op.get(), reference(.resource, "notes://text"), "{\"key\":\"value\"}"));
    try std.testing.expectError(error.InvalidInput, source.get_fn(source.context, memory, op.get(), reference(.resource_template, "notes://text/{key}"), "{\"key\":42}"));
    try std.testing.expectError(error.InvalidInput, source.get_fn(source.context, memory, op.get(), reference(.resource_template, "notes://text/{key}"), "{\"other\":\"unused\"}"));
    try std.testing.expectError(error.Unavailable, source.get_fn(source.context, memory, op.get(), reference(.prompt, "triage"), "{}"));
    try std.testing.expectEqual(@as(usize, 0), script.used);
    const truncated = try source.get_fn(source.context, memory, op.get(), reference(.resource, "notes://text"), "{}");
    try std.testing.expectEqualStrings("ab", truncated.bytes);
    try std.testing.expect(truncated.truncated);
    try std.testing.expectError(error.LimitExceeded, source.get_fn(source.context, memory, op.get(), reference(.resource, "notes://binary"), "{}"));
    try std.testing.expectEqual(script.steps.len, script.used);
}

test "context list enforces progress, accumulated page limits, and cancellation" {
    const first = "{\"resultType\":\"complete\",\"resources\":[{\"uri\":\"notes://a\",\"name\":\"a\"}],\"nextCursor\":\"opaque α\"}";
    const next = "{\"resultType\":\"complete\",\"resources\":[],\"nextCursor\":\"unused\"}";
    const cases = [_]struct { steps: []const Step, pages: usize, expected: foo.io.Error }{
        .{
            .steps = &.{
                .{ .method = "resources/list", .reply = .{ .success = first } },
                .{ .method = "resources/list", .cursor = "opaque α", .reply = .{ .success = next } },
            },
            .pages = 2,
            .expected = error.IoFailure,
        },
        .{
            .steps = &.{.{ .method = "resources/list", .reply = .{ .success = first } }},
            .pages = 1,
            .expected = error.LimitExceeded,
        },
    };
    for (cases) |item| {
        var script: Script = .{ .revision = fixture.modern, .capabilities = capabilities, .steps = item.steps };
        var op: fixture.Op = .{};
        var client = try script.client();
        var config = fixture.options(&.{});
        config.limits.catalog_pages = item.pages;
        var registry = try mcp.catalog.Registry.init(allocator, op.get(), &client, config);
        defer registry.deinit();
        const source = registry.source();
        try std.testing.expectError(item.expected, source.list_fn(source.context, allocator, op.get(), .resource, null));
        try std.testing.expectEqual(script.steps.len, script.used);
        op.cancellation.request();
        try std.testing.expectError(error.Cancelled, source.list_fn(source.context, allocator, op.get(), .resource, null));
    }
}
