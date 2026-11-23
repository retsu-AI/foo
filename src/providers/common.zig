const std = @import("std");
const foo = @import("foo");
pub const p = foo.provider;
pub const Error = p.Error;
pub const Value = std.json.Value;

pub fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn field(value: Value, name: []const u8) ?Value {
    return if (value == .object) value.object.get(name) else null;
}

pub fn required(value: Value, name: []const u8) Error!Value {
    return field(value, name) orelse error.Protocol;
}

pub fn string(value: Value) Error![]const u8 {
    return if (value == .string) value.string else error.Protocol;
}

pub fn str(value: Value, name: []const u8) Error![]const u8 {
    return string(try required(value, name));
}

pub fn array(value: Value) Error![]const Value {
    return if (value == .array) value.array.items else error.Protocol;
}

pub fn number(value: Value) Error!u64 {
    if (value != .integer or value.integer < 0) return error.Protocol;
    return @intCast(value.integer);
}

pub fn index(value: Value) Error!usize {
    return std.math.cast(usize, try number(try required(value, "index"))) orelse error.LimitExceeded;
}

pub fn parse(a: std.mem.Allocator, input: []const u8, limits: foo.config.Limits) Error!Value {
    if (input.len > limits.wire_message_bytes) return error.LimitExceeded;
    const payload_size = std.math.mul(usize, input.len, 16) catch return error.LimitExceeded;
    const scratch_size = std.math.add(usize, payload_size, 4096) catch return error.LimitExceeded;
    const scratch = try a.create(std.heap.FixedBufferAllocator);
    scratch.* = .init(try a.alloc(u8, scratch_size));
    return foo.wire.json.decode(Value, input, scratch, .{ .max_bytes = limits.wire_message_bytes, .max_depth = limits.json_depth }, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory, error.MessageTooLarge, error.NestingTooDeep => return error.LimitExceeded,
        else => return error.Protocol,
    };
}

pub const Json = struct {
    a: std.mem.Allocator,

    pub fn object(_: Json) Value {
        return .{ .object = .empty };
    }

    pub fn list(self: Json) Value {
        return .{ .array = .init(self.a) };
    }

    pub fn put(self: Json, obj: *Value, key: []const u8, value: Value) Error!void {
        try obj.object.put(self.a, key, value);
    }

    pub fn add(_: Json, values: *Value, value: Value) Error!void {
        try values.array.append(value);
    }

    pub fn text(self: Json, obj: *Value, key: []const u8, value: []const u8) Error!void {
        try self.put(obj, key, .{ .string = value });
    }

    pub fn typed(self: Json, name: []const u8) Error!Value {
        var obj = self.object();
        try self.text(&obj, "type", name);
        return obj;
    }

    pub fn encode(self: Json, value: Value, limit: usize) Error![]const u8 {
        var counting_buffer: [256]u8 = undefined;
        var counter = std.Io.Writer.Discarding.init(&counting_buffer);
        std.json.Stringify.value(value, .{}, &counter.writer) catch return error.LimitExceeded;
        const size = std.math.cast(usize, counter.fullCount()) orelse return error.LimitExceeded;
        if (size > limit) return error.LimitExceeded;
        const buffer = try self.a.alloc(u8, size);
        var writer = std.Io.Writer.fixed(buffer);
        std.json.Stringify.value(value, .{}, &writer) catch return error.LimitExceeded;
        return writer.buffered();
    }
};

pub const State = struct {
    a: std.mem.Allocator,
    model: foo.config.Model,
    limits: foo.config.Limits,
    operation: foo.io.Context,
    sink: p.Sink,
    budget: foo.io.Budget,
    blocks: std.ArrayList(p.Block) = .empty,
    calls: u32 = 0,
    usage: p.Usage = .{},
    stop: ?p.Stop = null,
    terminal: bool = false,

    pub fn copy(self: *State, bytes: []const u8) Error![]const u8 {
        try self.budget.take(bytes.len);
        return self.a.dupe(u8, bytes);
    }

    pub fn append(self: *State, buffer: *std.ArrayList(u8), bytes: []const u8) Error!void {
        try self.budget.take(bytes.len);
        try buffer.appendSlice(self.a, bytes);
    }

    pub fn block(self: *State, value: p.Block) Error!void {
        try self.budget.take(@sizeOf(p.Block));
        try self.blocks.append(self.a, value);
    }

    pub fn tool(self: *State) Error!void {
        if (self.calls == self.limits.tool_calls) return error.LimitExceeded;
        self.calls += 1;
    }

    pub fn emit(self: *State, delta: p.Delta) Error!void {
        const bytes = switch (delta) {
            .text, .reasoning => |v| v,
            .tool_arguments => |v| v.bytes,
        };
        if (bytes.len == 0) return;
        try self.sink.emit(self.operation, delta);
    }

    pub fn replay(self: *State, value: Value) Error!void {
        try self.budget.take(self.model.endpoint.len);
        try self.budget.take(self.model.id.len);
        const bytes = try (Json{ .a = self.a }).encode(value, @min(self.limits.wire_message_bytes, self.budget.limit -| self.budget.used));
        try self.budget.take(bytes.len);
        try self.block(.{ .replay = .{ .family = self.model.family, .endpoint = self.model.endpoint, .model = self.model.id, .bytes = bytes } });
    }

    pub fn arguments(self: *State, bytes: []const u8, complete: bool) Error!void {
        if (bytes.len > self.limits.tool_argument_bytes) return error.LimitExceeded;
        if (complete) {
            foo.wire.json.validate(bytes, .{ .max_bytes = self.limits.tool_argument_bytes, .max_depth = self.limits.json_depth }) catch |err| switch (err) {
                error.InvalidJson => if (self.model.family == .anthropic_messages) return error.Protocol,
                else => return error.LimitExceeded,
            };
            if (self.model.family == .anthropic_messages and !std.mem.startsWith(u8, std.mem.trim(u8, bytes, " \t\r\n"), "{")) return error.Protocol;
        }
    }

    pub fn finish(self: *State, result: std.mem.Allocator) Error!p.Response {
        if (!self.terminal) return error.Disconnected;
        const stop = self.stop orelse return error.Protocol;
        var ids: std.StringHashMapUnmanaged(void) = .empty;
        for (self.blocks.items) |block_value| switch (block_value) {
            .tool_call => |call| {
                if (call.id.len == 0 or call.name.len == 0) return error.Protocol;
                const entry = try ids.getOrPut(self.a, call.id);
                if (entry.found_existing) return error.Protocol;
                try self.arguments(call.arguments_json, stop == .tool_use or stop == .end_turn);
            },
            else => {},
        };
        if (stop == .tool_use and self.calls == 0) return error.Protocol;
        if (stop == .end_turn and self.calls != 0) return error.Protocol;
        return .{ .message = try p.copyMessage(result, .{ .role = .assistant, .blocks = self.blocks.items }), .stop = stop, .usage = self.usage };
    }
};

pub fn optionalCount(value: Value, name: []const u8) Error!?u64 {
    const entry = field(value, name) orelse return null;
    if (entry == .null) return null;
    return try number(entry);
}

pub fn openAiUsage(value: Value, current: *p.Usage, shape: enum { chat, responses }) Error!void {
    if (value == .null) return;
    if (value != .object) return error.Protocol;
    const is_chat = shape == .chat;
    if (try optionalCount(value, if (is_chat) "prompt_tokens" else "input_tokens")) |count| current.input_tokens = count;
    if (try optionalCount(value, if (is_chat) "completion_tokens" else "output_tokens")) |count| current.output_tokens = count;
    if (is_chat) {
        if (try optionalCount(value, "prompt_cache_hit_tokens")) |count| current.cache_read_tokens = count;
    }
    if (field(value, if (is_chat) "prompt_tokens_details" else "input_tokens_details")) |details| {
        if (details == .null) return;
        if (details != .object) return error.Protocol;
        if (try optionalCount(details, "cached_tokens")) |count| current.cache_read_tokens = count;
    }
}

pub fn apiError(value: Value) Error {
    const info = field(value, "error") orelse value;
    const kind = field(info, "code") orelse field(info, "type") orelse return error.Rejected;
    const code = string(kind) catch return error.Protocol;
    if (eq(code, "authentication_error") or eq(code, "invalid_api_key") or eq(code, "permission_error")) return error.Authentication;
    if (eq(code, "rate_limit_error") or eq(code, "rate_limit_exceeded")) return error.RateLimited;
    if (eq(code, "api_error") or eq(code, "overloaded_error") or eq(code, "server_error")) return error.Unavailable;
    return error.Rejected;
}
