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
    \\{"providers":{"demo":{"family":"openai_responses","base_url":"https://fixture.invalid/v1","models":{"explicit-model":{}}}},"model":"demo/explicit-model"}
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

test "editor schema references leave the resolved configuration unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var call: Request = .{};
    const layers = [_]config.Layer{
        .{ .source = .file, .data = .{ .json = minimal_model } },
        .{ .source = .file, .data = .{ .json = "{\"$schema\":\"../missing-editor-schema.json\"}" } },
    };
    const plain = try call.resolve(allocator, .{ .cwd = invocation_cwd, .layers = layers[0..1] });
    const annotated = try call.resolve(allocator, .{ .cwd = invocation_cwd, .layers = &layers });
    try same(try config.effectiveJson(allocator, plain), try config.effectiveJson(allocator, annotated));
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
            \\{"model":"demo/cli-model","system_prompt":{"text":"","append_files":[]},"enabled_tools":[]}
            } },
            .{ .source = .file, .location = "user.json", .data = .{ .json = minimal_model } },
            .{ .source = .environment, .location = "FOO_CONFIG", .data = .{ .json =
            \\{"model":"demo/environment-model","limits":{"pending_requests":5}}
            } },
            .{ .source = .file, .location = "project.json", .data = .{ .json =
            \\{"model":"demo/project-model","providers":{"demo":{"models":{"project-model":{},"environment-model":{},"cli-model":{"max_output_tokens":1024}}}},
            \\ "limits":{"pending_requests":4,"pending_events":3},"enabled_tools":["read"]}
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
            \\{"providers":{"demo":{"models":{"last-model":{}}}},"model":"demo/last-model"}
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
        .{ .json = "{\"$schema\":false}", .path_hint = "$schema" },
        .{ .json = "{\"providers\":{\"demo\":{\"endpont\":\"https://fixture.invalid\"}}}", .path_hint = "endpont" },
        .{ .json = "{\"version\":2}", .path_hint = "version" },
        .{ .json = "{\"providers\":{\"demo\":{\"family\":\"guessed\"}}}", .path_hint = "family" },
        .{ .json = "{\"providers\":{\"demo\":{\"models\":{\"explicit-model\":{\"endpoint\":\"https://name:bad-value@fixture.invalid/v1\"}}}}}", .path_hint = "endpoint" },
        .{ .json = "{\"model\":\"demo/explicit-model\",\"model\":\"duplicate-value\"}", .path_hint = "" },
        .{ .json = "{\"limits\":{\"pending_requests\":0}}", .path_hint = "pending_requests" },
        .{ .json = "{\"providers\":{\"demo\":{\"credential\":{\"command\":\"bad-value\"}}}}", .path_hint = "command" },
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
            \\ {"id":"remote","revision":"2026-07-28","transport":{"http":{"url":"hTtP://fixture.invalid/Mcp"}}}
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
    try same("http://fixture.invalid/Mcp", remote.transport.http.url);
}

test "an invalid lower layer fails even if a higher layer replaces its value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var call: Request = .{};
    try std.testing.expectError(error.InvalidConfiguration, call.resolve(arena.allocator(), .{
        .cwd = invocation_cwd,
        .layers = &.{
            .{ .source = .file, .data = .{ .json = minimal_model } },
            .{ .source = .file, .location = "bad.json", .data = .{ .json = "{\"providers\":{\"demo\":{\"models\":{\"explicit-model\":{\"max_output_tokens\":0}}}}}" } },
            .{ .source = .command_line, .data = .{ .json = "{\"providers\":{\"demo\":{\"models\":{\"explicit-model\":{\"max_output_tokens\":2000}}}}}" } },
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
        patch: config.ModelPatch,
        credential: ?[]const u8,
        endpoint: []const u8,
        headers: usize,
    }{
        .{
            .patch = .{ .endpoint = "HTTPS://API.DEEPSEEK.COM:443/v1/chat/Completions" },
            .credential = "DEEPSEEK_API_KEY",
            .endpoint = "https://API.DEEPSEEK.COM:443/v1/chat/Completions",
            .headers = 2,
        },
        .{
            .patch = .{ .endpoint = "https://other.invalid/v1/chat/completions?key=fixture-query-secret" },
            .credential = null,
            .endpoint = "https://other.invalid/v1/chat/completions?key=fixture-query-secret",
            .headers = 0,
        },
        .{
            .patch = .{ .family = .openai_responses },
            .credential = null,
            .endpoint = "https://api.deepseek.com/responses",
            .headers = 0,
        },
        .{
            .patch = .{ .endpoint = "https://other.invalid/responses", .credential_env = "EXPLICIT_REPLACEMENT" },
            .credential = "EXPLICIT_REPLACEMENT",
            .endpoint = "https://other.invalid/responses",
            .headers = 0,
        },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var call: Request = .{};
        const result = try call.resolve(allocator, .{
            .cwd = invocation_cwd,
            .layers = &.{.{ .source = .file, .data = .{ .json = @embedFile("fixtures/deepseek.json") } }},
            .model_patch = case.patch,
        });
        if (case.credential) |env| {
            try same(env, result.runtime.model.credential.environment);
        } else {
            try expect(result.runtime.model.credential == .none);
            try equal(foo.config.Source.command_line, (try sourceOf(result, "model.credential")).source);
        }
        try equal(case.headers, result.runtime.model.headers.len);
        try same(case.endpoint, result.runtime.model.endpoint);
        try expect(!has(try config.effectiveJson(allocator, result), "fixture-query-secret"));
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

test "provider and model fields merge independently across files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var call: Request = .{};
    const settings = try call.resolve(allocator, .{
        .cwd = invocation_cwd,
        .layers = &.{
            .{ .source = .file, .location = "user.json", .data = .{ .json =
            \\{"providers":{"gateway":{"family":"anthropic_messages","credential":{"environment":"USER_KEY"},
            \\ "options":{"shared":"provider","base_only":true,"nested":{"provider":true}},
            \\ "models":{"vendor/main":{"name":"Main","options":{"shared":"model","nested":{"model":true}}},"unused":{}}}},
            \\ "model":"gateway/vendor/main"}
            } },
            .{ .source = .file, .location = "project.json", .data = .{ .json =
            \\{"providers":{"gateway":{"base_url":"https://fixture.invalid/v1///?token=base-query-secret",
            \\ "credential":{"environment":"PROJECT_KEY"},"models":{"vendor/main":{"max_output_tokens":2048}}}}}
            } },
        },
    });
    const provider = settings.providers.get("gateway").?;
    try equal(2, provider.models.len);
    try same("Main", provider.models[0].name.?);
    try same("vendor/main", settings.runtime.model.id);
    try same("https://fixture.invalid/v1/messages?token=base-query-secret", settings.runtime.model.endpoint);
    try same("PROJECT_KEY", settings.runtime.model.credential.environment);
    try equal(@as(u32, 2048), settings.runtime.model.max_output_tokens);
    try same(
        "{\"shared\":\"model\",\"base_only\":true,\"nested\":{\"model\":true}}",
        settings.runtime.model.options_json,
    );
    const family = try sourceOf(settings, "model.family");
    try same("user.json", family.location.?);
    try same("providers.gateway.family", family.input_key.?);
    const cap = try sourceOf(settings, "model.max_output_tokens");
    try same("project.json", cap.location.?);
    try same("providers.gateway.models.vendor/main.max_output_tokens", cap.input_key.?);
    try same("project.json", (try sourceOf(settings, "providers.gateway.credential")).location.?);
    try same("user.json", (try sourceOf(settings, "providers.gateway.models.vendor/main.name")).location.?);
    try expect(!has(try config.effectiveJson(allocator, settings), "base-query-secret"));
}

test "null removes whole entries and their provenance while preserving the rest of the order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var call: Request = .{};
    const settings = try call.resolve(arena.allocator(), .{
        .cwd = invocation_cwd,
        .layers = &.{
            .{ .source = .file, .location = "user.json", .data = .{ .json =
            \\{"providers":{"a":{"family":"openai_responses","models":{"stale":{"name":"Stale"}}},
            \\ "a.b":{"family":"openai_chat","base_url":"https://fixture.invalid","models":{
            \\ "old":{"name":"Old"},"first":{},"readded":{"name":"Old name","max_output_tokens":7}}}}}
            } },
            .{ .source = .file, .data = .{ .json =
            \\{"providers":{"a":null,"a.b":{"models":{"old":null,"readded":null,"second":{}}}}}
            } },
            .{ .source = .file, .location = "project.json", .data = .{ .json =
            \\{"providers":{"a.b":{"models":{"readded":{"name":"Fresh"}}}}}
            } },
        },
        .model_patch = .{ .provider = "a.b" },
    });
    try expect(settings.providers.get("a") == null);
    try same("first", settings.runtime.model.id);
    const models = settings.providers.get("a.b").?.models;
    try equal(3, models.len);
    try same("second", models[1].id);
    try same("readded", models[2].id);
    try equal(@as(u32, 4096), models[2].max_output_tokens);
    try same("Fresh", models[2].name.?);
    try same("project.json", (try sourceOf(settings, "providers.a.b.models.readded.name")).location.?);
    try same("user.json", (try sourceOf(settings, "providers.a.b.family")).location.?);
    for ([_][]const u8{
        "providers.a.family",
        "providers.a.models.stale.name",
        "providers.a.b.models.old.name",
        "providers.a.b.models.readded.max_output_tokens",
    }) |key| try std.testing.expectError(error.MissingProvenance, sourceOf(settings, key));
}

test "unknown file selections fail with the source of model" {
    for ([_][]const u8{
        "{\"model\":\"unknown/explicit-model\"}",
        "{\"model\":\"demo/unknown\"}",
        "{\"providers\":{\"demo\":null}}",
        "{\"providers\":{\"demo\":{\"models\":{\"explicit-model\":null}}}}",
    }, 0..) |json, i| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var call: Request = .{};
        try std.testing.expectError(error.InvalidConfiguration, call.resolve(arena.allocator(), .{
            .cwd = invocation_cwd,
            .layers = &.{
                .{ .source = .file, .location = "user.json", .data = .{ .json = minimal_model } },
                .{ .source = .file, .location = "project.json", .data = .{ .json = json } },
            },
        }));
        const diagnostic = call.diagnostic.?;
        try same("model", diagnostic.path);
        try expect(diagnostic.reason == .invalid_value);
        try same(if (i < 2) "project.json" else "user.json", diagnostic.location.?);
    }
}

test "typed CLI selects existing or ad hoc models and prefers qualified selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var call: Request = .{};
    const layers: []const config.Layer = &.{.{ .source = .file, .data = .{ .json = minimal_model } }};
    for ([_]struct { patch: config.ModelPatch, id: []const u8, location: []const u8 }{
        .{ .patch = .{ .provider = "demo" }, .id = "explicit-model", .location = "--provider" },
        .{ .patch = .{ .provider = "demo", .selection = "another" }, .id = "another", .location = "--model" },
        .{ .patch = .{ .provider = "ignored", .selection = "demo/vendor/custom" }, .id = "vendor/custom", .location = "--model" },
    }) |case| {
        const settings = try call.resolve(arena.allocator(), .{
            .cwd = invocation_cwd,
            .layers = layers,
            .model_patch = case.patch,
        });
        try same(case.id, settings.runtime.model.id);
        try same("https://fixture.invalid/v1/responses", settings.runtime.model.endpoint);
        try equal(@as(u32, 4096), settings.runtime.model.max_output_tokens);
        const origin = try sourceOf(settings, "model.id");
        try equal(foo.config.Source.command_line, origin.source);
        try same(case.location, origin.location.?);
    }
}

test "changing the provider origin requires an explicit replacement credential" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var call: Request = .{};
    const layers = [_]config.Layer{
        .{ .source = .file, .location = "user.json", .data = .{ .json = @embedFile("fixtures/deepseek.json") } },
        .{ .source = .file, .location = "project.json", .data = .{ .json =
        \\{"providers":{"deepseek":{"base_url":"https://other.invalid/v1","family":"openai_responses"}}}
        } },
        .{ .source = .environment, .location = "FOO_CONFIG", .data = .{ .json =
        \\{"providers":{"deepseek":{"credential":null}}}
        } },
    };
    try std.testing.expectError(error.InvalidConfiguration, call.resolve(arena.allocator(), .{
        .cwd = invocation_cwd,
        .layers = layers[0..2],
    }));
    const diagnostic = call.diagnostic.?;
    try expect(diagnostic.reason == .missing_value);
    try same("providers.deepseek.credential", diagnostic.path);
    try same("project.json", diagnostic.location.?);

    const cleared = try call.resolve(arena.allocator(), .{ .cwd = invocation_cwd, .layers = &layers });
    try expect(cleared.runtime.model.credential == .none);
    try equal(0, cleared.runtime.model.headers.len);
    try same("https://other.invalid/v1/responses", cleared.runtime.model.endpoint);
    try same("FOO_CONFIG", (try sourceOf(cleared, "model.credential")).location.?);
    try std.testing.expectError(error.MissingProvenance, sourceOf(cleared, "providers.deepseek.headers"));

    const reset = try call.resolve(arena.allocator(), .{
        .cwd = invocation_cwd,
        .layers = layers[0..2],
        .model_patch = .{ .credential_env = "NEW_KEY" },
    });
    try same("NEW_KEY", reset.runtime.model.credential.environment);
    try equal(0, reset.runtime.model.headers.len);
}

test "model endpoint preserves its path and receives only same-origin inherited auth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var call: Request = .{};
    const settings = try call.resolve(arena.allocator(), .{
        .cwd = invocation_cwd,
        .layers = &.{
            .{ .source = .file, .data = .{ .json = @embedFile("fixtures/deepseek.json") } },
            .{ .source = .file, .location = "gateway.json", .data = .{ .json =
            \\{"providers":{"deepseek":{"models":{"deepseek-v4-pro":{"endpoint":"https://gateway.invalid/per-model"}}}}}
            } },
        },
    });
    try same("https://gateway.invalid/per-model", settings.runtime.model.endpoint);
    try expect(settings.runtime.model.credential == .none);
    try equal(0, settings.runtime.model.headers.len);
    const origin = try sourceOf(settings, "model.endpoint");
    try same("gateway.json", origin.location.?);
    try same("providers.deepseek.models.deepseek-v4-pro.endpoint", origin.input_key.?);
}

test "show redacts literals and queries in every provider and model" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var call: Request = .{};
    const settings = try call.resolve(allocator, .{
        .cwd = invocation_cwd,
        .layers = &.{.{ .source = .file, .data = .{ .json =
        \\{"providers":{
        \\ "gateway":{"family":"openai_chat","base_url":"https://host.invalid?literal=provider-query-secret",
        \\ "credential":{"literal":"literal-key-secret"},"headers":[{"name":"X-Trace","value":"literal-header-secret"}],
        \\ "options":{"long":"provider-option-secret"},"models":{"chosen":{"options":{"short":"model-option-secret"},
        \\ "endpoint":"https://host.invalid/choose?literal=model-query-secret"}}},
        \\ "oauth":{"family":"openai_responses","base_url":"https://auth.invalid","credential":{"auth":"auth-profile"},"models":{"spare":{}}}
        \\},"model":"gateway/chosen"}
        } }},
    });
    try same("literal-key-secret", settings.runtime.model.credential.literal);
    try same("literal-header-secret", settings.runtime.model.headers[0].value.literal);
    try same("auth-profile", settings.providers.get("oauth").?.credential.auth);
    const rendered = try config.effectiveJson(allocator, settings);
    for ([_][]const u8{
        "provider-query-secret",  "literal-key-secret",  "literal-header-secret",
        "provider-option-secret", "model-option-secret", "model-query-secret",
    }) |secret| try expect(!has(rendered, secret));
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, rendered, .{});
    const providers = parsed.object.get("providers").?.object;
    const gateway = providers.get("gateway").?.object;
    const chosen = gateway.get("models").?.object.get("chosen").?.object;
    try same("<redacted>", gateway.get("credential").?.object.get("literal").?.string);
    try same("https://host.invalid/choose?<redacted>", chosen.get("endpoint").?.string);
    try same("auth-profile", providers.get("oauth").?.object.get("credential").?.object.get("auth").?.string);
}

test "old model objects get the migration message and their own file location" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var call: Request = .{};
    try std.testing.expectError(error.InvalidConfiguration, call.resolve(arena.allocator(), .{
        .cwd = invocation_cwd,
        .layers = &.{.{ .source = .file, .location = "old.json", .data = .{ .json = "{\"model\":{\"id\":\"old-model\"}}" } }},
    }));
    const diagnostic = call.diagnostic.?;
    try same("model", diagnostic.path);
    try expect(diagnostic.reason == .invalid_value);
    try same("old.json", diagnostic.location.?);
    try same("model is a string \"provider/id\"; define providers under \"providers\"", diagnostic.message.?);
}

test "long provider IDs do not amplify empty entries and bound generated paths" {
    const storage = try std.testing.allocator.alloc(u8, 16 * 1024 * 1024);
    defer std.testing.allocator.free(storage);
    var provider_id: [32 * 1024]u8 = undefined;
    @memset(&provider_id, 'p');
    for ([_]bool{ false, true }) |has_fields| {
        var json = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer json.deinit();
        try json.writer.print(
            "{{\"model\":\"{s}/m0\",\"providers\":{{\"{s}\":{{\"family\":\"openai_chat\",\"base_url\":\"https://example.invalid\",\"models\":{{",
            .{ &provider_id, &provider_id },
        );
        for (0..1024) |index| {
            if (index != 0) try json.writer.writeByte(',');
            try json.writer.print("\"m{d}\":{s}", .{ index, if (has_fields) "{\"max_output_tokens\":123}" else "{}" });
        }
        try json.writer.writeAll("}}}}");

        var fixed = std.heap.FixedBufferAllocator.init(storage);
        var arena = std.heap.ArenaAllocator.init(if (has_fields) std.testing.allocator else fixed.allocator());
        defer arena.deinit();
        var call: Request = .{};
        const result = call.resolve(arena.allocator(), .{
            .cwd = invocation_cwd,
            .layers = &.{.{ .source = .file, .data = .{ .json = json.written() } }},
        });
        if (has_fields) {
            try std.testing.expectError(error.LimitExceeded, result);
            try expect(call.diagnostic.?.reason == .limit_exceeded);
        } else {
            const effective = try result;
            try same("m0", effective.runtime.model.id);
            try equal(1024, effective.providers.get(&provider_id).?.models.len);
        }
    }
}

test "built-in providers resolve from defaults and user layers can replace or remove them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var call: Request = .{};
    const select =
        \\{"providers":{"openai-codex":{"models":{"gpt-6.1-terra":{}}}},"model":"openai-codex/gpt-6.1-terra"}
    ;
    const builtin = try call.resolve(allocator, .{ .cwd = invocation_cwd, .layers = &.{.{ .source = .file, .data = .{ .json = select } }} });
    const model = builtin.runtime.model;
    try same("https://chatgpt.com/backend-api/codex/responses", model.endpoint);
    try same("openai-codex", model.credential.auth);
    try same("originator", model.headers[0].name);
    try same("foo", model.headers[0].value.literal);
    try equal(foo.config.Source.defaults, (try sourceOf(builtin, "providers.openai-codex.base_url")).source);
    try equal(foo.config.Source.defaults, (try sourceOf(builtin, "model.credential")).source);

    const moved = [_]config.Layer{
        .{ .source = .file, .data = .{ .json = select } },
        .{ .source = .file, .location = "user.json", .data = .{ .json =
        \\{"providers":{"openai-codex":{"base_url":"https://other.invalid/v1"}}}
        } },
    };
    try std.testing.expectError(error.InvalidConfiguration, call.resolve(allocator, .{ .cwd = invocation_cwd, .layers = &moved }));
    try same("providers.openai-codex.credential", call.diagnostic.?.path);

    const removed = try call.resolve(allocator, .{ .cwd = invocation_cwd, .layers = &.{.{ .source = .file, .data = .{ .json =
        \\{"providers":{"openai-codex":null,"demo":{"family":"openai_responses","base_url":"https://fixture.invalid/v1","models":{"explicit-model":{}}}},"model":"demo/explicit-model"}
    } }} });
    try expect(removed.providers.get("openai-codex") == null);
}
