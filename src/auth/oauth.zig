const std = @import("std");
const builtin = @import("builtin");
const foo = @import("foo");
const root = @import("root.zig");
const Allocator = std.mem.Allocator;
const Error = root.Error;
const OAuth = root.OAuth;

pub const Param = struct { name: []const u8, value: []const u8 };

pub const Pkce = struct {
    verifier: [43]u8,
    challenge: [43]u8,

    pub fn generate(io: std.Io) Error!Pkce {
        var bytes: [32]u8 = undefined;
        io.randomSecure(&bytes) catch return error.IoFailure;
        var pkce: Pkce = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&pkce.verifier, &bytes);
        pkce.challenge = challenge(&pkce.verifier);
        return pkce;
    }
};

pub fn challenge(verifier: []const u8) [43]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var encoded: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &digest);
    return encoded;
}

pub fn state(io: std.Io) Error![32]u8 {
    var bytes: [16]u8 = undefined;
    io.randomSecure(&bytes) catch return error.IoFailure;
    return std.fmt.bytesToHex(bytes, .lower);
}

pub fn form(a: Allocator, params: []const Param) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (params, 0..) |param, i| {
        if (i != 0) try out.append(a, '&');
        try percentEncode(a, &out, param.name);
        try out.append(a, '=');
        try percentEncode(a, &out, param.value);
    }
    return out.items;
}

pub fn authorizeUrl(a: Allocator, endpoint: []const u8, params: []const Param) Error![]const u8 {
    return std.mem.concat(a, u8, &.{ endpoint, "?", try form(a, params) });
}

fn percentEncode(a: Allocator, out: *std.ArrayList(u8), text: []const u8) Error!void {
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null) {
            try out.append(a, byte);
        } else {
            const hex = std.fmt.bytesToHex([1]u8{byte}, .upper);
            try out.appendSlice(a, &.{ '%', hex[0], hex[1] });
        }
    }
}

pub const Tokens = struct { oauth: OAuth, id_token: ?[]const u8 = null };

const max_lifetime_s = 10 * 365 * 24 * 3600;

pub fn parseTokens(a: Allocator, now_ms: i64, body: []const u8) Error!Tokens {
    const Wire = struct {
        access_token: []const u8,
        refresh_token: ?[]const u8 = null,
        expires_in: i64,
        id_token: ?[]const u8 = null,
    };
    const wire = std.json.parseFromSliceLeaky(Wire, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Authentication,
    };
    if (wire.access_token.len == 0 or wire.expires_in <= 0 or wire.expires_in > max_lifetime_s) return error.Authentication;
    return .{
        .oauth = .{
            .access = wire.access_token,
            .refresh = if (wire.refresh_token) |token| if (token.len == 0) null else token else null,
            .expires_ms = now_ms +| wire.expires_in * 1000,
        },
        .id_token = wire.id_token,
    };
}

/// Reads a string claim at `path`. The token came from the issuer over TLS and
/// only selects an account header, so the signature is not checked.
pub fn jwtClaim(a: Allocator, token: []const u8, path: []const []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return null;
    const payload = std.mem.trimEnd(u8, parts.next() orelse return null, "=");
    _ = parts.next() orelse return null;
    if (parts.next() != null) return null;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(payload) catch return null;
    const bytes = a.alloc(u8, size) catch return null;
    decoder.decode(bytes, payload) catch return null;
    var value = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return null;
    for (path) |key| {
        if (value != .object) return null;
        value = value.object.get(key) orelse return null;
    }
    return if (value == .string and value.string.len != 0) value.string else null;
}

pub fn errorCode(a: Allocator, body: []const u8) ?[]const u8 {
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return null;
    if (value != .object) return null;
    const failure = value.object.get("error") orelse return null;
    return switch (failure) {
        .string => |code| code,
        .object => |object| if (object.get("code")) |code| if (code == .string) code.string else null else null,
        else => null,
    };
}

pub fn statusError(status: u16) Error {
    return switch (status) {
        429, 500...599 => error.Unavailable,
        else => error.Authentication,
    };
}

pub const Client = struct {
    a: Allocator,
    operation: foo.io.Context,
    http: foo.io.HttpTransport,

    pub const Body = union(enum) { form: []const Param, json: []const u8 };
    pub const Response = struct { status: u16, body: []const u8 };

    const max_response_bytes = 64 * 1024;

    pub fn post(self: Client, url: []const u8, body: Body) Error!Response {
        try self.operation.check();
        const bytes, const content_type = switch (body) {
            .form => |params| .{ try form(self.a, params), "application/x-www-form-urlencoded" },
            .json => |json| .{ json, "application/json" },
        };
        var collector: Collector = .{ .a = self.a };
        var delivery: foo.io.Delivery = .unsent;
        try self.http.exchange_fn(self.http.context, self.operation, .{
            .method = .post,
            .url = url,
            .headers = &.{ .{ .name = "content-type", .value = content_type }, .{ .name = "accept", .value = "application/json" } },
            .body = .{ .bytes = bytes },
            .max_response_bytes = max_response_bytes,
        }, .{ .context = &collector, .head_fn = Collector.head, .body = .{ .context = &collector, .write_fn = Collector.write } }, &delivery);
        return .{ .status = collector.status orelse return error.Disconnected, .body = collector.body.items };
    }

    pub fn tokens(self: Client, url: []const u8, params: []const Param) Error!Tokens {
        const response = try self.post(url, .{ .form = params });
        if (response.status < 200 or response.status > 299) return statusError(response.status);
        return parseTokens(self.a, std.Io.Timestamp.now(self.operation.io, .real).toMilliseconds(), response.body);
    }

    pub fn exchangeCode(self: Client, url: []const u8, client_id: []const u8, code: []const u8, verifier: []const u8, redirect_uri: []const u8) Error!Tokens {
        return self.tokens(url, &.{
            .{ .name = "grant_type", .value = "authorization_code" },
            .{ .name = "client_id", .value = client_id },
            .{ .name = "code", .value = code },
            .{ .name = "code_verifier", .value = verifier },
            .{ .name = "redirect_uri", .value = redirect_uri },
        });
    }

    /// Keeps the current refresh token when the issuer does not rotate it.
    pub fn refresh(self: Client, url: []const u8, client_id: []const u8, current: OAuth) Error!Tokens {
        const token = current.refresh orelse return error.Authentication;
        var result = try self.tokens(url, &.{
            .{ .name = "grant_type", .value = "refresh_token" },
            .{ .name = "client_id", .value = client_id },
            .{ .name = "refresh_token", .value = token },
        });
        if (result.oauth.refresh == null) result.oauth.refresh = token;
        return result;
    }

    const Collector = struct {
        a: Allocator,
        status: ?u16 = null,
        body: std.ArrayList(u8) = .empty,

        fn head(context: *anyopaque, _: foo.io.Context, value: foo.io.HttpHead) foo.io.Error!void {
            const self: *Collector = @ptrCast(@alignCast(context));
            self.status = value.status;
        }

        fn write(context: *anyopaque, _: foo.io.Context, bytes: []const u8) foo.io.Error!void {
            const self: *Collector = @ptrCast(@alignCast(context));
            if (bytes.len > max_response_bytes - self.body.items.len) return error.LimitExceeded;
            try self.body.appendSlice(self.a, bytes);
        }
    };
};

pub fn Poll(comptime T: type) type {
    return union(enum) { pending, slow_down, done: T };
}

pub const Schedule = struct {
    interval_ms: u64 = 5_000,
    expires_ms: u64,
    wait_first: bool = false,
    sleep: *const fn (foo.io.Context, u64) Error!void = sleep,
};

const min_interval_ms = 1_000;
const slow_down_ms = 5_000;

pub fn pollDevice(comptime T: type, operation: foo.io.Context, schedule: Schedule, poller: anytype) Error!T {
    const deadline = operation.clock.now() +| schedule.expires_ms;
    var interval = @max(schedule.interval_ms, min_interval_ms);
    if (schedule.wait_first) try schedule.sleep(operation, @min(interval, schedule.expires_ms));
    while (operation.clock.now() < deadline) {
        try operation.check();
        switch (try poller.poll()) {
            .done => |value| return value,
            .pending => {},
            .slow_down => interval +|= slow_down_ms,
        }
        const now = operation.clock.now();
        if (now >= deadline) break;
        try schedule.sleep(operation, @min(interval, deadline - now));
    }
    return error.DeadlineExceeded;
}

fn sleep(operation: foo.io.Context, ms: u64) Error!void {
    var remaining = ms;
    while (remaining != 0) {
        try operation.check();
        const step = @min(remaining, 100);
        std.Io.sleep(operation.io, .fromMilliseconds(@intCast(step)), .awake) catch return error.Cancelled;
        remaining -= step;
    }
    try operation.check();
}

pub const Redirect = union(enum) { unrelated, rejected, code: []const u8 };

pub fn parseCallback(a: Allocator, target: []const u8, path: []const u8, expected_state: []const u8) Error!Redirect {
    const split = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    if (!std.mem.eql(u8, target[0..split], path)) return .unrelated;
    var code: ?[]const u8 = null;
    var received: ?[]const u8 = null;
    var pairs = std.mem.splitScalar(u8, if (split == target.len) "" else target[split + 1 ..], '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const name = try decode(a, pair[0..equals]);
        const slot = if (std.mem.eql(u8, name, "code")) &code else if (std.mem.eql(u8, name, "state")) &received else continue;
        if (slot.* != null) return .rejected;
        slot.* = try decode(a, if (equals == pair.len) "" else pair[equals + 1 ..]);
    }
    if (!std.mem.eql(u8, received orelse return .rejected, expected_state)) return .rejected;
    const value = code orelse return .rejected;
    return if (value.len == 0) .rejected else .{ .code = value };
}

fn decode(a: Allocator, text: []const u8) Error![]const u8 {
    const copy = try a.dupe(u8, text);
    for (copy) |*byte| if (byte.* == '+') {
        byte.* = ' ';
    };
    return std.Uri.percentDecodeInPlace(copy);
}

pub const Callback = struct {
    server: std.Io.net.Server,

    pub fn listen(io: std.Io, port: u16) Error!Callback {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        // A finished callback leaves the port in TIME_WAIT, which would block a retry. On Windows the same flag lets another process take a bound port.
        return .{ .server = address.listen(io, .{ .reuse_address = builtin.os.tag != .windows }) catch |err| return switch (err) {
            error.Canceled => error.Cancelled,
            else => error.Unavailable,
        } };
    }

    pub fn boundPort(self: *const Callback) u16 {
        return self.server.socket.address.getPort();
    }

    pub fn close(self: *Callback, io: std.Io) void {
        self.server.deinit(io);
    }

    /// Returns the authorization code, or null when no matching callback arrives in time.
    /// A callback with the wrong state ends the wait with `Authentication`.
    pub fn wait(self: *Callback, a: Allocator, operation: foo.io.Context, path: []const u8, expected_state: []const u8, timeout_ms: u64) Error!?[]const u8 {
        const io = operation.io;
        var done: std.Io.Event = .unset;
        var task = io.concurrent(serve, .{ &self.server, a, io, path, expected_state, &done }) catch return error.Unavailable;
        const deadline = operation.clock.now() +| timeout_ms;
        while (!done.isSet()) {
            operation.check() catch |err| {
                if (task.cancel(io)) |_| {} else |_| {}
                return err;
            };
            if (operation.clock.now() >= deadline) {
                if (task.cancel(io)) |_| {} else |_| {}
                return null;
            }
            done.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch |err| switch (err) {
                error.Canceled => {
                    if (task.cancel(io)) |_| {} else |_| {}
                    return error.Cancelled;
                },
                error.Timeout => {},
            };
        }
        return try task.await(io);
    }

    const max_request_bytes = 8 * 1024;
    const read_timeout_ms = 2_000;

    fn serve(server: *std.Io.net.Server, a: Allocator, io: std.Io, path: []const u8, expected_state: []const u8, done: *std.Io.Event) Error![]const u8 {
        defer done.set(io);
        while (true) {
            const stream = server.accept(io) catch |err| return switch (err) {
                error.Canceled => error.Cancelled,
                error.ConnectionAborted => continue,
                else => error.IoFailure,
            };
            defer stream.close(io);
            var buffer: [max_request_bytes]u8 = undefined;
            const target = readTarget(io, stream, &buffer) catch |err| switch (err) {
                error.Cancelled => return error.Cancelled,
                error.Malformed => {
                    respond(io, stream, "400 Bad Request", "Bad request.");
                    continue;
                },
            };
            switch (try parseCallback(a, target, path, expected_state)) {
                .unrelated => respond(io, stream, "404 Not Found", "Not found."),
                .rejected => {
                    respond(io, stream, "400 Bad Request", "Login failed. Return to the terminal and run foo auth login again.");
                    return error.Authentication;
                },
                .code => |code| {
                    respond(io, stream, "200 OK", "Login complete. You can close this tab.");
                    return code;
                },
            }
        }
    }

    fn readTarget(io: std.Io, stream: std.Io.net.Stream, buffer: []u8) error{ Cancelled, Malformed }![]const u8 {
        // Browsers open speculative connections that never send; drop them so the real request is accepted.
        // operateTimeout cannot time out a socket read on Windows, so the read runs as a task under a timed wait.
        var ready: std.Io.Event = .unset;
        var task = io.concurrent(readHead, .{ io, stream, buffer, &ready }) catch return error.Malformed;
        ready.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(read_timeout_ms), .clock = .awake } }) catch |err| {
            if (task.cancel(io)) |_| {} else |_| {}
            return if (err == error.Canceled) error.Cancelled else error.Malformed;
        };
        const used = try task.await(io);
        const line = buffer[0 .. std.mem.indexOf(u8, buffer[0..used], "\r\n") orelse unreachable];
        var fields = std.mem.splitScalar(u8, line, ' ');
        if (!std.mem.eql(u8, fields.next() orelse "", "GET")) return error.Malformed;
        const target = fields.next() orelse return error.Malformed;
        if (!std.mem.startsWith(u8, fields.next() orelse "", "HTTP/1.") or fields.next() != null) return error.Malformed;
        return target;
    }

    fn readHead(io: std.Io, stream: std.Io.net.Stream, buffer: []u8, ready: *std.Io.Event) error{ Cancelled, Malformed }!usize {
        defer ready.set(io);
        var used: usize = 0;
        while (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n") == null) {
            if (used == buffer.len) return error.Malformed;
            var slices = [_][]u8{buffer[used..]};
            const n = stream.read(io, &slices) catch |err| return switch (err) {
                error.Canceled => error.Cancelled,
                else => error.Malformed,
            };
            if (n == 0) return error.Malformed;
            used += n;
        }
        return used;
    }

    fn respond(io: std.Io, stream: std.Io.net.Stream, status: []const u8, message: []const u8) void {
        var head: [256]u8 = undefined;
        const bytes = std.fmt.bufPrint(&head, "HTTP/1.1 {s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, message.len }) catch return;
        var buffer: [512]u8 = undefined;
        var writer = stream.writer(io, &buffer);
        writer.interface.writeAll(bytes) catch return;
        writer.interface.writeAll(message) catch return;
        writer.interface.flush() catch {};
    }
};
