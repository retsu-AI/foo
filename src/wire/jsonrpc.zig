//! JSON-RPC 2.0 envelope codec shared by MCP and ACP.
const std = @import("std");
const json = @import("json.zig");
const rpc = @import("../contracts/jsonrpc.zig");

pub const Envelope = union(enum) {
    request: rpc.Request,
    response: rpc.Response,
};

pub const DecodeError = json.ValidationError || error{
    InvalidEnvelope,
    UnsupportedBatch,
    DuplicateField,
    UnsupportedId,
    OutOfMemory,
};

pub const EncodeError = json.ValidationError || error{
    InvalidEnvelope,
    BufferTooSmall,
};

const whitespace = " \t\r\n";
const EnvelopeField = enum { jsonrpc, id, method, params, result, @"error" };
const ErrorField = enum { code, message, data };

/// The envelope borrows opaque JSON and unescaped strings from input.
/// Escaped method, ID, and message strings borrow caller scratch, which must
/// be disjoint from input.
pub fn decode(input: []const u8, scratch: []u8, limits: json.Limits) DecodeError!Envelope {
    try json.validate(input, limits);
    const value = std.mem.trimStart(u8, input, whitespace);
    if (value[0] == '[') return error.UnsupportedBatch;
    const fields = try readFields(EnvelopeField, value);

    const version = fields.get(.jsonrpc) orelse return error.InvalidEnvelope;
    if (!isVersion(version)) return error.InvalidEnvelope;

    var strings = scratch;
    const id = fields.get(.id);
    const params = fields.get(.params);
    const result = fields.get(.result);
    const failure = fields.get(.@"error");

    if (fields.get(.method)) |method| {
        if (result != null or failure != null) return error.InvalidEnvelope;
        if (params) |raw| {
            if (raw[0] != '{' and raw[0] != '[') return error.InvalidEnvelope;
        }
        return .{ .request = .{
            .id = if (id) |raw| try readId(raw, &strings) else null,
            .method = try readString(method, &strings),
            .params_json = params,
        } };
    }

    if (params != null) return error.InvalidEnvelope;
    const response_id = id orelse return error.InvalidEnvelope;
    if (result) |raw| {
        if (failure != null) return error.InvalidEnvelope;
        return .{ .response = .{ .success = .{
            .id = try readId(response_id, &strings),
            .result_json = raw,
        } } };
    }

    const error_value = failure orelse return error.InvalidEnvelope;
    const details = try readFields(ErrorField, error_value);
    const code = details.get(.code) orelse return error.InvalidEnvelope;
    const message = details.get(.message) orelse return error.InvalidEnvelope;
    return .{ .response = .{ .failure = .{
        .id = if (response_id[0] == 'n') null else try readId(response_id, &strings),
        .err = .{
            .code = std.fmt.parseInt(i32, code, 10) catch return error.InvalidEnvelope,
            .message = try readString(message, &strings),
            .data_json = details.get(.data),
        },
    } } };
}

// Input passed to these helpers has already passed complete JSON validation.
fn readFields(comptime Field: type, input: []const u8) DecodeError!std.EnumArray(Field, ?[]const u8) {
    var buffer: json.ScannerBuffer = .{};
    var scanner = buffer.init(input);
    defer scanner.deinit();
    if ((scanner.next() catch unreachable) != .object_begin) return error.InvalidEnvelope;

    const max_name_len = comptime blk: {
        var longest = 0;
        for (@typeInfo(Field).@"enum".field_names) |name| longest = @max(longest, name.len);
        break :blk longest;
    };
    var name_buffer: [max_name_len]u8 = undefined;
    var fields: std.EnumArray(Field, ?[]const u8) = .initFill(null);
    while ((scanner.peekNextTokenType() catch unreachable) != .object_end) {
        const field = if (readStringToken(&scanner, &name_buffer)) |name|
            std.meta.stringToEnum(Field, name.bytes)
        else
            null;
        _ = scanner.peekNextTokenType() catch unreachable;
        const start = scanner.cursor;
        scanner.skipValue() catch unreachable;
        if (field) |known| {
            if (fields.get(known) != null) return error.DuplicateField;
            fields.set(known, input[start..scanner.cursor]);
        }
    }
    return fields;
}

fn isVersion(input: []const u8) bool {
    if (input[0] != '"') return false;
    var scanner: std.json.Scanner = .initCompleteInput(std.mem.Allocator.failing, input);
    defer scanner.deinit();
    var buffer: [3]u8 = undefined;
    const version = readStringToken(&scanner, &buffer) orelse return false;
    return std.mem.eql(u8, version.bytes, "2.0");
}

const DecodedString = struct { bytes: []const u8, scratch_used: usize = 0 };

// Consume oversized strings too, so an unknown field name never needs scratch.
fn readStringToken(scanner: *std.json.Scanner, buffer: []u8) ?DecodedString {
    var token = scanner.next() catch unreachable;
    if (token == .string) return .{ .bytes = token.string };
    var len: usize = 0;
    while (true) : (token = scanner.next() catch unreachable) {
        switch (token) {
            .string, .partial_string => |part| len = appendSmall(buffer, len, part),
            inline .partial_string_escaped_1,
            .partial_string_escaped_2,
            .partial_string_escaped_3,
            .partial_string_escaped_4,
            => |part| len = appendSmall(buffer, len, &part),
            else => unreachable,
        }
        if (token == .string) {
            if (len > buffer.len) return null;
            return .{ .bytes = buffer[0..len], .scratch_used = len };
        }
    }
}

fn appendSmall(buffer: []u8, len: usize, part: []const u8) usize {
    if (len > buffer.len or part.len > buffer.len - len) return buffer.len + 1;
    @memcpy(buffer[len..][0..part.len], part);
    return len + part.len;
}

fn readString(input: []const u8, scratch: *[]u8) DecodeError![]const u8 {
    if (input[0] != '"') return error.InvalidEnvelope;
    var scanner: std.json.Scanner = .initCompleteInput(std.mem.Allocator.failing, input);
    defer scanner.deinit();
    const decoded = readStringToken(&scanner, scratch.*) orelse return error.OutOfMemory;
    scratch.* = scratch.*[decoded.scratch_used..];
    return decoded.bytes;
}

fn readId(input: []const u8, scratch: *[]u8) DecodeError!rpc.Id {
    return switch (input[0]) {
        '"' => .{ .string = try readString(input, scratch) },
        '-', '0'...'9' => .{ .number = std.fmt.parseInt(i64, input, 10) catch return error.UnsupportedId },
        else => error.UnsupportedId,
    };
}

/// Returns a compact JSON message in output, ready for newline framing.
/// Output must be disjoint from the request's slices.
pub fn encodeRequest(output: []u8, request: rpc.Request, limits: json.Limits) EncodeError![]const u8 {
    return encode(output, .{ .request = request }, limits);
}

/// Returns a compact JSON message in output, ready for newline framing.
/// Output must be disjoint from the response's slices.
pub fn encodeResponse(output: []u8, response: rpc.Response, limits: json.Limits) EncodeError![]const u8 {
    return encode(output, .{ .response = response }, limits);
}

const WriteError = EncodeError || std.Io.Writer.Error;

fn encode(output: []u8, envelope: Envelope, limits: json.Limits) EncodeError![]const u8 {
    const bounded: json.Limits = .{
        .max_bytes = limits.max_bytes,
        .max_depth = @min(limits.max_depth, json.max_supported_depth),
    };
    var writer: std.Io.Writer = .fixed(output[0..@min(output.len, bounded.max_bytes)]);
    var stream: std.json.Stringify = .{ .writer = &writer };
    writeEnvelope(&stream, envelope, bounded) catch |err| switch (err) {
        error.WriteFailed => return if (output.len < bounded.max_bytes)
            error.BufferTooSmall
        else
            error.MessageTooLarge,
        else => |reason| return reason,
    };
    return writer.buffered();
}

fn writeEnvelope(stream: *std.json.Stringify, envelope: Envelope, limits: json.Limits) WriteError!void {
    if (limits.max_depth == 0) return error.NestingTooDeep;
    try stream.beginObject();
    try stream.objectField("jsonrpc");
    try stream.write("2.0");
    switch (envelope) {
        .request => |request| {
            if (request.id) |id| try writeId(stream, id, limits);
            try stream.objectField("method");
            try writeString(stream, request.method, limits);
            if (request.params_json) |params| {
                try stream.objectField("params");
                try writeRaw(stream, params, limits, 1, .params);
            }
        },
        .response => |response| switch (response) {
            .success => |success| {
                try writeId(stream, success.id, limits);
                try stream.objectField("result");
                try writeRaw(stream, success.result_json, limits, 1, .any);
            },
            .failure => |failure| {
                if (limits.max_depth < 2) return error.NestingTooDeep;
                try writeId(stream, failure.id, limits);
                try stream.objectField("error");
                try stream.beginObject();
                try stream.objectField("code");
                try stream.write(failure.err.code);
                try stream.objectField("message");
                try writeString(stream, failure.err.message, limits);
                if (failure.err.data_json) |data| {
                    try stream.objectField("data");
                    try writeRaw(stream, data, limits, 2, .any);
                }
                try stream.endObject();
            },
        },
    }
    try stream.endObject();
}

fn writeId(stream: *std.json.Stringify, id: ?rpc.Id, limits: json.Limits) WriteError!void {
    try stream.objectField("id");
    if (id) |value| switch (value) {
        .string => |text| try writeString(stream, text, limits),
        .number => |number| try stream.write(number),
    } else try stream.write(null);
}

fn writeString(stream: *std.json.Stringify, value: []const u8, limits: json.Limits) WriteError!void {
    if (value.len > limits.max_bytes) return error.MessageTooLarge;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidJson;
    try stream.write(value);
}

fn writeRaw(
    stream: *std.json.Stringify,
    input: []const u8,
    limits: json.Limits,
    parent_depth: usize,
    kind: enum { params, any },
) WriteError!void {
    try json.validate(input, .{ .max_bytes = limits.max_bytes, .max_depth = limits.max_depth - parent_depth });
    const value = std.mem.trim(u8, input, whitespace);
    if (kind == .params and value[0] != '{' and value[0] != '[') return error.InvalidEnvelope;

    try stream.beginWriteRaw();
    var state: enum { outside, string, escape } = .outside;
    var start: usize = 0;
    for (value, 0..) |byte, index| {
        switch (state) {
            .outside => switch (byte) {
                '"' => state = .string,
                ' ', '\t', '\r', '\n' => {
                    try stream.writer.writeAll(value[start..index]);
                    start = index + 1;
                },
                else => {},
            },
            .string => switch (byte) {
                '\\' => state = .escape,
                '"' => state = .outside,
                else => {},
            },
            .escape => state = .string,
        }
    }
    try stream.writer.writeAll(value[start..]);
    stream.endWriteRaw();
}
