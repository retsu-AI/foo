const std = @import("std");
const foo = @import("foo");
const link = @import("link.zig");
const io = foo.io;
const rpc = foo.jsonrpc;
const wire = foo.wire;
const Sse = wire.framing.Sse;
const Allocator = std.mem.Allocator;
const legacy: foo.config.McpRevision = .@"2025-11-25";
const modern: foo.config.McpRevision = .@"2026-07-28";
const json_type = "application/json";
const sse_type = "text/event-stream";
const protocol_header = "MCP-Protocol-Version";
const session_header = "MCP-Session-Id";
const cursor_header = "Last-Event-ID";
const parameter_prefix = "Mcp-Param-";
const max_headers = 128;
const max_header_bytes = 64 * 1024;
const max_cursor_bytes = 4096;
const max_resume_attempts = 3;
const max_retry_ms = 30_000;

pub const Http = struct {
    pub const Options = struct {
        url: []const u8,
        transport: io.HttpTransport,
        listener: ?io.HttpTransport = null,
        housekeeping: ?io.HttpTransport = null,
        headers: []const io.Header = &.{},
        max_message_bytes: usize = 8 * 1024 * 1024,
        max_stream_bytes: usize = 64 * 1024 * 1024,
        scratch_allocator: Allocator = std.heap.page_allocator,
    };

    const Channel = enum { main, listener, housekeeping };
    const Session = struct { generation: u64, token: Token };
    const SessionState = union(enum) { uninitialized, awaiting_initialized: Session, active: Session, expired };
    const LegacyRequest = enum { initialize, acknowledge, established };

    options: Options,
    mutex: std.Io.Mutex = .init,
    busy: std.EnumArray(Channel, bool) = .initFill(false),
    session: SessionState = .uninitialized,
    generation: u64 = 0,
    closed: bool = false,

    /// Keep the configured URL, headers, and transports alive until deinit.
    /// A listener and a reverse-request reply can overlap the main exchange when
    /// each uses an independent transport.
    pub fn init(options: Options) link.Error!Http {
        if (options.max_message_bytes == 0 or options.max_message_bytes > options.max_stream_bytes or
            options.max_message_bytes > std.math.maxInt(usize) - "data: ".len) return error.InvalidInput;
        if (options.url.len > 8192) return error.LimitExceeded;
        for (options.url) |byte| {
            if (byte <= ' ' or byte == 0x7f or byte == '\\') return error.InvalidInput;
        }
        const uri = std.Uri.parse(options.url) catch return error.InvalidInput;
        if ((!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) or
            uri.host == null or uri.user != null or uri.password != null or uri.fragment != null or
            !std.mem.startsWith(u8, options.url[uri.scheme.len..], "://")) return error.InvalidInput;

        var validated: Headers = .{};
        for (options.headers) |header| {
            if (reserved(header.name)) return error.InvalidInput;
            try validated.add(header.name, header.value);
        }
        const transports = [_]?io.HttpTransport{ options.transport, options.listener, options.housekeeping };
        for (transports, 0..) |entry, index| {
            const present = entry orelse continue;
            for (transports[0..index]) |earlier| {
                if (earlier) |other| {
                    if (present.context == other.context and present.exchange_fn == other.exchange_fn) return error.InvalidInput;
                }
            }
        }
        return .{ .options = options };
    }

    /// Shut down the link and join any active exchange before deinit.
    pub fn deinit(self: *Http) void {
        self.* = undefined;
    }

    pub fn interface(self: *Http) link.Link {
        return .{ .context = self, .kind = .http, .exchange_fn = exchange, .shutdown_fn = shutdown };
    }

    fn exchange(raw: *anyopaque, result: Allocator, op: io.Context, request: link.Request, observer: ?link.Observer, delivery: *io.Delivery) link.Error!link.Reply {
        const self: *Http = @ptrCast(@alignCast(raw));
        const listening = request.mode != .request;
        const channel: Channel = if (listening and self.options.listener != null) .listener else .main;
        try self.claim(op, channel);
        defer self.release(op, channel);

        var arena = std.heap.ArenaAllocator.init(self.options.scratch_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const kind = try classify(request);
        const legacy_request: ?LegacyRequest = if (request.revision != legacy)
            null
        else if (kind == .request and same(request.method, "initialize"))
            .initialize
        else if (kind == .notification and same(request.method, "notifications/initialized"))
            .acknowledge
        else
            .established;
        const initializing = legacy_request == .initialize;
        const session = if (legacy_request) |phase| try self.sessionFor(op, phase) else null;
        const headers = try self.requestHeaders(allocator, request, kind, if (session) |*current| current.token.slice() else "", initializing);

        var pending: Pending = .{
            .http = self,
            .channel = channel,
            .revision = request.revision,
            .id = request.id,
            .observer = observer,
            .session = session,
            .initializing = initializing,
            .discovering = request.revision == modern and same(request.method, "server/discover"),
            .budget = .{ .limit = self.options.max_stream_bytes },
        };
        const reply = pending.run(result, op, kind, headers.slice(), request.body, delivery) catch |err| {
            if ((err == error.Cancelled or err == error.DeadlineExceeded) and delivery.* == .possibly_sent and
                request.revision == legacy and kind == .request and !initializing)
            {
                self.cancelRequest(op, channel, request.id.?, session.?) catch {};
            }
            return err;
        };
        if (initializing and reply == .success) self.beginInitialization(op, pending.token);
        if (legacy_request == .acknowledge and reply == .accepted) self.activate(op, session.?);
        return reply;
    }

    fn shutdown(raw: *anyopaque, cleanup: io.Context) link.Error!void {
        const self: *Http = @ptrCast(@alignCast(raw));
        self.mutex.lockUncancelable(cleanup.io);
        const session: Session = state: {
            defer self.mutex.unlock(cleanup.io);
            if (self.closed) return;
            for (self.busy.values) |busy| {
                if (busy) return error.Unavailable;
            }
            try cleanup.check();
            self.closed = true;
            if (self.session != .active or self.session.active.token.len == 0) return;
            const session = self.session.active;
            self.session = .uninitialized;
            break :state session;
        };
        try self.sendAuxiliary(cleanup, .main, .delete, "", session, session.token.slice());
    }

    fn claim(self: *Http, op: io.Context, channel: Channel) link.Error!void {
        self.mutex.lockUncancelable(op.io);
        defer self.mutex.unlock(op.io);
        try op.check();
        if (self.closed or self.busy.get(channel)) return error.Unavailable;
        self.busy.set(channel, true);
    }

    fn release(self: *Http, op: io.Context, channel: Channel) void {
        self.mutex.lockUncancelable(op.io);
        defer self.mutex.unlock(op.io);
        self.busy.set(channel, false);
    }

    fn transport(self: *const Http, channel: Channel) io.HttpTransport {
        return switch (channel) {
            .main => self.options.transport,
            .listener => self.options.listener.?,
            .housekeeping => self.options.housekeeping.?,
        };
    }

    fn sessionFor(self: *Http, op: io.Context, request: LegacyRequest) link.Error!?Session {
        self.mutex.lockUncancelable(op.io);
        defer self.mutex.unlock(op.io);
        if (request == .initialize) {
            switch (self.session) {
                .uninitialized, .expired => {},
                .awaiting_initialized => self.session = .uninitialized,
                .active => return error.InvalidInput,
            }
            return null;
        }
        return switch (self.session) {
            .uninitialized => error.InvalidInput,
            .expired => error.SessionExpired,
            .awaiting_initialized => |session| if (request == .acknowledge) session else error.InvalidInput,
            .active => |session| if (request == .established) session else error.InvalidInput,
        };
    }

    fn checkSession(self: *Http, op: io.Context, session: Session) link.Error!void {
        self.mutex.lockUncancelable(op.io);
        defer self.mutex.unlock(op.io);
        if (self.session != .active or self.session.active.generation != session.generation) return error.SessionExpired;
    }

    fn beginInitialization(self: *Http, op: io.Context, token: Token) void {
        self.mutex.lockUncancelable(op.io);
        defer self.mutex.unlock(op.io);
        self.generation +%= 1;
        self.session = .{ .awaiting_initialized = .{ .generation = self.generation, .token = token } };
    }

    fn activate(self: *Http, op: io.Context, session: Session) void {
        self.mutex.lockUncancelable(op.io);
        defer self.mutex.unlock(op.io);
        self.session = .{ .active = session };
    }

    fn expire(self: *Http, op: io.Context, session: Session) void {
        self.mutex.lockUncancelable(op.io);
        defer self.mutex.unlock(op.io);
        const current = switch (self.session) {
            .awaiting_initialized, .active => |current| current,
            .uninitialized, .expired => return,
        };
        if (current.generation == session.generation) self.session = .expired;
    }

    fn requestHeaders(self: *Http, allocator: Allocator, request: link.Request, kind: Kind, token: []const u8, initializing: bool) link.Error!Headers {
        var headers = try self.baseHeaders(kind, request.revision, token, initializing);
        if (kind == .listen) {
            if (request.body.len != 0 or request.headers.len != 0 or request.name != null) return error.InvalidInput;
            return headers;
        }
        const message_limits = self.limits();
        if (request.body.len > message_limits.max_bytes) return error.LimitExceeded;
        const scratch = try allocator.alloc(u8, request.body.len);
        const envelope = wire.jsonrpc.decode(request.body, scratch, message_limits) catch |err| return switch (err) {
            error.MessageTooLarge, error.NestingTooDeep => error.LimitExceeded,
            else => error.InvalidInput,
        };
        if (envelope != .request or !same(envelope.request.method, request.method) or
            !sameId(envelope.request.id, request.id)) return error.InvalidInput;
        if (request.revision == legacy) {
            if (request.headers.len != 0) return error.InvalidInput;
            return headers;
        }

        try headers.add("Mcp-Method", envelope.request.method);
        const params = std.json.parseFromSliceLeaky(struct {
            _meta: struct { @"io.modelcontextprotocol/protocolVersion": []const u8 },
            name: ?[]const u8 = null,
            uri: ?[]const u8 = null,
        }, allocator, envelope.request.params_json orelse return error.InvalidInput, .{
            .ignore_unknown_fields = true,
        }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidInput;
        if (!same(params._meta.@"io.modelcontextprotocol/protocolVersion", @tagName(modern))) return error.InvalidInput;
        const name = if (same(request.method, "tools/call") or same(request.method, "prompts/get"))
            params.name orelse return error.InvalidInput
        else if (same(request.method, "resources/read"))
            params.uri orelse return error.InvalidInput
        else
            null;
        if (request.name) |provided| {
            if (!same(provided, name orelse return error.InvalidInput)) return error.InvalidInput;
        }
        if (name) |value| try headers.add("Mcp-Name", try encodeHeader(allocator, value));
        if (request.headers.len > max_headers) return error.LimitExceeded;
        for (request.headers) |header| {
            if (!same(request.method, "tools/call") or !hasParameterPrefix(header.name) or
                header.name.len == parameter_prefix.len) return error.InvalidInput;
            try headers.add(header.name, try encodeHeader(allocator, header.value));
        }
        return headers;
    }

    fn baseHeaders(self: *Http, kind: Kind, revision: foo.config.McpRevision, token: []const u8, initializing: bool) link.Error!Headers {
        var headers: Headers = .{};
        for (self.options.headers) |header| try headers.add(header.name, header.value);
        switch (kind.method()) {
            .post => {
                try headers.add("Accept", json_type ++ ", " ++ sse_type);
                try headers.add("Content-Type", json_type);
            },
            .get => try headers.add("Accept", sse_type),
            .delete => {},
        }
        if (!initializing) try headers.add(protocol_header, @tagName(revision));
        if (token.len != 0) try headers.add(session_header, token);
        return headers;
    }

    fn limits(self: *const Http) wire.json.Limits {
        return .{ .max_bytes = self.options.max_message_bytes };
    }

    fn cancelRequest(self: *Http, op: io.Context, channel: Channel, id: rpc.Id, session: Session) link.Error!void {
        var cancellation: io.Cancellation = .{};
        var cleanup = op;
        cleanup.cancellation = &cancellation;
        cleanup.deadline_ms = op.clock.now() +| 250;
        try self.checkSession(cleanup, session);
        var arena = std.heap.ArenaAllocator.init(self.options.scratch_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const params = try std.json.Stringify.valueAlloc(allocator, .{
            .requestId = switch (id) {
                .number => |value| std.json.Value{ .integer = value },
                .string => |value| std.json.Value{ .string = value },
            },
        }, .{});
        const buffer = try allocator.alloc(u8, @min(self.options.max_message_bytes, params.len +| 80));
        const body = wire.jsonrpc.encodeRequest(buffer, .{ .id = null, .method = "notifications/cancelled", .params_json = params }, self.limits()) catch return error.LimitExceeded;
        try self.sendAuxiliary(cleanup, channel, .notification, body, session, session.token.slice());
    }

    fn sendAuxiliary(self: *Http, op: io.Context, channel: Channel, kind: Kind, body: []const u8, session: ?Session, token: []const u8) link.Error!void {
        const headers = try self.baseHeaders(kind, legacy, token, false);
        var pending: Pending = .{
            .http = self,
            .channel = channel,
            .revision = legacy,
            .session = session,
            .budget = .{ .limit = self.options.max_stream_bytes },
        };
        if (session == null) try pending.token.set(token);
        var delivery: io.Delivery = .unsent;
        _ = try pending.run(self.options.scratch_allocator, op, kind, headers.slice(), body, &delivery);
    }
};

const Kind = enum {
    request,
    subscription,
    listen,
    notification,
    delete,

    fn method(self: Kind) @FieldType(io.HttpRequest, "method") {
        return switch (self) {
            .request, .subscription, .notification => .post,
            .listen => .get,
            .delete => .delete,
        };
    }
};

fn classify(request: link.Request) link.Error!Kind {
    return switch (request.mode) {
        .request => if (request.id != null) .request else if (request.revision == legacy) .notification else error.InvalidInput,
        .subscription => if (request.revision == modern and request.id != null and same(request.method, "subscriptions/listen"))
            .subscription
        else
            error.InvalidInput,
        .legacy_notifications => if (request.revision == legacy and request.id == null) .listen else error.InvalidInput,
    };
}

const Token = struct {
    bytes: [max_cursor_bytes]u8 = undefined,
    len: usize = 0,

    fn set(self: *Token, value: []const u8) link.Error!void {
        if (value.len > self.bytes.len) return error.LimitExceeded;
        @memcpy(self.bytes[0..value.len], value);
        self.len = value.len;
    }

    fn slice(self: *const Token) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Headers = struct {
    entries: [max_headers]io.Header = undefined,
    count: usize = 0,
    budget: io.Budget = .{ .limit = max_header_bytes },

    fn add(self: *Headers, name: []const u8, value: []const u8) link.Error!void {
        if (self.count == self.entries.len) return error.LimitExceeded;
        try self.budget.take(name.len);
        try self.budget.take(value.len);
        try self.budget.take(4);
        if (!validHeaderName(name) or !validHeaderValue(value)) return error.InvalidInput;
        for (self.slice()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return error.InvalidInput;
        }
        self.entries[self.count] = .{ .name = name, .value = value };
        self.count += 1;
    }

    fn slice(self: *const Headers) []const io.Header {
        return self.entries[0..self.count];
    }
};

fn encodeHeader(allocator: Allocator, value: []const u8) link.Error![]const u8 {
    const prefix = "=?base64?";
    const suffix = "?=";
    if (value.len > max_header_bytes) return error.LimitExceeded;
    var safe = value.len == std.mem.trim(u8, value, " \t").len and
        !(std.mem.startsWith(u8, value, prefix) and std.mem.endsWith(u8, value, suffix));
    for (value) |byte| {
        if ((byte < ' ' and byte != '\t') or byte > '~') safe = false;
    }
    if (safe) return value;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidInput;
    const encoder = std.base64.standard.Encoder;
    const size = encoder.calcSize(value.len);
    if (size > max_header_bytes - prefix.len - suffix.len) return error.LimitExceeded;
    const encoded = try allocator.alloc(u8, prefix.len + size + suffix.len);
    @memcpy(encoded[0..prefix.len], prefix);
    _ = encoder.encode(encoded[prefix.len..][0..size], value);
    @memcpy(encoded[prefix.len + size ..], suffix);
    return encoded;
}

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^`_|~", byte) == null) return false;
    }
    return true;
}

fn validHeaderValue(value: []const u8) bool {
    for (value) |byte| {
        if ((byte < ' ' and byte != '\t') or byte == 0x7f) return false;
    }
    return true;
}

fn hasParameterPrefix(name: []const u8) bool {
    return name.len >= parameter_prefix.len and std.ascii.eqlIgnoreCase(name[0..parameter_prefix.len], parameter_prefix);
}

fn reserved(name: []const u8) bool {
    if (hasParameterPrefix(name)) return true;
    for ([_][]const u8{
        "Accept",              "Content-Type",   protocol_header,     session_header, cursor_header, "Mcp-Method", "Mcp-Name",
        "Host",                "Content-Length", "Transfer-Encoding", "Expect",       "Connection",  "Keep-Alive", "Proxy-Connection",
        "Proxy-Authorization", "Upgrade",        "TE",                "Trailer",
    }) |header| {
        if (std.ascii.eqlIgnoreCase(name, header)) return true;
    }
    return false;
}

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn sameId(a: ?rpc.Id, b: ?rpc.Id) bool {
    return if (a) |id| if (b) |other| id.eql(other) else false else b == null;
}

const Pending = struct {
    http: *Http,
    channel: Http.Channel,
    revision: foo.config.McpRevision,
    id: ?rpc.Id = null,
    observer: ?link.Observer = null,
    session: ?Http.Session = null,
    initializing: bool = false,
    discovering: bool = false,
    budget: io.Budget,
    token: Token = .{},
    cursor: Token = .{},
    retry_ms: u64 = 100,

    fn run(self: *Pending, result: Allocator, op: io.Context, kind: Kind, headers: []const io.Header, body: []const u8, delivery: *io.Delivery) link.Error!link.Reply {
        var outcome = self.attempt(result, op, kind, headers, body, delivery);
        if (self.revision != legacy) return outcome;

        for (0..max_resume_attempts) |_| {
            if (outcome) |reply| return reply else |err| {
                if (err != error.Disconnected or self.cursor.len == 0 or self.retry_ms > max_retry_ms) return err;
            }
            try waitRetry(op, self.retry_ms);
            if (self.session) |session| try self.http.checkSession(op, session);
            const token = self.sessionToken();
            var resume_headers = try self.http.baseHeaders(.listen, legacy, token, false);
            resume_headers.add(cursor_header, self.cursor.slice()) catch |err| return if (err == error.InvalidInput) error.MalformedPeer else err;
            var resume_delivery: io.Delivery = .unsent;
            outcome = self.attempt(result, op, .listen, resume_headers.slice(), "", &resume_delivery);
        }
        return outcome;
    }

    fn sessionToken(self: *const Pending) []const u8 {
        return if (self.session) |*session| session.token.slice() else self.token.slice();
    }

    fn attempt(self: *Pending, result: Allocator, op: io.Context, kind: Kind, headers: []const io.Header, body: []const u8, delivery: *io.Delivery) link.Error!link.Reply {
        try op.check();
        const remaining = self.budget.limit - self.budget.used;
        if (remaining == 0) return error.LimitExceeded;
        var scratch = std.heap.ArenaAllocator.init(self.http.options.scratch_allocator);
        defer scratch.deinit();
        var incoming: Incoming = .{ .pending = self, .kind = kind, .result = result, .scratch = scratch.allocator() };
        errdefer if (incoming.reply) |reply| freeReply(result, reply);

        const transport = self.http.transport(self.channel);
        const transferred = transport.exchange_fn(transport.context, op, .{
            .method = kind.method(),
            .url = self.http.options.url,
            .headers = headers,
            .body = .{ .bytes = body },
            .max_response_bytes = remaining,
        }, .{
            .context = &incoming,
            .head_fn = Incoming.head,
            .body = .{ .context = &incoming, .write_fn = Incoming.body },
        }, delivery);
        if (incoming.failure) |err| return err;
        if (incoming.stopped) return incoming.reply.?;
        if (transferred) |_| {
            try op.check();
        } else |err| {
            if (err == error.Disconnected) try incoming.rememberCursor();
            return err;
        }
        return incoming.finish(op);
    }

    fn reverse(self: *Pending, allocator: Allocator, op: io.Context, request: rpc.Request) link.Error!void {
        const id = request.id.?;
        if (self.session) |session| try self.http.checkSession(op, session);
        const channel = for ([_]Http.Channel{ .housekeeping, .main, .listener }) |channel| {
            if (channel == self.channel) continue;
            if (channel == .housekeeping and self.http.options.housekeeping == null) continue;
            if (channel == .listener and self.http.options.listener == null) continue;
            self.http.claim(op, channel) catch |err| {
                if (err != error.Unavailable) return err;
                continue;
            };
            break channel;
        } else return error.Unavailable;
        defer self.http.release(op, channel);

        const id_size = if (id == .string) id.string.len else 21;
        const buffer = try allocator.alloc(u8, @min(self.http.options.max_message_bytes, id_size *| 6 +| 160));
        const response: rpc.Response = if (same(request.method, "ping")) .{
            .success = .{ .id = id, .result_json = "{}" },
        } else .{
            .failure = .{
                .id = id,
                .err = .{ .code = rpc.Code.method_not_found, .message = "Method not supported" },
            },
        };
        const body = wire.jsonrpc.encodeResponse(buffer, response, self.http.limits()) catch return error.LimitExceeded;
        try self.http.sendAuxiliary(op, channel, .notification, body, self.session, self.sessionToken());
    }
};

const Incoming = struct {
    const Format = enum { awaiting, empty, discard, json, sse };

    pending: *Pending,
    kind: Kind,
    result: Allocator,
    scratch: Allocator,
    format: Format = .awaiting,
    status: u16 = 0,
    json: std.ArrayList(u8) = .empty,
    sse: ?Sse = null,
    line_event: [256]u8 = undefined,
    cursor: [max_cursor_bytes]u8 = undefined,
    pending_cursor: [max_cursor_bytes]u8 = undefined,
    decode_scratch: []u8 = &.{},
    reply: ?link.Reply = null,
    failure: ?link.Error = null,
    stopped: bool = false,

    fn head(raw: *anyopaque, op: io.Context, value: io.HttpHead) io.Error!void {
        const self: *Incoming = @ptrCast(@alignCast(raw));
        self.readHead(op, value) catch |err| return self.abort(err);
    }

    fn readHead(self: *Incoming, op: io.Context, value: io.HttpHead) link.Error!void {
        if (self.format != .awaiting) return error.MalformedPeer;
        self.status = value.status;
        if (value.status == 401) return error.UnsupportedAuthentication;
        if (self.kind == .delete) {
            if ((value.status >= 200 and value.status < 300) or value.status == 404 or value.status == 405) {
                self.format = .discard;
                return;
            }
            return error.IoFailure;
        }
        if (self.pending.revision == legacy and value.status == 404 and self.pending.sessionToken().len != 0) {
            if (self.pending.session) |session| self.pending.http.expire(op, session);
            return error.SessionExpired;
        }
        if (self.kind == .listen and value.status == 405) return error.StreamUnsupported;
        if (self.kind == .notification) {
            if (value.status != 202) return error.IoFailure;
            self.format = .empty;
            return;
        }
        const rpc_error = self.pending.revision == modern and (value.status == 400 or value.status == 404);
        const success = value.status >= 200 and value.status < 300 and value.status != 202;
        if (!success and !rpc_error) return error.IoFailure;

        const content_type = try uniqueHeader(value.headers, "Content-Type");
        const media_type = if (content_type) |field| std.mem.trim(u8, field[0..(std.mem.indexOfScalar(u8, field, ';') orelse field.len)], " \t") else "";
        if (rpc_error and !std.ascii.eqlIgnoreCase(media_type, json_type) and !(value.status == 400 and self.pending.discovering)) return error.IoFailure;
        if (rpc_error or (self.kind != .listen and std.ascii.eqlIgnoreCase(media_type, json_type))) {
            self.format = .json;
        } else if (std.ascii.eqlIgnoreCase(media_type, sse_type)) {
            const max_bytes = self.pending.http.options.max_message_bytes;
            self.sse = .init(.{
                .line = try self.scratch.alloc(u8, max_bytes + "data: ".len),
                .data = try self.scratch.alloc(u8, max_bytes),
                .event = &self.line_event,
                .id = &self.cursor,
                .pending_id = &self.pending_cursor,
                .max_event_bytes = max_bytes,
            });
            self.format = .sse;
        } else return error.MalformedPeer;

        if (self.pending.initializing and success) {
            if (try uniqueHeader(value.headers, session_header)) |token| {
                if (token.len == 0) return error.MalformedPeer;
                for (token) |byte| {
                    if (byte < 0x21 or byte > 0x7e) return error.MalformedPeer;
                }
                if (self.pending.token.len != 0 and !same(token, self.pending.token.slice())) return error.MalformedPeer;
                try self.pending.token.set(token);
            }
        }
    }

    fn body(raw: *anyopaque, op: io.Context, bytes: []const u8) io.Error!void {
        const self: *Incoming = @ptrCast(@alignCast(raw));
        self.readBody(op, bytes) catch |err| return self.abort(err);
        if (self.reply != null and self.format == .sse) {
            self.stopped = true;
            return error.IoFailure;
        }
    }

    fn readBody(self: *Incoming, op: io.Context, bytes: []const u8) link.Error!void {
        try self.pending.budget.take(bytes.len);
        switch (self.format) {
            .awaiting => return error.MalformedPeer,
            .empty => if (bytes.len != 0) return error.MalformedPeer,
            .discard => {},
            .json => {
                if (bytes.len > self.pending.http.options.max_message_bytes - self.json.items.len) return error.LimitExceeded;
                try self.json.appendSlice(self.scratch, bytes);
            },
            .sse => self.sse.?.feed(op, bytes, .{ .context = self, .emit_fn = event }) catch |err| return self.failure orelse mapFraming(err),
        }
    }

    fn abort(self: *Incoming, err: link.Error) io.Error {
        self.failure = err;
        return error.IoFailure;
    }

    fn event(raw: *anyopaque, op: io.Context, value: Sse.Event) wire.framing.Error!void {
        const self: *Incoming = @ptrCast(@alignCast(raw));
        if (!same(value.event, "message")) return self.abort(error.MalformedPeer);
        if (value.data.len == 0 and self.pending.revision == legacy and value.last_event_id != null) return;
        self.message(op, value.data) catch |err| return self.abort(err);
    }

    fn message(self: *Incoming, op: io.Context, data: []const u8) link.Error!void {
        if (self.reply != null) return error.MalformedPeer;
        if (self.decode_scratch.len < data.len) self.decode_scratch = try self.scratch.realloc(self.decode_scratch, data.len);
        const envelope = wire.jsonrpc.decode(data, self.decode_scratch, self.pending.http.limits()) catch |err| return switch (err) {
            error.MessageTooLarge, error.NestingTooDeep => error.LimitExceeded,
            else => error.MalformedPeer,
        };
        switch (envelope) {
            .response => |response| {
                self.reply = try link.copyReply(self.result, self.pending.id orelse return error.MalformedPeer, response);
            },
            .request => |message_value| {
                if (self.format != .sse) return error.MalformedPeer;
                if (message_value.id == null) {
                    try link.Observer.notify(self.pending.observer, op, message_value);
                } else if (self.pending.revision == legacy) {
                    var arena = std.heap.ArenaAllocator.init(self.pending.http.options.scratch_allocator);
                    defer arena.deinit();
                    try self.pending.reverse(arena.allocator(), op, message_value);
                } else return error.MalformedPeer;
            },
        }
    }

    fn finish(self: *Incoming, op: io.Context) link.Error!link.Reply {
        switch (self.format) {
            .awaiting => return error.Disconnected,
            .empty, .discard => return .accepted,
            .json => {
                if (self.status == 400 or self.status == 404) return self.httpRpcError();
                try self.message(op, self.json.items);
                const reply = self.reply orelse return error.MalformedPeer;
                if (self.kind == .subscription and reply != .failure) return error.MalformedPeer;
                return reply;
            },
            .sse => {
                try self.rememberCursor();
                self.sse.?.finish(op) catch |err| {
                    if (err != error.TruncatedFrame or self.pending.cursor.len == 0) return mapFraming(err);
                };
                return error.Disconnected;
            },
        }
    }

    fn httpRpcError(self: *Incoming) link.Error!link.Reply {
        const fallback = self.status == 400 and self.pending.discovering;
        const unrecognized: link.Error = if (fallback) error.UnsupportedRevision else error.MalformedPeer;
        const body_bytes = self.json.items;
        wire.json.validate(body_bytes, self.pending.http.limits()) catch |err| return switch (err) {
            error.MessageTooLarge, error.NestingTooDeep => error.LimitExceeded,
            else => unrecognized,
        };
        const decoded = std.json.parseFromSliceLeaky(struct {
            jsonrpc: []const u8,
            id: ?std.json.Value = null,
            method: ?std.json.Value = null,
            result: ?std.json.Value = null,
            @"error": struct { code: i32, message: []const u8, data: ?std.json.Value = null },
        }, self.scratch, body_bytes, .{ .ignore_unknown_fields = true }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else unrecognized;
        if (!same(decoded.jsonrpc, "2.0") or decoded.method != null or decoded.result != null) return unrecognized;
        const details = decoded.@"error";
        const expected = self.pending.id orelse return error.MalformedPeer;
        if (decoded.id) |value| {
            const actual: rpc.Id = switch (value) {
                .integer => .{ .number = value.integer },
                .string => .{ .string = value.string },
                else => return error.MalformedPeer,
            };
            if (!expected.eql(actual)) return error.MalformedPeer;
        }
        const recognized = switch (self.status) {
            400 => details.code == -32020 or details.code == -32021 or details.code == -32022,
            404 => details.code == rpc.Code.method_not_found,
            else => unreachable,
        };
        if (!recognized and (fallback or decoded.id == null)) return unrecognized;
        // HTTP-scoped error envelopes can omit the RPC ID in this revision.
        const data = if (details.data) |value| try std.json.Stringify.valueAlloc(self.scratch, value, .{}) else null;
        return link.copyReply(self.result, expected, .{ .failure = .{
            .id = expected,
            .err = .{ .code = details.code, .message = details.message, .data_json = data },
        } });
    }

    fn rememberCursor(self: *Incoming) link.Error!void {
        if (self.pending.revision != legacy) return;
        const sse = if (self.sse) |*stream| stream else return;
        if (sse.lastEventId()) |id| try self.pending.cursor.set(id);
        if (sse.retryMilliseconds()) |ms| self.pending.retry_ms = ms;
    }
};

fn uniqueHeader(headers: []const io.Header, name: []const u8) link.Error!?[]const u8 {
    var value: ?[]const u8 = null;
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            if (value != null) return error.MalformedPeer;
            value = header.value;
        }
    }
    return value;
}

fn freeReply(allocator: Allocator, reply: link.Reply) void {
    switch (reply) {
        .accepted => {},
        .success => |bytes| allocator.free(bytes),
        .failure => |failure| {
            allocator.free(failure.message);
            if (failure.data_json) |data| allocator.free(data);
        },
    }
}

fn waitRetry(op: io.Context, delay_ms: u64) link.Error!void {
    var remaining = delay_ms;
    while (remaining != 0) {
        try op.check();
        const before_deadline = if (op.deadline_ms) |deadline| deadline -| op.clock.now() else remaining;
        const chunk = @min(remaining, before_deadline, 20);
        if (chunk == 0) return error.DeadlineExceeded;
        op.io.sleep(.fromMilliseconds(@intCast(chunk)), .awake) catch return error.Cancelled;
        remaining -= chunk;
    }
    try op.check();
}

fn mapFraming(err: wire.framing.Error) link.Error {
    return switch (err) {
        error.MalformedFrame, error.TruncatedFrame, error.Closed, error.Busy => error.MalformedPeer,
        else => |io_error| io_error,
    };
}
