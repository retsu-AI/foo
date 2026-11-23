const std = @import("std");
const foo = @import("foo");

pub const Error = foo.io.Error || error{
    MalformedPeer,
    UnsupportedRevision,
    UnsupportedAuthentication,
    SessionExpired,
    StreamUnsupported,
    RpcFailure,
    UnsupportedCapability,
};

pub const Mode = enum { request, subscription, legacy_notifications };

pub const Request = struct {
    revision: foo.config.McpRevision,
    id: ?foo.jsonrpc.Id,
    method: []const u8,
    body: []const u8,
    mode: Mode = .request,
    name: ?[]const u8 = null,
    headers: []const foo.io.Header = &.{},
};

pub const Reply = union(enum) {
    accepted,
    success: []const u8,
    failure: foo.jsonrpc.RpcError,
};

pub const Observer = struct {
    context: *anyopaque,
    notify_fn: *const fn (*anyopaque, foo.io.Context, foo.jsonrpc.Request) foo.io.Error!void,

    pub fn notify(self: ?Observer, op: foo.io.Context, message: foo.jsonrpc.Request) foo.io.Error!void {
        if (self) |observer| try observer.notify_fn(observer.context, op, message);
    }
};

pub const Link = struct {
    context: *anyopaque,
    exchange_fn: *const fn (*anyopaque, std.mem.Allocator, foo.io.Context, Request, ?Observer, *foo.io.Delivery) Error!Reply,
    shutdown_fn: *const fn (*anyopaque, foo.io.Context) Error!void,

    pub fn exchange(self: Link, allocator: std.mem.Allocator, op: foo.io.Context, request: Request, observer: ?Observer, delivery: *foo.io.Delivery) Error!Reply {
        delivery.* = .unsent;
        try op.check();
        return self.exchange_fn(self.context, allocator, op, request, observer, delivery);
    }

    pub fn shutdown(self: Link, cleanup: foo.io.Context) Error!void {
        return self.shutdown_fn(self.context, cleanup);
    }
};

pub fn copyReply(allocator: std.mem.Allocator, expected: foo.jsonrpc.Id, response: foo.jsonrpc.Response) Error!Reply {
    return switch (response) {
        .success => |message| if (expected.eql(message.id))
            .{ .success = try allocator.dupe(u8, message.result_json) }
        else
            error.MalformedPeer,
        .failure => |message| result: {
            const id = message.id orelse return error.MalformedPeer;
            if (!expected.eql(id)) return error.MalformedPeer;
            const text = try allocator.dupe(u8, message.err.message);
            errdefer allocator.free(text);
            const data = if (message.err.data_json) |raw| try allocator.dupe(u8, raw) else null;
            break :result .{ .failure = .{ .code = message.err.code, .message = text, .data_json = data } };
        },
    };
}
