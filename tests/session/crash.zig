const std = @import("std");
const foo = @import("foo");
const journal = @import("journal");
const fixture = @import("fixture.zig");

const Phase = enum { before_intent, after_intent, after_effect, after_result, after_finish };
const Scope = enum { top, nested };

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    const mode = args.next() orelse return error.MissingMode;
    const phase = std.meta.stringToEnum(Phase, args.next() orelse return error.MissingPhase) orelse
        return error.InvalidPhase;
    const path = args.next() orelse return error.MissingDirectory;
    const scope = std.meta.stringToEnum(Scope, args.next() orelse return error.MissingScope) orelse
        return error.InvalidScope;
    const dir = try std.Io.Dir.cwd().openDir(init.io, path, .{ .iterate = true });
    defer dir.close(init.io);
    const cancellation: foo.io.Cancellation = .{};
    const op = fixture.operation(init.io, &cancellation);

    if (std.mem.eql(u8, mode, "hold")) {
        var store = try journal.Store.create(init.gpa, init.io, dir, fixture.identity, .{});
        defer store.deinit();
        try fixture.begin(&store, op);
        const dispatch = phase != .before_intent;
        if (scope == .nested or dispatch) _ = try store.commit(op, fixture.intent);
        if (scope == .nested and dispatch)
            _ = try store.commit(op, fixture.nestedIntent(fixture.call.id, 1, fixture.child_id));
        if (@backingInt(phase) >= @backingInt(Phase.after_effect)) {
            const file = try dir.createFile(init.io, "effect", .{ .exclusive = true });
            defer file.close(init.io);
            try file.writePositionalAll(init.io, "executed once\n", 0);
            try file.sync(init.io);
        }
        if (phase == .after_result or phase == .after_finish) {
            const result = if (scope == .nested)
                fixture.nestedResult(fixture.call.id, 1, fixture.child_result)
            else
                foo.session.Record{ .tool_result = fixture.result };
            _ = try store.commit(op, result);
        }
        if (phase == .after_finish) {
            if (scope == .nested) _ = try store.commit(op, .{ .tool_result = fixture.result });
            _ = try store.commit(op, fixture.outcome);
        }
        const ready = try dir.createFile(init.io, "ready", .{ .exclusive = true });
        ready.close(init.io);
        var buffer: [16]u8 = undefined;
        var stdin = std.Io.File.stdin().readerStreaming(init.io, &buffer);
        _ = try stdin.interface.discardRemaining();
        return;
    }

    if (std.mem.eql(u8, mode, "busy")) {
        if (journal.Store.open(init.gpa, init.io, dir, fixture.identity, .{})) |opened| {
            var store = opened;
            store.deinit();
            return error.SecondWriterOpened;
        } else |err| {
            if (err != error.WriterBusy) return err;
            return;
        }
    }

    if (!std.mem.eql(u8, mode, "recover")) return error.InvalidMode;
    var store = try journal.Store.open(init.gpa, init.io, dir, fixture.identity, .{});
    defer store.deinit();
    const result = try store.load(init.arena.allocator(), op);
    const start: u64 = if (scope == .nested) 4 else 3;
    const last: u64 = switch (phase) {
        .before_intent => start,
        .after_intent, .after_effect => start + 1,
        .after_result => start + 2,
        .after_finish => start + if (scope == .nested) @as(u64, 4) else 3,
    };
    try std.testing.expectEqual(last, result.last_sequence);
    try std.testing.expectEqual(phase != .after_finish, result.interrupted);
    const pending = phase == .after_intent or phase == .after_effect;
    const uncertain = if (scope == .nested) switch (phase) {
        .before_intent, .after_result => @as(usize, 1),
        .after_intent, .after_effect => 2,
        .after_finish => 0,
    } else @intFromBool(pending);
    try std.testing.expectEqual(uncertain, result.uncertain_call_ids.len);
    if (uncertain >= 1) try std.testing.expectEqualStrings(fixture.call.id, result.uncertain_call_ids[0]);
    if (uncertain == 2) try std.testing.expectEqualStrings(fixture.child_id, result.uncertain_call_ids[1]);
    if ((phase == .after_result and scope == .top) or phase == .after_finish) {
        try std.testing.expectEqual(@as(usize, 3), result.messages.len);
        try std.testing.expectEqualStrings("marked", result.messages[2].blocks[0].tool_result.content);
    } else {
        try std.testing.expectEqual(@as(usize, 1), result.messages.len);
    }
    if (result.uncertain_call_ids.len == 0) {
        try std.testing.expectEqual(last + 1, try store.commit(op, fixture.prompt));
    }
}
