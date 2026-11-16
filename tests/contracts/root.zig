const std = @import("std");
const foo = @import("foo");
const support = @import("support");

const model: foo.config.Model = .{ .family = .openai_responses, .endpoint = "https://example.invalid", .id = "test-model" };
const declaration: foo.tool.Declaration = .{
    .identity = .{ .backend = "executable", .name = "echo" },
    .spec = .{ .name = "echo", .description = "echo", .schema_json = "{}" },
    .generation = 1,
};
const invocation: foo.tool.Invocation = .{
    .declaration = declaration,
    .call = .{ .id = "call-1", .name = "echo", .arguments_json = "{}" },
};

fn operation(cancel: *const foo.io.Cancellation, clock: *support.Clock) foo.io.Context {
    return .{ .io = std.testing.io, .cancellation = cancel, .clock = clock.interface() };
}

test "cancellation wakes once even when output cannot accept data" {
    const Wake = struct {
        fn run(context: ?*anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }
    };
    var wakes: usize = 0;
    var cancel: foo.io.Cancellation = .{ .wake_context = &wakes, .wake_fn = Wake.run };
    var clock: support.Clock = .{};
    var storage: [2]u8 = undefined;
    var bytes: support.Bytes = .{ .buffer = &storage, .reject = true };
    try std.testing.expectError(error.Unavailable, bytes.interface().write(operation(&cancel, &clock), "x"));
    cancel.request();
    cancel.request();
    try std.testing.expectEqual(@as(usize, 1), wakes);
    try std.testing.expectError(error.Cancelled, bytes.interface().write(operation(&cancel, &clock), "x"));
    try std.testing.expectEqual(@as(usize, 0), bytes.used);
}

test "deadline uses injected monotonic time and budget rejects without consuming" {
    var clock: support.Clock = .{ .time_ms = 10 };
    var cancel: foo.io.Cancellation = .{};
    var context = operation(&cancel, &clock);
    context.deadline_ms = 11;
    try context.check();
    clock.time_ms = 11;
    try std.testing.expectError(error.DeadlineExceeded, context.check());
    var budget: foo.io.Budget = .{ .limit = 5 };
    try budget.take(3);
    try std.testing.expectError(error.LimitExceeded, budget.take(std.math.maxInt(usize)));
    try std.testing.expectEqual(@as(usize, 3), budget.used);
    try budget.take(2);
    try std.testing.expectError(error.LimitExceeded, budget.take(1));
}

test "provider deltas are borrowed but final response survives scratch mutation" {
    const Collector = struct {
        bytes: support.Bytes,
        fn emit(context: *anyopaque, op: foo.io.Context, delta: foo.provider.Delta) foo.io.Error!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (delta == .text) try self.bytes.interface().write(op, delta.text);
        }
    };
    var scratch = [_]u8{ 'h', 'i' };
    var fake: support.Provider = .{
        .deltas = &.{.{ .text = &scratch }},
        .response = .{
            .message = .{ .role = .assistant, .blocks = &.{
                .{ .text = &scratch },
                .{ .replay = .{ .family = model.family, .endpoint = model.endpoint, .model = model.id, .bytes = &scratch } },
            } },
            .stop = .end_turn,
        },
    };
    var buffer: [8]u8 = undefined;
    var collector: Collector = .{ .bytes = .{ .buffer = &buffer } };
    var clock: support.Clock = .{};
    var cancel: foo.io.Cancellation = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const adapter = fake.interface();
    var delivery: foo.io.Delivery = .unsent;
    const response = try adapter.stream_fn(adapter.context, arena.allocator(), operation(&cancel, &clock), .{ .model = model, .messages = &.{} }, .{ .context = &collector, .emit_fn = Collector.emit }, &delivery);
    @memset(&scratch, 'x');
    try std.testing.expectEqualStrings("hi", response.message.blocks[0].text);
    try std.testing.expectEqualStrings("hi", response.message.blocks[1].replay.bytes);
    try std.testing.expectEqualStrings("hi", collector.bytes.buffer[0..collector.bytes.used]);
    try std.testing.expect(response.usage.input_tokens == null);
    try std.testing.expectEqual(foo.io.Delivery.possibly_sent, delivery);
    var other = model;
    other.endpoint = "https://other.invalid";
    try std.testing.expect(!response.message.blocks[1].replay.compatible(other));
}

test "scripted provider error is not a successful response or zero usage" {
    const Ignore = struct {
        fn emit(_: *anyopaque, _: foo.io.Context, _: foo.provider.Delta) foo.io.Error!void {}
    };
    var fake: support.Provider = .{
        .response = .{ .message = .{ .role = .assistant, .blocks = &.{} }, .stop = .end_turn },
        .failure = error.Authentication,
    };
    var cancel: foo.io.Cancellation = .{};
    var clock: support.Clock = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const adapter = fake.interface();
    var delivery: foo.io.Delivery = .unsent;
    try std.testing.expectError(error.Authentication, adapter.stream_fn(adapter.context, arena.allocator(), operation(&cancel, &clock), .{ .model = model, .messages = &.{} }, .{ .context = &fake, .emit_fn = Ignore.emit }, &delivery));
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}

test "catalog revocation and cancellation prevent scripted effects" {
    var fake: support.Tools = .{ .declarations = &.{declaration}, .revoked = true };
    var cancel: foo.io.Cancellation = .{};
    var clock: support.Clock = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const registry = fake.interface();
    const rejected = try registry.invoke_fn(registry.context, arena.allocator(), operation(&cancel, &clock), invocation);
    try std.testing.expectEqual(foo.tool.Status.catalog_changed, rejected.status);
    try std.testing.expectEqual(foo.tool.Effect.not_started, rejected.effect);
    try std.testing.expectEqual(@as(usize, 0), fake.effects);
    fake.revoked = false;
    fake.failure = true;
    const failed = try registry.invoke_fn(registry.context, arena.allocator(), operation(&cancel, &clock), invocation);
    try std.testing.expectEqual(foo.tool.Status.failure, failed.status);
    try std.testing.expectEqual(foo.tool.Effect.observed, failed.effect);
    cancel.request();
    try std.testing.expectError(error.Cancelled, registry.invoke_fn(registry.context, arena.allocator(), operation(&cancel, &clock), invocation));
    try std.testing.expectEqual(@as(usize, 1), fake.effects);
}

test "failed result commit leaves uncertainty without replaying tool" {
    var journal: support.Journal = .{};
    var tools: support.Tools = .{ .declarations = &.{declaration} };
    var cancel: foo.io.Cancellation = .{};
    var clock: support.Clock = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const store = journal.interface();
    const registry = tools.interface();
    const context = operation(&cancel, &clock);
    try std.testing.expectEqual(@as(u64, 1), try store.commit_fn(store.context, context, .{ .dispatch_intent = invocation }));
    const result = try registry.invoke_fn(registry.context, arena.allocator(), context, invocation);
    journal.fail_commit = true;
    try std.testing.expectError(error.CommitFailed, store.commit_fn(store.context, context, .{ .tool_result = result }));
    const recovery = try store.load_fn(store.context, arena.allocator(), context);
    try std.testing.expectEqual(@as(usize, 1), tools.effects);
    try std.testing.expectEqual(@as(usize, 1), journal.committed);
    try std.testing.expectEqualStrings("call-1", recovery.uncertain_call_ids[0]);
    try std.testing.expect(recovery.interrupted);
}

test "ordered events reject repeated commit IDs and events after finish" {
    var order: foo.events.Order = .{};
    const event: foo.events.Event = .{ .run = @fromBackingInt(@intCast(1)), .data = .{ .message_committed = .{
        .sequence = 1,
        .message = .{ .role = .user, .blocks = &.{} },
    } } };
    try order.accept(event);
    try std.testing.expectError(error.InvalidSequence, order.accept(event));
    try order.accept(.{ .run = event.run, .data = .{ .finished = .{ .reason = .cancelled, .uncertain_effects = true } } });
    try std.testing.expectError(error.AlreadyFinished, order.accept(event));
}

test "JSON-RPC retains distinct numeric string and notification identities" {
    const numeric: foo.jsonrpc.Id = .{ .number = 42 };
    const string: foo.jsonrpc.Id = .{ .string = "42" };
    try std.testing.expect(!numeric.eql(string));
    try std.testing.expect(string.eql(.{ .string = "42" }));
    const notification: foo.jsonrpc.Request = .{ .id = null, .method = "session/cancel" };
    try std.testing.expect(notification.id == null);
    const failure: foo.jsonrpc.Response = .{ .failure = .{ .err = .{
        .code = foo.jsonrpc.Code.parse_error,
        .message = "invalid JSON",
    } } };
    try std.testing.expect(failure.failure.id == null);
}

test "transport streams within limits and preserves possible delivery on error" {
    const Head = struct {
        fn receive(_: *anyopaque, op: foo.io.Context, head: foo.io.HttpHead) foo.io.Error!void {
            try op.check();
            if (head.status != 200) return error.InvalidInput;
        }
    };
    var http: support.Http = .{ .chunks = &.{ "ab", "cd" } };
    var cancel: foo.io.Cancellation = .{};
    var clock: support.Clock = .{};
    var storage: [8]u8 = undefined;
    var bytes: support.Bytes = .{ .buffer = &storage };
    const adapter = http.interface();
    var delivery: foo.io.Delivery = .unsent;
    try std.testing.expectError(error.LimitExceeded, adapter.exchange_fn(adapter.context, operation(&cancel, &clock), .{
        .method = .post,
        .url = "https://example.invalid",
        .max_response_bytes = 3,
    }, .{ .context = &http, .head_fn = Head.receive, .body = bytes.interface() }, &delivery));
    try std.testing.expectEqualStrings("ab", storage[0..bytes.used]);
    try std.testing.expectEqual(foo.io.Delivery.possibly_sent, delivery);
}

const Upload = struct {
    bytes: []const u8,
    chunk_size: usize = 3,
    offset: usize = 0,
    failure_after: ?usize = null,
    cancellation: ?*foo.io.Cancellation = null,

    fn interface(self: *Upload) foo.io.ByteSource {
        return .{ .context = self, .read_fn = read };
    }

    fn read(context: *anyopaque, op: foo.io.Context, buffer: []u8) foo.io.Error!usize {
        const self: *Upload = @ptrCast(@alignCast(context));
        try op.check();
        if (self.failure_after) |offset| {
            if (self.offset >= offset) {
                if (self.cancellation) |cancel| {
                    cancel.request();
                    return error.Cancelled;
                }
                return error.Disconnected;
            }
        }
        const count = @min(buffer.len, self.chunk_size, self.bytes.len - self.offset);
        @memcpy(buffer[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        return count;
    }
};

const HttpResponse = struct {
    heads: usize = 0,
    bytes: support.Bytes = .{ .buffer = &.{} },
    head_failure: ?foo.io.Error = null,

    fn interface(self: *HttpResponse) foo.io.HttpSink {
        return .{ .context = self, .head_fn = head, .body = self.bytes.interface() };
    }

    fn head(context: *anyopaque, op: foo.io.Context, _: foo.io.HttpHead) foo.io.Error!void {
        const self: *HttpResponse = @ptrCast(@alignCast(context));
        try op.check();
        self.heads += 1;
        if (self.head_failure) |failure| return failure;
    }
};

test "byte and chunked known or unknown uploads preserve the same body" {
    var payload: [8197]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @intCast(i % 251);
    for ([_]enum { bytes, known, unknown }{ .bytes, .known, .unknown }) |kind| {
        var source: Upload = .{ .bytes = &payload };
        var captured: [payload.len]u8 = undefined;
        var http: support.Http = .{ .chunks = &.{"ok"}, .upload = .{ .buffer = &captured } };
        var response_storage: [2]u8 = undefined;
        var response: HttpResponse = .{ .bytes = .{ .buffer = &response_storage } };
        var cancel: foo.io.Cancellation = .{};
        var clock: support.Clock = .{};
        const adapter = http.interface();
        var delivery: foo.io.Delivery = .unsent;
        try adapter.exchange_fn(adapter.context, operation(&cancel, &clock), .{
            .method = .post,
            .url = "https://example.invalid",
            .body = if (kind == .bytes) .{ .bytes = &payload } else .{ .stream = .{
                .source = source.interface(),
                .content_length = if (kind == .known) payload.len else null,
            } },
            .max_response_bytes = 2,
        }, response.interface(), &delivery);
        try std.testing.expectEqualSlices(u8, &payload, captured[0..http.upload.used]);
        try std.testing.expectEqualStrings("ok", response_storage[0..response.bytes.used]);
        try std.testing.expectEqual(@as(usize, 1), response.heads);
        try std.testing.expectEqual(foo.io.Delivery.possibly_sent, delivery);
    }
}

test "declared upload length leaves later bytes unread including zero length" {
    for ([_]u64{ 0, 1, 4, 6 }) |length| {
        var source: Upload = .{ .bytes = "abcdefextra", .failure_after = @intCast(length) };
        var captured: [6]u8 = undefined;
        var http: support.Http = .{ .chunks = &.{}, .upload = .{ .buffer = &captured } };
        var response: HttpResponse = .{};
        var cancel: foo.io.Cancellation = .{};
        var clock: support.Clock = .{};
        const adapter = http.interface();
        var delivery: foo.io.Delivery = .unsent;
        try adapter.exchange_fn(adapter.context, operation(&cancel, &clock), .{
            .method = .post,
            .url = "https://example.invalid",
            .body = .{ .stream = .{ .source = source.interface(), .content_length = length } },
            .max_response_bytes = 0,
        }, response.interface(), &delivery);
        try std.testing.expectEqualStrings("abcdef"[0..@intCast(length)], captured[0..http.upload.used]);
        try std.testing.expectEqual(@as(usize, @intCast(length)), source.offset);
    }
}

test "premature upload EOF fails before a scripted response" {
    var source: Upload = .{ .bytes = "abc" };
    var captured: [6]u8 = undefined;
    var http: support.Http = .{ .chunks = &.{}, .upload = .{ .buffer = &captured } };
    var response: HttpResponse = .{};
    var cancel: foo.io.Cancellation = .{};
    var clock: support.Clock = .{};
    const adapter = http.interface();
    var delivery: foo.io.Delivery = .unsent;
    try std.testing.expectError(error.IoFailure, adapter.exchange_fn(adapter.context, operation(&cancel, &clock), .{
        .method = .post,
        .url = "https://example.invalid",
        .body = .{ .stream = .{ .source = source.interface(), .content_length = 4 } },
        .max_response_bytes = 0,
    }, response.interface(), &delivery));
    try std.testing.expectEqualStrings("abc", captured[0..http.upload.used]);
    try std.testing.expectEqual(@as(usize, 0), response.heads);
    try std.testing.expectEqual(foo.io.Delivery.possibly_sent, delivery);
}

test "upload source errors and cancellation preserve the consumed prefix" {
    for ([_]bool{ false, true }) |cancel_during_read| {
        var cancel: foo.io.Cancellation = .{};
        var source: Upload = .{
            .bytes = "abcdef",
            .failure_after = 3,
            .cancellation = if (cancel_during_read) &cancel else null,
        };
        var captured: [6]u8 = undefined;
        var http: support.Http = .{ .chunks = &.{}, .upload = .{ .buffer = &captured } };
        var response: HttpResponse = .{};
        var clock: support.Clock = .{};
        const adapter = http.interface();
        var delivery: foo.io.Delivery = .unsent;
        try std.testing.expectError(if (cancel_during_read) error.Cancelled else error.Disconnected, adapter.exchange_fn(adapter.context, operation(&cancel, &clock), .{
            .method = .post,
            .url = "https://example.invalid",
            .body = .{ .stream = .{ .source = source.interface() } },
            .max_response_bytes = 0,
        }, response.interface(), &delivery));
        try std.testing.expectEqualStrings("abc", captured[0..http.upload.used]);
        try std.testing.expectEqual(@as(usize, 3), source.offset);
        try std.testing.expectEqual(@as(usize, 0), response.heads);
        try std.testing.expectEqual(foo.io.Delivery.possibly_sent, delivery);
    }
}

test "pre-cancelled exchange does not consume an upload" {
    var source: Upload = .{ .bytes = "abc" };
    var http: support.Http = .{ .chunks = &.{} };
    var response: HttpResponse = .{};
    var cancel: foo.io.Cancellation = .{};
    cancel.request();
    var clock: support.Clock = .{};
    const adapter = http.interface();
    var delivery: foo.io.Delivery = .unsent;
    try std.testing.expectError(error.Cancelled, adapter.exchange_fn(adapter.context, operation(&cancel, &clock), .{
        .method = .post,
        .url = "https://example.invalid",
        .body = .{ .stream = .{ .source = source.interface() } },
        .max_response_bytes = 0,
    }, response.interface(), &delivery));
    try std.testing.expectEqual(@as(usize, 0), source.offset);
    try std.testing.expectEqual(@as(usize, 0), http.calls);
    try std.testing.expectEqual(foo.io.Delivery.unsent, delivery);
}

test "HTTP fake propagates bounded capture and response sink failures" {
    for ([_]enum { capture, head, body }{ .capture, .head, .body }) |failure| {
        var captured: [2]u8 = undefined;
        var http: support.Http = .{
            .chunks = &.{"ok"},
            .upload = .{ .buffer = if (failure == .capture) captured[0..1] else &captured },
        };
        var response: HttpResponse = .{
            .head_failure = if (failure == .head) error.InvalidInput else null,
            .bytes = .{ .buffer = &.{}, .reject = true },
        };
        var cancel: foo.io.Cancellation = .{};
        var clock: support.Clock = .{};
        const adapter = http.interface();
        var delivery: foo.io.Delivery = .unsent;
        try std.testing.expectError(switch (failure) {
            .capture => error.LimitExceeded,
            .head => error.InvalidInput,
            .body => error.Unavailable,
        }, adapter.exchange_fn(adapter.context, operation(&cancel, &clock), .{
            .method = .post,
            .url = "https://example.invalid",
            .body = .{ .bytes = "hi" },
            .max_response_bytes = 2,
        }, response.interface(), &delivery));
        try std.testing.expectEqual(@as(usize, if (failure == .capture) 0 else 1), response.heads);
        try std.testing.expectEqual(foo.io.Delivery.possibly_sent, delivery);
    }
}

test "editor permissions remain tied to operation and cancellation" {
    var editor: support.Editor = .{};
    var cancel: foo.io.Cancellation = .{};
    var clock: support.Clock = .{};
    const prepared: foo.host.PreparedOperation = .{
        .session = @fromBackingInt(@intCast(1)),
        .run = @fromBackingInt(@intCast(1)),
        .operation_id = 7,
        .invocation = invocation,
        .targets = &.{"/workspace/test"},
    };
    const handler = editor.interface();
    try std.testing.expectEqual(foo.host.Decision.deny_once, try handler.decide_fn(handler.context, operation(&cancel, &clock), prepared));
    try std.testing.expectEqual(@as(?u64, 7), editor.operation_id);
    cancel.request();
    try std.testing.expectError(error.Cancelled, handler.decide_fn(handler.context, operation(&cancel, &clock), prepared));
    try std.testing.expectEqual(@as(usize, 1), editor.calls);
    const host: foo.host.Host = .{};
    try std.testing.expect(!host.capabilities.read_file and host.files == null);
}

test "resolved configuration requires an explicit model and nonzero bounds" {
    var settings: foo.config.Resolved = .{ .model = model, .cwd = "/workspace" };
    try settings.validate();
    try std.testing.expectEqualStrings("", settings.system_prompt);
    settings.limits.wire_message_bytes = 0;
    try std.testing.expectError(error.InvalidConfiguration, settings.validate());
    try std.testing.expectEqual(foo.config.Source.command_line, foo.config.precedence[4]);
    try std.testing.expectEqual(@as(u32, 1), foo.config.acp_version);
    try std.testing.expectEqual(@as(usize, 0), settings.enabled_tools.len);
    const literal: foo.config.Header = .{ .name = "anthropic-beta", .value = .{ .literal = "test-feature" } };
    try std.testing.expectEqualStrings("test-feature", literal.value.literal);
    settings.limits.wire_message_bytes = 1;
    settings.mcp_servers = &.{.{ .id = "test", .transport = .{ .stdio = .{ .argv = &.{} } } }};
    try std.testing.expectError(error.InvalidConfiguration, settings.validate());
}

fn copyUnderAllocationFailure(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const message: foo.provider.Message = .{ .role = .assistant, .blocks = &.{
        .{ .text = "answer" },
        .{ .reasoning = .{ .text = "reasoning", .signature = "signature" } },
        .{ .tool_call = invocation.call },
        .{ .tool_result = .{ .call_id = "call-1", .content = "result", .is_error = false } },
        .{ .replay = .{ .family = model.family, .endpoint = model.endpoint, .model = model.id, .bytes = "opaque" } },
    } };
    const copied = try foo.provider.copyMessage(arena.allocator(), message);
    try std.testing.expectEqualStrings("signature", copied.blocks[1].reasoning.signature.?);
    try std.testing.expectEqualStrings("{}", copied.blocks[2].tool_call.arguments_json);
    try std.testing.expectEqualStrings("result", copied.blocks[3].tool_result.content);
    try std.testing.expectEqualStrings("opaque", copied.blocks[4].replay.bytes);
}

test "completed message copy releases its arena on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, copyUnderAllocationFailure, .{});
}

test "duplex child keeps diagnostics separate and cleanup survives run cancellation" {
    var input: [16]u8 = undefined;
    var process: support.Process = .{
        .input = .{ .buffer = &input },
        .stdout_bytes = "{}\n",
        .stderr_bytes = "diagnostic",
    };
    var cancel: foo.io.Cancellation = .{};
    var clock: support.Clock = .{};
    const child = process.interface();
    const context = operation(&cancel, &clock);
    try child.stdin.write(context, "request\n");
    var out: [16]u8 = undefined;
    var err: [16]u8 = undefined;
    const out_size = try child.stdout.read_fn(child.stdout.context, context, &out);
    const err_size = try child.stderr.read_fn(child.stderr.context, context, &err);
    try std.testing.expectEqualStrings("{}\n", out[0..out_size]);
    try std.testing.expectEqualStrings("diagnostic", err[0..err_size]);
    try std.testing.expectEqualStrings("request\n", input[0..process.input.used]);
    cancel.request();
    try std.testing.expectError(error.Cancelled, child.wait_fn(child.context, context));
    var cleanup_cancel: foo.io.Cancellation = .{};
    const cleanup = operation(&cleanup_cancel, &clock);
    try child.terminate_fn(child.context, cleanup);
    try std.testing.expectEqual(@as(i32, 1), (try child.wait_fn(child.context, cleanup)).exited);
    try child.release_fn(child.context, cleanup);
    try std.testing.expectError(error.Unavailable, child.stdin.write(cleanup, "extra"));
}
