const std = @import("std");
const curl = @import("curl");
const io = @import("../contracts/io.zig");

fn token(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^`_|~", byte) == null)
            return false;
    }
    return true;
}

fn fieldValue(value: []const u8) bool {
    for (value) |byte| {
        if ((byte < ' ' and byte != '\t') or byte == 0x7f) return false;
    }
    return true;
}

pub const Request = struct {
    list: [*c]curl.curl_slist = null,

    pub fn init(allocator: std.mem.Allocator, fields: []const io.Header, max_bytes: usize, max_fields: usize) io.Error!Request {
        if (fields.len > max_fields) return error.LimitExceeded;
        var byte_budget: io.Budget = .{ .limit = max_bytes };
        var self: Request = .{};
        errdefer self.deinit();

        for (fields) |field| {
            try byte_budget.take(field.name.len);
            try byte_budget.take(field.value.len);
            try byte_budget.take(4);
            if (!token(field.name) or !fieldValue(field.value)) return error.InvalidInput;
            for ([_][]const u8{
                "Host",             "Content-Length",      "Transfer-Encoding", "Expect", "Connection", "Keep-Alive",
                "Proxy-Connection", "Proxy-Authorization", "Upgrade",           "TE",     "Trailer",
            }) |reserved| {
                if (std.ascii.eqlIgnoreCase(field.name, reserved)) return error.InvalidInput;
            }

            const line = if (field.value.len == 0)
                try std.fmt.allocPrintSentinel(allocator, "{s};", .{field.name}, 0)
            else
                try std.fmt.allocPrintSentinel(allocator, "{s}: {s}", .{ field.name, field.value }, 0);
            defer allocator.free(line);
            try self.append(line);
        }

        // libcurl interprets a trailing colon without a value as a suppression.
        try self.append("Expect:");
        return self;
    }

    fn append(self: *Request, line: [:0]const u8) io.Error!void {
        self.list = curl.curl_slist_append(self.list, line.ptr) orelse return error.OutOfMemory;
    }

    pub fn deinit(self: *Request) void {
        curl.curl_slist_free_all(self.list);
    }
};

pub const Response = struct {
    proxy_status: ?u16 = null,
    phase: union(enum) { status, fields: u16, body } = .status,
    bytes: []u8,
    fields: []io.Header,
    byte_budget: io.Budget,
    field_budget: io.Budget,
    stored_bytes: usize = 0,
    stored_fields: usize = 0,

    pub fn acceptProxy(self: *Response, line: []const u8) io.Error!void {
        const text = try self.accountLine(line);
        if (text.len == 0) return;
        if (std.mem.startsWith(u8, text, "HTTP/")) {
            self.proxy_status = try parseStatus(text);
        } else {
            _ = try self.accountField(text);
        }
    }

    pub fn accept(self: *Response, line: []const u8) io.Error!?io.HttpHead {
        const text = try self.accountLine(line);
        switch (self.phase) {
            .status => self.phase = .{ .fields = try parseStatus(text) },
            .fields => |status| {
                if (text.len != 0) {
                    const field = try self.accountField(text);
                    if (status >= 200) self.store(field);
                    return null;
                }
                if (status == 101) return error.IoFailure;
                if (status < 200) {
                    self.phase = .status;
                } else {
                    self.phase = .body;
                    return .{ .status = status, .headers = self.fields[0..self.stored_fields] };
                }
            },
            .body => if (text.len != 0) {
                _ = try self.accountField(text);
            },
        }
        return null;
    }

    fn store(self: *Response, field: io.Header) void {
        self.fields[self.stored_fields] = .{
            .name = self.copy(field.name),
            .value = self.copy(field.value),
        };
        self.stored_fields += 1;
    }

    fn copy(self: *Response, text: []const u8) []const u8 {
        const copy_to = self.bytes[self.stored_bytes..][0..text.len];
        @memcpy(copy_to, text);
        self.stored_bytes += text.len;
        return copy_to;
    }

    fn parseStatus(text: []const u8) io.Error!u16 {
        if (text.len < 12 or !(std.mem.startsWith(u8, text, "HTTP/1.1 ") or
            std.mem.startsWith(u8, text, "HTTP/1.0 ")) or (text.len > 12 and text[12] != ' ')) return error.IoFailure;
        for (text[9..12]) |byte| {
            if (!std.ascii.isDigit(byte)) return error.IoFailure;
        }
        const status = std.fmt.parseInt(u16, text[9..12], 10) catch unreachable;
        if (status < 100 or status > 599) return error.IoFailure;
        return status;
    }

    fn accountLine(self: *Response, line: []const u8) io.Error![]const u8 {
        try self.byte_budget.take(line.len);
        if (!std.mem.endsWith(u8, line, "\r\n")) return error.IoFailure;
        return line[0 .. line.len - 2];
    }

    fn accountField(self: *Response, text: []const u8) io.Error!io.Header {
        try self.field_budget.take(1);
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.IoFailure;
        const name = text[0..colon];
        const value = std.mem.trim(u8, text[colon + 1 ..], " \t");
        if (!token(name) or !fieldValue(value)) return error.IoFailure;
        return .{ .name = name, .value = value };
    }
};
