const std = @import("std");
const foo = @import("foo");
const auth = @import("auth");
const c = @import("common.zig");
const request_codec = @import("request.zig");
const framing = foo.wire.framing;
const io = foo.io;
const p = foo.provider;

pub const Adapter = struct {
    transport: io.HttpTransport,
    credentials: ?auth.CredentialSource = null,
    environment: ?*const std.process.Environ.Map = null,
    retry_attempts: u32 = 0,
    scratch_allocator: std.mem.Allocator = std.heap.page_allocator,
    /// One adapter serves one runtime session, so the key stays stable across turns.
    session_key: ?[32]u8 = null,

    pub fn interface(self: *Adapter) p.Provider {
        return .{ .context = self, .stream_fn = stream };
    }

    fn stream(context: *anyopaque, result: std.mem.Allocator, operation: io.Context, request: p.Request, sink: p.Sink, delivery: *io.Delivery) p.Error!p.Response {
        const self: *Adapter = @ptrCast(@alignCast(context));
        delivery.* = .unsent;
        try operation.check();
        var arena = std.heap.ArenaAllocator.init(self.scratch_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const body = try request_codec.encode(a, request);
        const flags = try request_codec.chatOptions(a, request);
        const environment = auth.Resolver{ .environment = self.environment };
        const credentials = self.credentials orelse environment.interface();
        var attempt: u32 = 0;
        var refreshed = false;
        while (true) {
            try operation.check();
            delivery.* = .unsent;
            var attempt_arena = std.heap.ArenaAllocator.init(self.scratch_allocator);
            defer attempt_arena.deinit();
            const scratch = attempt_arena.allocator();
            const reference = request.model.credential;
            const credential: ?auth.Credential = if (reference == .none) null else credentials.resolve(scratch, operation, reference) catch |err| return credentialError(err);
            const request_headers = try self.headers(scratch, operation, request, credential);
            var exchange = try Exchange.init(scratch, self.scratch_allocator, operation, request, sink);
            exchange.reducer = switch (request.model.family) {
                .openai_responses => .{ .openai_responses = .{} },
                .openai_chat => .{ .openai_chat = .{ .reasoning_content = flags.reasoning_content, .litellm = flags.litellm } },
                .anthropic_messages => .{ .anthropic_messages = .{} },
            };
            const exchanged = self.transport.exchange_fn(self.transport.context, operation, .{
                .method = .post,
                .url = request.model.endpoint,
                .headers = request_headers,
                .body = .{ .bytes = body },
                .max_response_bytes = request.limits.transcript_bytes,
            }, .{ .context = &exchange, .head_fn = Exchange.head, .body = .{ .context = &exchange, .write_fn = Exchange.body } }, delivery);
            if (exchange.failure) |failure| {
                if (failure == error.Authentication and exchange.status == 401 and !refreshed and credential != null and credential.? == .bearer) {
                    const did_refresh = credentials.refresh(scratch, operation, reference, credential.?.bearer) catch |err| return credentialError(err);
                    if (did_refresh) {
                        refreshed = true;
                        continue;
                    }
                }
                return exchange.report(sink, failure);
            }
            exchanged catch |err| {
                const transient = err == error.Unavailable or err == error.Disconnected;
                if (transient and delivery.* == .unsent and exchange.status == null and exchange.received.used == 0 and attempt < self.retry_attempts) {
                    attempt += 1;
                    continue;
                }
                return err;
            };
            try operation.check();
            if (exchange.status == null) return error.Disconnected;
            exchange.sse.finish(operation) catch |err| return mapFraming(err);
            return exchange.state.finish(result);
        }
    }

    fn headers(self: *Adapter, a: std.mem.Allocator, operation: io.Context, request: p.Request, credential: ?auth.Credential) p.Error![]const io.Header {
        const model = request.model;
        if (!std.mem.startsWith(u8, model.endpoint, "https://") and !std.mem.startsWith(u8, model.endpoint, "http://")) return error.InvalidInput;
        var headers_list: std.ArrayList(io.Header) = .empty;
        var budget: io.Budget = .{ .limit = request.limits.wire_message_bytes };
        try headers_list.appendSlice(a, &.{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "accept", .value = "text/event-stream" } });
        if (model.family == .anthropic_messages) try headers_list.append(a, .{ .name = "anthropic-version", .value = "2023-06-01" });
        if (credential) |resolved| {
            const key = switch (resolved) {
                .api_key => |value| value,
                .bearer => |bearer| bearer.token,
            };
            const api_key = model.family == .anthropic_messages and resolved == .api_key;
            try budget.take(key.len);
            try headers_list.append(a, .{
                .name = if (api_key) "x-api-key" else "authorization",
                .value = if (api_key) key else try std.fmt.allocPrint(a, "Bearer {s}", .{key}),
            });
        }
        if (credential) |resolved| {
            if (resolved == .bearer) {
                if (resolved.bearer.account) |account| try appendHeader(a, &headers_list, &budget, account.header, account.value);
            }
        }
        if (model.headers.len > 128) return error.LimitExceeded;
        for (model.headers) |header| {
            if (managedHeader(header.name)) return error.InvalidInput;
            const value = auth.resolveValue(self.environment, header.value) catch return error.InvalidInput;
            try appendHeader(a, &headers_list, &budget, header.name, value);
        }
        if (sessionHeader(model.endpoint)) |name| {
            for (headers_list.items) |existing| {
                if (std.ascii.eqlIgnoreCase(existing.name, name)) return headers_list.items;
            }
            try appendHeader(a, &headers_list, &budget, name, try self.sessionKey(operation));
        }
        return headers_list.items;
    }

    fn sessionKey(self: *Adapter, operation: io.Context) p.Error![]const u8 {
        if (self.session_key == null) {
            var bytes: [16]u8 = undefined;
            operation.io.randomSecure(&bytes) catch return error.IoFailure;
            self.session_key = std.fmt.bytesToHex(bytes, .lower);
        }
        return &self.session_key.?;
    }
};

/// Hosts that ask clients to name the conversation so they can route and cache it.
const session_headers = [_]struct { host: []const u8, header: []const u8 }{
    .{ .host = "opencode.ai", .header = "x-opencode-session" },
};

fn sessionHeader(endpoint: []const u8) ?[]const u8 {
    const uri = std.Uri.parse(endpoint) catch return null;
    const host = switch (uri.host orelse return null) {
        .raw, .percent_encoded => |text| text,
    };
    for (session_headers) |entry| {
        if (std.ascii.eqlIgnoreCase(host, entry.host)) return entry.header;
    }
    return null;
}

fn appendHeader(a: std.mem.Allocator, list: *std.ArrayList(io.Header), budget: *io.Budget, name: []const u8, value: []const u8) p.Error!void {
    if (name.len == 0) return error.InvalidInput;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null) return error.InvalidInput;
    for (list.items) |previous| if (std.ascii.eqlIgnoreCase(previous.name, name)) return error.InvalidInput;
    if (!auth.validHeaderValue(value)) return error.InvalidInput;
    try budget.take(name.len);
    try budget.take(value.len);
    try list.append(a, .{ .name = name, .value = value });
}

fn credentialError(err: auth.Error) p.Error {
    return switch (err) {
        error.InsecurePermissions, error.InvalidStore, error.UnsafeStore => error.Authentication,
        else => |shared| shared,
    };
}

fn managedHeader(name: []const u8) bool {
    for ([_][]const u8{
        "authorization", "proxy-authorization", "x-api-key",         "api-key",    "content-type", "accept",  "anthropic-version",
        "host",          "content-length",      "transfer-encoding", "connection", "expect",       "upgrade", "te",
        "trailer",       "keep-alive",
    }) |reserved| if (std.ascii.eqlIgnoreCase(name, reserved)) return true;
    return false;
}

const Reducer = union(foo.config.Family) {
    openai_responses: @import("responses.zig").Reducer,
    openai_chat: @import("chat.zig").Reducer,
    anthropic_messages: @import("anthropic.zig").Reducer,
};

const Exchange = struct {
    state: c.State,
    backing: std.mem.Allocator,
    reducer: Reducer = undefined,
    sse: framing.Sse,
    received: io.Budget,
    status: ?u16 = null,
    failure: ?p.Error = null,
    retry_after_ms: ?u64 = null,

    fn init(a: std.mem.Allocator, backing: std.mem.Allocator, operation: io.Context, request: p.Request, sink: p.Sink) p.Error!Exchange {
        const limit = request.limits.wire_message_bytes;
        const line_limit = std.math.add(usize, limit, 6) catch return error.LimitExceeded;
        return .{
            .state = .{ .a = a, .model = request.model, .limits = request.limits, .operation = operation, .sink = sink, .budget = .{ .limit = request.limits.transcript_bytes } },
            .backing = backing,
            .received = .{ .limit = request.limits.transcript_bytes },
            .sse = framing.Sse.init(.{
                .line = try a.alloc(u8, line_limit),
                .data = try a.alloc(u8, limit),
                .event = try a.alloc(u8, @min(limit, 128)),
                .id = try a.alloc(u8, @min(limit, 1024)),
                .pending_id = try a.alloc(u8, @min(limit, 1024)),
                .max_event_bytes = limit,
            }),
        };
    }

    fn report(self: *const Exchange, sink: p.Sink, err: p.Error) p.Error {
        if (sink.failure) |failure| {
            if (self.status) |status| {
                if (status < 200 or status > 299) failure.status = status;
            }
            if (self.retry_after_ms) |ms| failure.retry_after_ms = ms;
        }
        return err;
    }

    fn fail(self: *Exchange, err: p.Error) io.Error {
        self.failure = err;
        return error.IoFailure;
    }

    fn head(context: *anyopaque, operation: io.Context, value: io.HttpHead) io.Error!void {
        const self: *Exchange = @ptrCast(@alignCast(context));
        try operation.check();
        if (self.status != null) return self.fail(error.Protocol);
        self.status = value.status;
        if (value.status < 200 or value.status > 299) {
            for (value.headers) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) self.retry_after_ms = retryAfter(header.value);
            }
        }
        switch (value.status) {
            200...299 => {},
            401, 403 => return self.fail(error.Authentication),
            429 => return self.fail(error.RateLimited),
            500...599 => return self.fail(error.Unavailable),
            else => return self.fail(error.Rejected),
        }
        // The ChatGPT Codex backend streams without a content type; the SSE framing still validates the body.
        var content_type_seen = false;
        for (value.headers) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "content-type")) continue;
            if (content_type_seen) return self.fail(error.Protocol);
            content_type_seen = true;
            const end = std.mem.indexOfScalar(u8, header.value, ';') orelse header.value.len;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, header.value[0..end], " \t"), "text/event-stream")) return self.fail(error.Protocol);
        }
    }

    fn body(context: *anyopaque, operation: io.Context, bytes: []const u8) io.Error!void {
        const self: *Exchange = @ptrCast(@alignCast(context));
        if (self.status == null or self.failure != null) return self.fail(error.Protocol);
        try self.received.take(bytes.len);
        self.sse.feed(operation, bytes, .{ .context = self, .emit_fn = event }) catch |err| {
            if (self.failure == null) self.failure = mapFraming(err);
            return error.IoFailure;
        };
    }

    fn event(context: *anyopaque, _: io.Context, event_value: framing.Sse.Event) framing.Error!void {
        const self: *Exchange = @ptrCast(@alignCast(context));
        self.reduce(event_value) catch |err| return self.fail(err);
    }

    fn reduce(self: *Exchange, event_value: framing.Sse.Event) p.Error!void {
        if (c.eq(event_value.data, "[DONE]")) {
            switch (self.reducer) {
                .openai_chat => |*chat| return chat.done(&self.state),
                .openai_responses => if (self.state.terminal) return,
                .anthropic_messages => {},
            }
            return error.Protocol;
        }
        var scratch = std.heap.ArenaAllocator.init(self.backing);
        defer scratch.deinit();
        const value = try c.parse(scratch.allocator(), event_value.data, self.state.limits);
        if (value != .object) return error.Protocol;
        if (!c.eq(event_value.event, "message")) {
            if (!c.eq(try c.str(value, "type"), event_value.event)) return error.Protocol;
        }
        switch (self.reducer) {
            inline else => |*reducer| try reducer.event(&self.state, value),
        }
    }
};

/// Only delta-seconds; an HTTP-date needs a wall clock the adapter lacks.
fn retryAfter(value: []const u8) ?u64 {
    const digits = std.mem.trim(u8, value, " \t");
    if (digits.len == 0) return null;
    var seconds: u64 = 0;
    for (digits) |digit| {
        if (!std.ascii.isDigit(digit)) return null;
        seconds = seconds *| 10 +| (digit - '0');
    }
    return seconds *| 1000;
}

fn mapFraming(err: framing.Error) p.Error {
    return switch (err) {
        error.MalformedFrame, error.Closed, error.Busy => error.Protocol,
        error.TruncatedFrame => error.Disconnected,
        else => |e| e,
    };
}
