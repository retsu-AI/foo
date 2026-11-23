const std = @import("std");
const rpc = @import("../contracts/jsonrpc.zig");

pub const Error = error{
    Closed,
    DuplicateId,
    UnknownId,
    RetiredId,
    StaleRequest,
    LimitExceeded,
    IdExhausted,
    OutOfMemory,
};

pub const Limits = struct {
    pending_per_direction: usize = 64,
    id_bytes: usize = 4096,
};

pub const Ticket = struct {
    table: *const Table,
    direction: rpc.Direction,
    slot: usize,
    sequence: u64,

    pub fn eql(a: Ticket, b: Ticket) bool {
        return a.table == b.table and a.direction == b.direction and
            a.slot == b.slot and a.sequence == b.sequence;
    }
};

pub const Outbound = struct { id: rpc.Id, ticket: Ticket };
pub const Resolution = union(enum) { response: Ticket, expired: Ticket };
pub const ResponseAdmission = union(enum) {
    ready: struct { id: rpc.Id, deadline_ms: ?u64 },
    expired: Ticket,
};

const Entry = struct {
    id: rpc.Id,
    sequence: u64,
    deadline_ms: ?u64,
};

pub const Table = struct {
    allocator: std.mem.Allocator,
    inbound: []?Entry,
    outbound: []?Entry,
    id_bytes: usize,
    inbound_sequence: u64 = 0,
    outbound_sequence: i64 = 0,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) Error!Table {
        const inbound = try allocator.alloc(?Entry, limits.pending_per_direction);
        errdefer allocator.free(inbound);
        const outbound = try allocator.alloc(?Entry, limits.pending_per_direction);
        @memset(inbound, null);
        @memset(outbound, null);
        return .{ .allocator = allocator, .inbound = inbound, .outbound = outbound, .id_bytes = limits.id_bytes };
    }

    pub fn deinit(self: *Table) void {
        self.close();
        while (self.drainNext() != null) {}
        self.allocator.free(self.inbound);
        self.allocator.free(self.outbound);
        self.* = undefined;
    }

    pub fn beginOutbound(self: *Table, deadline_ms: ?u64) Error!Outbound {
        if (self.closed) return error.Closed;
        const slot = findEmpty(self.outbound) orelse return error.LimitExceeded;
        const number = std.math.add(i64, self.outbound_sequence, 1) catch return error.IdExhausted;
        const entry: Entry = .{ .id = .{ .number = number }, .sequence = @intCast(number), .deadline_ms = deadline_ms };
        self.outbound[slot] = entry;
        self.outbound_sequence = number;
        return .{ .id = entry.id, .ticket = self.ticketAt(.outbound, slot, entry.sequence) };
    }

    pub fn beginInbound(self: *Table, id: rpc.Id, deadline_ms: ?u64) Error!Ticket {
        if (self.closed) return error.Closed;
        if (self.lookup(.inbound, id) != null) return error.DuplicateId;
        const slot = findEmpty(self.inbound) orelse return error.LimitExceeded;
        const sequence = std.math.add(u64, self.inbound_sequence, 1) catch return error.IdExhausted;
        const owned: rpc.Id = switch (id) {
            .number => id,
            .string => |bytes| owned: {
                if (bytes.len > self.id_bytes) return error.LimitExceeded;
                break :owned .{ .string = try self.allocator.dupe(u8, bytes) };
            },
        };
        self.inbound[slot] = .{ .id = owned, .sequence = sequence, .deadline_ms = deadline_ms };
        self.inbound_sequence = sequence;
        return self.ticketAt(.inbound, slot, sequence);
    }

    pub fn resolve(self: *Table, response: rpc.Response, now_ms: u64) Error!Resolution {
        if (self.closed) return error.Closed;
        const id = switch (response) {
            .success => |success| success.id,
            .failure => |failure| failure.id orelse return error.UnknownId,
        };
        const slot = try self.requireId(.outbound, id);
        const expired = hasExpired(self.outbound[slot].?, now_ms);
        const ticket = self.take(.outbound, slot);
        return if (expired) .{ .expired = ticket } else .{ .response = ticket };
    }

    /// The ready ID borrows the table's entry through retirement.
    pub fn prepareInboundResponse(self: *Table, ticket: Ticket, now_ms: u64) Error!ResponseAdmission {
        const entry = try self.entryFor(ticket);
        if (ticket.direction != .inbound) return error.StaleRequest;
        if (hasExpired(entry, now_ms)) return .{ .expired = self.take(.inbound, ticket.slot) };
        return .{ .ready = .{ .id = entry.id, .deadline_ms = entry.deadline_ms } };
    }

    fn entryFor(self: *const Table, ticket: Ticket) Error!Entry {
        if (self.closed) return error.Closed;
        if (ticket.table != self) return error.StaleRequest;
        const slots = self.slotsFor(ticket.direction);
        if (ticket.slot >= slots.len) return error.StaleRequest;
        const entry = slots[ticket.slot] orelse return error.StaleRequest;
        if (entry.sequence != ticket.sequence) return error.StaleRequest;
        return entry;
    }

    pub fn retire(self: *Table, ticket: Ticket) Error!void {
        _ = try self.entryFor(ticket);
        _ = self.take(ticket.direction, ticket.slot);
    }

    pub fn cancel(self: *Table, direction: rpc.Direction, id_value: rpc.Id) Error!Ticket {
        if (self.closed) return error.Closed;
        return self.take(direction, try self.requireId(direction, id_value));
    }

    pub fn expireNext(self: *Table, now_ms: u64) ?Ticket {
        if (self.closed) return null;
        for (directions) |direction| {
            for (self.slotsFor(direction), 0..) |maybe_entry, slot| {
                const entry = maybe_entry orelse continue;
                if (hasExpired(entry, now_ms)) return self.take(direction, slot);
            }
        }
        return null;
    }

    pub fn close(self: *Table) void {
        self.closed = true;
    }

    pub fn drainNext(self: *Table) ?Ticket {
        if (!self.closed) return null;
        for (directions) |direction| {
            for (self.slotsFor(direction), 0..) |entry, slot| {
                if (entry != null) return self.take(direction, slot);
            }
        }
        return null;
    }

    const directions = [_]rpc.Direction{ .outbound, .inbound };

    fn slotsFor(self: *const Table, direction: rpc.Direction) []?Entry {
        return switch (direction) {
            .inbound => self.inbound,
            .outbound => self.outbound,
        };
    }

    fn ticketAt(self: *const Table, direction: rpc.Direction, slot: usize, sequence: u64) Ticket {
        return .{ .table = self, .direction = direction, .slot = slot, .sequence = sequence };
    }

    fn take(self: *Table, direction: rpc.Direction, slot: usize) Ticket {
        const slots = self.slotsFor(direction);
        const entry = slots[slot].?;
        if (entry.id == .string) self.allocator.free(entry.id.string);
        slots[slot] = null;
        return self.ticketAt(direction, slot, entry.sequence);
    }

    fn lookup(self: *const Table, direction: rpc.Direction, id_value: rpc.Id) ?usize {
        for (self.slotsFor(direction), 0..) |maybe_entry, slot| {
            const entry = maybe_entry orelse continue;
            if (entry.id.eql(id_value)) return slot;
        }
        return null;
    }

    fn requireId(self: *const Table, direction: rpc.Direction, id_value: rpc.Id) Error!usize {
        if (self.lookup(direction, id_value)) |slot| return slot;
        if (direction == .outbound and id_value == .number and
            id_value.number > 0 and id_value.number <= self.outbound_sequence) return error.RetiredId;
        return error.UnknownId;
    }
};

fn findEmpty(slots: []const ?Entry) ?usize {
    for (slots, 0..) |entry, slot| {
        if (entry == null) return slot;
    }
    return null;
}

fn hasExpired(entry: Entry, now_ms: u64) bool {
    const deadline = entry.deadline_ms orelse return false;
    return now_ms >= deadline;
}
