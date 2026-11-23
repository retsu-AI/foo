const std = @import("std");
const foo = @import("foo");
const core = @import("core");
const scripted = @import("fixture.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;
const Fixture = scripted.Fixture;
const Point = scripted.Point;
const answer = scripted.answer;
const batch = scripted.batch;
const call = scripted.call;
const two_calls = batch(&.{ call("one", "echo", "{}"), call("two", "echo", "{}") });

test "text deltas are provisional and natural stop after one request returns through Runner" {
    var fixture: Fixture = .{
        .steps = &.{.{ .deltas = &.{ .{ .text = "do" }, .{ .text = "ne" } } }},
        .recovery = .{ .messages = &.{}, .last_sequence = 8, .interrupted = false, .uncertain_call_ids = &.{} },
    };
    defer fixture.deinit();

    const outcome = try fixture.executeRunner();
    try expectEqual(.completed, outcome.reason);
    try expectEqual(.end_turn, outcome.provider_stop);
    try expectEqualStrings("done", fixture.delta_text.items);
    try expectEqualSlices(u64, &.{ 9, 10 }, fixture.sequences.items);
    try expectEqualSlices(Point, &.{
        .load,             .user_record,     .user_event,      .request,        .delta, .delta,
        .assistant_record, .assistant_event, .terminal_record, .terminal_event,
    }, fixture.trace.items);
    try expectEqualSlices(foo.events.Outcome, &.{outcome}, fixture.terminal_outcomes.items);
    try expectEqualSlices(foo.events.Outcome, &.{outcome}, fixture.journal_outcomes.items);
    try expectEqual(0, fixture.invocations.items.len);
}

test "ordered tool batches commit intent before effects and expose paired history to the provider" {
    const replay: foo.provider.Replay = .{
        .family = scripted.model.family,
        .endpoint = scripted.model.endpoint,
        .model = scripted.model.id,
        .bytes = &.{ 0, 255, 17 },
    };
    var fixture: Fixture = .{
        .steps = &.{
            .{ .response = batch(&.{ .{ .replay = replay }, call("one", "echo", "{}"), call("two", "echo", "{}") }) },
            .{ .response = batch(&.{call("three", "echo", "{\"again\":true}")}) },
            .{},
        },
        .tools = &.{ .{}, .{ .status = .denied, .effect = .not_started, .content = "denied" }, .{ .status = .failure, .content = "failed" } },
    };
    defer fixture.deinit();

    const report = try fixture.execute();
    try fixture.expectTerminal(.completed, report);
    try expectEqual(3, report.model_turns);
    try expectEqual(3, report.tool_calls);
    try expectEqual(13, report.usage.input_tokens.?);
    try expectEqual(10, report.usage.output_tokens.?);
    try expectEqual(null, report.usage.cache_read_tokens);
    try expectEqual(2, fixture.effects);
    try expectEqualSlices(Point, &.{
        .load,             .user_record,     .user_event,      .request,        .assistant_record, .assistant_event,
        .intent,           .invoke,          .effect,          .result_record,  .result_event,     .intent,
        .invoke,           .result_record,   .result_event,    .request,        .assistant_record, .assistant_event,
        .intent,           .invoke,          .effect,          .result_record,  .result_event,     .request,
        .assistant_record, .assistant_event, .terminal_record, .terminal_event,
    }, fixture.trace.items);

    const followup = fixture.requests.items[1].messages;
    try expectEqual(4, followup.len);
    try expectEqual(.user, followup[0].role);
    try expectEqual(.assistant, followup[1].role);
    try expectEqualSlices(u8, replay.bytes, followup[1].blocks[0].replay.bytes);
    for (followup[2..], [_][]const u8{ "one", "two" }, [_]bool{ false, true }) |message, id, is_error| {
        try expectEqual(.tool, message.role);
        const result = message.blocks[0].tool_result;
        try expectEqualStrings(id, result.call_id);
        try expectEqual(is_error, result.is_error);
    }
    const third_result = fixture.requests.items[2].messages[5].blocks[0].tool_result;
    try expectEqualStrings("three", third_result.call_id);
    try expect(third_result.is_error);
    try expectEqual(.failure, fixture.published_results.items[2].status);
    try expectEqual(null, fixture.pending_id);
}

test "unknown tools and malformed arguments produce correlated results without an intent" {
    var fixture: Fixture = .{
        .limits = .{ .tool_argument_bytes = 24, .json_depth = 3 },
        .steps = &.{
            .{ .response = batch(&.{
                call("unknown", "disabled", "{}"),
                call("partial", "echo", "{\"x\":"),
                call("trailing", "echo", "{} {}"),
                call("array", "echo", "[]"),
                call("deep", "echo", "{\"a\":[[[0]]]}"),
                call("large", "echo", "{\"a\":\"1234567890123456789012345\"}"),
            }) },
            .{},
        },
    };
    defer fixture.deinit();

    const report = try fixture.execute();
    try fixture.expectTerminal(.completed, report);
    try expectEqual(0, fixture.invocations.items.len);
    try expect(std.mem.indexOfScalar(Point, fixture.trace.items, .intent) == null);
    try expectEqual(6, fixture.results.items.len);
    const followup = fixture.requests.items[1].messages;
    try expectEqual(8, followup.len);
    for (fixture.results.items, followup[2..], [_][]const u8{ "unknown", "partial", "trailing", "array", "deep", "large" }) |result, message, id| {
        try expectEqualStrings(id, result.call_id);
        try expectEqual(.failure, result.status);
        try expectEqual(.not_started, result.effect);
        try expectEqualStrings(id, message.blocks[0].tool_result.call_id);
        try expect(message.blocks[0].tool_result.is_error);
    }
}

test "a truncated model message does not admit even well-formed tool arguments" {
    var truncated = two_calls;
    truncated.stop = .output_limit;
    var fixture: Fixture = .{
        .steps = &.{.{
            .response = truncated,
            .deltas = &.{ .{ .text = "partial" }, .{ .tool_arguments = .{ .call_id = "one", .bytes = "{}" } } },
        }},
    };
    defer fixture.deinit();

    const report = try fixture.execute();
    try fixture.expectTerminal(.limit_reached, report);
    try expectEqual(.output_limit, report.outcome.provider_stop.?);
    try expectEqual(.max_output_tokens, report.limit.?);
    try expectEqual(0, report.tool_calls);
    try expectEqual(0, fixture.invocations.items.len);
    try expectEqual(1, fixture.messages_published.items.len);
    try expectEqualStrings("partial", fixture.delta_text.items);
    try expectEqual(4, report.usage.output_tokens.?);
}

test "a possibly sent transport failure discards partial text and invalidates aggregate usage" {
    var fixture: Fixture = .{
        .steps = &.{
            .{ .response = batch(&.{call("one", "echo", "{}")}) },
            .{ .failure = error.Disconnected, .deltas = &.{.{ .text = "partial" }} },
        },
    };
    defer fixture.deinit();

    const report = try fixture.execute();
    try fixture.expectTerminal(.provider_error, report);
    try expectEqual(2, fixture.requests.items.len);
    try expectEqual(2, fixture.messages_published.items.len);
    try expectEqual(1, fixture.effects);
    try expectEqual(null, report.usage.input_tokens);
    try expectEqual(null, report.usage.output_tokens);
    try expectEqualStrings("partial", fixture.delta_text.items);
}

test "provider refusal has a distinct terminal reason from natural stop" {
    var refused = answer;
    refused.stop = .refusal;
    var fixture: Fixture = .{ .steps = &.{.{ .response = refused }} };
    defer fixture.deinit();

    const report = try fixture.execute();
    try fixture.expectTerminal(.provider_error, report);
    try expectEqual(.refusal, report.outcome.provider_stop.?);
    try expectEqual(1, fixture.requests.items.len);
    try expectEqual(0, fixture.invocations.items.len);
}

test "a duplicate call ID or conflicting stop cannot dispatch a batch" {
    var wrong_stop = two_calls;
    wrong_stop.stop = .end_turn;
    for ([_]foo.provider.Response{
        batch(&.{ call("same", "echo", "{}"), call("same", "echo", "{}") }),
        batch(&.{call("", "echo", "{}")}),
        wrong_stop,
    }) |response| {
        var fixture: Fixture = .{ .steps = &.{.{ .response = response }} };
        defer fixture.deinit();

        try fixture.expectTerminal(.provider_error, try fixture.execute());
        try expectEqual(0, fixture.invocations.items.len);
        try expectEqual(1, fixture.messages_published.items.len);
    }
}

test "explicit resume context is borrowed history and cannot admit historical tool IDs" {
    const history: []const foo.provider.Message = &.{
        .{ .role = .assistant, .blocks = &.{call("previous", "echo", "{}")} },
        .{ .role = .tool, .blocks = &.{.{ .tool_result = .{
            .call_id = "previous",
            .content = "prior result",
            .is_error = false,
        } }} },
        scripted.prompt,
    };
    var fixture: Fixture = .{
        .messages = history,
        .steps = &.{.{ .response = batch(&.{call("previous", "echo", "{}")}) }},
    };
    defer fixture.deinit();

    try fixture.expectTerminal(.provider_error, try fixture.execute());
    try expectEqual(1, fixture.requests.items.len);
    try expectEqual(3, fixture.requests.items[0].messages.len);
    try expectEqual(1, fixture.messages_published.items.len);
    try expectEqual(0, fixture.invocations.items.len);
}

test "resume reports an unresolved intent without a request or replay" {
    var fixture: Fixture = .{ .steps = &.{}, .pending_id = "unknown-effect" };
    defer fixture.deinit();

    const report = try fixture.execute();
    try fixture.expectTerminal(.interrupted, report);
    try expect(report.outcome.uncertain_effects);
    try expectEqual(0, fixture.requests.items.len);
    try expectEqual(0, fixture.invocations.items.len);
    try expectEqual(0, fixture.messages_published.items.len);
    try expectEqualStrings("unknown-effect", fixture.pending_id.?);
}

test "preparation supplies context while pinned request settings and committed input survive" {
    const replacement: foo.provider.Message = .{ .role = .user, .blocks = &.{.{ .text = "prepared" }} };
    var fixture: Fixture = .{ .steps = &.{.{}}, .prepared = &.{replacement}, .use_store = false };
    defer fixture.deinit();

    try fixture.expectTerminal(.completed, try fixture.execute());
    const request = fixture.requests.items[0];
    try expectEqualStrings("prepared", request.messages[0].blocks[0].text);
    try expectEqualStrings("hello", fixture.messages_published.items[0].blocks[0].text);
    try expectEqualStrings(scripted.model.id, request.model.id);
    try expectEqual(fixture.limits.model_turns, request.limits.model_turns);
    try expectEqualStrings(scripted.declaration.spec.name, request.tools[0].name);
    try expectEqualSlices(u64, &.{ 1, 2 }, fixture.sequences.items);
}

test "incompatible replay in explicit or prepared context fails before provider I/O" {
    const incompatible: foo.provider.Message = .{ .role = .assistant, .blocks = &.{.{
        .replay = .{
            .family = scripted.model.family,
            .endpoint = scripted.model.endpoint,
            .model = "another-model",
            .bytes = "opaque",
        },
    }} };
    for ([_]bool{ false, true }) |prepared| {
        var fixture: Fixture = .{
            .steps = &.{},
            .messages = if (prepared) &.{scripted.prompt} else &.{ incompatible, scripted.prompt },
            .prepared = if (prepared) &.{ incompatible, scripted.prompt } else null,
        };
        defer fixture.deinit();

        const report = try fixture.execute();
        try expect(report.outcome.reason != .completed);
        try expectEqual(1, fixture.terminal_outcomes.items.len);
        try expectEqual(0, fixture.requests.items.len);
    }
}

test "the model turn and tool call limits bound new effects" {
    var request_limit: Fixture = .{
        .limits = .{ .model_turns = 1 },
        .steps = &.{.{ .response = two_calls }},
    };
    defer request_limit.deinit();
    const model_report = try request_limit.execute();
    try request_limit.expectTerminal(.limit_reached, model_report);
    try expectEqual(.model_turns, model_report.limit.?);
    try expectEqual(1, request_limit.requests.items.len);

    var call_limit: Fixture = .{
        .limits = .{ .tool_calls = 1 },
        .steps = &.{.{ .response = two_calls }},
    };
    defer call_limit.deinit();
    const tool_report = try call_limit.execute();
    try call_limit.expectTerminal(.limit_reached, tool_report);
    try expectEqual(.tool_calls, tool_report.limit.?);
    try expectEqual(0, call_limit.invocations.items.len);
}

test "the transcript budget prevents provider I/O and tool excerpts are bounded" {
    var small_transcript: Fixture = .{ .limits = .{ .transcript_bytes = 1 }, .steps = &.{} };
    defer small_transcript.deinit();
    const limited = try small_transcript.execute();
    try small_transcript.expectTerminal(.limit_reached, limited);
    try expectEqual(.transcript_bytes, limited.limit.?);
    try expectEqual(0, small_transcript.requests.items.len);

    var small_excerpt: Fixture = .{
        .limits = .{ .tool_output_bytes = 3 },
        .steps = &.{ .{ .response = batch(&.{call("one", "echo", "{}")}) }, .{} },
        .tools = &.{.{ .content = "long output" }},
    };
    defer small_excerpt.deinit();
    try small_excerpt.expectTerminal(.completed, try small_excerpt.execute());
    try expectEqualStrings("lon", small_excerpt.results.items[0].content);
    try expect(small_excerpt.results.items[0].truncated);
    try expectEqualStrings("lon", small_excerpt.requests.items[1].messages[2].blocks[0].tool_result.content);
}

test "streamed response exceeding the wire budget remains provisional" {
    var long_delta: [257]u8 = undefined;
    @memset(&long_delta, 'x');
    var fixture: Fixture = .{
        .limits = .{ .wire_message_bytes = 256 },
        .steps = &.{.{ .deltas = &.{.{ .text = &long_delta }} }},
    };
    defer fixture.deinit();

    const report = try fixture.execute();
    try fixture.expectTerminal(.limit_reached, report);
    try expectEqual(.wire_message_bytes, report.limit.?);
    try expectEqual(1, fixture.messages_published.items.len);
    try expectEqual(0, fixture.delta_text.items.len);
}

test "busy prompt rejection leaves the admitted run and terminal callback intact" {
    for ([_]Point{ .delta, .terminal_event }) |point| {
        var fixture: Fixture = .{
            .steps = &.{.{ .deltas = &.{.{ .text = "done" }} }},
            .reenter_at = point,
        };
        defer fixture.deinit();
        try fixture.expectTerminal(.completed, try fixture.execute());
        try expectEqual(error.Unavailable, fixture.busy_error.?);
        try expectEqual(1, fixture.requests.items.len);
    }
}

test "pre-cancellation, preparation, provisional output, and provider cancellation return once" {
    for ([_]?Point{ null, .prepare, .request, .delta }) |point| {
        var fixture: Fixture = .{
            .steps = &.{.{ .deltas = &.{.{ .text = "done" }} }},
            .prepared = if (point == .prepare) &.{scripted.prompt} else null,
            .cancel_at = point,
        };
        defer fixture.deinit();
        if (point == null) fixture.cancel.request();

        try fixture.expectTerminal(.cancelled, try fixture.execute());
        try expectEqual(0, fixture.invocations.items.len);
        try expect(fixture.messages_published.items.len <= 1);
        if (point == null or point == .prepare) try expectEqual(0, fixture.requests.items.len);
    }
}

test "cancellation independently wakes blocked provider, output, and tool callbacks" {
    for ([_]Point{ .request, .delta, .effect }) |point| {
        var fixture: Fixture = .{
            .steps = &.{.{
                .deltas = &.{.{ .text = "done" }},
                .response = if (point == .effect) two_calls else answer,
            }},
            .blocked_at = point,
        };
        defer fixture.deinit();
        fixture.enableWake();
        const thread = try std.Thread.spawn(.{}, Fixture.cancelWhenBlocked, .{&fixture});
        defer thread.join();

        try fixture.expectTerminal(.cancelled, try fixture.execute());
        try expect(fixture.woken.isSet());
        try expectEqual(@as(usize, if (point == .effect) 1 else 0), fixture.invocations.items.len);
    }
}

test "cancelled committed batch fills correlated results without authorizing another effect" {
    for ([_]Point{ .assistant_event, .intent, .effect, .result_event }) |point| {
        var fixture: Fixture = .{
            .steps = &.{.{ .response = two_calls }},
            .cancel_at = point,
        };
        defer fixture.deinit();

        const report = try fixture.execute();
        try fixture.expectTerminal(.cancelled, report);
        try expect(!report.outcome.uncertain_effects);
        try expectEqual(1, fixture.requests.items.len);
        try expectEqual(2, fixture.results.items.len);
        try expectEqualStrings("one", fixture.results.items[0].call_id);
        try expectEqualStrings("two", fixture.results.items[1].call_id);
        try expectEqual(.cancelled, fixture.results.items[1].status);
        try expectEqual(.not_started, fixture.results.items[1].effect);
        try expectEqual(null, fixture.pending_id);
        try expectEqual(@as(usize, if (point == .effect or point == .result_event) 1 else 0), fixture.effects);
    }
}

test "an elapsed deadline stops an accepted batch and still commits the finished outcome" {
    var fixture: Fixture = .{
        .steps = &.{.{ .response = two_calls }},
        .deadline = 50,
        .expire_at = .intent,
    };
    defer fixture.deinit();

    try fixture.expectTerminal(.interrupted, try fixture.execute());
    try expectEqual(0, fixture.invocations.items.len);
    try expectEqual(2, fixture.results.items.len);
    try expectEqual(1, fixture.journal_outcomes.items.len);
}

test "a committed uncertain result blocks a subsequent run through recovery" {
    var fixture: Fixture = .{
        .steps = &.{.{ .response = two_calls }},
        .tools = &.{.{ .status = .failure, .effect = .uncertain, .content = "possibly applied" }},
    };
    defer fixture.deinit();
    const report = try fixture.execute();

    try fixture.expectTerminal(.interrupted, report);
    try expect(report.outcome.uncertain_effects);
    try expectEqual(1, fixture.invocations.items.len);
    try expectEqual(.uncertain, fixture.results.items[0].effect);
    try expectEqual(.not_started, fixture.results.items[1].effect);
    try expectEqual(1, fixture.requests.items.len);
    try expectEqual(null, fixture.pending_id);
    try expectEqualStrings("one", fixture.uncertain_id.?);

    var resumed: Fixture = .{
        .steps = &.{},
        .uncertain_id = fixture.uncertain_id,
        .recovery = .{
            .messages = &.{},
            .last_sequence = fixture.sequence.?,
            .interrupted = false,
            .uncertain_call_ids = &.{},
        },
    };
    defer resumed.deinit();

    const recovered = try resumed.execute();
    try resumed.expectTerminal(.interrupted, recovered);
    try expect(recovered.outcome.uncertain_effects);
    try expectEqual(0, resumed.requests.items.len);
    try expectEqual(0, resumed.invocations.items.len);
}

test "a failed journal intent blocks effects and a failed result commit leaves recoverable uncertainty" {
    for ([_]Point{ .intent, .result_record }) |point| {
        var fixture: Fixture = .{
            .steps = &.{.{ .response = two_calls }},
            .fail_commit = point,
        };
        defer fixture.deinit();

        const report = try fixture.execute();
        try fixture.expectTerminal(.storage_error, report);
        try expectEqual(point == .result_record, report.outcome.uncertain_effects);
        try expectEqual(@as(usize, if (point == .result_record) 1 else 0), fixture.effects);
        try expectEqual(0, fixture.published_results.items.len);
        try expectEqual(1, fixture.requests.items.len);
        if (point == .result_record) {
            fixture.fail_commit = null;
            try expectEqual(.interrupted, (try fixture.execute()).outcome.reason);
            try expectEqual(1, fixture.requests.items.len);
            try expectEqual(1, fixture.effects);
        }
    }
}

test "a disconnected sink stops new effects and terminal delivery is attempted once" {
    var output_failure: Fixture = .{
        .steps = &.{.{ .response = two_calls }},
        .fail_event = .assistant_event,
    };
    defer output_failure.deinit();
    const report = try output_failure.execute();
    try output_failure.expectTerminal(.host_error, report);
    try expectEqual(error.Disconnected, report.output_error.?);
    try expectEqual(0, output_failure.invocations.items.len);

    var terminal_failure: Fixture = .{ .steps = &.{.{}}, .fail_event = .terminal_event };
    defer terminal_failure.deinit();
    const completed = try terminal_failure.execute();
    try expectEqual(.completed, completed.outcome.reason);
    try expectEqual(error.Disconnected, completed.output_error.?);
    try expectEqualSlices(foo.events.Outcome, &.{completed.outcome}, terminal_failure.journal_outcomes.items);
    try expectEqual(1, std.mem.countScalar(Point, terminal_failure.trace.items, .terminal_event));
}

test "cancellation observed during final assistant publication wins before terminal sealing" {
    var fixture: Fixture = .{ .steps = &.{.{}}, .cancel_at = .assistant_event };
    defer fixture.deinit();

    try fixture.expectTerminal(.cancelled, try fixture.execute());
    try expectEqual(2, fixture.messages_published.items.len);
    try expectEqual(1, fixture.requests.items.len);
}

test "a terminal commit failure is observable without a second terminal attempt" {
    var fixture: Fixture = .{ .steps = &.{.{}}, .fail_commit = .terminal_record };
    defer fixture.deinit();

    try fixture.expectTerminal(.storage_error, try fixture.execute());
    try expectEqual(0, fixture.journal_outcomes.items.len);
    try expectEqual(1, std.mem.countScalar(Point, fixture.trace.items, .terminal_record));
}

test "a mismatched registry result cannot resolve another call or continue execution" {
    var fixture: Fixture = .{
        .steps = &.{.{ .response = two_calls }},
        .tools = &.{.{ .returned_id = "two" }},
    };
    defer fixture.deinit();

    const report = try fixture.execute();
    try fixture.expectTerminal(.interrupted, report);
    try expect(report.outcome.uncertain_effects);
    try expectEqual(1, fixture.invocations.items.len);
    try expectEqual(2, fixture.results.items.len);
    try expectEqualStrings("one", fixture.results.items[0].call_id);
    try expectEqual(.uncertain, fixture.results.items[0].effect);
    try expectEqualStrings("two", fixture.results.items[1].call_id);
    try expectEqual(.not_started, fixture.results.items[1].effect);
}

fn allocationFailureRun(allocator: std.mem.Allocator) !void {
    var fixture: Fixture = .{
        .steps = &.{ .{ .response = two_calls }, .{} },
    };
    defer fixture.deinit();

    const report = try fixture.executeWith(allocator);
    try expectEqualSlices(foo.events.Outcome, &.{report.outcome}, fixture.terminal_outcomes.items);
    try expect(fixture.invocations.items.len <= 2);
    const expected = [_][]const u8{ "one", "two" };
    for (fixture.invocations.items, 0..) |id, index| {
        try expectEqualStrings(expected[index], id);
    }
    if (report.outcome.reason != .completed) return error.OutOfMemory;
}

test "allocation failures leave a single terminal result with no replay or leaks" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureRun, .{});
}
