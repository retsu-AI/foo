const std = @import("std");
const builtin = @import("builtin");
const foo = @import("foo");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const Local = @This();

pub const Error = foo.session.Error || error{
    AlreadyExists,
    InvalidArtifact,
    MissingJournal,
    UnsupportedBackend,
};

pub const journal_name = "journal.jsonl";
const lock_name = "writer.lock";
const artifact_prefix = "artifact-";

io: Io,
dir: Dir,
lock: File,
journal: File,

pub fn init(io: Io, dir: Dir, create: bool) Error!Local {
    switch (builtin.os.tag) {
        .linux, .macos, .windows => {},
        else => return error.UnsupportedBackend,
    }
    const lock = createFile(io, dir, lock_name) catch |err| switch (err) {
        error.PathAlreadyExists => (try openRegular(io, dir, lock_name, .read_write, error.CorruptHistory)).file,
        else => return ioError(err),
    };
    errdefer lock.close(io);
    if (!(lock.tryLock(io, .exclusive) catch |err| return ioError(err))) return error.WriterBusy;

    const journal = if (create)
        createFile(io, dir, journal_name) catch |err| return switch (err) {
            error.PathAlreadyExists => error.AlreadyExists,
            else => ioError(err),
        }
    else
        (try openRegular(io, dir, journal_name, .read_write, error.CorruptHistory)).file;
    return .{ .io = io, .dir = dir, .lock = lock, .journal = journal };
}

pub fn deinit(self: Local) void {
    self.journal.close(self.io);
    self.lock.close(self.io);
}

pub fn abandonCreate(self: Local) void {
    const protection = self.io.swapCancelProtection(.blocked);
    defer _ = self.io.swapCancelProtection(protection);
    self.journal.close(self.io);
    self.dir.deleteFile(self.io, journal_name) catch {};
    self.syncDirectory() catch {};
    self.lock.close(self.io);
}

pub fn journalSize(self: Local) Error!u64 {
    const stat = self.journal.stat(self.io) catch |err| return ioError(err);
    return stat.size;
}

pub fn readJournal(self: Local, buffer: []u8, offset: u64) Error!usize {
    return self.journal.readPositional(self.io, &.{buffer}, offset) catch |err| return ioError(err);
}

pub fn append(self: Local, bytes: []const u8, offset: u64) Error!void {
    writeAll(self.journal, self.io, bytes, offset) catch return self.failedAppend(offset);
    self.journal.sync(self.io) catch return self.failedAppend(offset);
}

fn failedAppend(self: Local, offset: u64) Error {
    self.truncate(offset) catch {};
    return error.CommitFailed;
}

pub fn truncate(self: Local, size: u64) Error!void {
    const protection = self.io.swapCancelProtection(.blocked);
    defer _ = self.io.swapCancelProtection(protection);
    self.journal.setLength(self.io, size) catch return error.CommitFailed;
    self.journal.sync(self.io) catch return error.CommitFailed;
}

pub fn syncDirectory(self: Local) Error!void {
    switch (builtin.os.tag) {
        .linux, .macos => while (true) {
            switch (std.posix.errno(std.posix.system.fsync(self.dir.handle))) {
                .SUCCESS => return,
                .INTR => continue,
                else => return error.CommitFailed,
            }
        },
        .windows => {},
        else => return error.UnsupportedBackend,
    }
}

pub const ArtifactUsage = struct {
    bytes: u64 = 0,
    count: usize = 0,
};

pub fn artifactUsage(self: Local, byte_limit: u64, count_limit: usize) Error!ArtifactUsage {
    var usage: ArtifactUsage = .{};
    var entries = self.dir.iterate();
    while (entries.next(self.io) catch |err| return ioError(err)) |entry| {
        if (entry.name.len < artifact_prefix.len or
            !std.ascii.eqlIgnoreCase(entry.name[0..artifact_prefix.len], artifact_prefix))
            continue;
        if (!validArtifactName(entry.name)) return error.InvalidArtifact;
        const stat = try statRegular(self.io, self.dir, entry.name, error.InvalidArtifact);
        if (usage.count == count_limit or stat.size > byte_limit - usage.bytes) return error.LimitExceeded;
        usage.count += 1;
        usage.bytes += stat.size;
    }
    return usage;
}

pub fn validArtifactName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, artifact_prefix) or name.len <= artifact_prefix.len or name.len > 128)
        return false;
    for (name[artifact_prefix.len..]) |byte| {
        if (!asciiIdentifierByte(byte) and byte != '-' and byte != '_' and byte != '.') return false;
    }
    return asciiIdentifierByte(name[name.len - 1]);
}

fn asciiIdentifierByte(byte: u8) bool {
    return std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'z');
}

pub fn createArtifact(self: Local, name: []const u8) Error!File {
    return createFile(self.io, self.dir, name) catch |err| switch (err) {
        error.PathAlreadyExists => error.AlreadyExists,
        else => ioError(err),
    };
}

pub fn writeArtifact(self: Local, file: File, name: []const u8, bytes: []const u8) Error!void {
    var ok = false;
    defer {
        file.close(self.io);
        if (!ok) {
            const protection = self.io.swapCancelProtection(.blocked);
            defer _ = self.io.swapCancelProtection(protection);
            self.dir.deleteFile(self.io, name) catch {};
            self.syncDirectory() catch {};
        }
    }
    try writeAll(file, self.io, bytes, 0);
    file.sync(self.io) catch return error.CommitFailed;
    try self.syncDirectory();
    ok = true;
}

pub fn checkArtifact(self: Local, artifact: foo.tool.Artifact, synchronize: bool) Error!void {
    const file = try self.openArtifact(artifact, if (synchronize) .read_write else .read_only);
    defer file.close(self.io);
    if (synchronize) {
        file.sync(self.io) catch |err| return ioError(err);
        try self.syncDirectory();
    }
}

pub fn readArtifact(self: Local, allocator: Allocator, artifact: foo.tool.Artifact) Error![]u8 {
    const file = try self.openArtifact(artifact, .read_only);
    defer file.close(self.io);
    const length = std.math.cast(usize, artifact.bytes) orelse return error.LimitExceeded;
    const bytes = try allocator.alloc(u8, length);
    errdefer allocator.free(bytes);
    const read = file.readPositionalAll(self.io, bytes, 0) catch |err| return ioError(err);
    if (read != length) return error.InvalidArtifact;
    return bytes;
}

fn openArtifact(self: Local, artifact: foo.tool.Artifact, mode: Dir.OpenFileOptions.Mode) Error!File {
    const opened = try openRegular(self.io, self.dir, artifact.relative_path, mode, error.InvalidArtifact);
    errdefer opened.file.close(self.io);
    if (opened.stat.size != artifact.bytes) return error.InvalidArtifact;
    return opened.file;
}

fn createFile(io: Io, dir: Dir, name: []const u8) File.OpenError!File {
    return dir.createFile(io, name, .{
        .exclusive = true,
        .truncate = false,
        .read = true,
        .permissions = switch (builtin.os.tag) {
            .linux, .macos => .fromMode(0o600),
            else => .default_file,
        },
    });
}

fn statRegular(io: Io, dir: Dir, name: []const u8, invalid: Error) Error!File.Stat {
    const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| return switch (err) {
        error.FileNotFound => if (std.mem.eql(u8, journal_name, name)) error.MissingJournal else invalid,
        error.SymLinkLoop, error.IsDir => invalid,
        else => ioError(err),
    };
    if (stat.kind != .file or stat.nlink != 1) return invalid;
    return stat;
}

const OpenedFile = struct { file: File, stat: File.Stat };

fn openRegular(io: Io, dir: Dir, name: []const u8, mode: Dir.OpenFileOptions.Mode, invalid: Error) Error!OpenedFile {
    const expected = try statRegular(io, dir, name, invalid);
    const file = dir.openFile(io, name, .{
        .mode = mode,
        .follow_symlinks = false,
        .allow_directory = false,
    }) catch |err| return switch (err) {
        error.FileNotFound, error.SymLinkLoop, error.IsDir => invalid,
        else => ioError(err),
    };
    errdefer file.close(io);
    const actual = file.stat(io) catch |err| return ioError(err);
    if (actual.kind != .file or actual.nlink != 1 or actual.inode != expected.inode) return invalid;
    return .{ .file = file, .stat = actual };
}

fn writeAll(file: File, io: Io, bytes: []const u8, offset: u64) Error!void {
    var position: usize = 0;
    while (position < bytes.len) {
        const remaining = bytes[position..];
        const count = file.writePositional(io, &.{remaining}, offset + position) catch return error.CommitFailed;
        if (count == 0 or count > remaining.len) return error.CommitFailed;
        position += count;
    }
}

fn ioError(err: anyerror) Error {
    return switch (err) {
        error.Canceled => error.Cancelled,
        error.OutOfMemory => error.OutOfMemory,
        else => error.IoFailure,
    };
}
