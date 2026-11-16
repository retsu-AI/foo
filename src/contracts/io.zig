const std = @import("std");

pub const Error = error{
    Cancelled,
    DeadlineExceeded,
    LimitExceeded,
    Unavailable,
    InvalidInput,
    Disconnected,
    IoFailure,
    OutOfMemory,
};

/// The wake callback must be thread-safe, nonblocking, and installed before sharing.
/// It wakes adapter-owned waits independently of the output queue. Cancellation is
/// a request, not proof of completion; all tasks must be joined before teardown.
pub const Cancellation = struct {
    requested: std.atomic.Value(bool) = .init(false),
    wake_context: ?*anyopaque = null,
    wake_fn: ?*const fn (?*anyopaque) void = null,

    pub fn request(self: *Cancellation) void {
        if (!self.requested.swap(true, .acq_rel)) {
            if (self.wake_fn) |wake| wake(self.wake_context);
        }
    }

    pub fn check(self: *const Cancellation) Error!void {
        if (self.requested.load(.acquire)) return error.Cancelled;
    }
};

/// Monotonic milliseconds.
pub const Clock = struct {
    context: *anyopaque,
    now_fn: *const fn (*anyopaque) u64,

    pub fn now(self: Clock) u64 {
        return self.now_fn(self.context);
    }
};

pub const Context = struct {
    io: std.Io,
    cancellation: *const Cancellation,
    clock: Clock,
    deadline_ms: ?u64 = null,

    pub fn check(self: Context) Error!void {
        try self.cancellation.check();
        if (self.deadline_ms) |deadline| {
            if (self.clock.now() >= deadline) return error.DeadlineExceeded;
        }
    }
};

pub const Budget = struct {
    limit: usize,
    used: usize = 0,

    pub fn take(self: *Budget, amount: usize) Error!void {
        if (amount > self.limit -| self.used) return error.LimitExceeded;
        self.used += amount;
    }
};

/// Bytes are borrowed for the callback only. Write accepts the entire slice or
/// fails; an adapter must not hide an unbounded queue behind this interface.
pub const ByteSink = struct {
    context: *anyopaque,
    write_fn: *const fn (*anyopaque, Context, []const u8) Error!void,

    pub fn write(self: ByteSink, operation: Context, bytes: []const u8) Error!void {
        try operation.check();
        try self.write_fn(self.context, operation, bytes);
    }
};

pub const ByteSource = struct {
    context: *anyopaque,
    /// Writes at most buffer.len bytes and returns zero only at EOF. The buffer
    /// is nonempty caller storage, borrowed for this callback only.
    read_fn: *const fn (*anyopaque, Context, []u8) Error!usize,
};
pub const ProcessExit = union(enum) { exited: i32, signalled: u32 };
pub const Child = struct {
    context: *anyopaque,
    stdin: ByteSink,
    stdout: ByteSource,
    stderr: ByteSource,
    close_stdin_fn: *const fn (*anyopaque, Context) Error!void,
    terminate_fn: *const fn (*anyopaque, Context) Error!void,
    wait_fn: *const fn (*anyopaque, Context) Error!ProcessExit,
    /// Reaps and closes handles; no callbacks or pipe operations may remain.
    release_fn: *const fn (*anyopaque, Context) Error!void,
};
pub const Environment = struct { name: []const u8, value: []const u8 };
pub const Spawn = struct {
    argv: []const []const u8,
    cwd: []const u8,
    environment: []const Environment = &.{},
    inherit_environment: bool = false,
};
pub const Spawner = struct {
    context: *anyopaque,
    /// Child storage belongs to allocator until release; pipes are independent.
    spawn_fn: *const fn (*anyopaque, std.mem.Allocator, Context, Spawn) Error!Child,
};

pub const Header = struct { name: []const u8, value: []const u8 };
pub const Delivery = enum { unsent, possibly_sent };
pub const HttpBody = union(enum) {
    bytes: []const u8,
    stream: struct {
        source: ByteSource,
        content_length: ?u64 = null,
    },
};
pub const HttpRequest = struct {
    method: enum { get, post, delete },
    url: []const u8,
    headers: []const Header = &.{},
    body: HttpBody = .{ .bytes = "" },
    max_response_bytes: usize,
};
pub const HttpHead = struct { status: u16, headers: []const Header };
pub const HttpSink = struct {
    context: *anyopaque,
    head_fn: *const fn (*anyopaque, Context, HttpHead) Error!void,
    body: ByteSink,
};
pub const HttpTransport = struct {
    context: *anyopaque,
    /// Set delivery before bytes can reach the peer, including on error.
    /// The request and its source live until return; callback buffers are borrowed
    /// only in callbacks. Never rewind or replay the body. Return after I/O is quiescent.
    exchange_fn: *const fn (*anyopaque, Context, HttpRequest, HttpSink, *Delivery) Error!void,
};
