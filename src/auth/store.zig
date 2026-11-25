const std = @import("std");
const builtin = @import("builtin");
const foo = @import("foo");
const windows = @import("windows.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

pub const Error = foo.io.Error || error{ InvalidStore, UnsafeStore, InsecurePermissions };

pub const OAuth = struct {
    access: []const u8,
    refresh: ?[]const u8 = null,
    expires_ms: i64,
    account: ?[]const u8 = null,

    fn eql(self: OAuth, other: OAuth) bool {
        return self.expires_ms == other.expires_ms and
            std.mem.eql(u8, self.access, other.access) and
            equalOptional(self.refresh, other.refresh) and equalOptional(self.account, other.account);
    }

    fn equalOptional(first: ?[]const u8, second: ?[]const u8) bool {
        return if (first) |left| if (second) |right| std.mem.eql(u8, left, right) else false else second == null;
    }
};

pub const Entry = union(enum) {
    api_key: []const u8,
    oauth: OAuth,

    fn valid(self: Entry) bool {
        switch (self) {
            .api_key => |key| return validSecret(key),
            .oauth => |oauth| {
                if (!validSecret(oauth.access) or oauth.expires_ms < 0) return false;
                if (oauth.refresh) |token| if (!validSecret(token)) return false;
                if (oauth.account) |account| if (!validSecret(account)) return false;
                return true;
            },
        }
    }
};

const Entries = std.StringArrayHashMapUnmanaged(Entry);
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    entries: Entries = .empty,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
    }
};

pub const max_secret_bytes = 16 * 1024;
pub const max_store_bytes = 1024 * 1024;
const store_name = "auth.json";
const lock_name = "auth.lock";

pub const Store = struct {
    directory: []const u8,

    pub fn read(self: Store, a: Allocator, operation: foo.io.Context) Error!Snapshot {
        const dir = try self.openDirectory(operation, false) orelse return .{ .arena = .init(a) };
        defer dir.close(operation.io);
        return readEntries(a, operation, dir);
    }

    pub fn put(self: Store, a: Allocator, operation: foo.io.Context, provider: []const u8, entry: Entry) Error!void {
        _ = try self.change(a, operation, provider, .{ .put = entry });
    }

    pub fn remove(self: Store, a: Allocator, operation: foo.io.Context, provider: []const u8) Error!void {
        _ = try self.change(a, operation, provider, .remove);
    }

    pub fn replaceOAuth(self: Store, a: Allocator, operation: foo.io.Context, provider: []const u8, expected: OAuth, updated: OAuth) Error!bool {
        return self.change(a, operation, provider, .{ .refresh = .{ .expected = expected, .updated = updated } });
    }

    const Change = union(enum) {
        put: Entry,
        remove,
        refresh: struct { expected: OAuth, updated: OAuth },
    };

    fn change(self: Store, a: Allocator, operation: foo.io.Context, provider: []const u8, update: Change) Error!bool {
        if (!validProviderId(provider)) return error.InvalidInput;
        const replacement: ?Entry = switch (update) {
            .put => |entry| entry,
            .remove => null,
            .refresh => |entry| .{ .oauth = entry.updated },
        };
        if (replacement) |entry| if (!entry.valid()) return error.InvalidInput;

        const io = operation.io;
        const dir = try self.openDirectory(operation, update == .put) orelse return false;
        defer dir.close(io);
        const lock = createPrivate(io, dir, lock_name) catch |err| switch (err) {
            error.PathAlreadyExists => (try openPrivate(io, dir, lock_name, .read_write) orelse return error.UnsafeStore).file,
            else => |e| return e,
        };
        defer lock.close(io);
        while (!(lock.tryLock(io, .exclusive) catch |err| return mapIo(err))) {
            try operation.check();
            Io.sleep(io, .fromMilliseconds(10), .awake) catch |err| return mapIo(err);
        }

        var snapshot = try readEntries(a, operation, dir);
        defer snapshot.deinit();
        const entries = &snapshot.entries;
        switch (update) {
            .put => |entry| try entries.put(snapshot.arena.allocator(), provider, entry),
            .remove => if (!entries.orderedRemove(provider)) return false,
            .refresh => |refresh| {
                const current = entries.getPtr(provider) orelse return false;
                if (current.* != .oauth or !current.oauth.eql(refresh.expected)) return false;
                current.* = .{ .oauth = refresh.updated };
            },
        }
        try writeEntries(snapshot.arena.allocator(), operation, dir, entries);
        return true;
    }

    fn openDirectory(self: Store, operation: foo.io.Context, create: bool) Error!?Dir {
        try operation.check();
        if (!std.fs.path.isAbsolute(self.directory)) return error.InvalidInput;
        const io = operation.io;
        if (create) {
            const permissions: Dir.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
            _ = Dir.cwd().createDirPathStatus(io, self.directory, permissions) catch |err| return directoryError(err);
        }
        const dir = Dir.openDirAbsolute(io, self.directory, .{ .iterate = true, .follow_symlinks = false }) catch |err| return switch (err) {
            error.FileNotFound => if (create) error.UnsafeStore else null,
            else => |e| directoryError(e),
        };
        errdefer dir.close(io);
        const metadata = dir.stat(io) catch |err| return mapIo(err);
        if (metadata.kind != .directory) return error.UnsafeStore;
        if (builtin.os.tag != .windows and metadata.permissions.toMode() & 0o022 != 0) return error.UnsafeStore;
        return dir;
    }
};

pub fn validProviderId(id: []const u8) bool {
    if (id.len == 0 or !std.unicode.utf8ValidateSlice(id)) return false;
    for (id) |byte| if (byte < 32 or byte == 127 or byte == '/') return false;
    return true;
}

pub fn validSecret(value: []const u8) bool {
    if (value.len == 0 or value.len > max_secret_bytes or !std.unicode.utf8ValidateSlice(value)) return false;
    if (std.mem.trim(u8, value, " ").len != value.len) return false;
    for (value) |byte| if (byte < 32 or byte == 127) return false;
    return true;
}

const WireEntry = struct {
    type: std.meta.Tag(Entry),
    key: ?[]const u8 = null,
    access: ?[]const u8 = null,
    refresh: ?[]const u8 = null,
    expires_ms: ?i64 = null,
    account: ?[]const u8 = null,

    fn entry(self: WireEntry) Error!Entry {
        const decoded: Entry = switch (self.type) {
            .api_key => key: {
                if (self.access != null or self.refresh != null or self.expires_ms != null or self.account != null) return error.InvalidStore;
                break :key .{ .api_key = self.key orelse return error.InvalidStore };
            },
            .oauth => .{ .oauth = .{
                .access = self.access orelse return error.InvalidStore,
                .expires_ms = self.expires_ms orelse return error.InvalidStore,
                .refresh = self.refresh,
                .account = self.account,
            } },
        };
        if ((self.type == .oauth and self.key != null) or !decoded.valid()) return error.InvalidStore;
        return decoded;
    }
};

fn readEntries(a: Allocator, operation: foo.io.Context, dir: Dir) Error!Snapshot {
    try operation.check();
    var snapshot: Snapshot = .{ .arena = .init(a) };
    errdefer snapshot.deinit();
    const scratch = snapshot.arena.allocator();
    const io = operation.io;
    const opened = try openPrivate(io, dir, store_name, .read_only) orelse return snapshot;
    defer opened.file.close(io);
    if (opened.stat.size > max_store_bytes) return error.LimitExceeded;
    const bytes = try scratch.alloc(u8, @as(usize, @intCast(opened.stat.size)) + 1);
    const len = opened.file.readPositionalAll(io, bytes, 0) catch |err| return mapIo(err);
    if (len != opened.stat.size) return error.InvalidStore;
    const parsed = std.json.parseFromSliceLeaky(std.json.ArrayHashMap(WireEntry), scratch, bytes[0..len], .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidStore,
    };
    try snapshot.entries.ensureTotalCapacity(scratch, parsed.map.count());
    for (parsed.map.keys(), parsed.map.values()) |provider, stored| {
        if (!validProviderId(provider)) return error.InvalidStore;
        snapshot.entries.putAssumeCapacityNoClobber(provider, try stored.entry());
    }
    try operation.check();
    return snapshot;
}

const StoreJson = struct {
    entries: *const Entries,

    pub fn jsonStringify(self: StoreJson, out: *std.json.Stringify) std.Io.Writer.Error!void {
        try out.beginObject();
        for (self.entries.keys(), self.entries.values()) |provider, entry| {
            try out.objectField(provider);
            switch (entry) {
                .api_key => |key| try out.write(.{ .type = .api_key, .key = key }),
                .oauth => |oauth| try out.write(.{
                    .type = .oauth,
                    .access = oauth.access,
                    .refresh = oauth.refresh,
                    .expires_ms = oauth.expires_ms,
                    .account = oauth.account,
                }),
            }
        }
        try out.endObject();
    }
};

fn writeEntries(a: Allocator, operation: foo.io.Context, dir: Dir, entries: *const Entries) Error!void {
    const bytes = try std.json.Stringify.valueAlloc(a, StoreJson{ .entries = entries }, .{ .whitespace = .indent_2 });
    if (bytes.len > max_store_bytes) return error.LimitExceeded;
    try operation.check();
    const io = operation.io;
    var nonce: [16]u8 = undefined;
    io.randomSecure(&nonce) catch |err| return mapIo(err);
    const hex = std.fmt.bytesToHex(nonce, .lower);
    var name: [48]u8 = undefined;
    const temp = std.fmt.bufPrint(&name, "auth-{s}.tmp", .{hex}) catch unreachable;
    const file = createPrivate(io, dir, temp) catch |err| return mapIo(err);
    errdefer {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        dir.deleteFile(io, temp) catch {};
    }
    {
        defer file.close(io);
        file.writePositionalAll(io, bytes, 0) catch |err| return mapIo(err);
        file.sync(io) catch |err| return mapIo(err);
    }
    try operation.check();
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    dir.rename(temp, dir, store_name, io) catch |err| return mapIo(err);
    if (builtin.os.tag != .windows) {
        while (true) {
            switch (std.posix.errno(std.posix.system.fsync(dir.handle))) {
                .SUCCESS => break,
                .INTR => continue,
                else => return error.IoFailure,
            }
        }
    }
}

fn createPrivate(io: Io, dir: Dir, name: []const u8) (Error || error{PathAlreadyExists})!File {
    if (builtin.os.tag == .windows) {
        const file = try windows.create(dir, name);
        windows.check(file) catch |err| {
            file.close(io);
            dir.deleteFile(io, name) catch {};
            return err;
        };
        return file;
    }
    return dir.createFile(io, name, .{ .exclusive = true, .read = true, .permissions = .fromMode(0o600) }) catch |err| return switch (err) {
        error.PathAlreadyExists => error.PathAlreadyExists,
        else => |e| mapIo(e),
    };
}

const Opened = struct { file: File, stat: File.Stat };

fn openPrivate(io: Io, dir: Dir, name: []const u8, mode: Dir.OpenFileOptions.Mode) Error!?Opened {
    const expected = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| return switch (err) {
        error.FileNotFound => null,
        else => |e| directoryError(e),
    };
    if (expected.kind != .file or expected.nlink > 1) return error.UnsafeStore;
    const file = dir.openFile(io, name, .{ .mode = mode, .follow_symlinks = false, .allow_directory = false }) catch |err| return switch (err) {
        error.FileNotFound => null,
        else => |e| directoryError(e),
    };
    errdefer file.close(io);
    const actual = file.stat(io) catch |err| return mapIo(err);
    if (actual.kind != .file or actual.nlink > 1) return error.UnsafeStore;
    // A concurrent rename can unlink an opened auth.json. The writer lock must keep its original identity.
    if (mode == .read_write and (actual.nlink != 1 or actual.inode != expected.inode)) return error.UnsafeStore;
    if (builtin.os.tag == .windows) {
        windows.check(file) catch |err| return if (mode == .read_write and err == error.InsecurePermissions) error.UnsafeStore else err;
    } else if (actual.permissions.toMode() & 0o077 != 0) return if (mode == .read_write) error.UnsafeStore else error.InsecurePermissions;
    return .{ .file = file, .stat = actual };
}

fn directoryError(err: anyerror) Error {
    return switch (err) {
        error.SymLinkLoop, error.IsDir, error.NotDir => error.UnsafeStore,
        else => mapIo(err),
    };
}

fn mapIo(err: anyerror) Error {
    return switch (err) {
        error.Canceled, error.Cancelled => error.Cancelled,
        error.OutOfMemory => error.OutOfMemory,
        else => error.IoFailure,
    };
}
