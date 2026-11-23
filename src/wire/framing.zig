const std = @import("std");
const io = @import("../contracts/io.zig");

pub const Error = io.Error || error{ MalformedFrame, TruncatedFrame, Closed, Busy };
pub const EmptyLines = enum { reject, skip };

const cancellation_check_interval = 4096;

/// Incremental UTF-8 records separated by LF or CRLF. The caller owns the buffer
/// and serializes reader use. The sink borrows each record during its callback.
/// EOF or an error closes the reader. Parse JSON in the record sink.
pub const Ndjson = struct {
    buffer: []u8,
    empty_lines: EmptyLines,
    length: usize = 0,
    saw_cr: bool = false,
    closed: bool = false,

    pub fn init(record_buffer: []u8, empty_lines: EmptyLines) Ndjson {
        return .{ .buffer = record_buffer, .empty_lines = empty_lines };
    }

    pub fn feed(self: *Ndjson, operation: io.Context, bytes: []const u8, sink: io.ByteSink) Error!void {
        if (self.closed) return error.Closed;
        errdefer self.closed = true;
        try operation.check();
        for (bytes, 0..) |byte, index| {
            if (index != 0 and index % cancellation_check_interval == 0) try operation.check();
            if (byte == '\n') {
                self.saw_cr = false;
                const record = self.buffer[0..self.length];
                if (record.len == 0) {
                    if (self.empty_lines == .reject) return error.MalformedFrame;
                    continue;
                }
                if (!std.unicode.utf8ValidateSlice(record)) return error.MalformedFrame;
                try sink.write(operation, record);
                self.length = 0;
            } else {
                if (self.saw_cr) return error.MalformedFrame;
                if (byte == '\r') {
                    self.saw_cr = true;
                    continue;
                }
                if (self.length == self.buffer.len) return error.LimitExceeded;
                self.buffer[self.length] = byte;
                self.length += 1;
            }
        }
    }

    pub fn finish(self: *Ndjson, operation: io.Context) Error!void {
        if (self.closed) return error.Closed;
        self.closed = true;
        try operation.check();
        if (self.length != 0 or self.saw_cr) return error.TruncatedFrame;
    }
};

/// Incremental Server-Sent Events. The caller owns disjoint storage and
/// serializes reader use. Each callback borrows event data until it returns.
/// Malformed UTF-8 closes the stream with an error. EOF also closes the stream
/// and reports an incomplete line or event as truncated.
pub const Sse = struct {
    pub const Storage = struct {
        line: []u8,
        data: []u8,
        event: []u8,
        id: []u8,
        pending_id: []u8,
        /// Combined bytes of the data, explicit event type, and effective ID.
        /// Synthesized defaults cost no storage. Both ID buffers must fit any ID.
        max_event_bytes: usize,
    };

    pub const Event = struct {
        data: []const u8,
        event: []const u8,
        last_event_id: ?[]const u8,
    };

    pub const EventSink = struct {
        context: *anyopaque,
        emit_fn: *const fn (*anyopaque, io.Context, Event) Error!void,
    };

    const bom = "\xef\xbb\xbf";

    storage: Storage,
    line_len: usize = 0,
    data_len: ?usize = null,
    event_len: ?usize = null,
    id_len: ?usize = null,
    pending_id_len: ?usize = null,
    retry_ms: ?u64 = null,
    bom_prefix_len: ?usize = 0,
    saw_cr: bool = false,
    closed: bool = false,

    pub fn init(storage: Storage) Sse {
        return .{ .storage = storage };
    }

    /// A null cursor means no ID has been committed. An empty ID resets it.
    /// Borrowed until the next feed.
    pub fn lastEventId(self: *const Sse) ?[]const u8 {
        return self.storage.id[0..(self.id_len orelse return null)];
    }

    pub fn retryMilliseconds(self: *const Sse) ?u64 {
        return self.retry_ms;
    }

    pub fn feed(self: *Sse, operation: io.Context, bytes: []const u8, sink: EventSink) Error!void {
        if (self.closed) return error.Closed;
        errdefer self.closed = true;
        try operation.check();
        for (bytes, 0..) |byte, index| {
            if (index != 0 and index % cancellation_check_interval == 0) try operation.check();
            if (self.bom_prefix_len) |prefix_len| {
                if (byte == bom[prefix_len]) {
                    self.bom_prefix_len = if (prefix_len + 1 == bom.len) null else prefix_len + 1;
                    continue;
                }
                for (bom[0..prefix_len]) |prefix_byte| try self.appendLineByte(prefix_byte);
                self.bom_prefix_len = null;
            }
            if (self.saw_cr) {
                self.saw_cr = false;
                if (byte == '\n') continue;
            }
            switch (byte) {
                '\r', '\n' => {
                    self.saw_cr = byte == '\r';
                    try self.completeLine(operation, sink);
                    self.line_len = 0;
                },
                else => try self.appendLineByte(byte),
            }
        }
    }

    pub fn finish(self: *Sse, operation: io.Context) Error!void {
        if (self.closed) return error.Closed;
        self.closed = true;
        try operation.check();
        if ((self.bom_prefix_len orelse 0) != 0 or self.line_len != 0 or
            self.data_len != null or self.event_len != null or self.pending_id_len != null)
            return error.TruncatedFrame;
    }

    fn appendLineByte(self: *Sse, byte: u8) Error!void {
        if (self.line_len == self.storage.line.len) return error.LimitExceeded;
        self.storage.line[self.line_len] = byte;
        self.line_len += 1;
    }

    fn completeLine(self: *Sse, operation: io.Context, sink: EventSink) Error!void {
        const line = self.storage.line[0..self.line_len];
        if (line.len == 0) return self.dispatch(operation, sink);
        if (!std.unicode.utf8ValidateSlice(line)) return error.MalformedFrame;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
        const field = line[0..colon];
        const raw_value = if (colon == line.len) "" else line[colon + 1 ..];
        const value = if (std.mem.startsWith(u8, raw_value, " ")) raw_value[1..] else raw_value;
        const data_len = self.data_len orelse 0;
        const event_len = self.event_len orelse 0;
        const id_len = self.pending_id_len orelse self.id_len orelse 0;

        if (std.mem.eql(u8, field, "data")) {
            const start = data_len + @intFromBool(self.data_len != null);
            if (start > self.storage.data.len or value.len > self.storage.data.len - start)
                return error.LimitExceeded;
            try self.checkEventLength(start + value.len, event_len, id_len);
            if (self.data_len != null) self.storage.data[data_len] = '\n';
            @memcpy(self.storage.data[start..][0..value.len], value);
            self.data_len = start + value.len;
        } else if (std.mem.eql(u8, field, "event")) {
            if (value.len > self.storage.event.len) return error.LimitExceeded;
            try self.checkEventLength(data_len, value.len, id_len);
            @memcpy(self.storage.event[0..value.len], value);
            self.event_len = value.len;
        } else if (std.mem.eql(u8, field, "id")) {
            if (std.mem.indexOfScalar(u8, value, 0) != null) return;
            if (value.len > @min(self.storage.id.len, self.storage.pending_id.len))
                return error.LimitExceeded;
            try self.checkEventLength(data_len, event_len, value.len);
            @memcpy(self.storage.pending_id[0..value.len], value);
            self.pending_id_len = value.len;
        } else if (std.mem.eql(u8, field, "retry")) {
            if (value.len == 0) return;
            for (value) |digit| {
                if (!std.ascii.isDigit(digit)) return;
            }
            self.retry_ms = std.fmt.parseInt(u64, value, 10) catch return;
        }
    }

    fn checkEventLength(self: *const Sse, data_len: usize, event_len: usize, id_len: usize) Error!void {
        var budget: io.Budget = .{ .limit = self.storage.max_event_bytes };
        try budget.take(data_len);
        try budget.take(event_len);
        try budget.take(id_len);
    }

    fn dispatch(self: *Sse, operation: io.Context, sink: EventSink) Error!void {
        try operation.check();
        if (self.pending_id_len) |len| {
            @memcpy(self.storage.id[0..len], self.storage.pending_id[0..len]);
            self.id_len = len;
            self.pending_id_len = null;
        }
        const event_len = self.event_len orelse 0;
        self.event_len = null;
        const data_len = self.data_len orelse return;
        self.data_len = null;
        try sink.emit_fn(sink.context, operation, .{
            .data = self.storage.data[0..data_len],
            .event = if (event_len == 0) "message" else self.storage.event[0..event_len],
            .last_event_id = self.lastEventId(),
        });
    }
};

/// Serializes sink access. A concurrent or reentrant call returns Busy.
/// The caller reserves scratch for the writer and supplies records separately.
/// Scratch must fit the UTF-8 record and its trailing LF. The caller schedules
/// and encodes JSON messages. Any error inside the sink closes the writer.
pub const Writer = struct {
    scratch: []u8,
    sink: io.ByteSink,
    busy: std.atomic.Value(bool) = .init(false),
    closed: bool = false,

    pub fn init(scratch: []u8, sink: io.ByteSink) Writer {
        return .{ .scratch = scratch, .sink = sink };
    }

    pub fn write(self: *Writer, operation: io.Context, record: []const u8) Error!void {
        if (self.busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null)
            return error.Busy;
        defer self.busy.store(false, .release);
        if (self.closed) return error.Closed;
        try operation.check();
        if (record.len == 0) return error.MalformedFrame;
        if (record.len >= self.scratch.len) return error.LimitExceeded;
        if (!std.unicode.utf8ValidateSlice(record) or std.mem.indexOfAny(u8, record, "\r\n") != null)
            return error.MalformedFrame;
        @memcpy(self.scratch[0..record.len], record);
        self.scratch[record.len] = '\n';
        try operation.check();
        errdefer self.closed = true;
        try self.sink.write_fn(self.sink.context, operation, self.scratch[0 .. record.len + 1]);
    }
};
