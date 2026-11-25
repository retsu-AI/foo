const std = @import("std");
const builtin = @import("builtin");
const foo = @import("foo");
const auth = @import("auth");
const support = @import("support");
const testing = std.testing;
const io = testing.io;
const allocator = testing.allocator;
const expect = testing.expect;
const equal = testing.expectEqual;
const same = testing.expectEqualStrings;

const oauth: auth.OAuth = .{ .access = "old-access", .refresh = "old-refresh", .expires_ms = 1, .account = "fixture-account" };
const updated: auth.OAuth = .{ .access = "new-access", .refresh = "new-refresh", .expires_ms = 2, .account = "fixture-account" };

fn operation() foo.io.Context {
    const State = struct {
        var clock: support.Clock = .{};
        const cancellation: foo.io.Cancellation = .{};
    };
    return .{ .io = io, .clock = State.clock.interface(), .cancellation = &State.cancellation };
}

fn in(dir: std.Io.Dir) !auth.Store {
    const path = try dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    return .{ .directory = try allocator.dupe(u8, path) };
}

test "new store is private and each write replaces the previous file atomically" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const store = try in(tmp.dir);
    defer allocator.free(store.directory);

    try store.put(allocator, operation(), "gateway", .{ .api_key = "first-key" });
    const original = try tmp.dir.openFile(io, "auth.json", .{});
    defer original.close(io);
    const before = try original.stat(io);
    if (builtin.os.tag != .windows) try equal(0o600, before.permissions.toMode() & 0o777);
    try store.put(allocator, operation(), "service", .{ .oauth = oauth });
    const after = try tmp.dir.statFile(io, "auth.json", .{});
    try expect(before.inode != after.inode);
    if (builtin.os.tag != .windows) try equal(0o600, after.permissions.toMode() & 0o777);

    var text: [1024]u8 = undefined;
    const count = try original.readPositionalAll(io, &text, 0);
    try expect(std.mem.indexOf(u8, text[0..count], "first-key") != null);
    try expect(std.mem.indexOf(u8, text[0..count], "old-access") == null);

    var snapshot = try store.read(allocator, operation());
    defer snapshot.deinit();
    try equal(2, snapshot.entries.count());
    try same("first-key", snapshot.entries.get("gateway").?.api_key);
    try same("old-access", snapshot.entries.get("service").?.oauth.access);
    try same("old-refresh", snapshot.entries.get("service").?.oauth.refresh.?);
    try same("fixture-account", snapshot.entries.get("service").?.oauth.account.?);
    try equal(1, snapshot.entries.get("service").?.oauth.expires_ms);

    try store.remove(allocator, operation(), "gateway");
    var latest = try store.read(allocator, operation());
    defer latest.deinit();
    try equal(1, latest.entries.count());
    try expect(latest.entries.get("gateway") == null);
}

test "store rejects exposed permissions, links, malformed input and oversized files" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const store = try in(tmp.dir);
    defer allocator.free(store.directory);

    try store.put(allocator, operation(), "gateway", .{ .api_key = "secret" });
    const file = try tmp.dir.openFile(io, "auth.json", .{ .mode = .read_write });
    defer file.close(io);
    try file.setPermissions(io, .fromMode(0o644));
    try testing.expectError(error.InsecurePermissions, store.read(allocator, operation()));
    try testing.expectError(error.InsecurePermissions, store.put(allocator, operation(), "other", .{ .api_key = "key" }));
    try file.setPermissions(io, .fromMode(0o600));
    try tmp.dir.hardLink("auth.json", tmp.dir, "hard-link", io, .{});
    try testing.expectError(error.UnsafeStore, store.read(allocator, operation()));
    try tmp.dir.deleteFile(io, "hard-link");

    try file.setLength(io, 0);
    try file.writePositionalAll(io, "{\"gateway\":{\"type\":\"api_key\",\"key\":\"one\"},\"gateway\":{\"type\":\"api_key\",\"key\":\"two\"}}", 0);
    try testing.expectError(error.InvalidStore, store.read(allocator, operation()));
    try file.setLength(io, 1_048_577);
    try testing.expectError(error.LimitExceeded, store.read(allocator, operation()));

    try tmp.dir.rename("auth.json", tmp.dir, "target", io);
    try tmp.dir.symLink(io, "target", "auth.json", .{});
    try testing.expectError(error.UnsafeStore, store.read(allocator, operation()));
}

test "Windows rejects a store file with inherited permissions" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const store = try in(tmp.dir);
    defer allocator.free(store.directory);
    try tmp.dir.writeFile(io, .{ .sub_path = "auth.json", .data = "{\"gateway\":{\"type\":\"api_key\",\"key\":\"fixture\"}}" });
    try testing.expectError(error.InsecurePermissions, store.read(allocator, operation()));
}

test "environment and store resolve only the requested credentials" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const store = try in(tmp.dir);
    defer allocator.free(store.directory);
    var variables = std.process.Environ.Map.init(allocator);
    defer variables.deinit();
    try variables.put("FOO_KEY", "environment-key");
    try variables.put("EMPTY", "");
    const resolver = auth.Resolver{ .environment = &variables, .store = store };
    const source = resolver.interface();
    try same("environment-key", (try source.resolve(allocator, operation(), .{ .environment = "FOO_KEY" })).api_key);
    try same("literal-key", (try source.resolve(allocator, operation(), .{ .literal = "literal-key" })).api_key);
    try testing.expectError(error.Authentication, source.resolve(allocator, operation(), .{ .environment = "EMPTY" }));
    try testing.expectError(error.Authentication, source.resolve(allocator, operation(), .{ .auth = "missing" }));
    try testing.expectError(error.Unavailable, auth.resolveValue(&variables, .{ .environment = "MISSING" }));
    try same("", try auth.resolveValue(&variables, .{ .environment = "EMPTY" }));

    try store.put(allocator, operation(), "gateway", .{ .api_key = "stored-key" });
    try store.put(allocator, operation(), "service", .{ .oauth = oauth });
    const stored = try source.resolve(allocator, operation(), .{ .auth = "gateway" });
    defer allocator.free(stored.api_key);
    try same("stored-key", stored.api_key);
    const bearer = (try source.resolve(allocator, operation(), .{ .auth = "service" })).bearer;
    defer allocator.free(bearer.token);
    defer allocator.free(bearer.account.?);
    try same("old-access", bearer.token);
    try same("fixture-account", bearer.account.?);
}

test "a refresh cannot overwrite a newer entry or reinstate a logged out provider" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const store = try in(tmp.dir);
    defer allocator.free(store.directory);
    try store.put(allocator, operation(), "service", .{ .oauth = oauth });
    try expect(try store.replaceOAuth(allocator, operation(), "service", oauth, updated));
    try expect(!try store.replaceOAuth(allocator, operation(), "service", oauth, updated));
    try store.remove(allocator, operation(), "service");
    try expect(!try store.replaceOAuth(allocator, operation(), "service", updated, oauth));
    var snapshot = try store.read(allocator, operation());
    defer snapshot.deinit();
    try equal(0, snapshot.entries.count());
}
