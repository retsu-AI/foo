const std = @import("std");
const foo = @import("foo");

pub const version = 1;
pub const control_bytes = 1024;
const id_bytes = 128;
pub const max_prompt_bytes = 1024 * 1024;

pub const ErrorCode = enum {
    invalid_command,
    unsupported_version,
    unknown_command,
    busy,
    no_active_run,
    limit_exceeded,
};

pub const Command = union(enum) {
    prompt: []const u8,
    cancel: u64,
    reject: ErrorCode,
};

pub const Request = struct {
    id: ?[]const u8 = null,
    command: Command = .{ .reject = .invalid_command },
};

const Envelope = struct {
    version: Unsigned(u32),
    id: String,
    command: String,
    prompt: ?String = null,
    run: ?Unsigned(u64) = null,
};

pub fn decode(a: std.mem.Allocator, record: []const u8, limits: foo.config.Limits) foo.io.Error!Request {
    foo.wire.json.validate(record, .{
        .max_bytes = limits.wire_message_bytes,
        .max_depth = limits.json_depth,
    }) catch |err| return switch (err) {
        error.MessageTooLarge, error.NestingTooDeep => .{ .command = .{ .reject = .limit_exceeded } },
        error.InvalidJson => .{},
    };
    const input = std.json.parseFromSliceLeaky(Envelope, a, record, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .id = try recoverId(a, record) },
    };
    if (!validId(input.id.value)) return .{};
    const command: Command = command: {
        if (input.version.value != version) break :command .{ .reject = .unsupported_version };
        if (std.mem.eql(u8, input.command.value, "prompt")) {
            if (input.run != null) break :command .{ .reject = .invalid_command };
            const prompt = (input.prompt orelse break :command .{ .reject = .invalid_command }).value;
            if (prompt.len == 0) break :command .{ .reject = .invalid_command };
            if (prompt.len > @min(max_prompt_bytes, limits.transcript_bytes)) break :command .{ .reject = .limit_exceeded };
            break :command .{ .prompt = prompt };
        }
        if (std.mem.eql(u8, input.command.value, "cancel")) {
            if (input.prompt != null) break :command .{ .reject = .invalid_command };
            const run = (input.run orelse break :command .{ .reject = .invalid_command }).value;
            if (run == 0) break :command .{ .reject = .invalid_command };
            break :command .{ .cancel = run };
        }
        break :command .{ .reject = .unknown_command };
    };
    return .{ .id = input.id.value, .command = command };
}

fn recoverId(a: std.mem.Allocator, record: []const u8) foo.io.Error!?[]const u8 {
    const Header = struct { id: String };
    const header = std.json.parseFromSliceLeaky(Header, a, record, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return if (validId(header.id.value)) header.id.value else null;
}

const String = struct {
    value: []const u8,

    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !String {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        return .{ .value = try std.json.innerParse([]const u8, a, source, options) };
    }
};

fn Unsigned(comptime T: type) type {
    return struct {
        value: T,

        pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            if (try source.peekNextTokenType() != .number) return error.UnexpectedToken;
            const token = try source.nextAllocMax(a, .alloc_if_needed, options.max_value_len.?);
            const bytes = switch (token) {
                .number, .allocated_number => |value| value,
                else => unreachable,
            };
            for (bytes) |byte| if (!std.ascii.isDigit(byte)) return error.UnexpectedToken;
            return .{ .value = std.fmt.parseInt(T, bytes, 10) catch return error.UnexpectedToken };
        }
    };
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > id_bytes) return false;
    for (id) |byte| if (std.ascii.isControl(byte)) return false;
    return true;
}

pub const Reply = struct {
    version: u32 = version_value,
    id: ?[]const u8,
    run: ?u64 = null,
    type: enum { accepted, cancel_ack, event, result, @"error" },
    code: ?ErrorCode = null,
    event: ?Event = null,
    outcome: ?foo.events.Outcome = null,
};

const version_value = version;

pub const Event = union(enum) {
    delta: foo.provider.Delta,
    message_committed: struct { sequence: u64, message: PublicMessage },
    tool_committed: @FieldType(@FieldType(foo.events.Event, "data"), "tool_committed"),

    pub fn from(event: foo.events.Event) ?Event {
        return switch (event.data) {
            .finished => null,
            .delta => |delta| .{ .delta = delta },
            .message_committed => |commit| .{ .message_committed = .{
                .sequence = commit.sequence,
                .message = .{ .value = commit.message },
            } },
            .tool_committed => |commit| .{ .tool_committed = commit },
        };
    }
};

const PublicMessage = struct {
    value: foo.provider.Message,

    pub fn jsonStringify(self: PublicMessage, json: *std.json.Stringify) std.json.Stringify.Error!void {
        try json.beginObject();
        try json.objectField("role");
        try json.write(self.value.role);
        try json.objectField("blocks");
        try json.beginArray();
        for (self.value.blocks) |block| switch (block) {
            .text => |text| try json.write(.{ .text = text }),
            .reasoning => |reasoning| try json.write(.{ .reasoning = .{ .text = reasoning.text } }),
            .tool_call => |call| try json.write(.{ .tool_call = call }),
            .tool_result => |result| try json.write(.{ .tool_result = result }),
            .replay => {},
        };
        try json.endArray();
        try json.endObject();
    }
};

pub fn encode(buffer: []u8, reply: Reply) foo.io.Error![]const u8 {
    if (buffer.len < 2) return error.LimitExceeded;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    std.json.Stringify.value(reply, .{ .emit_null_optional_fields = false }, &writer) catch return error.LimitExceeded;
    const n = writer.end;
    buffer[n] = '\n';
    return buffer[0 .. n + 1];
}
