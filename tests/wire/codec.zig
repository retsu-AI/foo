const std = @import("std");
const foo = @import("foo");
const json = foo.wire.json;
const jsonrpc = foo.wire.jsonrpc;
const t = std.testing;

test "JSON validates one UTF-8 value with inclusive byte and container limits" {
    try t.expectError(error.InvalidJson, json.validate("", .{ .max_bytes = 0 }));
    try json.validate(" true ", .{ .max_bytes = 6, .max_depth = 0 });
    try t.expectError(error.MessageTooLarge, json.validate(" true ", .{ .max_bytes = 5 }));
    try json.validate("{\"a\":[{}]}", .{ .max_depth = 3 });
    try t.expectError(error.NestingTooDeep, json.validate("{\"a\":[{}]}", .{ .max_depth = 2 }));
    try t.expectError(error.NestingTooDeep, json.validate("[]", .{ .max_depth = 0 }));

    for ([_][]const u8{ "true false", "[2", "{]", "[0,]", "{\"a\" 1}", "\"\xff\"", "\"\n\"", "\"\\uD800\"" }) |bad| {
        try t.expectError(error.InvalidJson, json.validate(bad, .{}));
    }
    try json.validate("\"\\uD83D\\uDE80\"", .{});
    try json.validate("\"🚀\"", .{});
}

test "JSON caps nesting even when the requested limit exceeds scanner capacity" {
    const depth = json.max_supported_depth + 1;
    var nested: [2 * depth + 1]u8 = undefined;
    @memset(nested[0..depth], '[');
    nested[depth] = '0';
    @memset(nested[depth + 1 ..], ']');
    const maximum = nested[1 .. nested.len - 1];
    try json.validate(maximum, .{ .max_depth = depth });
    try t.expectError(error.NestingTooDeep, json.validate(&nested, .{ .max_depth = depth }));
}

test "typed JSON decode honors options and restores scratch after a failed decode" {
    const Data = struct { name: []const u8 };
    var buffer: [8192]u8 align(@alignOf(usize)) = undefined;
    var scratch: std.heap.FixedBufferAllocator = .init(&buffer);
    const before = try scratch.allocator().dupe(u8, "keep");
    const checkpoint = scratch.end_index;

    try t.expectError(error.UnknownField, json.decode(Data, "{\"name\":\"a\\nb\",\"extra\":1}", &scratch, .{}, .{}));
    try t.expectEqual(checkpoint, scratch.end_index);
    try t.expectEqualStrings("keep", before);

    const parsed = try json.decode(Data, "{\"name\":\"a\\nb\",\"extra\":1}", &scratch, .{}, .{ .ignore_unknown_fields = true });
    try t.expectEqualStrings("a\nb", parsed.name);

    const large_number = "123456789012345678901234567890";
    const value = try json.decode(std.json.Value, "{\"n\":" ++ large_number ++ "}", &scratch, .{}, .{ .parse_numbers = false });
    try t.expectEqualStrings(large_number, value.object.get("n").?.number_string);

    var tiny_storage: [2]u8 = undefined;
    var tiny: std.heap.FixedBufferAllocator = .init(&tiny_storage);
    try t.expectError(error.OutOfMemory, json.decode([]const u8, "\"a\\nb\"", &tiny, .{}, .{ .allocate = .alloc_always }));
    try t.expectEqual(@as(usize, 0), tiny.end_index);
    try t.expectEqualStrings("plain", try json.decode([]const u8, "\"plain\"", &tiny, .{}, .{}));
}

test "RPC decodes notifications, typed IDs, escapes and exact opaque request fields" {
    const no_scratch = &.{};
    const notification = try jsonrpc.decode("{\"j\\u0073onrpc\":\"2\\u002e0\",\"method\":\"ping\",\"long\\u0065r-extra-field-with-escapes\":{\"x\":[1]}}", no_scratch, .{});
    try t.expectEqualStrings("ping", notification.request.method);
    try t.expect(notification.request.id == null);
    try t.expect(notification.request.params_json == null);

    const raw_params = "{ \"value\": [1, \"\\n\", 2.0e1] }";
    const input = " \r\n{\"params\" : \t " ++ raw_params ++ "  ,\"id\":1,\"method\":\"tools/call\",\"jsonrpc\":\"2.0\"}\t";
    const request = (try jsonrpc.decode(input, no_scratch, .{})).request;
    try t.expectEqualStrings(raw_params, request.params_json.?);
    try t.expect(request.params_json.?.ptr == input[std.mem.indexOf(u8, input, raw_params).?..].ptr);
    try t.expectEqual(@as(i64, 1), request.id.?.number);

    const escaped = "{\"jsonrpc\":\"2.0\",\"id\":\"\\u0031\",\"method\":\"\\uD83D\\uDE80\"}";
    var scratch: [5]u8 = undefined;
    try t.expectError(error.OutOfMemory, jsonrpc.decode(escaped, scratch[0..4], .{}));
    const other = (try jsonrpc.decode(escaped, &scratch, .{})).request;
    try t.expectEqualStrings("1", other.id.?.string);
    try t.expectEqualStrings("🚀", other.method);
    try t.expect(!foo.jsonrpc.Id.eql(request.id.?, other.id.?));
}

test "RPC decodes raw success and error payloads and an unknown error ID" {
    const success = (try jsonrpc.decode(
        "{\"jsonrpc\":\"2.0\",\"id\":-9223372036854775808,\"result\":[ false, 1e9999 ] }",
        &.{},
        .{},
    )).response.success;
    try t.expectEqual(std.math.minInt(i64), success.id.number);
    try t.expectEqualStrings("[ false, 1e9999 ]", success.result_json);

    var scratch: [32]u8 = undefined;
    const failure = (try jsonrpc.decode(
        "{\"error\":{\"data\": \"f\\u006fo\", \"message\":\"bad\\nrequest\",\"code\":-32600,\"extension\":5},\"id\":null,\"jsonrpc\":\"2.0\"}",
        &scratch,
        .{},
    )).response.failure;
    try t.expect(failure.id == null);
    try t.expectEqual(foo.jsonrpc.Code.invalid_request, failure.err.code);
    try t.expectEqualStrings("bad\nrequest", failure.err.message);
    try t.expectEqualStrings("\"f\\u006fo\"", failure.err.data_json.?);
}

test "RPC reports syntax, limits, batches and malformed envelopes distinctly" {
    const fixtures = [_]struct { err: jsonrpc.DecodeError, input: []const u8 }{
        .{ .err = error.InvalidJson, .input = "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"unknown\":[,]}" },
        .{ .err = error.InvalidJson, .input = "[x]" },
        .{ .err = error.InvalidJson, .input = "{} {}" },
        .{ .err = error.UnsupportedBatch, .input = " [ {} ] " },
        .{ .err = error.InvalidEnvelope, .input = "null" },
        .{ .err = error.InvalidEnvelope, .input = "{}" },
        .{ .err = error.InvalidEnvelope, .input = "{\"jsonrpc\":\"1.0\",\"method\":\"ping\"}" },
        .{ .err = error.InvalidEnvelope, .input = "{\"jsonrpc\":2.0,\"method\":\"ping\"}" },
        .{ .err = error.InvalidEnvelope, .input = "{\"jsonrpc\":\"2.0\",\"method\":5}" },
        .{ .err = error.InvalidEnvelope, .input = "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"params\":null}" },
        .{ .err = error.InvalidEnvelope, .input = "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"result\":null}" },
        .{ .err = error.InvalidEnvelope, .input = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null,\"error\":null}" },
        .{ .err = error.InvalidEnvelope, .input = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null,\"params\":[]}" },
        .{ .err = error.InvalidEnvelope, .input = "{\"jsonrpc\":\"2.0\",\"result\":null}" },
        .{ .err = error.InvalidEnvelope, .input = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":0,\"message\":\"bad\"}}" },
        .{ .err = error.InvalidEnvelope, .input = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":[]}" },
        .{ .err = error.InvalidEnvelope, .input = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":1.0,\"message\":\"bad\"}}" },
        .{ .err = error.InvalidEnvelope, .input = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":2147483648,\"message\":\"bad\"}}" },
        .{ .err = error.InvalidEnvelope, .input = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":1,\"message\":null}}" },
        .{ .err = error.UnsupportedId, .input = "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"ping\"}" },
        .{ .err = error.UnsupportedId, .input = "{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":null}" },
        .{ .err = error.UnsupportedId, .input = "{\"jsonrpc\":\"2.0\",\"id\":1.0,\"result\":null}" },
        .{ .err = error.UnsupportedId, .input = "{\"jsonrpc\":\"2.0\",\"id\":1e0,\"result\":null}" },
        .{ .err = error.UnsupportedId, .input = "{\"jsonrpc\":\"2.0\",\"id\":9223372036854775808,\"result\":null}" },
        .{ .err = error.UnsupportedId, .input = "{\"jsonrpc\":\"2.0\",\"id\":true,\"result\":null}" },
        .{ .err = error.DuplicateField, .input = "{\"jsonrpc\":\"2.0\",\"method\":\"a\",\"m\\u0065thod\":\"b\"}" },
        .{ .err = error.DuplicateField, .input = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":0,\"message\":\"x\",\"d\\u0061ta\":null,\"data\":true}}" },
    };
    for (fixtures) |fixture| {
        try t.expectError(fixture.err, jsonrpc.decode(fixture.input, &.{}, .{}));
    }
    const over_depth = "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"unknown\":[[1]]}";
    try t.expectError(error.NestingTooDeep, jsonrpc.decode(over_depth, &.{}, .{ .max_depth = 2 }));
    try t.expectError(error.MessageTooLarge, jsonrpc.decode(over_depth, &.{}, .{ .max_bytes = over_depth.len - 1 }));
}

test "RPC compactly encodes request and response values without changing opaque string or number syntax" {
    const params = " \r\n{ \"nested\": [ -0, 1e+90, \"space  and \\\"quotes\\\" \\\\ \\n\" ] } \n";
    var output: [256]u8 = undefined;
    var scratch: [64]u8 = undefined;
    const request: foo.jsonrpc.Request = .{
        .id = .{ .string = "id\r" },
        .method = "method\n",
        .params_json = params,
    };
    const encoded = try jsonrpc.encodeRequest(&output, request, .{});
    try t.expect(std.mem.indexOfAny(u8, encoded, "\r\n") == null);
    const parsed = (try jsonrpc.decode(encoded, &scratch, .{})).request;
    try t.expect(foo.jsonrpc.Id.eql(request.id.?, parsed.id.?));
    try t.expectEqualStrings(request.method, parsed.method);
    try t.expectEqualStrings("{\"nested\":[-0,1e+90,\"space  and \\\"quotes\\\" \\\\ \\n\"]}", parsed.params_json.?);

    const notification = try jsonrpc.encodeRequest(&output, .{ .id = null, .method = "ping" }, .{});
    try t.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}", notification);

    const success: foo.jsonrpc.Response = .{ .success = .{
        .id = .{ .number = std.math.maxInt(i64) },
        .result_json = " null\r\n ",
    } };
    const decoded_success = (try jsonrpc.decode(try jsonrpc.encodeResponse(&output, success, .{}), &scratch, .{})).response.success;
    try t.expectEqual(std.math.maxInt(i64), decoded_success.id.number);
    try t.expectEqualStrings("null", decoded_success.result_json);

    const failure: foo.jsonrpc.Response = .{ .failure = .{
        .err = .{ .code = -1, .message = "failure\r\n", .data_json = "\n { \"ext\": \"\\u0061\" } " },
    } };
    const encoded_error = try jsonrpc.encodeResponse(&output, failure, .{});
    try t.expect(std.mem.indexOfAny(u8, encoded_error, "\r\n") == null);
    try t.expect(std.mem.indexOf(u8, encoded_error, "\"id\":null") != null);
    const decoded_error = (try jsonrpc.decode(encoded_error, &scratch, .{})).response.failure;
    try t.expect(decoded_error.id == null);
    try t.expectEqualStrings(failure.failure.err.message, decoded_error.err.message);
    try t.expectEqualStrings("{\"ext\":\"\\u0061\"}", decoded_error.err.data_json.?);
}

test "RPC encode enforces output and opaque fragment limits" {
    var output: [128]u8 = undefined;
    const request: foo.jsonrpc.Request = .{ .id = null, .method = "ping", .params_json = "[]" };
    const encoded = try jsonrpc.encodeRequest(&output, request, .{});
    try t.expectError(error.BufferTooSmall, jsonrpc.encodeRequest(output[0 .. encoded.len - 1], request, .{}));
    try t.expectError(error.MessageTooLarge, jsonrpc.encodeRequest(&output, request, .{ .max_bytes = encoded.len - 1 }));
    try t.expectEqual(encoded.len, (try jsonrpc.encodeRequest(output[0..encoded.len], request, .{ .max_bytes = encoded.len, .max_depth = 2 })).len);
    try t.expectError(error.NestingTooDeep, jsonrpc.encodeRequest(&output, request, .{ .max_depth = 1 }));
    try t.expectError(error.InvalidEnvelope, jsonrpc.encodeRequest(&output, .{ .id = null, .method = "ping", .params_json = "7" }, .{}));
    try t.expectError(error.InvalidJson, jsonrpc.encodeRequest(&output, .{ .id = null, .method = "ping", .params_json = "[}" }, .{}));
    try t.expectError(error.InvalidJson, jsonrpc.encodeRequest(&output, .{ .id = null, .method = "\xff" }, .{}));

    const response: foo.jsonrpc.Response = .{ .failure = .{ .err = .{ .code = 0, .message = "", .data_json = "[0]" } } };
    try t.expectError(error.NestingTooDeep, jsonrpc.encodeResponse(&output, response, .{ .max_depth = 2 }));
    _ = try jsonrpc.encodeResponse(&output, response, .{ .max_depth = 3 });
}
