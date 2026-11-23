const std = @import("std");
const foo = @import("foo");
const format = @import("format.zig");
const History = @import("history.zig");
const Local = @import("local.zig");
const Allocator = std.mem.Allocator;
const session = foo.session;

pub const Error = Local.Error || History.Error || error{ IdentityMismatch, Poisoned };

pub const Limits = struct {
    max_record_bytes: usize = 8 * 1024 * 1024,
    max_journal_bytes: u64 = 256 * 1024 * 1024,
    max_context_bytes: usize = 32 * 1024 * 1024,
    max_artifact_bytes: u64 = 64 * 1024 * 1024,
    max_artifacts: usize = 1024,
};

pub const Store = struct {
    allocator: Allocator,
    limits: Limits,
    frame: []u8,
    history: History = .{},
    sequence: u64 = 0,
    journal_bytes: u64 = 0,
    artifact_usage: Local.ArtifactUsage = .{},
    poisoned: bool = false,
    storage: union(enum) {
        memory: std.StringHashMapUnmanaged([]u8),
        local: Local,
    } = .{ .memory = .empty },

    pub fn initMemory(allocator: Allocator, config_identity: []const u8, limits: Limits) Error!Store {
        var self = try init(allocator, config_identity, limits);
        errdefer self.deinit();
        self.journal_bytes = (try self.encodeHeader(config_identity)).len;
        self.sequence = 1;
        return self;
    }

    /// Borrow an iterable, private session directory for the store's lifetime.
    pub fn create(allocator: Allocator, io: std.Io, dir: std.Io.Dir, config_identity: []const u8, limits: Limits) Error!Store {
        var self = try init(allocator, config_identity, limits);
        errdefer self.deinit();
        const header = try self.encodeHeader(config_identity);
        const local = try Local.init(io, dir, true);
        errdefer local.abandonCreate();
        self.artifact_usage = try local.artifactUsage(limits.max_artifact_bytes, limits.max_artifacts);
        try local.append(header, 0);
        try local.syncDirectory();
        self.sequence = 1;
        self.journal_bytes = header.len;
        self.storage = .{ .local = local };
        return self;
    }

    pub fn open(allocator: Allocator, io: std.Io, dir: std.Io.Dir, config_identity: []const u8, limits: Limits) Error!Store {
        var self = try init(allocator, config_identity, limits);
        errdefer self.deinit();
        const local = try Local.init(io, dir, false);
        errdefer local.deinit();
        self.artifact_usage = try local.artifactUsage(limits.max_artifact_bytes, limits.max_artifacts);
        try self.replay(local, config_identity);
        self.storage = .{ .local = local };
        return self;
    }

    fn init(allocator: Allocator, config_identity: []const u8, limits: Limits) Error!Store {
        if (config_identity.len == 0) return error.InvalidInput;
        if (limits.max_record_bytes == 0 or limits.max_journal_bytes == 0 or limits.max_context_bytes == 0)
            return error.InvalidInput;
        const capacity = @min(limits.max_record_bytes, limits.max_journal_bytes);
        return .{ .allocator = allocator, .limits = limits, .frame = try allocator.alloc(u8, @intCast(capacity)) };
    }

    pub fn deinit(self: *Store) void {
        switch (self.storage) {
            .local => |local| local.deinit(),
            .memory => |*artifacts| {
                var iterator = artifacts.iterator();
                while (iterator.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                artifacts.deinit(self.allocator);
            },
        }
        self.history.deinit(self.allocator);
        self.allocator.free(self.frame);
        self.* = undefined;
    }

    /// The adapter borrows this address until teardown. Calls are sequential.
    pub fn interface(self: *Store) session.Store {
        return .{ .context = self, .commit_fn = commitAdapter, .load_fn = loadAdapter };
    }

    fn commitAdapter(context: *anyopaque, operation: foo.io.Context, record: session.Record) session.Error!u64 {
        const self: *Store = @ptrCast(@alignCast(context));
        return self.commit(operation, record) catch |err| return switch (err) {
            error.InvalidRecord, error.InvalidArtifact, error.Poisoned => error.CommitFailed,
            error.AlreadyExists, error.IdentityMismatch, error.MissingJournal, error.UnsupportedBackend => unreachable,
            else => |shared| shared,
        };
    }

    fn loadAdapter(context: *anyopaque, allocator: Allocator, operation: foo.io.Context) session.Error!session.Recovery {
        const self: *Store = @ptrCast(@alignCast(context));
        return self.load(allocator, operation) catch |err| return switch (err) {
            error.Poisoned => error.CommitFailed,
            else => |shared| shared,
        };
    }

    pub fn commit(self: *Store, operation: foo.io.Context, record: session.Record) Error!u64 {
        try self.check(operation);
        if (record == .header) return error.InvalidRecord;
        const sequence = self.sequence + 1;
        const frame = try format.encode(self.frame, .{ .sequence = sequence, .record = record });
        if (frame.len > self.limits.max_journal_bytes - self.journal_bytes) return error.LimitExceeded;
        if (resultArtifact(record)) |artifact| {
            try self.checkArtifact(artifact, true);
            try operation.check();
        }
        try self.history.accept(self.allocator, self.limits.max_context_bytes, record);
        switch (self.storage) {
            .memory => {},
            .local => |local| local.append(frame, self.journal_bytes) catch |err| {
                self.poisoned = true;
                return err;
            },
        }
        self.journal_bytes += frame.len;
        self.sequence = sequence;
        return sequence;
    }

    pub fn load(self: *const Store, allocator: Allocator, operation: foo.io.Context) (foo.io.Error || error{Poisoned})!session.Recovery {
        try self.check(operation);
        return self.history.recovery(allocator, self.sequence);
    }

    pub fn writeArtifact(self: *Store, operation: foo.io.Context, basename: []const u8, bytes: []const u8) Error!foo.tool.Artifact {
        try self.check(operation);
        if (!Local.validArtifactName(basename)) return error.InvalidArtifact;
        if (self.artifact_usage.count == self.limits.max_artifacts or
            bytes.len > self.limits.max_artifact_bytes - self.artifact_usage.bytes)
            return error.LimitExceeded;

        switch (self.storage) {
            .memory => |*artifacts| {
                if (artifacts.contains(basename)) return error.AlreadyExists;
                const name = try self.allocator.dupe(u8, basename);
                errdefer self.allocator.free(name);
                const data = try self.allocator.dupe(u8, bytes);
                errdefer self.allocator.free(data);
                try artifacts.putNoClobber(self.allocator, name, data);
            },
            .local => |local| {
                const file = try local.createArtifact(basename);
                local.writeArtifact(file, basename, bytes) catch |err| {
                    self.poisoned = true;
                    return err;
                };
            },
        }
        self.artifact_usage.count += 1;
        self.artifact_usage.bytes += bytes.len;
        return .{ .relative_path = basename, .bytes = bytes.len };
    }

    pub fn readArtifact(self: *const Store, allocator: Allocator, operation: foo.io.Context, artifact: foo.tool.Artifact) Error![]u8 {
        try self.check(operation);
        try self.validateArtifact(artifact);
        return switch (self.storage) {
            .local => |local| local.readArtifact(allocator, artifact),
            .memory => allocator.dupe(u8, try self.memoryArtifact(artifact)),
        };
    }

    fn check(self: *const Store, operation: foo.io.Context) (foo.io.Error || error{Poisoned})!void {
        if (self.poisoned) return error.Poisoned;
        try operation.check();
    }

    fn validateArtifact(self: *const Store, artifact: foo.tool.Artifact) Error!void {
        if (!Local.validArtifactName(artifact.relative_path)) return error.InvalidArtifact;
        if (artifact.bytes > self.limits.max_artifact_bytes) return error.LimitExceeded;
    }

    fn memoryArtifact(self: *const Store, artifact: foo.tool.Artifact) Error![]const u8 {
        const bytes = self.storage.memory.get(artifact.relative_path) orelse return error.InvalidArtifact;
        if (bytes.len != artifact.bytes) return error.InvalidArtifact;
        return bytes;
    }

    fn checkArtifact(self: *const Store, artifact: foo.tool.Artifact, synchronize: bool) Error!void {
        try self.validateArtifact(artifact);
        switch (self.storage) {
            .local => |local| try local.checkArtifact(artifact, synchronize),
            .memory => _ = try self.memoryArtifact(artifact),
        }
    }

    fn encodeHeader(self: *Store, identity: []const u8) Error![]const u8 {
        return format.encode(self.frame, .{
            .sequence = 1,
            .record = .{ .header = .{ .config_identity = identity } },
        });
    }

    fn replay(self: *Store, local: Local, identity: []const u8) Error!void {
        const size = try local.journalSize();
        if (size > self.limits.max_journal_bytes) return error.LimitExceeded;
        var buffer: [8192]u8 = undefined;
        var offset: u64 = 0;
        var line_len: usize = 0;
        var overlong = false;
        while (offset < size) {
            const capacity: usize = @intCast(@min(buffer.len, size - offset));
            const n = try local.readJournal(buffer[0..capacity], offset);
            if (n == 0 or n > capacity) return error.CorruptHistory;
            var start: usize = 0;
            while (start < n) {
                const newline = std.mem.indexOfScalarPos(u8, buffer[0..n], start, '\n');
                const fragment = buffer[start .. newline orelse n];
                if (fragment.len > self.frame.len - 1 - line_len) overlong = true;
                if (!overlong) {
                    @memcpy(self.frame[line_len..][0..fragment.len], fragment);
                    line_len += fragment.len;
                }
                const end = newline orelse break;
                if (overlong) return error.LimitExceeded;
                try self.replayLine(local, identity, self.frame[0..line_len]);
                self.journal_bytes = offset + end + 1;
                line_len = 0;
                start = end + 1;
            }
            offset += n;
        }
        if (self.sequence == 0) return error.CorruptHistory;
        if (self.journal_bytes != size) try local.truncate(self.journal_bytes);
    }

    fn replayLine(self: *Store, local: Local, identity: []const u8, line: []const u8) Error!void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const payload = try format.decode(arena.allocator(), line);
        if (payload.sequence != self.sequence + 1) return error.CorruptHistory;
        const record = payload.record;
        if (self.sequence == 0) {
            if (record != .header) return error.CorruptHistory;
            if (record.header.version != session.format_version) return error.UnsupportedVersion;
            if (!std.mem.eql(u8, identity, record.header.config_identity)) return error.IdentityMismatch;
        } else {
            if (resultArtifact(record)) |artifact| {
                self.validateArtifact(artifact) catch |err| return corruptRecord(err);
                local.checkArtifact(artifact, false) catch |err| return corruptRecord(err);
            }
            self.history.accept(self.allocator, self.limits.max_context_bytes, record) catch |err| return corruptRecord(err);
        }
        self.sequence = payload.sequence;
    }
};

fn resultArtifact(record: session.Record) ?foo.tool.Artifact {
    return switch (record) {
        .tool_result => |result| result.artifact,
        .nested_tool => |nested| switch (nested.data) {
            .tool_result => |result| result.artifact,
            .dispatch_intent => null,
        },
        else => null,
    };
}

fn corruptRecord(err: Error) Error {
    return switch (err) {
        error.InvalidRecord, error.InvalidArtifact => error.CorruptHistory,
        else => err,
    };
}
