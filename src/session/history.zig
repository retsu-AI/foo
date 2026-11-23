const std = @import("std");
const foo = @import("foo");
const provider = foo.provider;
const Record = foo.session.Record;
const Allocator = std.mem.Allocator;

const History = @This();

pub const Error = error{ OutOfMemory, InvalidRecord, LimitExceeded };

messages: std.ArrayList(OwnedMessage) = .empty,
call_ids: std.StringHashMapUnmanaged(void) = .empty,
uncertain_ids: std.ArrayList([]const u8) = .empty,
context_bytes: usize = 0,
uncertain_bytes: usize = 0,
phase: enum { initial, active, finished } = .initial,
interrupted: bool = false,
batch: ?Batch = null,

const OwnedMessage = struct {
    message: provider.Message,
    arena: std.heap.ArenaAllocator,
};

const Batch = struct {
    start: usize,
    start_bytes: usize,
    cursor: usize,
    dispatched: bool = false,
    uncertain: bool = false,
};

pub fn deinit(self: *History, allocator: Allocator) void {
    self.call_ids.deinit(allocator);
    for (self.messages.items) |*entry| entry.arena.deinit();
    self.messages.deinit(allocator);
    for (self.uncertain_ids.items) |id| allocator.free(id);
    self.uncertain_ids.deinit(allocator);
}

pub fn accept(self: *History, allocator: Allocator, limit: usize, record: Record) Error!void {
    switch (record) {
        .header => return error.InvalidRecord,
        .message => |message| try self.acceptMessage(allocator, limit, message),
        .dispatch_intent => |intent| {
            const expected = self.currentCall() orelse return error.InvalidRecord;
            const batch = &self.batch.?;
            if (batch.dispatched or batch.uncertain or
                !std.mem.eql(u8, expected.id, intent.call.id) or
                !std.mem.eql(u8, expected.name, intent.call.name) or
                !std.mem.eql(u8, expected.arguments_json, intent.call.arguments_json) or
                !std.mem.eql(u8, expected.name, intent.declaration.spec.name))
                return error.InvalidRecord;
            batch.dispatched = true;
        },
        .tool_result => |result| try self.acceptResult(allocator, limit, result),
        .finished => |outcome| {
            if (self.phase != .active) return error.InvalidRecord;
            const incomplete = self.batch != null;
            if (self.pendingIntent()) |id| try self.addUncertainty(allocator, limit, id);
            self.discardBatch();
            self.phase = .finished;
            self.interrupted = incomplete or outcome.reason == .interrupted or outcome.uncertain_effects;
        },
    }
}

fn acceptMessage(self: *History, allocator: Allocator, limit: usize, message: provider.Message) Error!void {
    switch (message.role) {
        .system => if (self.phase != .initial) return error.InvalidRecord,
        .user => if (self.uncertain_ids.items.len != 0 or self.pendingIntent() != null) return error.InvalidRecord,
        .assistant => if (self.phase != .active or self.batch != null or self.uncertain_ids.items.len != 0)
            return error.InvalidRecord,
        .tool => return error.InvalidRecord,
    }
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    defer ids.deinit(allocator);
    for (message.blocks) |block| switch (block) {
        .text, .replay => {},
        .reasoning => if (message.role != .assistant) return error.InvalidRecord,
        .tool_result => return error.InvalidRecord,
        .tool_call => |call| {
            if (message.role != .assistant or call.id.len == 0 or self.call_ids.contains(call.id))
                return error.InvalidRecord;
            if ((try ids.getOrPut(allocator, call.id)).found_existing) return error.InvalidRecord;
        },
    };

    const bytes = messageBytes(message);
    const start_bytes = if (message.role == .user and self.batch != null)
        self.batch.?.start_bytes
    else
        self.context_bytes;
    if (bytes > limit -| start_bytes -| self.uncertain_bytes) return error.LimitExceeded;
    try self.call_ids.ensureUnusedCapacity(allocator, ids.count());
    var owned = try ownMessage(allocator, message);
    errdefer owned.arena.deinit();
    try self.messages.ensureUnusedCapacity(allocator, 1);
    if (message.role == .user) {
        self.discardBatch();
        self.phase = .active;
        self.interrupted = false;
    }

    const start = self.messages.items.len;
    self.messages.appendAssumeCapacity(owned);
    self.context_bytes += bytes;
    if (ids.count() != 0) {
        for (owned.message.blocks) |block| {
            if (block == .tool_call) self.call_ids.putAssumeCapacityNoClobber(block.tool_call.id, {});
        }
        self.batch = .{
            .start = start,
            .start_bytes = start_bytes,
            .cursor = nextCall(owned.message.blocks, 0).?,
        };
    }
}

fn acceptResult(self: *History, allocator: Allocator, limit: usize, result: foo.tool.Result) Error!void {
    const expected = self.currentCall() orelse return error.InvalidRecord;
    const batch = &self.batch.?;
    if (!std.mem.eql(u8, expected.id, result.call_id) or
        (result.effect != .not_started and !batch.dispatched))
        return error.InvalidRecord;

    if (result.effect == .uncertain) {
        try self.addUncertainty(allocator, limit, result.call_id);
        batch.uncertain = true;
    } else if (!batch.uncertain) {
        const blocks = [_]provider.Block{.{ .tool_result = .{
            .call_id = result.call_id,
            .content = result.content,
            .is_error = result.status != .success,
        } }};
        const message: provider.Message = .{ .role = .tool, .blocks = &blocks };
        const bytes = messageBytes(message);
        if (bytes > limit -| self.context_bytes -| self.uncertain_bytes) return error.LimitExceeded;
        var owned = try ownMessage(allocator, message);
        errdefer owned.arena.deinit();
        try self.messages.append(allocator, owned);
        self.context_bytes += bytes;
    }

    if (nextCall(self.messages.items[batch.start].message.blocks, batch.cursor + 1)) |cursor| {
        batch.cursor = cursor;
        batch.dispatched = false;
    } else if (batch.uncertain) {
        self.discardBatch();
    } else {
        self.batch = null;
    }
}

fn nextCall(blocks: []const provider.Block, start: usize) ?usize {
    for (blocks[start..], start..) |block, index| {
        if (block == .tool_call) return index;
    }
    return null;
}

fn currentCall(self: *const History) ?provider.ToolCall {
    const batch = self.batch orelse return null;
    return self.messages.items[batch.start].message.blocks[batch.cursor].tool_call;
}

fn pendingIntent(self: *const History) ?[]const u8 {
    const batch = self.batch orelse return null;
    return if (batch.dispatched) self.currentCall().?.id else null;
}

fn addUncertainty(self: *History, allocator: Allocator, limit: usize, id: []const u8) Error!void {
    const bytes = @sizeOf([]const u8) +| id.len;
    if (bytes > limit -| self.context_bytes -| self.uncertain_bytes) return error.LimitExceeded;
    const owned = try allocator.dupe(u8, id);
    errdefer allocator.free(owned);
    try self.uncertain_ids.append(allocator, owned);
    self.uncertain_bytes += bytes;
}

fn discardBatch(self: *History) void {
    const batch = self.batch orelse return;
    for (self.messages.items[batch.start].message.blocks) |block| {
        if (block == .tool_call) _ = self.call_ids.remove(block.tool_call.id);
    }
    for (self.messages.items[batch.start..]) |*entry| entry.arena.deinit();
    self.messages.shrinkRetainingCapacity(batch.start);
    self.context_bytes = batch.start_bytes;
    self.batch = null;
}

fn ownMessage(allocator: Allocator, message: provider.Message) error{OutOfMemory}!OwnedMessage {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const copy = try provider.copyMessage(arena.allocator(), message);
    return .{ .message = copy, .arena = arena };
}

fn messageBytes(message: provider.Message) usize {
    var bytes = @sizeOf(OwnedMessage) +| (message.blocks.len *| @sizeOf(provider.Block));
    for (message.blocks) |block| {
        bytes +|= switch (block) {
            .text => |text| text.len,
            .reasoning => |reasoning| reasoning.text.len +| (if (reasoning.signature) |s| s.len else 0),
            .tool_call => |call| call.id.len +| call.name.len +| call.arguments_json.len +| @sizeOf([]const u8),
            .tool_result => |result| result.call_id.len +| result.content.len,
            .replay => |replay| replay.endpoint.len +| replay.model.len +| replay.bytes.len,
        };
    }
    return bytes;
}

pub fn recovery(self: *const History, allocator: Allocator, sequence: u64) error{OutOfMemory}!foo.session.Recovery {
    const end = if (self.batch) |batch| batch.start else self.messages.items.len;
    const messages = try allocator.alloc(provider.Message, end);
    for (self.messages.items[0..end], messages) |entry, *message| {
        message.* = try provider.copyMessage(allocator, entry.message);
    }
    const pending = self.pendingIntent();
    const ids = try allocator.alloc([]const u8, self.uncertain_ids.items.len + @intFromBool(pending != null));
    for (self.uncertain_ids.items, ids[0..self.uncertain_ids.items.len]) |source, *dest| {
        dest.* = try allocator.dupe(u8, source);
    }
    if (pending) |id| ids[ids.len - 1] = try allocator.dupe(u8, id);
    return .{
        .messages = messages,
        .uncertain_call_ids = ids,
        .last_sequence = sequence,
        .interrupted = self.phase == .active or self.interrupted or ids.len != 0,
    };
}
