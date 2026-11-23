const std = @import("std");
const foo = @import("foo");
const journal = @import("journal");
const fixture = @import("fixture.zig");

const Phase = enum { before_intent, after_intent, after_effect, after_result, after_finish };

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    const mode = args.next() orelse return error.MissingMode;
    const phase = std.meta.stringToEnum(Phase, args.next() orelse return error.MissingPhase) orelse
        return error.InvalidPhase;
    const path = args.next() orelse return error.MissingDirectory;
    const dir = try std.Io.Dir.cwd().openDir(init.io, path, .{ .iterate = true });
    defer dir.close(init.io);
    const cancellation: foo.io.Cancellation = .{};
    const op = fixture.operation(init.io, &cancellation);

    if (std.mem.eql(u8, mode, "hold")) {
        var store = try journal.Store.create(init.gpa, init.io, dir, fixture.identity, .{});
        defer store.deinit();
        try fixture.begin(&store, op);
        if (@backingInt(phase) >= @backingInt(Phase.after_intent)) _ = try store.commit(op, fixture.intent);
        if (@backingInt(phase) >= @backingInt(Phase.after_effect)) {
            const file = try dir.createFile(init.io, "effect", .{ .exclusive = true });
            defer file.close(init.io);
            try file.writePositionalAll(init.io, "executed once\n", 0);
            try file.sync(init.io);
        }
        if (@backingInt(phase) >= @backingInt(Phase.after_result)) _ = try store.commit(op, .{ .tool_result = fixture.result });
        if (phase == .after_finish) _ = try store.commit(op, fixture.outcome);
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
    const last: u64 = switch (phase) {
        .before_intent => 3,
        .after_intent, .after_effect => 4,
        .after_result => 5,
        .after_finish => 6,
    };
    try std.testing.expectEqual(last, result.last_sequence);
    try std.testing.expectEqual(phase != .after_finish, result.interrupted);
    if (phase == .after_intent or phase == .after_effect) {
        try std.testing.expectEqual(@as(usize, 1), result.uncertain_call_ids.len);
        try std.testing.expectEqualStrings(fixture.call.id, result.uncertain_call_ids[0]);
    } else {
        try std.testing.expectEqual(@as(usize, 0), result.uncertain_call_ids.len);
    }
    if (phase == .after_result or phase == .after_finish) {
        try std.testing.expectEqual(@as(usize, 3), result.messages.len);
        try std.testing.expectEqualStrings("marked", result.messages[2].blocks[0].tool_result.content);
    } else {
        try std.testing.expectEqual(@as(usize, 1), result.messages.len);
    }
    if (result.uncertain_call_ids.len == 0) {
        try std.testing.expectEqual(last + 1, try store.commit(op, fixture.prompt));
    }
}
