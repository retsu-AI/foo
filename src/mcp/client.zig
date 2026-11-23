const std = @import("std");
const foo = @import("foo");
const link = @import("link.zig");

const Allocator = std.mem.Allocator;
const Json = std.json.Value;
const Object = std.json.ObjectMap;
const modern: foo.config.McpRevision = .@"2026-07-28";
const legacy: foo.config.McpRevision = .@"2025-11-25";
const subscription_id_key = "io.modelcontextprotocol/subscriptionId";

pub const Error = link.Error;
pub const Options = struct {
    server_id: []const u8,
    revision: ?foo.config.McpRevision = null,
    limits: foo.config.Limits = .{},
    handshake_ms: u64 = 5_000,
};

pub const Requests = struct {
    name: ?[]const u8 = null,
    headers: []const foo.io.Header = &.{},
};

pub const Capabilities = packed struct {
    tools: bool = false,
    resources: bool = false,
    prompts: bool = false,
    tools_changed: bool = false,
    resources_changed: bool = false,
    prompts_changed: bool = false,
};

pub const Profile = struct {
    revision: foo.config.McpRevision,
    capabilities: Capabilities,
};

pub const Completion = struct {
    raw: []const u8,
    fields: Object,
    kind: union(enum) { complete, input_required: ?[]const u8 } = .complete,
};

pub const Client = struct {
    link_io: link.Link,
    options: Options,
    profile: ?Profile = null,
    next_id: std.atomic.Value(i64) = .init(1),
    change_epoch: std.atomic.Value(u64) = .init(0),
    expired: std.atomic.Value(bool) = .init(false),

    pub fn init(wire: link.Link, options: Options) Error!Client {
        if (options.server_id.len == 0 or options.handshake_ms == 0 or
            options.limits.wire_message_bytes == 0 or options.limits.json_depth == 0)
            return error.InvalidInput;
        return .{ .link_io = wire, .options = options };
    }

    /// The caller serializes establishment and shutdown with other uses.
    pub fn connect(self: *Client, allocator: Allocator, operation: foo.io.Context) Error!Profile {
        if (self.profile) |known| if (!self.expired.load(.acquire)) return known;
        const preference = if (self.profile) |old| old.revision else self.options.revision;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var op = operation;
        op.deadline_ms = @min(op.deadline_ms orelse std.math.maxInt(u64), op.clock.now() +| self.options.handshake_ms);

        const profile = if (preference == legacy)
            try self.initializeLegacy(scratch, op)
        else
            (try self.discover(scratch, op, preference == null)) orelse try self.initializeLegacy(scratch, op);
        self.profile = profile;
        self.expired.store(false, .release);
        return profile;
    }

    pub fn request(
        self: *Client,
        allocator: Allocator,
        operation: foo.io.Context,
        method: []const u8,
        params: Object,
        request_info: Requests,
        delivery: *foo.io.Delivery,
    ) Error!Completion {
        delivery.* = .unsent;
        const active = self.profile orelse return error.Unavailable;
        if (self.expired.load(.acquire)) return error.SessionExpired;
        const reply = self.send(allocator, operation, active.revision, method, params, try self.next(), .request, request_info, self.observer(), delivery) catch |err| {
            if (err == error.SessionExpired) {
                self.expired.store(true, .release);
                self.markChanged();
            }
            return err;
        };
        const result = try self.complete(allocator, active.revision, reply);
        if (result.kind == .input_required and
            !std.mem.eql(u8, method, "tools/call") and
            !std.mem.eql(u8, method, "resources/read") and
            !std.mem.eql(u8, method, "prompts/get")) return error.MalformedPeer;
        return result;
    }

    /// Drive on an independent task after connect. Join it before shutdown.
    pub fn listen(self: *Client, allocator: Allocator, op: foo.io.Context) Error!void {
        const active = self.profile orelse return error.Unavailable;
        defer self.markChanged();
        var delivery: foo.io.Delivery = .unsent;
        if (active.revision == legacy) {
            _ = try self.link_io.exchange(allocator, op, .{
                .revision = legacy,
                .id = null,
                .method = "",
                .body = "",
                .mode = .legacy_notifications,
            }, self.observer(), &delivery);
            return;
        }

        const filter = Filter.fromCapabilities(active.capabilities);
        if (!filter.toolsListChanged and !filter.promptsListChanged and !filter.resourcesListChanged)
            return error.UnsupportedCapability;
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const temp = scratch.allocator();
        const raw = try std.json.Stringify.valueAlloc(temp, filter, .{});
        const object = try self.decodeObject(temp, raw);
        var params: Object = .empty;
        try params.put(temp, "notifications", .{ .object = object });
        const id = try self.next();
        var subscription: Subscription = .{ .client = self, .id = id, .requested = filter };
        var timer: SubscriptionTimer = .{
            .origin = op,
            .acknowledged = &subscription.ack_observed,
            .ack_deadline_ms = op.clock.now() +| self.options.handshake_ms,
        };
        var monitor = op.io.concurrent(SubscriptionTimer.run, .{&timer}) catch return error.Unavailable;
        defer monitor.cancel(op.io);
        var subscription_op = op;
        subscription_op.cancellation = &timer.token;
        const reply = self.send(temp, subscription_op, modern, "subscriptions/listen", params, id, .subscription, .{}, .{
            .context = &subscription,
            .notify_fn = Subscription.notify,
        }, &delivery) catch |err| {
            if (timer.ack_timeout.load(.acquire)) return error.DeadlineExceeded;
            try op.check();
            return err;
        };
        const completion = try self.complete(temp, modern, reply);
        if (completion.kind != .complete or subscription.acknowledged == null or !subscription.matches(completion.fields))
            return error.MalformedPeer;
    }

    pub fn shutdown(self: *Client, cleanup: foo.io.Context) Error!void {
        defer {
            self.profile = null;
            self.markChanged();
        }
        try self.link_io.shutdown(cleanup);
    }

    pub fn epoch(self: *const Client) u64 {
        return self.change_epoch.load(.acquire);
    }

    fn discover(self: *Client, allocator: Allocator, op: foo.io.Context, allow_auto: bool) Error!?Profile {
        var delivery: foo.io.Delivery = .unsent;
        const reply = self.send(allocator, op, modern, "server/discover", .empty, try self.next(), .request, .{}, null, &delivery) catch |err| {
            if (err == error.UnsupportedRevision and allow_auto) return null;
            return err;
        };
        if (reply == .failure and allow_auto) {
            if (reply.failure.code == foo.jsonrpc.Code.method_not_found or reply.failure.code == foo.jsonrpc.Code.invalid_request) {
                return null;
            }
            if (reply.failure.code == -32022 and reply.failure.data_json != null) {
                const details = try self.decodeObject(allocator, reply.failure.data_json.?);
                if (try supports(details.get("supported"), legacy)) return null;
                return error.UnsupportedRevision;
            }
        }
        const discovery = try self.complete(allocator, modern, reply);
        if (discovery.kind != .complete) return error.MalformedPeer;
        const outcome = discovery.fields;
        if (!try supports(outcome.get("supportedVersions"), modern)) {
            if (allow_auto and try supports(outcome.get("supportedVersions"), legacy)) return null;
            return error.UnsupportedRevision;
        }
        return .{ .revision = modern, .capabilities = try capabilitiesOf(outcome.get("capabilities")) };
    }

    fn initializeLegacy(self: *Client, allocator: Allocator, op: foo.io.Context) Error!Profile {
        const raw = try std.json.Stringify.valueAlloc(allocator, .{
            .protocolVersion = @tagName(legacy),
            .clientInfo = clientInfo(),
            .capabilities = Json{ .object = .empty },
        }, .{});
        const arguments = try self.decodeObject(allocator, raw);
        var delivery: foo.io.Delivery = .unsent;
        const reply = try self.send(allocator, op, legacy, "initialize", arguments, try self.next(), .request, .{}, null, &delivery);
        const initialized_reply = try self.complete(allocator, legacy, reply);
        if (initialized_reply.kind != .complete) return error.MalformedPeer;
        const outcome = initialized_reply.fields;
        const version = outcome.get("protocolVersion") orelse return error.MalformedPeer;
        if (version != .string) return error.MalformedPeer;
        if (!std.mem.eql(u8, version.string, @tagName(legacy))) return error.UnsupportedRevision;
        const capabilities = try capabilitiesOf(outcome.get("capabilities"));
        const initialized = try self.send(allocator, op, legacy, "notifications/initialized", .empty, null, .request, .{}, null, &delivery);
        if (initialized != .accepted) return error.MalformedPeer;
        return .{ .revision = legacy, .capabilities = capabilities };
    }

    fn send(
        self: *Client,
        allocator: Allocator,
        op: foo.io.Context,
        revision: foo.config.McpRevision,
        method: []const u8,
        params: Object,
        id: ?i64,
        mode: link.Mode,
        info: Requests,
        notify: ?link.Observer,
        delivery: *foo.io.Delivery,
    ) Error!link.Reply {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const temp = arena.allocator();
        var arguments = params;
        if (revision == modern) {
            arguments = try params.clone(temp);
            if (arguments.contains("_meta")) return error.InvalidInput;
            const metadata = try std.json.Stringify.valueAlloc(temp, .{
                .@"io.modelcontextprotocol/protocolVersion" = @tagName(modern),
                .@"io.modelcontextprotocol/clientInfo" = clientInfo(),
                .@"io.modelcontextprotocol/clientCapabilities" = Json{ .object = .empty },
            }, .{});
            const fields = try self.decodeObject(temp, metadata);
            try arguments.put(temp, "_meta", .{ .object = fields });
        }
        const envelope = .{
            .jsonrpc = "2.0",
            .id = id,
            .method = method,
            .params = Json{ .object = arguments },
        };
        const encoded = try std.json.Stringify.valueAlloc(temp, envelope, .{ .emit_null_optional_fields = false });
        foo.wire.json.validate(encoded, self.jsonLimits()) catch return error.LimitExceeded;
        return self.link_io.exchange(allocator, op, .{
            .revision = revision,
            .id = if (id) |number| .{ .number = number } else null,
            .method = method,
            .body = encoded,
            .mode = mode,
            .name = info.name,
            .headers = info.headers,
        }, notify, delivery);
    }

    fn complete(self: *Client, allocator: Allocator, revision: foo.config.McpRevision, reply: link.Reply) Error!Completion {
        switch (reply) {
            .accepted => return error.MalformedPeer,
            .failure => |failure| return switch (failure.code) {
                -32022 => error.UnsupportedRevision,
                -32021 => error.UnsupportedCapability,
                else => error.RpcFailure,
            },
            .success => |raw| {
                const fields = try self.decodeObject(allocator, raw);
                if (fields.get("resultType")) |kind| {
                    if (kind != .string) return error.MalformedPeer;
                    if (std.mem.eql(u8, kind.string, "input_required")) {
                        if (revision != modern) return error.MalformedPeer;
                        const state = fields.get("requestState");
                        if (state) |value| if (value != .string) return error.MalformedPeer;
                        return .{ .raw = raw, .fields = fields, .kind = .{ .input_required = if (state) |value| value.string else null } };
                    }
                    if (!std.mem.eql(u8, kind.string, "complete")) return error.MalformedPeer;
                } else if (revision == modern) return error.MalformedPeer;
                return .{ .raw = raw, .fields = fields };
            },
        }
    }

    pub fn decodeObject(self: *const Client, allocator: Allocator, bytes: []const u8) Error!Object {
        foo.wire.json.validate(bytes, self.jsonLimits()) catch |err| return switch (err) {
            error.InvalidJson => error.MalformedPeer,
            else => error.LimitExceeded,
        };
        const decoded = std.json.parseFromSliceLeaky(Json, allocator, bytes, .{}) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.MalformedPeer,
        };
        if (decoded != .object) return error.MalformedPeer;
        return decoded.object;
    }

    fn jsonLimits(self: *const Client) foo.wire.json.Limits {
        return .{ .max_bytes = self.options.limits.wire_message_bytes, .max_depth = self.options.limits.json_depth };
    }

    fn next(self: *Client) Error!i64 {
        var id = self.next_id.load(.acquire);
        while (id < std.math.maxInt(i64))
            id = self.next_id.cmpxchgWeak(id, id + 1, .acq_rel, .acquire) orelse return id;
        return error.LimitExceeded;
    }

    fn markChanged(self: *Client) void {
        _ = self.change_epoch.fetchAdd(1, .acq_rel);
    }

    fn observer(self: *Client) link.Observer {
        return .{ .context = self, .notify_fn = notifyChange };
    }

    fn notifyChange(context: *anyopaque, _: foo.io.Context, message: foo.jsonrpc.Request) foo.io.Error!void {
        const self: *Client = @ptrCast(@alignCast(context));
        if (message.id == null and Filter.key(message.method) != null) self.markChanged();
    }
};

fn clientInfo() struct { name: []const u8, version: []const u8 } {
    return .{ .name = "foo", .version = foo.version };
}

fn supports(value: ?Json, revision: foo.config.McpRevision) Error!bool {
    const list = value orelse return error.MalformedPeer;
    if (list != .array or list.array.items.len == 0) return error.MalformedPeer;
    var found = false;
    for (list.array.items) |item| {
        if (item != .string) return error.MalformedPeer;
        found = found or std.mem.eql(u8, item.string, @tagName(revision));
    }
    return found;
}

fn capabilitiesOf(value: ?Json) Error!Capabilities {
    const capabilities = value orelse return error.MalformedPeer;
    if (capabilities != .object) return error.MalformedPeer;
    var result: Capabilities = .{};
    inline for (.{
        .{ "tools", "tools_changed" },
        .{ "resources", "resources_changed" },
        .{ "prompts", "prompts_changed" },
    }) |pair| {
        if (capabilities.object.get(pair[0])) |entry| {
            if (entry != .object) return error.MalformedPeer;
            @field(result, pair[0]) = true;
            if (entry.object.get("listChanged")) |flag| {
                if (flag != .bool) return error.MalformedPeer;
                @field(result, pair[1]) = flag.bool;
            }
        }
    }
    return result;
}

const Filter = struct {
    toolsListChanged: bool = false,
    promptsListChanged: bool = false,
    resourcesListChanged: bool = false,

    fn fromCapabilities(capabilities: Capabilities) Filter {
        return .{
            .toolsListChanged = capabilities.tools_changed,
            .promptsListChanged = capabilities.prompts_changed,
            .resourcesListChanged = capabilities.resources_changed,
        };
    }

    fn key(method: []const u8) ?std.meta.FieldEnum(Filter) {
        const methods = .{
            .{ "notifications/tools/list_changed", .toolsListChanged },
            .{ "notifications/prompts/list_changed", .promptsListChanged },
            .{ "notifications/resources/list_changed", .resourcesListChanged },
        };
        inline for (methods) |entry| if (std.mem.eql(u8, entry[0], method)) return entry[1];
        return null;
    }
};

const Subscription = struct {
    client: *Client,
    id: i64,
    requested: Filter,
    acknowledged: ?Filter = null,
    ack_observed: std.atomic.Value(bool) = .init(false),

    fn matches(self: *const Subscription, params: Object) bool {
        const metadata = params.get("_meta") orelse return false;
        if (metadata != .object) return false;
        const subscription = metadata.object.get(subscription_id_key) orelse return false;
        return subscription == .integer and subscription.integer == self.id;
    }

    fn notify(context: *anyopaque, operation: foo.io.Context, message: foo.jsonrpc.Request) foo.io.Error!void {
        const self: *Subscription = @ptrCast(@alignCast(context));
        try operation.check();
        if (message.id != null) return error.InvalidInput;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const data = self.client.decodeObject(arena.allocator(), message.params_json orelse return error.InvalidInput) catch return error.InvalidInput;
        if (!self.matches(data)) return error.InvalidInput;
        if (std.mem.eql(u8, message.method, "notifications/subscriptions/acknowledged")) {
            if (self.acknowledged != null) return error.InvalidInput;
            const filters = data.get("notifications") orelse return error.InvalidInput;
            if (filters != .object) return error.InvalidInput;
            var accepted: Filter = .{};
            var it = filters.object.iterator();
            while (it.next()) |entry| {
                const field = std.meta.stringToEnum(std.meta.FieldEnum(Filter), entry.key_ptr.*) orelse return error.InvalidInput;
                if (entry.value_ptr.* != .bool) return error.InvalidInput;
                inline for (@typeInfo(Filter).@"struct".field_names) |name| {
                    if (field == @field(std.meta.FieldEnum(Filter), name)) {
                        if (entry.value_ptr.bool and !@field(self.requested, name)) return error.InvalidInput;
                        @field(accepted, name) = entry.value_ptr.bool;
                    }
                }
            }
            self.acknowledged = accepted;
            self.ack_observed.store(true, .release);
            return;
        }
        const accepted = self.acknowledged orelse return error.InvalidInput;
        const field = Filter.key(message.method) orelse return error.InvalidInput;
        inline for (@typeInfo(Filter).@"struct".field_names) |name| {
            if (field == @field(std.meta.FieldEnum(Filter), name) and !@field(accepted, name)) return error.InvalidInput;
        }
        self.client.markChanged();
    }
};

const SubscriptionTimer = struct {
    origin: foo.io.Context,
    acknowledged: *const std.atomic.Value(bool),
    ack_deadline_ms: u64,
    token: foo.io.Cancellation = .{},
    ack_timeout: std.atomic.Value(bool) = .init(false),

    fn run(self: *SubscriptionTimer) void {
        while (true) {
            self.origin.check() catch {
                self.token.request();
                return;
            };
            if (!self.acknowledged.load(.acquire) and self.origin.clock.now() >= self.ack_deadline_ms) {
                self.ack_timeout.store(true, .release);
                self.token.request();
                return;
            }
            self.origin.io.sleep(.fromMilliseconds(10), .awake) catch return;
        }
    }
};
