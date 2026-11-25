const std = @import("std");
const foo = @import("foo");
const providers = @import("providers");
const auth = @import("auth");
const support = @import("support");
const io = foo.io;
const provider = foo.provider;
const config = foo.config;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const same = std.testing.expectEqualStrings;

const profiles = [_]struct {
    family: config.Family,
    url: []const u8,
    body: []const u8,
    limit_field: []const u8,
    history_field: []const u8,
}{
    .{
        .family = .openai_responses,
        .url = "https://api.x.ai/v1/responses",
        .body = @embedFile("fixtures/responses.sse"),
        .limit_field = "max_output_tokens",
        .history_field = "input",
    },
    .{
        .family = .openai_chat,
        .url = "https://fixture.invalid/v1/chat/completions",
        .body = @embedFile("fixtures/chat.sse"),
        .limit_field = "max_completion_tokens",
        .history_field = "messages",
    },
    .{
        .family = .anthropic_messages,
        .url = "https://fixture.invalid/v1/messages",
        .body = @embedFile("fixtures/anthropic.sse"),
        .limit_field = "max_tokens",
        .history_field = "messages",
    },
};

const prompt = provider.Message{ .role = .user, .blocks = &.{.{ .text = "Look up the key." }} };
const lookup = provider.ToolSpec{
    .name = "lookup",
    .description = "Look up an entry by key.",
    .schema_json = "{\"type\":\"object\",\"properties\":{\"key\":{\"type\":\"string\"}},\"required\":[\"key\"]}",
};
const result_one: provider.Message = .{ .role = .tool, .blocks = &.{.{ .tool_result = .{
    .call_id = "call_1",
    .content = "Found one.",
    .is_error = false,
} }} };
const result_two: provider.Message = .{ .role = .tool, .blocks = &.{.{ .tool_result = .{
    .call_id = "call_2",
    .content = "Missing two.",
    .is_error = true,
} }} };

const Wire = struct {
    allocator: std.mem.Allocator,
    body: []const u8,
    status: u16 = 200,
    next_status: ?u16 = null,
    first_authorization: ?[]const u8 = null,
    content_type: []const u8 = "text/event-stream; charset=utf-8",
    chunk_bytes: usize = 7,
    fail_unsent: usize = 0,
    fail_delivered: bool = false,
    calls: usize = 0,
    url: []const u8 = "",
    request_body: []const u8 = "",
    headers: []const io.Header = &.{},

    fn transport(self: *Wire) io.HttpTransport {
        return .{ .context = self, .exchange_fn = exchange };
    }

    fn exchange(context: *anyopaque, operation: io.Context, request: io.HttpRequest, sink: io.HttpSink, delivery: *io.Delivery) io.Error!void {
        const self: *Wire = @ptrCast(@alignCast(context));
        try operation.check();
        self.calls += 1;
        if (self.calls <= self.fail_unsent) return error.Unavailable;
        delivery.* = .possibly_sent;
        if (self.fail_delivered) return error.Disconnected;
        if (request.method != .post or request.body != .bytes) return error.InvalidInput;
        self.url = try self.allocator.dupe(u8, request.url);
        self.request_body = try self.allocator.dupe(u8, request.body.bytes);
        const headers = try self.allocator.alloc(io.Header, request.headers.len);
        for (request.headers, headers) |source, *target| {
            target.* = .{
                .name = try self.allocator.dupe(u8, source.name),
                .value = try self.allocator.dupe(u8, source.value),
            };
        }
        self.headers = headers;
        if (self.calls == 1) self.first_authorization = self.header("authorization");
        try sink.head_fn(sink.context, operation, .{
            .status = if (self.calls == 1) self.status else self.next_status orelse self.status,
            .headers = &.{.{ .name = "Content-Type", .value = self.content_type }},
        });
        if (self.body.len > request.max_response_bytes) return error.LimitExceeded;
        var offset: usize = 0;
        while (offset < self.body.len) {
            const end = @min(offset + self.chunk_bytes, self.body.len);
            try sink.body.write(operation, self.body[offset..end]);
            offset = end;
        }
    }

    fn header(self: Wire, name: []const u8) ?[]const u8 {
        for (self.headers) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        }
        return null;
    }
};

const Run = struct {
    allocator: std.mem.Allocator,
    clock: support.Clock = .{},
    cancellation: io.Cancellation = .{},
    recorded_text: std.ArrayList(u8) = .empty,
    recorded_reasoning: std.ArrayList(u8) = .empty,
    call_one: []const u8 = "call_1",
    args_one: std.ArrayList(u8) = .empty,
    args_two: std.ArrayList(u8) = .empty,
    cancel_on_text: bool = false,
    delivery: io.Delivery = .unsent,

    fn stream(self: *Run, adapter: *providers.Adapter, request: provider.Request) provider.Error!provider.Response {
        const client = adapter.interface();
        return client.stream_fn(client.context, self.allocator, .{
            .io = std.testing.io,
            .cancellation = &self.cancellation,
            .clock = self.clock.interface(),
        }, request, .{ .context = self, .emit_fn = emit }, &self.delivery);
    }

    fn emit(context: *anyopaque, _: io.Context, delta: provider.Delta) io.Error!void {
        const self: *Run = @ptrCast(@alignCast(context));
        switch (delta) {
            .text => |bytes| {
                try self.recorded_text.appendSlice(self.allocator, bytes);
                if (self.cancel_on_text) self.cancellation.request();
            },
            .reasoning => |bytes| try self.recorded_reasoning.appendSlice(self.allocator, bytes),
            .tool_arguments => |part| {
                const list = if (std.mem.eql(u8, part.call_id, self.call_one))
                    &self.args_one
                else if (std.mem.eql(u8, part.call_id, "call_2"))
                    &self.args_two
                else
                    return error.InvalidInput;
                try list.appendSlice(self.allocator, part.bytes);
            },
        }
    }
};

fn requestFor(family: config.Family, url: []const u8) provider.Request {
    return .{
        .model = .{ .family = family, .endpoint = url, .id = "fixture", .max_output_tokens = 77 },
        .messages = &.{prompt},
        .tools = &.{lookup},
    };
}

fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{});
}

fn member(value: std.json.Value, key: []const u8) !std.json.Value {
    if (value != .object) return error.WantedObject;
    return value.object.get(key) orelse error.MissingField;
}

fn is(value: std.json.Value, key: []const u8, selected: []const u8) bool {
    const field = member(value, key) catch return false;
    return field == .string and std.mem.eql(u8, field.string, selected);
}

fn expectContinuation(family: config.Family, history: []const std.json.Value) !void {
    switch (family) {
        .openai_responses => {
            try equal(5, history.len);
            try expect(is(history[1], "type", "reasoning"));
            try expect(is(history[1], "encrypted_content", "cipher+/1="));
            try expect(is(history[2], "id", "msg_1"));
            try expect(is(history[3], "id", "fc_1"));
            try expect(is(history[3], "call_id", "call_1"));
            try expect(is(history[4], "type", "function_call_output"));
            try expect(is(history[4], "call_id", "call_1"));
            try expect(is(history[4], "output", "Found one."));
        },
        .openai_chat => {
            try equal(4, history.len);
            try expect(is(history[1], "role", "assistant"));
            try expect(is(history[1], "content", "Café ☕"));
            const calls = (try member(history[1], "tool_calls")).array.items;
            try equal(2, calls.len);
            try expect(is(calls[0], "id", "call_1"));
            try expect(is(calls[1], "id", "call_2"));
            try expect(is(history[2], "tool_call_id", "call_1"));
            try expect(is(history[3], "tool_call_id", "call_2"));
        },
        .anthropic_messages => {
            try equal(3, history.len);
            const content = (try member(history[1], "content")).array.items;
            try equal(5, content.len);
            try expect(is(content[0], "type", "thinking"));
            try expect(is(content[0], "thinking", "Check the source."));
            try expect(is(content[0], "signature", "signed+/1="));
            try expect(is(content[1], "type", "redacted_thinking"));
            try expect(is(content[1], "data", "opaque+/2="));
            try expect(is(content[2], "text", "Café ☕"));
            try expect(is(content[3], "id", "call_1"));
            try expect(is(try member(content[3], "input"), "key", "one"));
            try expect(is(history[2], "role", "user"));
            const results = (try member(history[2], "content")).array.items;
            try equal(2, results.len);
            try expect(is(results[0], "tool_use_id", "call_1"));
            try expect(is(results[0], "type", "tool_result"));
            try equal(false, (try member(results[0], "is_error")).bool);
            try expect(is(results[1], "tool_use_id", "call_2"));
            try equal(true, (try member(results[1], "is_error")).bool);
        },
    }
}

fn verifyProfile(comptime profile: @TypeOf(profiles[0])) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var wire: Wire = .{ .allocator = allocator, .body = profile.body, .chunk_bytes = 1 };
    var environment = std.process.Environ.Map.init(allocator);
    try environment.put("FOO_FIXTURE_KEY", "fixture-key");
    try environment.put("FOO_FIXTURE_HEADER", "explicit-value");
    var adapter: providers.Adapter = .{ .transport = wire.transport(), .environment = &environment };
    var run: Run = .{ .allocator = allocator };
    var request = requestFor(profile.family, profile.url);
    request.model.credential = .{ .environment = "FOO_FIXTURE_KEY" };
    request.model.headers = &.{
        .{ .name = "X-Foo-Test", .value = .{ .environment = "FOO_FIXTURE_HEADER" } },
    };

    const response = try run.stream(&adapter, request);
    try equal(io.Delivery.possibly_sent, run.delivery);
    try equal(provider.Stop.tool_use, response.stop);
    try equal(provider.Role.assistant, response.message.role);
    try equal(@as(?u64, if (profile.family == .anthropic_messages) 19 else 12), response.usage.input_tokens);
    try equal(@as(?u64, 7), response.usage.output_tokens);
    try equal(@as(?u64, if (profile.family == .anthropic_messages) 4 else 2), response.usage.cache_read_tokens);
    try same("Café ☕", run.recorded_text.items);
    if (profile.family != .openai_chat) try same("Check the source.", run.recorded_reasoning.items);
    try same("{\"key\":\"one\"}", run.args_one.items);
    if (profile.family != .openai_responses) try same("{\"key\":\"two\"}", run.args_two.items);

    var found_text = false;
    var calls: usize = 0;
    var replays: usize = 0;
    for (response.message.blocks) |block| switch (block) {
        .text => |bytes| {
            try same("Café ☕", bytes);
            found_text = true;
        },
        .tool_call => |call| {
            calls += 1;
            try same("lookup", call.name);
            const args = try parse(allocator, call.arguments_json);
            if (std.mem.eql(u8, call.id, "call_1")) {
                try expect(is(args, "key", "one"));
            } else {
                try same("call_2", call.id);
                try expect(is(args, "key", "two"));
            }
        },
        .replay => |value| {
            try expect(value.compatible(request.model));
            replays += 1;
        },
        else => {},
    };
    try expect(found_text);
    try equal(@as(usize, if (profile.family == .openai_responses) 1 else 2), calls);
    try expect((replays > 0) == (profile.family != .openai_chat));

    try same(profile.url, wire.url);
    try same("explicit-value", wire.header("X-Foo-Test") orelse return error.MissingHeader);
    if (profile.family == .anthropic_messages) {
        try same("fixture-key", wire.header("x-api-key") orelse return error.MissingHeader);
        try same("2023-06-01", wire.header("anthropic-version") orelse return error.MissingHeader);
        try equal(null, wire.header("Authorization"));
    } else {
        try same("Bearer fixture-key", wire.header("Authorization") orelse return error.MissingHeader);
        try equal(null, wire.header("x-api-key"));
    }
    const json = try parse(allocator, wire.request_body);
    try expect(is(json, "model", "fixture"));
    try equal(true, (try member(json, "stream")).bool);
    try equal(77, (try member(json, profile.limit_field)).integer);
    const definition = (try member(json, "tools")).array.items[0];
    const function = if (profile.family == .openai_chat) try member(definition, "function") else definition;
    try expect(is(function, "name", "lookup"));
    const schema = try member(function, if (profile.family == .anthropic_messages) "input_schema" else "parameters");
    try expect(is(schema, "type", "object"));
    if (profile.family == .openai_responses) {
        try equal(false, (try member(json, "store")).bool);
        try same("reasoning.encrypted_content", (try member(json, "include")).array.items[0].string);
    }

    const history = [_]provider.Message{ prompt, response.message, result_one, result_two };
    request.messages = history[0..if (profile.family == .openai_responses) 3 else 4];
    _ = try run.stream(&adapter, request);
    const continued = try parse(allocator, wire.request_body);
    try expectContinuation(profile.family, (try member(continued, profile.history_field)).array.items);

    if (profile.family != .openai_chat) {
        request.model.endpoint = "https://other.invalid/v1";
        try std.testing.expectError(error.IncompatibleReplay, run.stream(&adapter, request));
        try equal(2, wire.calls);
        try equal(io.Delivery.unsent, run.delivery);
    }
}

test "Responses replays ordered native output and correlates the tool call ID" {
    try verifyProfile(profiles[0]);
}

test "Chat Completions assembles interleaved calls and accepts trailing usage" {
    try verifyProfile(profiles[1]);
}

test "Messages replays signed and redacted thinking, grouping results as user input" {
    try verifyProfile(profiles[2]);
}

test "DeepSeek Chat preserves thinking for a tool continuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var wire: Wire = .{ .allocator = allocator, .body = @embedFile("fixtures/deepseek-chat.sse") };
    var adapter: providers.Adapter = .{ .transport = wire.transport() };
    var run: Run = .{ .allocator = allocator };
    var request = requestFor(.openai_chat, "https://api.deepseek.com/chat/completions");
    request.model.id = "deepseek-v4-pro";
    request.model.options_json =
        \\{"chat_token_limit":"max_tokens","chat_reasoning_content":true,
        \\ "reasoning_effort":"high","thinking":{"type":"enabled"}}
    ;
    const response = try run.stream(&adapter, request);
    try equal(provider.Stop.tool_use, response.stop);
    try same("Preserve exactly.", run.recorded_reasoning.items);
    try equal(@as(?u64, 2), response.usage.cache_read_tokens);
    const history = [_]provider.Message{ prompt, response.message, result_one, result_two };
    request.messages = &history;

    _ = try run.stream(&adapter, request);
    const continued = try parse(allocator, wire.request_body);
    const messages = (try member(continued, "messages")).array.items;
    try expectContinuation(.openai_chat, messages);
    try expect(is(messages[1], "reasoning_content", "Preserve exactly."));
    try expect(is(continued, "model", "deepseek-v4-pro"));
    try expect(is(continued, "reasoning_effort", "high"));
    try expect(is(try member(continued, "thinking"), "type", "enabled"));
    try equal(77, (try member(continued, "max_tokens")).integer);
    try expect(!continued.object.contains("max_completion_tokens"));
    try expect(!continued.object.contains("chat_token_limit"));
    try expect(!continued.object.contains("chat_reasoning_content"));

    request.model.id = "deepseek-flash";
    try std.testing.expectError(error.IncompatibleReplay, run.stream(&adapter, request));
    try equal(2, wire.calls);
}

test "Bedrock and gateway aliases use configured endpoint, model and credentials" {
    const routes = [_]struct {
        family: config.Family,
        url: []const u8,
        model: []const u8,
        body: []const u8,
        auth: []const u8,
        header: []const u8,
    }{
        .{
            .family = .openai_chat,
            .url = "https://bedrock-runtime.us-west-2.amazonaws.com/openai/v1/chat/completions",
            .model = "openai.gpt-oss-20b-1:0",
            .body = profiles[1].body,
            .auth = "Bearer fixture-key",
            .header = "Authorization",
        },
        .{
            .family = .openai_responses,
            .url = "https://bedrock-mantle.us-east-1.api.aws/v1/responses",
            .model = "openai.gpt-oss-120b",
            .body = profiles[0].body,
            .auth = "Bearer fixture-key",
            .header = "Authorization",
        },
        .{
            .family = .anthropic_messages,
            .url = "https://bedrock-runtime.us-east-1.amazonaws.com/anthropic/v1/messages",
            .model = "global.anthropic.claude-sonnet-5",
            .body = profiles[2].body,
            .auth = "fixture-key",
            .header = "x-api-key",
        },
        .{
            .family = .openai_chat,
            .url = "http://127.0.0.1:4000/v1/chat/completions",
            .model = "bedrock-claude",
            .body = profiles[1].body,
            .auth = "Bearer fixture-key",
            .header = "Authorization",
        },
        .{
            .family = .openai_chat,
            .url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
            .model = "gemini-4-hydrogen",
            .body = profiles[1].body,
            .auth = "Bearer fixture-key",
            .header = "Authorization",
        },
    };

    for (routes) |route| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var environment = std.process.Environ.Map.init(allocator);
        try environment.put("FOO_FIXTURE_KEY", "fixture-key");
        var wire: Wire = .{ .allocator = allocator, .body = route.body };
        var adapter: providers.Adapter = .{ .transport = wire.transport(), .environment = &environment };
        var run: Run = .{ .allocator = allocator };
        var request = requestFor(route.family, route.url);
        request.model.id = route.model;
        request.model.credential = .{ .environment = "FOO_FIXTURE_KEY" };
        if (route.family == .openai_chat) request.model.options_json =
            \\{"chat_include_usage":false}
        ;
        _ = try run.stream(&adapter, request);
        try same(route.url, wire.url);
        try same(route.auth, wire.header(route.header) orelse return error.MissingHeader);
        const json = try parse(allocator, wire.request_body);
        try expect(is(json, "model", route.model));
        if (route.family == .openai_chat) try expect(!json.object.contains("stream_options"));
    }
}

test "each codec requires its terminal event after provisional output" {
    for (profiles) |profile| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const boundary = std.mem.lastIndexOf(u8, profile.body[0 .. profile.body.len - 2], "\n\n").?;
        var wire: Wire = .{ .allocator = allocator, .body = profile.body[0 .. boundary + 2] };
        var adapter: providers.Adapter = .{ .transport = wire.transport(), .retry_attempts = 3 };
        var run: Run = .{ .allocator = allocator };
        try std.testing.expectError(error.Disconnected, run.stream(&adapter, requestFor(profile.family, profile.url)));
        try same("Café ☕", run.recorded_text.items);
        try equal(io.Delivery.possibly_sent, run.delivery);
        try equal(1, wire.calls);
    }
}

test "HTTP errors and status-specific results never retry a sent request" {
    const failures = [_]struct { status: u16, reason: provider.Error }{
        .{ .status = 400, .reason = error.Rejected },
        .{ .status = 401, .reason = error.Authentication },
        .{ .status = 403, .reason = error.Authentication },
        .{ .status = 429, .reason = error.RateLimited },
    };
    for (profiles) |profile| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        for (failures) |failure| {
            var wire: Wire = .{ .allocator = allocator, .body = "{\"error\":{\"message\":\"fixture\"}}", .status = failure.status, .content_type = "application/json" };
            var adapter: providers.Adapter = .{ .transport = wire.transport(), .retry_attempts = 3 };
            var run: Run = .{ .allocator = allocator };
            try std.testing.expectError(failure.reason, run.stream(&adapter, requestFor(profile.family, profile.url)));
            try equal(1, wire.calls);
            try equal(io.Delivery.possibly_sent, run.delivery);
            try equal(0, run.recorded_text.items.len);
        }
    }
}

test "retry allowance applies only to definitely-unsent transient transport failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for (profiles) |profile| {
        var wire: Wire = .{ .allocator = allocator, .body = profile.body, .fail_unsent = 2 };
        var adapter: providers.Adapter = .{ .transport = wire.transport(), .retry_attempts = 2 };
        var run: Run = .{ .allocator = allocator };
        const request = requestFor(profile.family, profile.url);
        _ = try run.stream(&adapter, request);
        try equal(3, wire.calls);
        try equal(io.Delivery.possibly_sent, run.delivery);

        wire.calls = 0;
        wire.fail_unsent = 3;
        try std.testing.expectError(error.Unavailable, run.stream(&adapter, request));
        try equal(3, wire.calls);
        try equal(io.Delivery.unsent, run.delivery);

        wire.calls = 0;
        wire.fail_unsent = 0;
        wire.fail_delivered = true;
        try std.testing.expectError(error.Disconnected, run.stream(&adapter, request));
        try equal(1, wire.calls);
        try equal(io.Delivery.possibly_sent, run.delivery);
    }
}

test "all three codecs stop deltas on cancellation and reject oversized tool arguments" {
    for (profiles) |profile| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var wire: Wire = .{ .allocator = allocator, .body = profile.body };
        var adapter: providers.Adapter = .{ .transport = wire.transport(), .retry_attempts = 2 };
        var run: Run = .{ .allocator = allocator, .cancel_on_text = true };
        var request = requestFor(profile.family, profile.url);
        try std.testing.expectError(error.Cancelled, run.stream(&adapter, request));
        try same("Café ", run.recorded_text.items);
        try equal(0, run.args_one.items.len);
        try equal(1, wire.calls);

        run = .{ .allocator = allocator };
        request.limits.tool_argument_bytes = 7;
        try std.testing.expectError(error.LimitExceeded, run.stream(&adapter, request));
        try expect(run.args_one.items.len <= request.limits.tool_argument_bytes);
        try equal(2, wire.calls);
    }
}

test "credentials, managed options and managed headers are checked before sending" {
    for (profiles) |profile| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var wire: Wire = .{ .allocator = allocator, .body = profile.body };
        var adapter: providers.Adapter = .{ .transport = wire.transport() };
        var run: Run = .{ .allocator = allocator };
        const request = requestFor(profile.family, profile.url);
        var invalid = request;
        invalid.model.credential = .{ .environment = "ABSENT" };
        try std.testing.expectError(error.Authentication, run.stream(&adapter, invalid));

        invalid = request;
        invalid.model.options_json = "{\"stream\":false}";
        try std.testing.expectError(error.InvalidInput, run.stream(&adapter, invalid));
        invalid.model.options_json = "{\"credential_mode\":\"subscription\"}";
        try std.testing.expectError(error.InvalidInput, run.stream(&adapter, invalid));

        invalid = request;
        invalid.model.headers = &.{.{ .name = "AUTHORIZATION", .value = .{ .literal = "fixture" } }};
        try std.testing.expectError(error.InvalidInput, run.stream(&adapter, invalid));
        try equal(0, wire.calls);
        try equal(io.Delivery.unsent, run.delivery);
    }
}

test "finished streams report actual output limits" {
    const bodies = [_][]const u8{
        \\data: {"type":"response.created","response":{"id":"resp_limit","status":"in_progress","output":[]}}
        \\
        \\data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_limit","role":"assistant","status":"in_progress","content":[]}}
        \\
        \\data: {"type":"response.content_part.added","output_index":0,"item_id":"msg_limit","content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}
        \\
        \\data: {"type":"response.output_text.delta","output_index":0,"item_id":"msg_limit","content_index":0,"delta":"Cut off"}
        \\
        \\data: {"type":"response.output_text.done","output_index":0,"item_id":"msg_limit","content_index":0,"text":"Cut off"}
        \\
        \\data: {"type":"response.content_part.done","output_index":0,"item_id":"msg_limit","content_index":0,"part":{"type":"output_text","text":"Cut off","annotations":[]}}
        \\
        \\data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_limit","role":"assistant","status":"incomplete","content":[{"type":"output_text","text":"Cut off","annotations":[]}]}}
        \\
        \\data: {"type":"response.incomplete","response":{"id":"resp_limit","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"message","id":"msg_limit","role":"assistant","status":"incomplete","content":[{"type":"output_text","text":"Cut off","annotations":[]}]}],"usage":{"output_tokens":77}}}
        \\
        \\
        ,
        \\data: {"id":"chat_limit","choices":[{"index":0,"delta":{"role":"assistant","content":"Cut off"},"finish_reason":null}]}
        \\
        \\data: {"id":"chat_limit","choices":[{"index":0,"delta":{},"finish_reason":"length"}]}
        \\
        \\data: [DONE]
        \\
        \\
        ,
        \\data: {"type":"message_start","message":{"id":"msg_limit","type":"message","role":"assistant","model":"fixture","content":[],"usage":{"input_tokens":12,"output_tokens":1}}}
        \\
        \\data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
        \\
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Cut off"}}
        \\
        \\data: {"type":"content_block_stop","index":0}
        \\
        \\data: {"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_sequence":null},"usage":{"output_tokens":77}}
        \\
        \\data: {"type":"message_stop"}
        \\
        \\
        ,
    };
    for (profiles, bodies) |profile, body| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var wire: Wire = .{ .allocator = allocator, .body = body };
        var adapter: providers.Adapter = .{ .transport = wire.transport() };
        var run: Run = .{ .allocator = allocator };
        const response = try run.stream(&adapter, requestFor(profile.family, profile.url));
        try equal(provider.Stop.output_limit, response.stop);
        try same("Cut off", run.recorded_text.items);
        for (response.message.blocks) |block| try expect(block != .tool_call);
    }
}

test "protocol error events abort without committing the partial response" {
    const errors = [_][]const u8{
        "event: error\ndata: {\"type\":\"error\",\"code\":\"server_error\",\"message\":\"fixture\"}\n\n",
        "data: {\"error\":{\"type\":\"server_error\",\"code\":\"server_error\",\"message\":\"fixture\"}}\n\n",
        "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"fixture\"}}\n\n",
    };
    for (profiles, errors) |profile, event| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const boundary = std.mem.lastIndexOf(u8, profile.body[0 .. profile.body.len - 2], "\n\n").?;
        const body = try std.mem.concat(allocator, u8, &.{ profile.body[0 .. boundary + 2], event });
        var wire: Wire = .{ .allocator = allocator, .body = body };
        var adapter: providers.Adapter = .{ .transport = wire.transport(), .retry_attempts = 3 };
        var run: Run = .{ .allocator = allocator };
        if (run.stream(&adapter, requestFor(profile.family, profile.url))) |_| {
            return error.ErrorEventAccepted;
        } else |failure| {
            try expect(failure != error.Disconnected);
        }
        try same("Café ☕", run.recorded_text.items);
        try equal(io.Delivery.possibly_sent, run.delivery);
        try equal(1, wire.calls);
    }
}

test "wire event and response limits apply independently" {
    for (profiles) |profile| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var wire: Wire = .{ .allocator = allocator, .body = profile.body };
        var adapter: providers.Adapter = .{ .transport = wire.transport() };
        var run: Run = .{ .allocator = allocator };
        var request = requestFor(profile.family, profile.url);
        request.limits.transcript_bytes = profile.body.len - 1;
        try std.testing.expectError(error.LimitExceeded, run.stream(&adapter, request));
        try equal(1, wire.calls);

        var event: [2048]u8 = @splat(' ');
        @memcpy(event[0..6], "data: ");
        @memcpy(event[event.len - 2 ..], "\n\n");
        wire.body = &event;
        request.limits = .{ .wire_message_bytes = 1024 };
        try std.testing.expectError(error.LimitExceeded, run.stream(&adapter, request));
        try equal(2, wire.calls);
    }
}

test "unsupported output types fail before committing a message" {
    const bodies = [_][]const u8{
        "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"image_generation_call\",\"id\":\"ig_1\"}}\n\n",
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"audio\":{\"id\":\"a_1\"}},\"finish_reason\":null}]}\n\n",
        "data: {\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[]}}\n\n" ++
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"image\"}}\n\n",
    };
    for (profiles, bodies) |profile, body| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var wire: Wire = .{ .allocator = allocator, .body = body };
        var adapter: providers.Adapter = .{ .transport = wire.transport() };
        var run: Run = .{ .allocator = allocator };
        if (run.stream(&adapter, requestFor(profile.family, profile.url))) |_| {
            return error.UnsupportedOutputAccepted;
        } else |failure| {
            try expect(failure == error.Rejected or failure == error.Protocol);
        }
        try equal(0, run.recorded_text.items.len);
        try equal(1, wire.calls);
    }
}

test "LiteLLM preserves provider metadata and opaque call IDs when enabled" {
    const body =
        \\data: {"id":"chat_gateway","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1__thought__dGhvdWdodA==","type":"function","function":{"name":"lookup","arguments":"{\"key\":\"one\"}"},"provider_specific_fields":{"thought_signature":"dGhvdWdodA=="}}],"provider_specific_fields":{"thought_signatures":["dGhvdWdodA=="]}},"finish_reason":null}]}
        \\
        \\data: {"id":"chat_gateway","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
        \\
        \\data: {"id":"chat_gateway","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":null}}}
        \\
        \\data: [DONE]
        \\
        \\
    ;
    const call_id = "call_1__thought__dGhvdWdodA==";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var wire: Wire = .{ .allocator = allocator, .body = body };
    var adapter: providers.Adapter = .{ .transport = wire.transport() };
    var run: Run = .{ .allocator = allocator, .call_one = call_id };
    var request = requestFor(.openai_chat, "http://127.0.0.1:4000/v1/chat/completions");

    try std.testing.expectError(error.Rejected, run.stream(&adapter, request));
    request.model.options_json = "{\"chat_litellm\":true}";
    const response = try run.stream(&adapter, request);
    try equal(provider.Stop.tool_use, response.stop);
    try equal(@as(?u64, null), response.usage.cache_read_tokens);
    try equal(@as(?u64, 12), response.usage.input_tokens);

    const result: provider.Message = .{ .role = .tool, .blocks = &.{.{ .tool_result = .{
        .call_id = call_id,
        .content = "Found one.",
        .is_error = false,
    } }} };
    const history = [_]provider.Message{ prompt, response.message, result };
    request.messages = &history;
    _ = try run.stream(&adapter, request);
    const sent = try parse(allocator, wire.request_body);
    const messages = (try member(sent, "messages")).array.items;
    const call = (try member(messages[1], "tool_calls")).array.items[0];
    try expect(is(call, "id", call_id));
    try expect(is(messages[2], "tool_call_id", call_id));
    try expect(is(try member(call, "provider_specific_fields"), "thought_signature", "dGhvdWdodA=="));
    const fields = try member(messages[1], "provider_specific_fields");
    try same("dGhvdWdodA==", (try member(fields, "thought_signatures")).array.items[0].string);
    try expect(!sent.object.contains("chat_litellm"));
}

test "Responses replay cannot override a normalized tool call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const profile = profiles[0];
    var wire: Wire = .{ .allocator = allocator, .body = profile.body };
    var adapter: providers.Adapter = .{ .transport = wire.transport() };
    var run: Run = .{ .allocator = allocator };
    var request = requestFor(profile.family, profile.url);
    const response = try run.stream(&adapter, request);
    const blocks = try allocator.dupe(provider.Block, response.message.blocks);
    for (blocks) |*block| {
        if (block.* == .tool_call) block.tool_call.name = "other";
    }
    const history = [_]provider.Message{ prompt, .{ .role = .assistant, .blocks = blocks }, result_one };
    request.messages = &history;
    try std.testing.expectError(error.IncompatibleReplay, run.stream(&adapter, request));
    try equal(1, wire.calls);
    try equal(io.Delivery.unsent, run.delivery);
}

test "a single invocation budget allows a larger tool catalog" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const profile = profiles[0];
    var wire: Wire = .{ .allocator = allocator, .body = profile.body };
    var adapter: providers.Adapter = .{ .transport = wire.transport() };
    var run: Run = .{ .allocator = allocator };
    var request = requestFor(profile.family, profile.url);
    request.tools = &.{ lookup, .{
        .name = "describe",
        .description = "Describe an entry.",
        .schema_json = "{\"type\":\"object\"}",
    } };
    request.limits.tool_calls = 1;
    const response = try run.stream(&adapter, request);
    try equal(provider.Stop.tool_use, response.stop);
    const sent = try parse(allocator, wire.request_body);
    try equal(2, (try member(sent, "tools")).array.items.len);
    try equal(1, wire.calls);
}

const Refresh = struct {
    var calls: usize = 0;

    fn login(_: std.mem.Allocator, _: io.Context) auth.Error!auth.OAuth {
        return error.Authentication;
    }

    fn refresh(_: std.mem.Allocator, _: io.Context, current: auth.OAuth, token: []const u8) auth.Error!auth.OAuth {
        if (!std.mem.eql(u8, current.access, "first-access") or !std.mem.eql(u8, token, "first-refresh")) return error.InvalidInput;
        calls += 1;
        return .{ .access = "second-access", .refresh = "second-refresh", .expires_ms = 200, .account = current.account };
    }

    const flow = auth.Flow{ .provider = "gateway", .login_fn = login, .refresh_fn = refresh };
};

test "only a bearer with a registered refresh token can retry an HTTP 401" {
    const cases = [_]struct {
        initial_status: u16,
        next_status: u16 = 200,
        refresh_token: ?[]const u8 = "first-refresh",
        registered: bool = true,
        api_key: bool = false,
        refreshed: bool,
    }{
        .{ .initial_status = 401, .refreshed = true },
        .{ .initial_status = 401, .next_status = 401, .refreshed = true },
        .{ .initial_status = 401, .refresh_token = null, .refreshed = false },
        .{ .initial_status = 401, .registered = false, .refreshed = false },
        .{ .initial_status = 403, .refreshed = false },
        .{ .initial_status = 401, .api_key = true, .refreshed = false },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var run: Run = .{ .allocator = a };
        const operation: io.Context = .{ .io = std.testing.io, .cancellation = &run.cancellation, .clock = run.clock.interface() };
        const store = auth.Store{ .directory = try tmp.dir.realPathFileAlloc(operation.io, ".", a) };
        try store.put(a, operation, "gateway", if (case.api_key) .{ .api_key = "first-access" } else .{ .oauth = .{
            .access = "first-access",
            .refresh = case.refresh_token,
            .expires_ms = 100,
            .account = "fixture-account",
        } });
        var wire: Wire = .{
            .allocator = a,
            .body = @embedFile("fixtures/chat.sse"),
            .status = case.initial_status,
            .next_status = case.next_status,
        };
        const resolver = auth.Resolver{ .store = store, .registry = if (case.registered) &.{Refresh.flow} else &.{} };
        var adapter: providers.Adapter = .{ .transport = wire.transport(), .credentials = resolver.interface(), .retry_attempts = 2 };
        var request = requestFor(.openai_chat, "https://fixture.invalid/v1/chat/completions");
        request.model.credential = .{ .auth = "gateway" };

        Refresh.calls = 0;
        if (case.refreshed and case.next_status == 200) {
            _ = try run.stream(&adapter, request);
        } else {
            try std.testing.expectError(error.Authentication, run.stream(&adapter, request));
        }
        try equal(if (case.refreshed) @as(usize, 2) else 1, wire.calls);
        try equal(if (case.refreshed) @as(usize, 1) else 0, Refresh.calls);
        try equal(io.Delivery.possibly_sent, run.delivery);
        try same("Bearer first-access", wire.first_authorization.?);
        try same(if (case.refreshed) "Bearer second-access" else "Bearer first-access", wire.header("authorization").?);
        var snapshot = try store.read(a, operation);
        defer snapshot.deinit();
        if (!case.api_key) try equal(if (case.refreshed) @as(i64, 200) else 100, snapshot.entries.get("gateway").?.oauth.expires_ms);
    }
}
