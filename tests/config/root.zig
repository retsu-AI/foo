const std = @import("std");
const foo = @import("foo");
const config = @import("configuration");
const support = @import("support");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const same = std.testing.expectEqualStrings;
const test_io = std.testing.io;

const Request = struct {
    clock: support.Clock = .{},
    cancellation: foo.io.Cancellation = .{},
    diagnostic: ?config.Diagnostic = null,

    fn context(self: *Request) foo.io.Context {
        return .{ .io = test_io, .clock = self.clock.interface(), .cancellation = &self.cancellation };
    }

    fn resolve(self: *Request, allocator: std.mem.Allocator, input: config.Input) !config.Effective {
        return config.resolve(allocator, self.context(), input, &self.diagnostic);
    }
};

const minimal_model =
    \\{"model":{"family":"openai_responses","endpoint":"https://fixture.invalid/v1/responses","id":"explicit-model"}}
;
const invocation_cwd = switch (@import("builtin").os.tag) {
    .windows => "C:\\foo-fixture",
    else => "/foo-fixture",
};

fn has(bytes: []const u8, value: []const u8) bool {
    return std.mem.indexOf(u8, bytes, value) != null;
}

fn sourceOf(result: config.Effective, key: []const u8) !foo.config.Provenance {
    for (result.runtime.provenance) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry;
    }
    return error.MissingProvenance;
}

test "layers apply by source and keep file order and empty overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var call: Request = .{};
    const result = try call.resolve(allocator, .{
        .cwd = invocation_cwd,
        .preset = .coding,
        .layers = &.{
            .{ .source = .command_line, .location = "--overrides", .data = .{ .json =
            \\{"model":{"id":"cli-model"},"system_prompt":{"text":"","append_files":[]},"enabled_tools":[]}
            } },
            .{ .source = .file, .location = "user.json", .data = .{ .json = minimal_model } },
            .{ .source = .environment, .location = "FOO_CONFIG", .data = .{ .json =
            \\{"model":{"id":"environment-model"},"limits":{"pending_requests":5}}
            } },
            .{ .source = .file, .location = "project.json", .data = .{ .json =
            \\{"model":{"id":"project-model","max_output_tokens":1024},"limits":{"pending_requests":4,"pending_events":3},"enabled_tools":["read"]}
            } },
        },
    });
    try equal(null, call.diagnostic);
    try same("cli-model", result.runtime.model.id);
    try same("https://fixture.invalid/v1/responses", result.runtime.model.endpoint);
    try equal(@as(u32, 1024), result.runtime.model.max_output_tokens);
    try same("", result.runtime.system_prompt);
    try equal(0, result.runtime.enabled_tools.len);
    try equal(5, result.runtime.limits.pending_requests);
    try equal(3, result.runtime.limits.pending_events);
    try equal(foo.config.PermissionMode.deny, result.runtime.permissions);
    const cli = try sourceOf(result, "model.id");
    try equal(foo.config.Source.command_line, cli.source);
    try same("--overrides", cli.location orelse return error.MissingLocation);
    try equal(foo.config.Source.file, (try sourceOf(result, "model.endpoint")).source);
    try equal(foo.config.Source.environment, (try sourceOf(result, "limits.pending_requests")).source);
    try equal(foo.config.Source.defaults, (try sourceOf(result, "limits.json_depth")).source);
}

test "same source preserves explicit file order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var call: Request = .{};
    const result = try call.resolve(arena.allocator(), .{
        .cwd = invocation_cwd,
        .layers = &.{
            .{ .source = .file, .location = "first.json", .data = .{ .json = minimal_model } },
            .{ .source = .file, .location = "last.json", .data = .{ .json =
            \\{"model":{"id":"last-model"}}
            } },
        },
    });
    try same("last-model", result.runtime.model.id);
    try same("last.json", (try sourceOf(result, "model.id")).location orelse return error.MissingLocation);
}

test "explicit files resolve paths where each setting originates" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const native_cwd = try tmp.dir.realPathFileAlloc(test_io, ".", allocator);

    try tmp.dir.createDirPath(test_io, "profile");
    try tmp.dir.writeFile(test_io, .{ .sub_path = "AGENTS.md", .data = "Unexpected ambient prompt." });
    try tmp.dir.writeFile(test_io, .{ .sub_path = "profile/first.txt", .data = "first fragment" });
    try tmp.dir.writeFile(test_io, .{ .sub_path = "profile/second.txt", .data = "second fragment" });
    try tmp.dir.writeFile(test_io, .{ .sub_path = "profile/foo.json", .data =
        \\{"version":1,"cwd":"./project","system_prompt":{"text":"explicit prefix","append_files":["first.txt","second.txt"]}}
    });
    var call: Request = .{};
    const result = try call.resolve(allocator, .{
        .cwd = native_cwd,
        .layers = &.{
            .{ .source = .file, .data = .{ .json = minimal_model } },
            .{ .source = .file, .data = .{ .file = "profile/foo.json" } },
        },
    });
    const expected = try std.fs.path.resolve(allocator, &.{ native_cwd, "profile", "project" });
    try same(expected, result.runtime.cwd);
    const prompt = result.runtime.system_prompt;
    try expect(std.mem.startsWith(u8, prompt, "explicit prefix"));
    const first = std.mem.indexOf(u8, prompt, "first fragment") orelse return error.MissingFirstFragment;
    const second = std.mem.indexOf(u8, prompt, "second fragment") orelse return error.MissingSecondFragment;
    try expect(first < second);
    try expect(!has(prompt, "Unexpected ambient prompt."));
    const provenance = try sourceOf(result, "cwd");
    try equal(foo.config.Source.file, provenance.source);
    try same(try std.fs.path.resolve(allocator, &.{ native_cwd, "profile", "foo.json" }), provenance.location orelse return error.MissingLocation);
}

test "higher prompt replacement never reads discarded append files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var call: Request = .{};
    const result = try call.resolve(arena.allocator(), .{
        .cwd = invocation_cwd,
        .layers = &.{
            .{ .source = .file, .data = .{ .json = minimal_model } },
            .{ .source = .file, .data = .{ .json =
            \\{"system_prompt":{"text":"reset this","append_files":["does-not-exist.txt"]}}
            } },
            .{ .source = .command_line, .data = .{ .json =
            \\{"system_prompt":{"text":"","append_files":[]}}
            } },
        },
    });
    try same("", result.runtime.system_prompt);
}

test "neutral settings select no tools and use an empty prompt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var call: Request = .{};
    const result = try call.resolve(arena.allocator(), .{
        .cwd = invocation_cwd,
        .layers = &.{.{ .source = .file, .data = .{ .json = minimal_model } }},
    });
    try same("", result.runtime.system_prompt);
    try equal(0, result.runtime.enabled_tools.len);
    try equal(foo.config.PermissionMode.deny, result.runtime.permissions);
}

test "redacted settings preserve credential references and provider options for runtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var call: Request = .{};
    const input: config.Input = .{
        .cwd = invocation_cwd,
        .layers = &.{.{ .source = .file, .location = "deepseek.json", .data = .{ .json = @embedFile("fixtures/deepseek.json") } }},
    };
    const result = try call.resolve(allocator, input);
    try equal(foo.config.Family.openai_chat, result.runtime.model.family);
    try same("DEEPSEEK_API_KEY", result.runtime.model.credential.environment);
    try same("https://api.deepseek.com/chat/completions", result.runtime.model.endpoint);
    try equal(@as(u32, 8192), result.runtime.model.max_output_tokens);
    try expect(has(result.runtime.model.options_json, "\"chat_reasoning_content\""));
    try same("fixture-header-secret", result.runtime.model.headers[0].value.literal);
    const effective = try config.effectiveJson(allocator, result);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, effective, .{});
    try expect(parsed == .object);
    try expect(has(effective, "DEEPSEEK_API_KEY"));
    try expect(has(effective, "FOO_WORKSPACE"));
    try expect(has(effective, "DEMO_SECRET"));
    try expect(has(effective, "deepseek-v4-pro"));
    for ([_][]const u8{ "fixture-header-secret", "fixture-mcp-secret", "fixture-process-secret" }) |secret| {
        try expect(!has(effective, secret));
    }
    const later = try call.resolve(allocator, input);
    try same(effective, try config.effectiveJson(allocator, later));
}

test "strict settings reject malformed, unsupported, and misspelled values" {
    const cases = [_]struct { json: []const u8, path_hint: []const u8 }{
        .{ .json = "{\"model\":{\"endpont\":\"https://fixture.invalid\"}}", .path_hint = "endpont" },
        .{ .json = "{\"version\":2}", .path_hint = "version" },
        .{ .json = "{\"model\":{\"family\":\"guessed\"}}", .path_hint = "family" },
        .{ .json = "{\"model\":{\"endpoint\":\"https://name:bad-value@fixture.invalid/v1\"}}", .path_hint = "endpoint" },
        .{ .json = "{\"model\":{\"id\":\"first\",\"id\":\"duplicate-value\"}}", .path_hint = "" },
        .{ .json = "{\"limits\":{\"pending_requests\":0}}", .path_hint = "pending_requests" },
        .{ .json = "{\"model\":{\"credential\":{\"command\":\"bad-value\"}}}", .path_hint = "command" },
        .{ .json = "{\"system_prompt\":", .path_hint = "" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var call: Request = .{};
        const result = call.resolve(arena.allocator(), .{
            .cwd = invocation_cwd,
            .layers = &.{
                .{ .source = .file, .data = .{ .json = minimal_model } },
                .{ .source = .command_line, .location = "--config-json", .data = .{ .json = case.json } },
            },
        });
        if (result) |_| return error.InvalidSettingsAccepted else |_| {}
        const diagnostic = call.diagnostic orelse return error.MissingDiagnostic;
        try equal(foo.config.Source.command_line, diagnostic.source);
        try same("--config-json", diagnostic.location orelse return error.MissingLocation);
        try expect(has(diagnostic.path, case.path_hint));
        try expect(!has(diagnostic.path, "duplicate-value"));
        try expect(!has(diagnostic.path, "bad-value"));
    }
}

test "cancelled resolution performs no configuration reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var call: Request = .{};
    call.cancellation.request();
    try std.testing.expectError(error.Cancelled, call.resolve(arena.allocator(), .{
        .cwd = invocation_cwd,
        .layers = &.{.{ .source = .file, .data = .{ .file = "missing.json" } }},
    }));
}

test "process, session, and TUI settings merge without changing runtime defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var call: Request = .{};
    const result = try call.resolve(allocator, .{
        .cwd = invocation_cwd,
        .layers = &.{
            .{ .source = .file, .data = .{ .json = minimal_model } },
            .{ .source = .file, .location = "project.json", .data = .{ .json =
            \\{"process":{"inherit_environment":true,"timeout_ms":45000},
            \\ "session":{"directory":"./history","limits":{"max_artifacts":12}},
            \\ "tui":{"keys":{"cancel":"escape"},"colors":{"assistant":"green"}}}
            } },
            .{ .source = .command_line, .data = .{ .json =
            \\{"process":{"inherit_environment":false},"session":{"directory":null},"tui":{"colors":{"tool":"blue"}}}
            } },
        },
    });
    try equal(false, result.launch.process.inherit_environment);
    try equal(@as(u64, 45_000), result.launch.process.timeout_ms);
    try equal(null, result.launch.session.directory);
    try equal(12, result.launch.session.limits.max_artifacts);
    try equal(@as(u32, 4096), result.runtime.model.max_output_tokens);
    try equal(foo.config.PermissionMode.deny, result.runtime.permissions);
    const rendered = try config.effectiveJson(allocator, result);
    const json = try std.json.parseFromSliceLeaky(std.json.Value, allocator, rendered, .{});
    const launch = json.object.get("launch").?.object;
    const tui = launch.get("tui").?.object;
    const keys = tui.get("keys").?.object;
    const colors = tui.get("colors").?.object;
    try same("escape", keys.get("cancel").?.string);
    try same("green", colors.get("assistant").?.string);
    try same("blue", colors.get("tool").?.string);
}

test "MCP accepts explicit stdio environments and pinned HTTP revisions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var call: Request = .{};
    const result = try call.resolve(arena.allocator(), .{
        .cwd = invocation_cwd,
        .layers = &.{
            .{ .source = .file, .data = .{ .json = minimal_model } },
            .{ .source = .file, .data = .{ .json =
            \\{"mcp_servers":[
            \\ {"id":"local","transport":{"stdio":{"argv":["fixture-bin","--stdio"],"environment":[{"name":"TOKEN","value":{"environment":"FIXTURE_TOKEN"}}]}}},
            \\ {"id":"remote","revision":"2026-07-28","transport":{"http":{"url":"https://fixture.invalid/mcp"}}}
            \\]}
            } },
        },
    });
    try equal(2, result.runtime.mcp_servers.len);
    const local = result.runtime.mcp_servers[0];
    const remote = result.runtime.mcp_servers[1];
    try same("--stdio", local.transport.stdio.argv[1]);
    try same("FIXTURE_TOKEN", local.transport.stdio.environment[0].value.environment);
    try equal(@as(?foo.config.McpRevision, .@"2026-07-28"), remote.revision);
    try same("https://fixture.invalid/mcp", remote.transport.http.url);
}

test "an invalid lower layer fails even if a higher layer replaces its value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var call: Request = .{};
    try std.testing.expectError(error.InvalidConfiguration, call.resolve(arena.allocator(), .{
        .cwd = invocation_cwd,
        .layers = &.{
            .{ .source = .file, .data = .{ .json = minimal_model } },
            .{ .source = .file, .location = "bad.json", .data = .{ .json = "{\"model\":{\"max_output_tokens\":0}}" } },
            .{ .source = .command_line, .data = .{ .json = "{\"model\":{\"max_output_tokens\":2000}}" } },
        },
    }));
    const diagnostic = call.diagnostic orelse return error.MissingDiagnostic;
    try equal(foo.config.Source.file, diagnostic.source);
    try same("bad.json", diagnostic.location orelse return error.MissingLocation);
    try expect(has(diagnostic.path, "max_output_tokens"));
}

test "the configuration byte limit applies before parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const oversize = try allocator.alloc(u8, config.max_config_bytes + 1);
    @memset(oversize, ' ');
    var call: Request = .{};
    try std.testing.expectError(error.LimitExceeded, call.resolve(allocator, .{
        .cwd = invocation_cwd,
        .layers = &.{.{ .source = .file, .location = "too-big.json", .data = .{ .json = oversize } }},
    }));
    const diagnostic = call.diagnostic orelse return error.MissingDiagnostic;
    try equal(foo.config.Source.file, diagnostic.source);
    try same("too-big.json", diagnostic.location orelse return error.MissingLocation);
}

test "model credentials and headers follow the endpoint origin" {
    const cases = [_]struct {
        patch: []const u8,
        credential: ?[]const u8,
        headers: usize,
    }{
        .{
            .patch = "{\"model\":{\"endpoint\":\"https://API.DEEPSEEK.COM:443/v1/chat/completions\"}}",
            .credential = "DEEPSEEK_API_KEY",
            .headers = 2,
        },
        .{
            .patch = "{\"model\":{\"endpoint\":\"https://other.invalid/v1/chat/completions?key=fixture-query-secret\"}}",
            .credential = null,
            .headers = 0,
        },
        .{
            .patch = "{\"model\":{\"family\":\"openai_responses\",\"credential\":{\"environment\":\"EXPLICIT_REPLACEMENT\"}}}",
            .credential = "EXPLICIT_REPLACEMENT",
            .headers = 0,
        },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var call: Request = .{};
        const allocator = arena.allocator();
        const result = try call.resolve(allocator, .{
            .cwd = invocation_cwd,
            .layers = &.{
                .{ .source = .file, .data = .{ .json = @embedFile("fixtures/deepseek.json") } },
                .{ .source = .command_line, .data = .{ .json = case.patch } },
            },
        });
        if (case.credential) |env| {
            try same(env, result.runtime.model.credential.environment);
        } else {
            try expect(result.runtime.model.credential == .none);
            try equal(foo.config.Source.command_line, (try sourceOf(result, "model.credential")).source);
        }
        try equal(case.headers, result.runtime.model.headers.len);
        if (has(case.patch, "fixture-query-secret")) {
            try expect(has(result.runtime.model.endpoint, "fixture-query-secret"));
            try expect(!has(try config.effectiveJson(allocator, result), "fixture-query-secret"));
        }
    }
}

test "the coding preset is explicit and never chooses a provider" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var call: Request = .{};
    try std.testing.expectError(error.InvalidConfiguration, call.resolve(allocator, .{
        .cwd = invocation_cwd,
        .preset = .coding,
    }));
    try expect(has((call.diagnostic orelse return error.MissingDiagnostic).path, "model"));
    const result = try call.resolve(allocator, .{
        .cwd = invocation_cwd,
        .preset = .coding,
        .layers = &.{.{ .source = .file, .data = .{ .json = minimal_model } }},
    });
    try expect(result.runtime.system_prompt.len != 0);
    try std.testing.expectEqualSlices([]const u8, &.{ "read", "edit", "write", "exec" }, result.runtime.enabled_tools);
    try equal(foo.config.Source.preset, (try sourceOf(result, "enabled_tools")).source);
    try equal(foo.config.PermissionMode.deny, result.runtime.permissions);
}

test "custom tool declarations preserve executable arguments without enabling or running them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var call: Request = .{};
    const result = try call.resolve(allocator, .{
        .cwd = invocation_cwd,
        .layers = &.{
            .{ .source = .file, .data = .{ .json = minimal_model } },
            .{ .source = .file, .data = .{ .json =
            \\{"custom_tools":[{
            \\  "name":"formatter","description":"Format an input value.",
            \\  "schema":{"type":"object","properties":{"text":{"type":"string"}}},
            \\  "argv":["fixture-nonexistent-program","--structured"],
            \\  "environment":[{"name":"DEMO_TOKEN","value":"fixture-custom-tool-secret"}],
            \\  "timeout_ms":2500
            \\}]}
            } },
        },
    });
    try equal(0, result.runtime.enabled_tools.len);
    try equal(1, result.launch.custom_tools.len);
    const tool = result.launch.custom_tools[0];
    try same("formatter", tool.name);
    try same("fixture-nonexistent-program", tool.argv[0]);
    try same("--structured", tool.argv[1]);
    try equal(@as(u64, 2500), tool.timeout_ms);
    try expect(has(tool.schema_json, "\"type\":\"object\""));
    try same("fixture-custom-tool-secret", tool.environment[0].value.literal);
    try expect(!has(try config.effectiveJson(allocator, result), "fixture-custom-tool-secret"));
}

test "rendered effective configuration matches the redaction fixture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var call: Request = .{};
    const settings = try call.resolve(allocator, .{
        .cwd = invocation_cwd,
        .layers = &.{.{ .source = .file, .data = .{ .json = @embedFile("fixtures/deepseek.json") } }},
    });
    const rendered = try config.effectiveJson(allocator, settings);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, rendered, .{});
    const runtime = parsed.object.get("runtime").?.object;
    const model = runtime.get("model").?.object;
    const launch = parsed.object.get("launch").?.object;
    const mcp = runtime.get("mcp_servers").?.array.items[0].object.get("transport").?.object.get("http").?.object;
    const selected = try std.json.Stringify.valueAlloc(allocator, .{
        .credential = model.get("credential").?,
        .model_headers = model.get("headers").?,
        .mcp_headers = mcp.get("headers").?,
        .process_environment = launch.get("process").?.object.get("environment").?,
    }, .{ .whitespace = .indent_2 });
    try same(std.mem.trimEnd(u8, @embedFile("fixtures/effective-redaction.json"), "\n"), selected);
}
