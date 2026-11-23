const std = @import("std");
const foo = @import("foo");
const io = foo.io;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Mode = enum {
    stream,
    replay,
    redirect,
    proxy,
    proxy_rejected,
    proxy_limited,
    trusted,
    tls_failure,
    first_byte_deadline,
    body_cancel,
    tls_cancel,
    tls_deadline,
    truncated,
    limits,
    refused,
};

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    const mode = std.meta.stringToEnum(Mode, args.next() orelse return error.MissingMode) orelse
        return error.UnknownMode;
    const url = args.next() orelse return error.MissingUrl;
    const extra = args.next();
    const ca_path = args.next();

    const ca_pem = if (ca_path) |path|
        try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(8192))
    else
        null;
    defer if (ca_pem) |bytes| init.gpa.free(bytes);

    const runtime = try foo.transport.Runtime.init();
    defer runtime.deinit();
    var client = try runtime.client(init.gpa, .{
        .ca_pem = ca_pem,
        .proxy = switch (mode) {
            .proxy, .proxy_rejected, .proxy_limited => .{ .http = .{
                .url = extra orelse return error.MissingProxyUrl,
                .basic = .{ .username = "fixture-user", .password = "fixture-password" },
            } },
            else => .direct,
        },
        .limits = if (mode == .limits or mode == .proxy_limited) .{
            .request_bytes = 16,
            .header_bytes = 128,
            .header_count = 5,
        } else .{},
    });
    defer client.deinit();

    var probe: Probe = .{ .system_io = init.io, .http = client.interface() };
    switch (mode) {
        .stream => try stream(&probe, url),
        .replay => try replay(&probe, url),
        .redirect => try redirect(&probe, url, extra orelse return error.MissingRedirectUrl),
        .proxy => {
            const response = try probe.success(authorizedRequest(url));
            try response.expect(200, "through tunnel");
        },
        .proxy_rejected => {
            const result = probe.exchange(authorizedRequest(url), .normal, null, 5000);
            try result.expectError(error.IoFailure, .unsent);
        },
        .proxy_limited => {
            const result = probe.exchange(authorizedRequest(url), .normal, null, 5000);
            try result.expectError(error.LimitExceeded, .unsent);
        },
        .trusted => try (try probe.success(request(url))).expect(200, "trusted"),
        .tls_failure => {
            try probe.exchange(request(url), .normal, null, 5000).expectError(
                error.IoFailure,
                .unsent,
            );
        },
        .first_byte_deadline, .tls_deadline => {
            try probe.exchange(request(url), .normal, null, 750).expectError(
                error.DeadlineExceeded,
                if (mode == .tls_deadline) .unsent else .possibly_sent,
            );
            try recovery(&probe, extra orelse return error.MissingRecoveryUrl);
        },
        .body_cancel, .tls_cancel => {
            var cancellation: io.Cancellation = .{};
            const worker = try std.Thread.spawn(.{}, cancelOnInput, .{ init.io, &cancellation });
            defer worker.join();
            const tls = mode == .tls_cancel;
            const result = probe.exchange(request(url), if (tls) .normal else .announce, &cancellation, 5000);
            try result.expectError(error.Cancelled, if (tls) .unsent else .possibly_sent);
            if (!tls) try result.response.expect(200, "part");
            try recovery(&probe, extra orelse return error.MissingRecoveryUrl);
        },
        .truncated => {
            const result = probe.exchange(request(url), .normal, null, 5000);
            try result.expectError(error.Disconnected, .possibly_sent);
            try result.response.expect(200, "part");
            try recovery(&probe, extra orelse return error.MissingRecoveryUrl);
        },
        .limits => try limits(&probe, url, extra orelse return error.MissingRecoveryUrl),
        .refused => {
            try probe.exchange(request(url), .normal, null, 5000).expectError(
                error.Disconnected,
                .unsent,
            );
            try recovery(&probe, extra orelse return error.MissingRecoveryUrl);
        },
    }
}

const Probe = struct {
    system_io: std.Io,
    http: io.HttpTransport,
    active: io.Cancellation = .{},

    fn now(context: *anyopaque) u64 {
        const system_io: *std.Io = @ptrCast(@alignCast(context));
        return @intCast(std.Io.Clock.awake.now(system_io.*).toMilliseconds());
    }

    fn exchange(
        self: *Probe,
        req: io.HttpRequest,
        gate: Response.Gate,
        cancellation: ?*const io.Cancellation,
        deadline_ms: u64,
    ) Result {
        var result: Result = .{ .response = .{ .gate = gate } };
        const operation: io.Context = .{
            .io = self.system_io,
            .cancellation = cancellation orelse &self.active,
            .clock = .{ .context = &self.system_io, .now_fn = now },
            .deadline_ms = now(&self.system_io) + deadline_ms,
        };
        self.http.exchange_fn(self.http.context, operation, req, result.response.sink(), &result.delivery) catch |err| {
            result.failure = err;
        };
        return result;
    }

    fn success(self: *Probe, req: io.HttpRequest) !Response {
        const result = self.exchange(req, .normal, null, 5000);
        return result.expectSuccess();
    }
};

const Result = struct {
    response: Response,
    delivery: io.Delivery = .possibly_sent,
    failure: ?io.Error = null,

    fn expectSuccess(self: *const Result) !Response {
        if (self.failure) |err| return err;
        try expectEqual(io.Delivery.possibly_sent, self.delivery);
        return self.response;
    }

    fn expectError(self: Result, failure: io.Error, delivery: io.Delivery) !void {
        try expectEqual(@as(?io.Error, failure), self.failure);
        try expectEqual(delivery, self.delivery);
        if (delivery == .unsent) try self.response.expect(null, "");
    }
};

const Response = struct {
    const Gate = enum { normal, announce, wait_for_input };

    gate: Gate,
    status: ?u16 = null,
    body: [64]u8 = undefined,
    body_len: usize = 0,
    location: [128]u8 = undefined,
    location_len: usize = 0,
    retry_after: ?u16 = null,

    fn sink(self: *Response) io.HttpSink {
        return .{
            .context = self,
            .head_fn = head,
            .body = .{ .context = self, .write_fn = write },
        };
    }

    fn head(context: *anyopaque, _: io.Context, value: io.HttpHead) io.Error!void {
        const self: *Response = @ptrCast(@alignCast(context));
        if (self.status != null) return error.InvalidInput;
        self.status = value.status;
        for (value.headers) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "location")) {
                if (header.value.len > self.location.len) return error.LimitExceeded;
                @memcpy(self.location[0..header.value.len], header.value);
                self.location_len = header.value.len;
            }
            if (std.ascii.eqlIgnoreCase(header.name, "retry-after"))
                self.retry_after = std.fmt.parseInt(u16, header.value, 10) catch return error.InvalidInput;
        }
    }

    fn write(context: *anyopaque, operation: io.Context, bytes: []const u8) io.Error!void {
        const self: *Response = @ptrCast(@alignCast(context));
        if (self.status == null) return error.InvalidInput;
        if (bytes.len > self.body.len - self.body_len) return error.LimitExceeded;
        const first = self.body_len == 0;
        @memcpy(self.body[self.body_len..][0..bytes.len], bytes);
        self.body_len += bytes.len;
        if (first and self.gate != .normal) {
            std.Io.File.stdout().writeStreamingAll(operation.io, "body\n") catch return error.IoFailure;
            if (self.gate == .wait_for_input and !readSignal(operation.io)) return error.IoFailure;
        }
    }

    fn expect(self: Response, status: ?u16, body: []const u8) !void {
        try expectEqual(status, self.status);
        try expectEqualStrings(body, self.body[0..self.body_len]);
    }
};

const Upload = struct {
    remaining: []const u8,

    fn body(self: *Upload, content_length: ?u64) io.HttpBody {
        return .{ .stream = .{
            .source = .{ .context = self, .read_fn = read },
            .content_length = content_length,
        } };
    }

    fn read(context: *anyopaque, operation: io.Context, buffer: []u8) io.Error!usize {
        try operation.check();
        const self: *Upload = @ptrCast(@alignCast(context));
        if (buffer.len == 0) return error.InvalidInput;
        const count = @min(3, buffer.len, self.remaining.len);
        @memcpy(buffer[0..count], self.remaining[0..count]);
        self.remaining = self.remaining[count..];
        return count;
    }
};

fn readSignal(system_io: std.Io) bool {
    var byte: [1]u8 = undefined;
    return (std.Io.File.stdin().readStreaming(system_io, &.{&byte}) catch 0) == 1;
}

fn cancelOnInput(system_io: std.Io, cancellation: *io.Cancellation) void {
    if (readSignal(system_io)) cancellation.request();
}

fn request(url: []const u8) io.HttpRequest {
    return .{ .method = .get, .url = url, .max_response_bytes = 64 };
}

fn authorizedRequest(url: []const u8) io.HttpRequest {
    var req = request(url);
    req.headers = &.{
        .{ .name = "Authorization", .value = "Bearer origin-fixture" },
        .{ .name = "Cookie", .value = "session=origin-fixture" },
    };
    return req;
}

fn recovery(probe: *Probe, url: []const u8) !void {
    try (try probe.success(request(url))).expect(200, "recovered");
}

fn stream(probe: *Probe, url: []const u8) !void {
    var req = request(url);
    req.method = .post;
    var known: Upload = .{ .remaining = "known upload" };
    req.body = known.body(known.remaining.len);
    const first = probe.exchange(req, .wait_for_input, null, 5000);
    try (try first.expectSuccess()).expect(200, "alpha beta");
    try expectEqualStrings("", known.remaining);

    var unknown: Upload = .{ .remaining = "chunked upload" };
    req.body = unknown.body(null);
    try (try probe.success(req)).expect(200, "chunked reply");
    try expectEqualStrings("", unknown.remaining);
}

fn replay(probe: *Probe, url: []const u8) !void {
    try (try probe.success(request(url))).expect(200, "seed");
    var req = request(url);
    req.method = .post;
    try probe.exchange(req, .normal, null, 5000).expectError(error.Disconnected, .possibly_sent);
    try recovery(probe, url);
}

fn redirect(probe: *Probe, url: []const u8, location: []const u8) !void {
    const result = try probe.success(authorizedRequest(url));
    try result.expect(307, "");
    try expectEqualStrings(location, result.location[0..result.location_len]);

    const explicit = try probe.success(request(location));
    try explicit.expect(429, "later");
    try expectEqual(@as(?u16, 3), explicit.retry_after);
}

fn limits(probe: *Probe, url: []const u8, recovery_url: []const u8) !void {
    var req = request(url);
    req.method = .post;
    req.body = .{ .bytes = "0123456789abcdef!" };
    try probe.exchange(req, .normal, null, 5000).expectError(error.LimitExceeded, .unsent);

    req.body = .{ .bytes = "" };
    req.headers = &.{.{ .name = "Content-Length", .value = "1" }};
    try probe.exchange(req, .normal, null, 5000).expectError(error.InvalidInput, .unsent);
    req.headers = &@as([2]io.Header, @splat(.{
        .name = "X-Large",
        .value = &@as([64]u8, @splat('x')),
    }));
    try probe.exchange(req, .normal, null, 5000).expectError(error.LimitExceeded, .unsent);
    req.headers = &@as([6]io.Header, @splat(.{ .name = "X", .value = "a" }));
    try probe.exchange(req, .normal, null, 5000).expectError(error.LimitExceeded, .unsent);

    req = request(url);
    for (0..2) |_| {
        const result = probe.exchange(req, .normal, null, 5000);
        try result.expectError(error.LimitExceeded, .possibly_sent);
        try expectEqual(@as(?u16, null), result.response.status);
    }

    req.max_response_bytes = 4;
    const response_limit = probe.exchange(req, .announce, null, 5000);
    try response_limit.expectError(error.LimitExceeded, .possibly_sent);
    try response_limit.response.expect(200, "part");

    var upload: Upload = .{ .remaining = "0123456789abcdef!" };
    req.method = .post;
    req.body = upload.body(null);
    try probe.exchange(req, .normal, null, 5000).expectError(error.LimitExceeded, .possibly_sent);
    try recovery(probe, recovery_url);
}
