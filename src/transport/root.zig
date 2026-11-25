const std = @import("std");
const curl = @import("curl");
const io = @import("../contracts/io.zig");
const headers = @import("headers.zig");
pub const trust = @import("trust.zig");
pub const Trust = trust.Trust;

pub const Limits = struct {
    request_bytes: usize = 16 * 1024 * 1024,
    header_bytes: usize = 64 * 1024,
    header_count: usize = 128,
};

pub const Proxy = union(enum) {
    direct,
    http: struct {
        url: []const u8,
        basic: ?struct { username: []const u8, password: []const u8 } = null,
    },
};

pub const Options = struct {
    trust: Trust = .platform,
    proxy: Proxy = .direct,
    limits: Limits = .{},
};

const max_url_bytes = 8192;
const max_ca_bytes = 2 * 1024 * 1024;
const max_proxy_credential_bytes = 4096;
const poll_ms = 20;
const pool_connections: c_long = 4;

pub const Runtime = struct {
    pub fn init() io.Error!Runtime {
        try curlResult(curl.curl_global_init(curl.CURL_GLOBAL_DEFAULT));
        errdefer curl.curl_global_cleanup();

        const version = curl.curl_version_info(curl.CURLVERSION_NOW).*;
        if (version.version_num < 0x080300 or version.ares == null or
            version.ssl_version == null or !std.mem.startsWith(u8, std.mem.span(version.ssl_version), "OpenSSL/"))
            return error.Unavailable;
        return .{};
    }

    pub fn deinit(_: Runtime) void {
        curl.curl_global_cleanup();
    }

    pub fn client(_: Runtime, allocator: std.mem.Allocator, system_io: std.Io, options: Options) io.Error!Client {
        return Client.init(allocator, system_io, options);
    }
};

const HttpProxy = struct {
    url: [:0]const u8,
    basic: ?struct { username: [:0]const u8, password: [:0]const u8 } = null,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    multi: *curl.CURLM,
    ca_pem: []const u8,
    proxy: ?HttpProxy,
    limits: Limits,
    busy: std.atomic.Value(bool) = .init(false),

    fn init(allocator: std.mem.Allocator, system_io: std.Io, options: Options) io.Error!Client {
        const ca_pem = switch (options.trust) {
            .platform => try trust.platformPem(allocator, system_io, .now(system_io, .real)),
            .pem => |pem| pem: {
                if (pem.len == 0) return error.InvalidInput;
                if (pem.len > max_ca_bytes) return error.LimitExceeded;
                break :pem try allocator.dupe(u8, pem);
            },
        };
        errdefer allocator.free(ca_pem);

        const proxy: ?HttpProxy = switch (options.proxy) {
            .direct => null,
            .http => |config| proxy: {
                if (try validateUrl(config.url, .proxy) != .http) return error.InvalidInput;
                const url = try allocator.dupeSentinel(u8, config.url, 0);
                errdefer allocator.free(url);
                if (config.basic) |basic| {
                    try validateCredential(basic.username);
                    try validateCredential(basic.password);
                    if (basic.username.len == 0 or std.mem.indexOfScalar(u8, basic.username, ':') != null)
                        return error.InvalidInput;
                    const username = try allocator.dupeSentinel(u8, basic.username, 0);
                    errdefer allocator.free(username);
                    break :proxy .{ .url = url, .basic = .{ .username = username, .password = try allocator.dupeSentinel(u8, basic.password, 0) } };
                }
                break :proxy .{ .url = url };
            },
        };
        errdefer if (proxy) |settings| freeProxy(allocator, settings);

        const multi = curl.curl_multi_init() orelse return error.OutOfMemory;
        errdefer _ = curl.curl_multi_cleanup(multi);
        try multiResult(curl.curl_multi_setopt(multi, curl.CURLMOPT_MAXCONNECTS, pool_connections));
        return .{ .allocator = allocator, .multi = multi, .ca_pem = ca_pem, .proxy = proxy, .limits = options.limits };
    }

    pub fn deinit(self: *Client) void {
        std.debug.assert(!self.busy.load(.acquire));
        _ = curl.curl_multi_cleanup(self.multi);
        self.allocator.free(self.ca_pem);
        if (self.proxy) |proxy| freeProxy(self.allocator, proxy);
        self.* = undefined;
    }

    pub fn interface(self: *Client) io.HttpTransport {
        return .{ .context = self, .exchange_fn = exchange };
    }

    fn exchange(context: *anyopaque, operation: io.Context, request: io.HttpRequest, sink: io.HttpSink, delivery: *io.Delivery) io.Error!void {
        delivery.* = .unsent;
        const self: *Client = @ptrCast(@alignCast(context));
        if (self.busy.swap(true, .acq_rel)) return error.Unavailable;
        defer self.busy.store(false, .release);
        try operation.check();

        const scheme = try validateUrl(request.url, .origin);
        const length = bodyLength(request.body);
        if (length) |amount| {
            if (amount > self.limits.request_bytes) return error.LimitExceeded;
            if (amount > std.math.maxInt(curl.curl_off_t)) return error.LimitExceeded;
        }

        var request_headers = try headers.Request.init(self.allocator, request.headers, self.limits.header_bytes, self.limits.header_count);
        defer request_headers.deinit();
        const url = try self.allocator.dupeSentinel(u8, request.url, 0);
        defer self.allocator.free(url);
        const parsed_url = curl.curl_url() orelse return error.OutOfMemory;
        defer curl.curl_url_cleanup(parsed_url);
        try urlResult(curl.curl_url_set(parsed_url, curl.CURLUPART_URL, url.ptr, curl.CURLU_DISALLOW_USER));

        const header_data = try self.allocator.alloc(u8, self.limits.header_bytes);
        defer self.allocator.free(header_data);
        const header_fields = try self.allocator.alloc(io.Header, self.limits.header_count);
        defer self.allocator.free(header_fields);
        var transfer: Exchange = .{
            .operation = operation,
            .sink = sink,
            .delivery = delivery,
            .upload = .{ .body = request.body, .length = length, .budget = .{ .limit = self.limits.request_bytes } },
            .response = .{
                .bytes = header_data,
                .fields = header_fields,
                .byte_budget = .{ .limit = self.limits.header_bytes },
                .field_budget = .{ .limit = self.limits.header_count },
            },
            .download = .{ .limit = request.max_response_bytes },
        };

        const easy = curl.curl_easy_init() orelse return error.OutOfMemory;
        defer curl.curl_easy_cleanup(easy);
        try self.configure(easy, parsed_url, scheme, request_headers.list, request.method, &transfer);
        try operation.check();
        try multiResult(curl.curl_multi_add_handle(self.multi, easy));
        defer _ = curl.curl_multi_remove_handle(self.multi, easy);
        try self.drive(&transfer);
    }

    fn configure(
        self: *const Client,
        easy: *curl.CURL,
        url: *curl.CURLU,
        scheme: Scheme,
        request_headers: [*c]curl.curl_slist,
        method: @FieldType(io.HttpRequest, "method"),
        transfer: *Exchange,
    ) io.Error!void {
        try set(easy, curl.CURLOPT_CURLU, url);
        try set(easy, curl.CURLOPT_PROTOCOLS_STR, "http,https");
        try set(easy, curl.CURLOPT_HTTP_VERSION, @as(c_long, curl.CURL_HTTP_VERSION_1_1));
        try set(easy, curl.CURLOPT_HTTP09_ALLOWED, @as(c_long, 0));
        try set(easy, curl.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
        try set(easy, curl.CURLOPT_HTTPAUTH, @as(c_long, curl.CURLAUTH_NONE));
        try set(easy, curl.CURLOPT_NOSIGNAL, @as(c_long, 1));
        try set(easy, curl.CURLOPT_HTTP_CONTENT_DECODING, @as(c_long, 0));
        try set(easy, curl.CURLOPT_HTTPHEADER, request_headers);

        const proxy = self.proxy;
        try set(easy, curl.CURLOPT_PROXY, if (proxy) |settings| settings.url.ptr else "");
        if (proxy) |settings| {
            try set(easy, curl.CURLOPT_NOPROXY, "");
            try set(easy, curl.CURLOPT_HTTPPROXYTUNNEL, @as(c_long, 1));
            try set(easy, curl.CURLOPT_HEADEROPT, @as(c_long, curl.CURLHEADER_SEPARATE));
            if (settings.basic) |basic| {
                try set(easy, curl.CURLOPT_PROXYAUTH, @as(c_long, curl.CURLAUTH_BASIC));
                try set(easy, curl.CURLOPT_PROXYUSERNAME, basic.username.ptr);
                try set(easy, curl.CURLOPT_PROXYPASSWORD, basic.password.ptr);
            }
        }
        if (scheme == .https) {
            const pem = self.ca_pem;
            var blob: curl.curl_blob = .{ .data = @constCast(pem.ptr), .len = pem.len, .flags = curl.CURL_BLOB_NOCOPY };
            try set(easy, curl.CURLOPT_SSL_VERIFYPEER, @as(c_long, 1));
            try set(easy, curl.CURLOPT_SSL_VERIFYHOST, @as(c_long, 2));
            try set(easy, curl.CURLOPT_CAPATH, @as(?[*:0]const u8, null));
            try set(easy, curl.CURLOPT_SSL_OPTIONS, @as(c_long, 0));
            try set(easy, curl.CURLOPT_CAINFO_BLOB, &blob);
        }

        try set(easy, curl.CURLOPT_PREREQDATA, transfer);
        try set(easy, curl.CURLOPT_PREREQFUNCTION, &Exchange.preRequest);
        try set(easy, curl.CURLOPT_HEADERDATA, transfer);
        try set(easy, curl.CURLOPT_HEADERFUNCTION, &Exchange.header);
        try set(easy, curl.CURLOPT_WRITEDATA, transfer);
        try set(easy, curl.CURLOPT_WRITEFUNCTION, &Exchange.write);
        try set(easy, curl.CURLOPT_READDATA, transfer);
        try set(easy, curl.CURLOPT_READFUNCTION, &Exchange.read);
        try set(easy, curl.CURLOPT_SEEKFUNCTION, &Exchange.refuseSeek);

        const length: curl.curl_off_t = if (transfer.upload.length) |amount| @intCast(amount) else -1;
        if (method == .post) {
            try set(easy, curl.CURLOPT_POST, @as(c_long, 1));
            try set(easy, curl.CURLOPT_POSTFIELDSIZE_LARGE, length);
        } else if (length != 0) {
            try set(easy, curl.CURLOPT_UPLOAD, @as(c_long, 1));
            try set(easy, curl.CURLOPT_INFILESIZE_LARGE, length);
        }
        const verb: [:0]const u8 = switch (method) {
            .get => "GET",
            .post => "POST",
            .delete => "DELETE",
        };
        try set(easy, curl.CURLOPT_CUSTOMREQUEST, verb.ptr);
    }

    fn drive(self: *const Client, transfer: *Exchange) io.Error!void {
        const operation = transfer.operation;
        while (true) {
            try operation.check();
            var running: c_int = 0;
            try multiResult(curl.curl_multi_perform(self.multi, &running));
            if (transfer.failure) |failure| return failure;
            try operation.check();
            if (running == 0) {
                var remaining: c_int = 0;
                const message = curl.curl_multi_info_read(self.multi, &remaining);
                if (message == null or message.*.msg != curl.CURLMSG_DONE) return error.IoFailure;
                if (transfer.response.proxy_status) |status| {
                    if (status >= 300) return error.IoFailure;
                }
                try curlResult(message.*.data.result);
                if (transfer.response.phase != .body) return error.Disconnected;
                return;
            }
            const wait: c_int = if (operation.deadline_ms) |deadline|
                @intCast(@min(poll_ms, deadline -| operation.clock.now()))
            else
                poll_ms;
            try multiResult(curl.curl_multi_poll(self.multi, null, 0, wait, null));
        }
    }
};

fn freeProxy(allocator: std.mem.Allocator, proxy: HttpProxy) void {
    allocator.free(proxy.url);
    if (proxy.basic) |basic| {
        allocator.free(basic.username);
        allocator.free(basic.password);
    }
}

const Scheme = enum { http, https };

fn validateUrl(raw: []const u8, kind: enum { origin, proxy }) io.Error!Scheme {
    if (raw.len > max_url_bytes) return error.LimitExceeded;
    for (raw) |byte| {
        if (byte <= ' ' or byte == 0x7f or byte == '\\') return error.InvalidInput;
    }
    const uri = std.Uri.parse(raw) catch return error.InvalidInput;
    if (uri.host == null or uri.user != null or uri.password != null or uri.fragment != null or
        !std.mem.startsWith(u8, raw[uri.scheme.len..], "://")) return error.InvalidInput;
    if (kind == .proxy and (uri.query != null or
        (!uri.path.isEmpty() and !std.mem.eql(u8, uri.path.percent_encoded, "/")))) return error.InvalidInput;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) return .http;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return .https;
    return error.InvalidInput;
}

fn validateCredential(value: []const u8) io.Error!void {
    if (value.len > max_proxy_credential_bytes) return error.LimitExceeded;
    for (value) |byte| {
        if (byte < ' ' or byte == 0x7f) return error.InvalidInput;
    }
}

fn set(easy: *curl.CURL, option: curl.CURLoption, value: anytype) io.Error!void {
    try curlResult(curl.curl_easy_setopt(easy, option, value));
}

fn curlResult(result: curl.CURLcode) io.Error!void {
    return switch (result) {
        curl.CURLE_OK => {},
        curl.CURLE_OPERATION_TIMEDOUT => error.DeadlineExceeded,
        curl.CURLE_OUT_OF_MEMORY => error.OutOfMemory,
        curl.CURLE_TOO_LARGE, curl.CURLE_FILESIZE_EXCEEDED => error.LimitExceeded,
        curl.CURLE_UNSUPPORTED_PROTOCOL, curl.CURLE_URL_MALFORMAT => error.InvalidInput,
        curl.CURLE_NOT_BUILT_IN, curl.CURLE_UNKNOWN_OPTION => error.Unavailable,
        curl.CURLE_COULDNT_CONNECT, curl.CURLE_COULDNT_RESOLVE_HOST, curl.CURLE_COULDNT_RESOLVE_PROXY, curl.CURLE_PARTIAL_FILE, curl.CURLE_GOT_NOTHING, curl.CURLE_SEND_ERROR, curl.CURLE_RECV_ERROR, curl.CURLE_SEND_FAIL_REWIND => error.Disconnected,
        else => error.IoFailure,
    };
}

fn multiResult(result: curl.CURLMcode) io.Error!void {
    return switch (result) {
        curl.CURLM_OK => {},
        curl.CURLM_OUT_OF_MEMORY => error.OutOfMemory,
        else => error.IoFailure,
    };
}

fn urlResult(result: curl.CURLUcode) io.Error!void {
    return switch (result) {
        curl.CURLUE_OK => {},
        curl.CURLUE_OUT_OF_MEMORY => error.OutOfMemory,
        else => error.InvalidInput,
    };
}

fn bodyLength(body: io.HttpBody) ?u64 {
    return switch (body) {
        .bytes => |bytes| bytes.len,
        .stream => |stream| stream.content_length,
    };
}

const Upload = struct {
    body: io.HttpBody,
    length: ?u64,
    budget: io.Budget,

    fn read(self: *Upload, operation: io.Context, buffer: []u8) io.Error!usize {
        if (buffer.len == 0) return error.IoFailure;
        const offset = self.budget.used;
        const remaining = self.budget.limit - offset;
        const count = switch (self.body) {
            .bytes => |bytes| count: {
                const chunk = bytes[offset..][0..@min(bytes.len - offset, buffer.len)];
                @memcpy(buffer[0..chunk.len], chunk);
                break :count chunk.len;
            },
            .stream => |stream| count: {
                const limit = if (self.length) |amount|
                    @as(usize, @intCast(amount)) - offset
                else
                    @max(remaining, 1);
                if (limit == 0) return 0;
                const target = buffer[0..@min(buffer.len, limit)];
                const count = try stream.source.read_fn(stream.source.context, operation, target);
                if (count > target.len) return error.InvalidInput;
                if (count == 0 and self.length != null) return error.Disconnected;
                break :count count;
            },
        };
        try self.budget.take(count);
        return count;
    }
};

const Exchange = struct {
    operation: io.Context,
    sink: io.HttpSink,
    delivery: *io.Delivery,
    upload: Upload,
    response: headers.Response,
    download: io.Budget,
    failure: ?io.Error = null,

    fn preRequest(context: ?*anyopaque, _: [*c]u8, _: [*c]u8, _: c_int, _: c_int) callconv(.c) c_int {
        const self: *Exchange = @ptrCast(@alignCast(context.?));
        self.operation.check() catch |err| {
            self.failure = err;
            return curl.CURL_PREREQFUNC_ABORT;
        };
        if (self.delivery.* == .possibly_sent) {
            self.failure = error.Disconnected;
            return curl.CURL_PREREQFUNC_ABORT;
        }
        self.delivery.* = .possibly_sent;
        return curl.CURL_PREREQFUNC_OK;
    }

    fn refuseSeek(_: ?*anyopaque, _: curl.curl_off_t, _: c_int) callconv(.c) c_int {
        return curl.CURL_SEEKFUNC_FAIL;
    }

    fn read(ptr: [*c]u8, size: usize, count: usize, context: ?*anyopaque) callconv(.c) usize {
        const self: *Exchange = @ptrCast(@alignCast(context.?));
        return self.readBody(ptr[0 .. size * count]) catch |err| {
            self.failure = err;
            return curl.CURL_READFUNC_ABORT;
        };
    }

    fn readBody(self: *Exchange, buffer: []u8) io.Error!usize {
        try self.operation.check();
        const count = try self.upload.read(self.operation, buffer);
        try self.operation.check();
        return count;
    }

    fn header(ptr: [*c]u8, size: usize, count: usize, context: ?*anyopaque) callconv(.c) usize {
        const self: *Exchange = @ptrCast(@alignCast(context.?));
        self.receiveHeader(ptr[0 .. size * count]) catch |err| {
            self.failure = err;
            return curl.CURL_WRITEFUNC_ERROR;
        };
        return size * count;
    }

    fn receiveHeader(self: *Exchange, line: []const u8) io.Error!void {
        try self.operation.check();
        if (self.delivery.* == .unsent) return self.response.acceptProxy(line);
        if (try self.response.accept(line)) |head| {
            try self.sink.head_fn(self.sink.context, self.operation, head);
            try self.operation.check();
        }
    }

    fn write(ptr: [*c]u8, size: usize, count: usize, context: ?*anyopaque) callconv(.c) usize {
        const self: *Exchange = @ptrCast(@alignCast(context.?));
        self.receiveBody(ptr[0 .. size * count]) catch |err| {
            self.failure = err;
            return curl.CURL_WRITEFUNC_ERROR;
        };
        return size * count;
    }

    fn receiveBody(self: *Exchange, bytes: []const u8) io.Error!void {
        if (self.response.phase != .body) return error.IoFailure;
        if (bytes.len == 0) return;
        try self.download.take(bytes.len);
        try self.sink.body.write(self.operation, bytes);
        try self.operation.check();
    }
};
