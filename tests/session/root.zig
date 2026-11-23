const std = @import("std");
const builtin = @import("builtin");
const foo = @import("foo");
const journal = @import("journal");
const fixture = @import("fixture.zig");

const testing = std.testing;
const allocator = testing.allocator;
const expect = testing.expect;
const equal = testing.expectEqual;
const strings = testing.expectEqualStrings;
const fails = testing.expectError;
const native = testing.io;
const cancellation: foo.io.Cancellation = .{};
const operation = fixture.operation(native, &cancellation);
const journal_path = "journal.jsonl";

test "memory store owns committed messages and uses no filesystem" {
    const op = fixture.operation(.failing, &cancellation);
    var store = try journal.Store.initMemory(allocator, fixture.identity, .{});
    defer store.deinit();
    const adapter = store.interface();
    var text = "caller-owned".*;
    const message: foo.provider.Message = .{ .role = .user, .blocks = &.{.{ .text = &text }} };
    try equal(@as(u64, 2), try adapter.commit_fn(adapter.context, op, .{ .message = message }));
    @memset(&text, 'x');

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const history = try adapter.load_fn(adapter.context, arena.allocator(), op);
    try equal(@as(usize, 1), history.messages.len);
    try strings("caller-owned", history.messages[0].blocks[0].text);
    try expect(history.interrupted);
}

test "result without intent closes a rejected call and another prompt can follow" {
    var store = try journal.Store.initMemory(allocator, fixture.identity, .{});
    defer store.deinit();
    try fixture.begin(&store, operation);
    const rejected: foo.tool.Result = .{
        .call_id = fixture.call.id,
        .status = .denied,
        .effect = .not_started,
        .content = "denied",
    };
    try equal(@as(u64, 4), try store.commit(operation, .{ .tool_result = rejected }));
    try equal(@as(u64, 5), try store.commit(operation, fixture.outcome));
    try equal(@as(u64, 6), try store.commit(operation, fixture.prompt));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const history = try store.load(arena.allocator(), operation);
    try equal(@as(usize, 4), history.messages.len);
    try equal(@as(usize, 0), history.uncertain_call_ids.len);
    const reply = history.messages[2];
    try equal(.tool, reply.role);
    try strings(fixture.call.id, reply.blocks[0].tool_result.call_id);
    try expect(reply.blocks[0].tool_result.is_error);
    try strings("denied", reply.blocks[0].tool_result.content);
}

test "durable uncertain result stays unresolved past a terminal record" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var store = try journal.Store.create(allocator, native, tmp.dir, fixture.identity, .{});
        defer store.deinit();
        try fixture.begin(&store, operation);
        _ = try store.commit(operation, fixture.intent);
        var result = fixture.result;
        result.effect = .uncertain;
        result.status = .failure;
        _ = try store.commit(operation, .{ .tool_result = result });
        _ = try store.commit(operation, .{ .finished = .{ .reason = .interrupted, .uncertain_effects = true } });
    }
    var reopened = try journal.Store.open(allocator, native, tmp.dir, fixture.identity, .{});
    defer reopened.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const history = try reopened.load(arena.allocator(), operation);
    try equal(@as(u64, 6), history.last_sequence);
    try equal(@as(usize, 1), history.messages.len);
    try equal(@as(usize, 1), history.uncertain_call_ids.len);
    try strings(fixture.call.id, history.uncertain_call_ids[0]);
    try expect(history.interrupted);
}

test "nested results persist with artifacts and stay out of the provider transcript" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var store = try journal.Store.create(allocator, native, tmp.dir, fixture.identity, .{});
        defer store.deinit();
        try fixture.begin(&store, operation);
        _ = try store.commit(operation, fixture.intent);
        var id = fixture.child_id.*;
        try equal(@as(u64, 5), try store.commit(operation, fixture.nestedIntent(fixture.call.id, 1, &id)));
        @memset(&id, 'x');

        var child = fixture.child_result;
        child.artifact = .{ .relative_path = "artifact-nested", .bytes = 6 };
        try fails(error.InvalidArtifact, store.commit(operation, fixture.nestedResult(fixture.call.id, 1, child)));
        child.artifact = try store.writeArtifact(operation, "artifact-nested", "output");
        try equal(@as(u64, 6), try store.commit(operation, fixture.nestedResult(fixture.call.id, 1, child)));
        var parent = fixture.result;
        parent.effect = .not_started;
        try fails(error.InvalidRecord, store.commit(operation, .{ .tool_result = parent }));

        const skipped: foo.tool.Result = .{ .call_id = "child-2", .status = .cancelled, .effect = .not_started, .content = "" };
        try equal(@as(u64, 7), try store.commit(operation, fixture.nestedIntent(fixture.call.id, 2, skipped.call_id)));
        try equal(@as(u64, 8), try store.commit(operation, fixture.nestedResult(fixture.call.id, 2, skipped)));
        _ = try store.commit(operation, .{ .tool_result = fixture.result });
        _ = try store.commit(operation, fixture.outcome);
    }
    {
        var store = try journal.Store.open(allocator, native, tmp.dir, fixture.identity, .{});
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const history = try store.load(arena.allocator(), operation);
        try equal(@as(u64, 10), history.last_sequence);
        try equal(@as(usize, 3), history.messages.len);
        try equal(@as(usize, 0), history.uncertain_call_ids.len);
        try strings(fixture.call.id, history.messages[2].blocks[0].tool_result.call_id);
        try strings(fixture.result.content, history.messages[2].blocks[0].tool_result.content);
        try expect(!history.interrupted);
    }
    try tmp.dir.deleteFile(native, "artifact-nested");
    try fails(error.CorruptHistory, journal.Store.open(allocator, native, tmp.dir, fixture.identity, .{}));
}

test "nested uncertainty survives reopen before and after terminal records" {
    const End = enum { pending, child_uncertain, parent_uncertain_pending, parent_uncertain, finished_pending, finished_uncertain };
    for (std.enums.values(End)) |end| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var last: u64 = 5;
        {
            var store = try journal.Store.create(allocator, native, tmp.dir, fixture.identity, .{});
            defer store.deinit();
            try fixture.begin(&store, operation);
            _ = try store.commit(operation, fixture.intent);
            _ = try store.commit(operation, fixture.nestedIntent(fixture.call.id, 1, fixture.child_id));
            if (end == .child_uncertain or end == .parent_uncertain or end == .finished_uncertain) {
                var child = fixture.child_result;
                child.effect = .uncertain;
                child.status = .failure;
                last = try store.commit(operation, fixture.nestedResult(fixture.call.id, 1, child));
            }
            var parent = fixture.result;
            try fails(error.InvalidRecord, store.commit(operation, .{ .tool_result = parent }));
            parent.effect = .not_started;
            try fails(error.InvalidRecord, store.commit(operation, .{ .tool_result = parent }));
            if (end == .parent_uncertain or end == .parent_uncertain_pending) {
                parent.effect = .uncertain;
                parent.status = .failure;
                last = try store.commit(operation, .{ .tool_result = parent });
            }
            if (end == .parent_uncertain or end == .parent_uncertain_pending or end == .finished_pending or end == .finished_uncertain) {
                last = try store.commit(operation, .{ .finished = .{ .reason = .interrupted, .uncertain_effects = true } });
            }
        }
        var store = try journal.Store.open(allocator, native, tmp.dir, fixture.identity, .{});
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const history = try store.load(arena.allocator(), operation);
        try equal(last, history.last_sequence);
        try equal(@as(usize, 1), history.messages.len);
        try strings("hello", history.messages[0].blocks[0].text);
        try equal(@as(usize, 2), history.uncertain_call_ids.len);
        try strings(fixture.call.id, history.uncertain_call_ids[0]);
        try strings(fixture.child_id, history.uncertain_call_ids[1]);
        try expect(history.interrupted);
        try fails(error.InvalidRecord, store.commit(operation, fixture.prompt));
    }
}

test "nested records require a dispatched parent and matched child at the next ordinal" {
    var store = try journal.Store.initMemory(allocator, fixture.identity, .{});
    defer store.deinit();
    try fixture.begin(&store, operation);
    const child_intent = fixture.nestedIntent(fixture.call.id, 1, fixture.child_id);
    const child_result = fixture.nestedResult(fixture.call.id, 1, fixture.child_result);
    try fails(error.InvalidRecord, store.commit(operation, child_intent));
    _ = try store.commit(operation, fixture.intent);
    try fails(error.InvalidRecord, store.commit(operation, child_result));
    try fails(error.InvalidRecord, store.commit(operation, fixture.nestedIntent("another-parent", 1, fixture.child_id)));
    try fails(error.InvalidRecord, store.commit(operation, fixture.nestedIntent(fixture.call.id, 0, fixture.child_id)));
    try fails(error.InvalidRecord, store.commit(operation, fixture.nestedIntent(fixture.call.id, 2, fixture.child_id)));
    try fails(error.InvalidRecord, store.commit(operation, fixture.nestedIntent(fixture.call.id, 1, fixture.call.id)));
    try equal(@as(u64, 5), try store.commit(operation, child_intent));
    try fails(error.InvalidRecord, store.commit(operation, child_intent));
    try fails(error.InvalidRecord, store.commit(operation, fixture.nestedResult(fixture.call.id, 2, fixture.child_result)));
    var wrong_child = fixture.child_result;
    wrong_child.call_id = "wrong-child";
    try fails(error.InvalidRecord, store.commit(operation, fixture.nestedResult(fixture.call.id, 1, wrong_child)));
    var skipped = fixture.child_result;
    skipped.effect = .not_started;
    skipped.status = .denied;
    try equal(@as(u64, 6), try store.commit(operation, fixture.nestedResult(fixture.call.id, 1, skipped)));
    try fails(error.InvalidRecord, store.commit(operation, child_result));
    var parent = fixture.result;
    parent.effect = .not_started;
    parent.status = .denied;
    try equal(@as(u64, 7), try store.commit(operation, .{ .tool_result = parent }));
}

test "nested intent reserves bounded space for parent and child recovery IDs" {
    var store = try journal.Store.initMemory(allocator, fixture.identity, .{
        .max_record_bytes = 4096,
        .max_context_bytes = 1024,
    });
    defer store.deinit();
    try fixture.begin(&store, operation);
    _ = try store.commit(operation, fixture.intent);
    const too_large: [2048]u8 = @splat('x');
    try fails(error.LimitExceeded, store.commit(operation, fixture.nestedIntent(fixture.call.id, 1, &too_large)));
    try equal(@as(u64, 5), try store.commit(operation, fixture.nestedIntent(fixture.call.id, 1, fixture.child_id)));
    try equal(@as(u64, 6), try store.commit(operation, .{ .finished = .{ .reason = .interrupted, .uncertain_effects = true } }));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const history = try store.load(arena.allocator(), operation);
    try equal(@as(usize, 2), history.uncertain_call_ids.len);
    try strings(fixture.child_id, history.uncertain_call_ids[1]);
}

test "nested ordinals restart at the next dispatched parent in the batch" {
    var store = try journal.Store.initMemory(allocator, fixture.identity, .{});
    defer store.deinit();
    var second_intent = fixture.intent.dispatch_intent;
    second_intent.call.id = "call-2";
    _ = try store.commit(operation, fixture.prompt);
    _ = try store.commit(operation, .{ .message = .{ .role = .assistant, .blocks = &.{
        .{ .tool_call = fixture.call },
        .{ .tool_call = second_intent.call },
    } } });
    _ = try store.commit(operation, fixture.intent);
    _ = try store.commit(operation, fixture.nestedIntent(fixture.call.id, 1, fixture.child_id));
    _ = try store.commit(operation, fixture.nestedResult(fixture.call.id, 1, fixture.child_result));
    _ = try store.commit(operation, .{ .tool_result = fixture.result });
    _ = try store.commit(operation, .{ .dispatch_intent = second_intent });
    try fails(error.InvalidRecord, store.commit(operation, fixture.nestedIntent(fixture.call.id, 2, "call-2:child-1")));
    try equal(@as(u64, 9), try store.commit(operation, fixture.nestedIntent(second_intent.call.id, 1, "call-2:child-1")));
}

test "local writer repairs a torn tail, preserves replay bytes, and stays appendable" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const replay = "opaque\x00\xff\x80";
    {
        var store = try journal.Store.create(allocator, native, tmp.dir, fixture.identity, .{});
        defer store.deinit();
        _ = try store.commit(operation, fixture.prompt);
        _ = try store.commit(operation, .{ .message = .{ .role = .assistant, .blocks = &.{
            .{ .reasoning = .{ .text = "思考", .signature = "signature" } },
            .{ .replay = .{ .family = .anthropic_messages, .endpoint = "example", .model = "model", .bytes = replay } },
        } } });
        try fails(error.WriterBusy, journal.Store.open(allocator, native, tmp.dir, fixture.identity, .{}));
    }
    {
        const file = try tmp.dir.openFile(native, journal_path, .{ .mode = .read_write });
        defer file.close(native);
        const end = try file.length(native);
        try file.writePositionalAll(native, "{\"crc32\": 12", end);
        try file.sync(native);
    }
    try fails(error.IdentityMismatch, journal.Store.open(allocator, native, tmp.dir, "other-model", .{}));
    {
        var store = try journal.Store.open(allocator, native, tmp.dir, fixture.identity, .{});
        defer store.deinit();
        try equal(@as(u64, 4), try store.commit(operation, fixture.outcome));
    }
    var store = try journal.Store.open(allocator, native, tmp.dir, fixture.identity, .{});
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const history = try store.load(arena.allocator(), operation);
    try expect(!history.interrupted);
    try equal(@as(u64, 4), history.last_sequence);
    try equal(@as(usize, 2), history.messages.len);
    try strings("思考", history.messages[1].blocks[0].reasoning.text);
    try strings("signature", history.messages[1].blocks[0].reasoning.signature.?);
    try strings(replay, history.messages[1].blocks[1].replay.bytes);
}

test "modified complete middle record is corruption and leaves the file untouched" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var store = try journal.Store.create(allocator, native, tmp.dir, fixture.identity, .{});
        defer store.deinit();
        _ = try store.commit(operation, fixture.prompt);
        _ = try store.commit(operation, fixture.outcome);
    }
    const bytes = try tmp.dir.readFileAlloc(native, journal_path, allocator, .limited(8192));
    defer allocator.free(bytes);
    const start = std.mem.find(u8, bytes, "hello") orelse return error.MissingPrompt;
    bytes[start] = 'j';
    try tmp.dir.writeFile(native, .{ .sub_path = journal_path, .data = bytes });
    try fails(error.CorruptHistory, journal.Store.open(allocator, native, tmp.dir, fixture.identity, .{}));
    const remaining = try tmp.dir.readFileAlloc(native, journal_path, allocator, .limited(8192));
    defer allocator.free(remaining);
    try strings(bytes, remaining);
}

test "complete malformed final record is corruption" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var store = try journal.Store.create(allocator, native, tmp.dir, fixture.identity, .{});
        defer store.deinit();
        _ = try store.commit(operation, fixture.prompt);
    }
    {
        const file = try tmp.dir.openFile(native, journal_path, .{ .mode = .read_write });
        defer file.close(native);
        try file.writePositionalAll(native, "{not-json}\n", try file.length(native));
    }
    try fails(error.CorruptHistory, journal.Store.open(allocator, native, tmp.dir, fixture.identity, .{}));
}

test "record and retained context limits leave the committed prefix intact" {
    var store = try journal.Store.initMemory(allocator, fixture.identity, .{
        .max_record_bytes = 512,
        .max_context_bytes = 256,
    });
    defer store.deinit();
    const huge: [1024]u8 = @splat('x');
    const oversized: foo.session.Record = .{ .message = .{ .role = .user, .blocks = &.{.{ .text = &huge }} } };
    try fails(error.LimitExceeded, store.commit(operation, oversized));
    _ = try store.commit(operation, fixture.prompt);
    const medium: [260]u8 = @splat('y');
    const over_context: foo.session.Record = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = &medium }} } };
    try fails(error.LimitExceeded, store.commit(operation, over_context));
    try equal(@as(u64, 3), try store.commit(operation, fixture.outcome));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const history = try store.load(arena.allocator(), operation);
    try equal(@as(usize, 1), history.messages.len);
    try strings("hello", history.messages[0].blocks[0].text);
}

const Fault = enum { none, short, partial, full, zero, sync };
threadlocal var fault: Fault = .none;

fn faultWrite(
    userdata: ?*anyopaque,
    file: std.Io.File,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    offset: u64,
) std.Io.File.WritePositionalError!usize {
    const native_write = native.vtable.fileWritePositional;
    switch (fault) {
        .none => return native_write(userdata, file, header, data, splat, offset),
        .short, .partial => {
            const first = if (header.len != 0) header else data[0];
            fault = if (fault == .partial) .full else .none;
            return native_write(userdata, file, &.{}, &.{first[0..@min(7, first.len)]}, 1, offset);
        },
        .full => return error.NoSpaceLeft,
        .zero => return 0,
        .sync => return native_write(userdata, file, header, data, splat, offset),
    }
}

fn faultSync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
    if (fault == .sync) {
        fault = .none;
        return error.InputOutput;
    }
    return native.vtable.fileSync(userdata, file);
}

test "positive short writes are retried through sync and survive reopen" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var vtable = native.vtable.*;
    vtable.fileWritePositional = faultWrite;
    const system: std.Io = .{ .vtable = &vtable, .userdata = native.userdata };
    {
        var store = try journal.Store.create(allocator, system, tmp.dir, fixture.identity, .{});
        defer store.deinit();
        fault = .short;
        defer fault = .none;
        try equal(@as(u64, 2), try store.commit(fixture.operation(system, &cancellation), fixture.prompt));
    }
    var reopened = try journal.Store.open(allocator, native, tmp.dir, fixture.identity, .{});
    defer reopened.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const history = try reopened.load(arena.allocator(), operation);
    try equal(@as(u64, 2), history.last_sequence);
    try strings("hello", history.messages[0].blocks[0].text);
}

test "disk full, zero progress, and sync failure stop commit acknowledgment" {
    var vtable = native.vtable.*;
    vtable.fileWritePositional = faultWrite;
    vtable.fileSync = faultSync;
    const system: std.Io = .{ .vtable = &vtable, .userdata = native.userdata };
    const op = fixture.operation(system, &cancellation);

    for ([_]Fault{ .full, .partial, .zero, .sync }) |failure| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        {
            var store = try journal.Store.create(allocator, system, tmp.dir, fixture.identity, .{});
            defer store.deinit();
            try fixture.begin(&store, op);
            _ = try store.commit(op, fixture.intent);
            const adapter = store.interface();
            fault = failure;
            defer fault = .none;
            try fails(error.CommitFailed, adapter.commit_fn(adapter.context, op, .{ .tool_result = fixture.result }));
            fault = .none;
            try fails(error.CommitFailed, adapter.commit_fn(adapter.context, op, fixture.outcome));
        }

        var reopened = try journal.Store.open(allocator, native, tmp.dir, fixture.identity, .{});
        defer reopened.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const history = try reopened.load(arena.allocator(), operation);
        try equal(@as(u64, 4), history.last_sequence);
        try equal(@as(usize, 1), history.uncertain_call_ids.len);
        try strings(fixture.call.id, history.uncertain_call_ids[0]);
    }
}

test "artifact reference stays session relative and must match stored bytes" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const limits: journal.Limits = .{ .max_artifact_bytes = 8, .max_artifacts = 2 };
    {
        var store = try journal.Store.create(allocator, native, tmp.dir, fixture.identity, limits);
        defer store.deinit();
        try fixture.begin(&store, operation);
        _ = try store.commit(operation, fixture.intent);
        try fails(error.InvalidArtifact, store.writeArtifact(operation, "../artifact-escape", "no"));
        try fails(error.InvalidArtifact, store.writeArtifact(operation, "artifact-../../escape", "no"));
        const artifact = try store.writeArtifact(operation, "artifact-output", "stdout");
        try equal(@as(u64, 6), artifact.bytes);
        const output = try store.readArtifact(allocator, operation, artifact);
        defer allocator.free(output);
        try strings("stdout", output);
        var result = fixture.result;
        result.artifact = .{ .relative_path = artifact.relative_path, .bytes = 3 };
        try fails(error.InvalidArtifact, store.commit(operation, .{ .tool_result = result }));
        result.artifact = artifact;
        _ = try store.commit(operation, .{ .tool_result = result });
        try fails(error.LimitExceeded, store.writeArtifact(operation, "artifact-extra", "too much"));
    }
    {
        var store = try journal.Store.open(allocator, native, tmp.dir, fixture.identity, limits);
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const history = try store.load(arena.allocator(), operation);
        try equal(@as(u64, 5), history.last_sequence);
        try equal(@as(usize, 0), history.uncertain_call_ids.len);
        const output = try store.readArtifact(allocator, operation, .{ .relative_path = "artifact-output", .bytes = 6 });
        defer allocator.free(output);
        try strings("stdout", output);
    }
    try tmp.dir.deleteFile(native, "artifact-output");
    try fails(error.CorruptHistory, journal.Store.open(allocator, native, tmp.dir, fixture.identity, limits));
}

test "artifact reference cannot follow a symlink outside the session" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(native, .{ .sub_path = "outside", .data = "x" });
    try tmp.dir.createDir(native, "session", .default_dir);
    const dir = try tmp.dir.openDir(native, "session", .{ .iterate = true });
    defer dir.close(native);
    var store = try journal.Store.create(allocator, native, dir, fixture.identity, .{});
    defer store.deinit();
    try fixture.begin(&store, operation);
    _ = try store.commit(operation, fixture.intent);

    try dir.symLink(native, "../outside", "artifact-alias", .{});
    var result = fixture.result;
    result.artifact = .{ .relative_path = "artifact-alias", .bytes = 1 };
    try fails(error.InvalidArtifact, store.commit(operation, .{ .tool_result = result }));
}

test "core exposes a provisional delta and never repeats an effect after failed result sync" {
    const core = @import("core");
    const Run = struct {
        requests: usize = 0,
        effects: usize = 0,
        deltas: usize = 0,
        sequences: [2]u64 = undefined,
        messages: usize = 0,
        results: usize = 0,

        fn stream(
            context: *anyopaque,
            _: std.mem.Allocator,
            op: foo.io.Context,
            _: foo.provider.Request,
            sink: foo.provider.Sink,
            delivery: *foo.io.Delivery,
        ) foo.provider.Error!foo.provider.Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.requests += 1;
            delivery.* = .possibly_sent;
            try sink.emit(op, .{ .text = "provisional" });
            return .{ .message = fixture.request.message, .stop = .tool_use };
        }

        fn invoke(
            context: *anyopaque,
            _: std.mem.Allocator,
            _: foo.io.Context,
            _: foo.tool.Invocation,
        ) foo.io.Error!foo.tool.Result {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.effects += 1;
            fault = .sync;
            return fixture.result;
        }

        fn emit(context: *anyopaque, _: foo.io.Context, event: foo.events.Event) foo.io.Error!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            switch (event.data) {
                .delta => self.deltas += 1,
                .message_committed => |committed| {
                    self.sequences[self.messages] = committed.sequence;
                    self.messages += 1;
                },
                .tool_committed => self.results += 1,
                .finished => {},
            }
        }

        fn input(self: *@This(), store: *journal.Store) foo.host.RunInput {
            return .{
                .session = @fromBackingInt(@intCast(1)),
                .run = @fromBackingInt(@intCast(1)),
                .settings = .{
                    .model = .{ .family = .openai_responses, .endpoint = "example", .id = fixture.identity },
                    .cwd = ".",
                },
                .messages = &.{fixture.prompt.message},
                .tools = .{
                    .context = self,
                    .declarations = &.{fixture.intent.dispatch_intent.declaration},
                    .invoke_fn = invoke,
                },
                .services = .{ .provider = .{ .context = self, .stream_fn = stream }, .store = store.interface() },
            };
        }
    };
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var vtable = native.vtable.*;
    vtable.fileSync = faultSync;
    const system: std.Io = .{ .vtable = &vtable, .userdata = native.userdata };
    var run: Run = .{};
    var engine: core.Engine = .{};
    const sink: foo.events.Sink = .{ .context = &run, .emit_fn = Run.emit };
    {
        var store = try journal.Store.create(allocator, system, tmp.dir, fixture.identity, .{});
        defer store.deinit();
        const report = try engine.run(allocator, fixture.operation(system, &cancellation), run.input(&store), sink);
        try equal(.storage_error, report.outcome.reason);
        try expect(report.outcome.uncertain_effects);
        try equal(@as(usize, 1), run.effects);
        try equal(@as(usize, 1), run.deltas);
        try equal(@as(usize, 0), run.results);
        try equal(@as(usize, 2), run.messages);
        try equal([2]u64{ 2, 3 }, run.sequences);
    }
    var store = try journal.Store.open(allocator, native, tmp.dir, fixture.identity, .{});
    defer store.deinit();
    const resumed = try engine.run(allocator, operation, run.input(&store), sink);
    try equal(.interrupted, resumed.outcome.reason);
    try expect(resumed.outcome.uncertain_effects);
    try equal(@as(usize, 1), run.requests);
    try equal(@as(usize, 1), run.effects);
}

fn updateChecksum(line: []u8) !void {
    const checksum_prefix = "{\"crc32\":\"";
    const payload_marker = "\"payload\":";
    const payload = (std.mem.find(u8, line, payload_marker) orelse return error.MissingPayload) + payload_marker.len;
    const checksum = std.hash.Crc32.hash(line[payload .. line.len - 1]);
    _ = try std.fmt.bufPrint(line[checksum_prefix.len .. checksum_prefix.len + 8], "{x:0>8}", .{checksum});
}

test "replay rejects a nested ordinal gap even with a valid checksum" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var store = try journal.Store.create(allocator, native, tmp.dir, fixture.identity, .{});
        defer store.deinit();
        try fixture.begin(&store, operation);
        _ = try store.commit(operation, fixture.intent);
        _ = try store.commit(operation, fixture.nestedIntent(fixture.call.id, 1, fixture.child_id));
    }
    const bytes = try tmp.dir.readFileAlloc(native, journal_path, allocator, .limited(8192));
    defer allocator.free(bytes);
    const start = (std.mem.lastIndexOfScalar(u8, bytes[0 .. bytes.len - 1], '\n') orelse return error.MissingFrame) + 1;
    const frame = bytes[start .. bytes.len - 1];
    const field = "\"ordinal\":";
    const ordinal = (std.mem.find(u8, frame, field) orelse return error.MissingOrdinal) + field.len;
    frame[ordinal] = '2';
    try updateChecksum(frame);
    try tmp.dir.writeFile(native, .{ .sub_path = journal_path, .data = bytes });
    try fails(error.CorruptHistory, journal.Store.open(allocator, native, tmp.dir, fixture.identity, .{}));
    const remaining = try tmp.dir.readFileAlloc(native, journal_path, allocator, .limited(8192));
    defer allocator.free(remaining);
    try strings(bytes, remaining);
}

test "unsupported version and duplicate sequence fail even with valid checksums" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        var store = try journal.Store.create(allocator, native, tmp.dir, fixture.identity, .{});
        defer store.deinit();
        _ = try store.commit(operation, fixture.prompt);
    }
    const bytes = try tmp.dir.readFileAlloc(native, journal_path, allocator, .limited(8192));
    defer allocator.free(bytes);
    const end = std.mem.findScalar(u8, bytes, '\n') orelse return error.MissingHeader;
    const header = bytes[0..end];
    const version_field = "\"version\":";
    const version = (std.mem.find(u8, header, version_field) orelse return error.MissingVersion) + version_field.len;
    header[version] = '9';
    try updateChecksum(header);
    try tmp.dir.writeFile(native, .{ .sub_path = journal_path, .data = bytes });
    try fails(error.UnsupportedVersion, journal.Store.open(allocator, native, tmp.dir, fixture.identity, .{}));

    header[version] = '1';
    try updateChecksum(header);
    const record = bytes[end + 1 .. bytes.len - 1];
    const sequence_field = "\"sequence\":";
    const sequence = (std.mem.find(u8, record, sequence_field) orelse return error.MissingSequence) + sequence_field.len;
    record[sequence] = '1';
    try updateChecksum(record);
    try tmp.dir.writeFile(native, .{ .sub_path = journal_path, .data = bytes });
    try fails(error.CorruptHistory, journal.Store.open(allocator, native, tmp.dir, fixture.identity, .{}));
}

test "bounded scanner reads a frame across chunks and the total journal limit preserves it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const limits: journal.Limits = .{ .max_journal_bytes = 18_000, .max_record_bytes = 12_000 };
    const text: [10_000]u8 = @splat('z');
    {
        var store = try journal.Store.create(allocator, native, tmp.dir, fixture.identity, limits);
        defer store.deinit();
        _ = try store.commit(operation, fixture.prompt);
        const reply: foo.session.Record = .{ .message = .{ .role = .assistant, .blocks = &.{.{ .text = &text }} } };
        _ = try store.commit(operation, reply);
        try fails(error.LimitExceeded, store.commit(operation, reply));
        try equal(@as(u64, 4), try store.commit(operation, fixture.outcome));
    }
    var store = try journal.Store.open(allocator, native, tmp.dir, fixture.identity, limits);
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const history = try store.load(arena.allocator(), operation);
    try equal(@as(u64, 4), history.last_sequence);
    try equal(@as(usize, 2), history.messages.len);
    try strings(&text, history.messages[1].blocks[0].text);
}

test "unreferenced local artifact counts against quota after reopening" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const limits: journal.Limits = .{ .max_artifact_bytes = 10, .max_artifacts = 2 };
    {
        var store = try journal.Store.create(allocator, native, tmp.dir, fixture.identity, limits);
        defer store.deinit();
        _ = try store.writeArtifact(operation, "artifact-orphan", "123456");
        try fails(error.AlreadyExists, store.writeArtifact(operation, "artifact-orphan", "0000"));
    }
    var store = try journal.Store.open(allocator, native, tmp.dir, fixture.identity, limits);
    defer store.deinit();
    try fails(error.LimitExceeded, store.writeArtifact(operation, "artifact-large", "12345"));
    _ = try store.writeArtifact(operation, "artifact-small", "1234");
    try fails(error.LimitExceeded, store.writeArtifact(operation, "artifact-empty", ""));
    const output = try store.readArtifact(allocator, operation, .{ .relative_path = "artifact-orphan", .bytes = 6 });
    defer allocator.free(output);
    try strings("123456", output);
}
