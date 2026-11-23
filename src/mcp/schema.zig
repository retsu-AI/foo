const std = @import("std");
const foo = @import("foo");
const client = @import("client.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Object = std.json.ObjectMap;
pub const Error = client.Error || error{ UnsupportedSchema, InvalidHeaderSchema };

pub const Schema = struct {
    value: Value,
    mirrors: []const Mirror,

    const Mirror = struct {
        path: []const []const u8,
        name: []const u8,
    };

    pub fn compile(allocator: Allocator, value: Value, require_object: bool, mirror: bool) Error!Schema {
        if (require_object) {
            if (value != .object) return error.UnsupportedSchema;
            const kind = value.object.get("type") orelse return error.UnsupportedSchema;
            if (kind != .string or !eql(kind.string, "object")) return error.UnsupportedSchema;
        }
        var mirrors: std.ArrayList(Mirror) = .empty;
        var path: std.ArrayList([]const u8) = .empty;
        defer path.deinit(allocator);
        try checkNode(allocator, value, &path, if (mirror) &mirrors else null, mirror, true);
        return .{ .value = value, .mirrors = mirrors.items };
    }

    pub fn headers(self: Schema, allocator: Allocator, arguments: Object) Error![]const foo.io.Header {
        var result: std.ArrayList(foo.io.Header) = .empty;
        for (self.mirrors) |mirror| {
            const value = atPath(.{ .object = arguments }, mirror.path) orelse continue;
            const raw = switch (value) {
                .null => continue,
                .string => |text| text,
                .bool => |boolean| if (boolean) "true" else "false",
                .number_string => |num| try headerInteger(allocator, num),
                else => return error.InvalidInput,
            };
            try result.append(allocator, .{ .name = mirror.name, .value = raw });
        }
        return result.items;
    }

    pub fn accepts(self: Schema, value: Value) bool {
        return acceptsNode(self.value, value);
    }
};

const Kind = enum { object, array, string, boolean, null, number, integer };
const Keyword = enum {
    type,
    properties,
    required,
    additionalProperties,
    items,
    @"enum",
    @"const",
    minLength,
    maxLength,
    minItems,
    maxItems,
    minProperties,
    maxProperties,
    minimum,
    maximum,
    exclusiveMinimum,
    exclusiveMaximum,
    allOf,
    anyOf,
    oneOf,
    not,
    title,
    description,
    default,
    examples,
    deprecated,
    readOnly,
    writeOnly,
    format,
    @"$schema",
    @"$comment",
    @"x-mcp-header",
};

fn checkNode(
    allocator: Allocator,
    value: Value,
    path: *std.ArrayList([]const u8),
    mirrors: ?*std.ArrayList(Schema.Mirror),
    reachable: bool,
    root: bool,
) Error!void {
    if (value == .bool) return;
    if (value != .object) return error.UnsupportedSchema;
    const object = value.object;
    var iter = object.iterator();
    while (iter.next()) |field| {
        const key = std.meta.stringToEnum(Keyword, field.key_ptr.*) orelse return error.UnsupportedSchema;
        const argument = field.value_ptr.*;
        switch (key) {
            .type => if (!validType(argument)) return error.UnsupportedSchema,
            .properties => {
                if (argument != .object) return error.UnsupportedSchema;
                var properties = argument.object.iterator();
                while (properties.next()) |property| {
                    try path.append(allocator, property.key_ptr.*);
                    try checkNode(allocator, property.value_ptr.*, path, mirrors, reachable, false);
                    _ = path.pop();
                }
            },
            .required => {
                if (argument != .array) return error.UnsupportedSchema;
                for (argument.array.items) |item| if (item != .string) return error.UnsupportedSchema;
            },
            .additionalProperties, .items, .not => try checkNode(allocator, argument, path, mirrors, false, false),
            .allOf, .anyOf, .oneOf => {
                if (argument != .array or argument.array.items.len == 0) return error.UnsupportedSchema;
                for (argument.array.items) |child| try checkNode(allocator, child, path, mirrors, false, false);
            },
            .@"enum" => if (argument != .array or argument.array.items.len == 0) return error.UnsupportedSchema,
            .minLength, .maxLength, .minItems, .maxItems, .minProperties, .maxProperties => {
                _ = natural(argument) orelse return error.UnsupportedSchema;
            },
            .minimum, .maximum, .exclusiveMinimum, .exclusiveMaximum => {
                if (argument != .number_string or Decimal.parse(argument.number_string) == null)
                    return error.UnsupportedSchema;
            },
            .@"$schema" => {
                if (!root or argument != .string or !eql(argument.string, "https://json-schema.org/draft/2020-12/schema"))
                    return error.UnsupportedSchema;
            },
            .title, .description, .format, .@"$comment" => if (argument != .string) return error.UnsupportedSchema,
            .deprecated, .readOnly, .writeOnly => if (argument != .bool) return error.UnsupportedSchema,
            .examples => if (argument != .array) return error.UnsupportedSchema,
            .@"const", .default => {},
            .@"x-mcp-header" => {
                const headers = mirrors orelse continue;
                const kind = object.get("type") orelse return error.InvalidHeaderSchema;
                if (!reachable or root or argument != .string or !validHeaderName(argument.string) or
                    kind != .string or !(eql(kind.string, "string") or eql(kind.string, "integer") or eql(kind.string, "boolean")))
                    return error.InvalidHeaderSchema;
                const name = try std.fmt.allocPrint(allocator, "Mcp-Param-{s}", .{argument.string});
                for (headers.items) |existing| {
                    if (std.ascii.eqlIgnoreCase(existing.name, name)) return error.InvalidHeaderSchema;
                }
                try headers.append(allocator, .{ .name = name, .path = try allocator.dupe([]const u8, path.items) });
            },
        }
    }
}

fn acceptsNode(schema: Value, value: Value) bool {
    if (schema == .bool) return schema.bool;
    var iter = schema.object.iterator();
    while (iter.next()) |field| {
        const key = std.meta.stringToEnum(Keyword, field.key_ptr.*).?;
        const constraint = field.value_ptr.*;
        switch (key) {
            .type => if (!matchesType(constraint, value)) return false,
            .properties => if (value == .object) {
                for (constraint.object.keys(), constraint.object.values()) |name, child| {
                    if (value.object.get(name)) |property| if (!acceptsNode(child, property)) return false;
                }
            },
            .required => if (value == .object) {
                for (constraint.array.items) |name| if (!value.object.contains(name.string)) return false;
            },
            .additionalProperties => if (value == .object) {
                const properties = if (schema.object.get("properties")) |p| p.object else Object.empty;
                for (value.object.keys(), value.object.values()) |name, property| {
                    if (!properties.contains(name) and !acceptsNode(constraint, property)) return false;
                }
            },
            .items => if (value == .array) {
                for (value.array.items) |item| if (!acceptsNode(constraint, item)) return false;
            },
            .@"enum" => {
                for (constraint.array.items) |candidate| {
                    if (equal(candidate, value)) break;
                } else return false;
            },
            .@"const" => if (!equal(constraint, value)) return false,
            .minLength, .maxLength => if (value == .string) {
                const length = std.unicode.utf8CountCodepoints(value.string) catch return false;
                if (!within(key == .minLength, length, natural(constraint).?)) return false;
            },
            .minItems, .maxItems => if (value == .array and !within(key == .minItems, value.array.items.len, natural(constraint).?)) return false,
            .minProperties, .maxProperties => if (value == .object and !within(key == .minProperties, value.object.count(), natural(constraint).?)) return false,
            .minimum, .maximum, .exclusiveMinimum, .exclusiveMaximum => if (value == .number_string) {
                const number = Decimal.parse(value.number_string) orelse return false;
                const boundary = Decimal.parse(constraint.number_string).?;
                const order = number.order(boundary);
                switch (key) {
                    .minimum => if (order == .lt) return false,
                    .maximum => if (order == .gt) return false,
                    .exclusiveMinimum => if (order != .gt) return false,
                    .exclusiveMaximum => if (order != .lt) return false,
                    else => unreachable,
                }
            },
            .allOf => {
                for (constraint.array.items) |child| if (!acceptsNode(child, value)) return false;
            },
            .anyOf => {
                for (constraint.array.items) |child| {
                    if (acceptsNode(child, value)) break;
                } else return false;
            },
            .oneOf => {
                var matched = false;
                for (constraint.array.items) |child| {
                    if (!acceptsNode(child, value)) continue;
                    if (matched) return false;
                    matched = true;
                }
                if (!matched) return false;
            },
            .not => if (acceptsNode(constraint, value)) return false,
            .title, .description, .default, .examples, .deprecated, .readOnly, .writeOnly, .format, .@"$schema", .@"$comment", .@"x-mcp-header" => {},
        }
    }
    return true;
}

fn validType(value: Value) bool {
    if (value == .string) return std.meta.stringToEnum(Kind, value.string) != null;
    if (value != .array or value.array.items.len == 0) return false;
    var seen: std.EnumSet(Kind) = .{};
    for (value.array.items) |item| {
        if (item != .string) return false;
        const kind = std.meta.stringToEnum(Kind, item.string) orelse return false;
        if (seen.contains(kind)) return false;
        seen.insert(kind);
    }
    return true;
}

fn matchesType(types: Value, value: Value) bool {
    if (types == .string) return matchesKind(std.meta.stringToEnum(Kind, types.string).?, value);
    for (types.array.items) |item| if (matchesKind(std.meta.stringToEnum(Kind, item.string).?, value)) return true;
    return false;
}

fn matchesKind(kind: Kind, value: Value) bool {
    return switch (kind) {
        .object => value == .object,
        .array => value == .array,
        .string => value == .string,
        .boolean => value == .bool,
        .null => value == .null,
        .number => value == .number_string,
        .integer => value == .number_string and if (Decimal.parse(value.number_string)) |n| n.integer() else false,
    };
}

fn within(minimum: bool, length: usize, threshold: usize) bool {
    return if (minimum) length >= threshold else length <= threshold;
}

fn natural(value: Value) ?usize {
    if (value != .number_string) return null;
    const decimal = Decimal.parse(value.number_string) orelse return null;
    return decimal.asUnsigned(usize);
}

fn atPath(start: Value, path: []const []const u8) ?Value {
    var current = start;
    for (path) |name| {
        if (current != .object) return null;
        current = current.object.get(name) orelse return null;
    }
    return current;
}

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |char| {
        if (!std.ascii.isAlphanumeric(char) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^`_|~", char) == null)
            return false;
    }
    return true;
}

fn headerInteger(allocator: Allocator, number: []const u8) Error![]const u8 {
    const decimal = Decimal.parse(number) orelse return error.InvalidInput;
    const magnitude = decimal.magnitude(u64) orelse return error.InvalidInput;
    if (magnitude > 9_007_199_254_740_991) return error.InvalidInput;
    const positive: i64 = @intCast(magnitude);
    return std.fmt.allocPrint(allocator, "{d}", .{if (decimal.negative) -positive else positive});
}

/// Compare JSON values from the lossless parser. Object member order carries no meaning.
pub fn equal(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |value| value == b.bool,
        .string => |value| eql(value, b.string),
        .number_string => |value| if (eql(value, b.number_string)) true else if (Decimal.parse(value)) |left|
            if (Decimal.parse(b.number_string)) |right| left.order(right) == .eq else false
        else
            false,
        .object => |object| result: {
            if (object.count() != b.object.count()) break :result false;
            for (object.keys(), object.values()) |key, value| {
                if (!equal(value, b.object.get(key) orelse break :result false)) break :result false;
            }
            break :result true;
        },
        .array => |array| result: {
            if (array.items.len != b.array.items.len) break :result false;
            for (array.items, b.array.items) |left, right| if (!equal(left, right)) break :result false;
            break :result true;
        },
        .integer, .float => unreachable,
    };
}

const Decimal = struct {
    digits: []const u8,
    whole_places: i128,
    negative: bool,

    fn parse(number: []const u8) ?Decimal {
        const exponent_at = std.mem.indexOfAny(u8, number, "eE") orelse number.len;
        const prefix: usize = @intFromBool(number[0] == '-');
        const mantissa = number[prefix..exponent_at];
        const first = std.mem.indexOfAny(u8, mantissa, "123456789") orelse
            return .{ .digits = "", .whole_places = 0, .negative = false };
        const last = std.mem.lastIndexOfAny(u8, mantissa, "123456789").?;
        const point = std.mem.indexOfScalar(u8, mantissa, '.') orelse mantissa.len;
        const shift = if (exponent_at == number.len) 0 else std.fmt.parseInt(i64, number[exponent_at + 1 ..], 10) catch return null;
        return .{
            .digits = mantissa[first .. last + 1],
            .whole_places = @as(i128, shift) + @as(i128, @intCast(point)) -
                @as(i128, @intCast(first)) + @intFromBool(first > point),
            .negative = prefix == 1,
        };
    }

    fn integer(self: Decimal) bool {
        const digits = self.digits.len - @intFromBool(std.mem.indexOfScalar(u8, self.digits, '.') != null);
        return self.whole_places >= digits;
    }

    fn asUnsigned(self: Decimal, comptime T: type) ?T {
        if (self.negative) return null;
        return self.magnitude(T);
    }

    fn magnitude(self: Decimal, comptime T: type) ?T {
        if (!self.integer() or self.whole_places > std.fmt.count("{d}", .{std.math.maxInt(T)})) return null;
        var value: T = 0;
        var digits: usize = 0;
        for (self.digits) |char| {
            if (char == '.') continue;
            value = std.math.mul(T, value, 10) catch return null;
            value = std.math.add(T, value, char - '0') catch return null;
            digits += 1;
        }
        while (digits < self.whole_places) : (digits += 1)
            value = std.math.mul(T, value, 10) catch return null;
        return value;
    }

    fn order(self: Decimal, other: Decimal) std.math.Order {
        if (self.negative != other.negative) return if (self.negative) .lt else .gt;
        const unsigned = self.orderMagnitude(other);
        return if (self.negative) unsigned.invert() else unsigned;
    }

    fn orderMagnitude(self: Decimal, other: Decimal) std.math.Order {
        if (self.digits.len == 0) return if (other.digits.len == 0) .eq else .lt;
        if (other.digits.len == 0) return .gt;
        const length_order = std.math.order(self.whole_places, other.whole_places);
        if (length_order != .eq) return length_order;
        var left: usize = 0;
        var right: usize = 0;
        while (left < self.digits.len and right < other.digits.len) {
            if (self.digits[left] == '.') left += 1;
            if (other.digits[right] == '.') right += 1;
            const digit_order = std.math.order(self.digits[left], other.digits[right]);
            if (digit_order != .eq) return digit_order;
            left += 1;
            right += 1;
        }
        return if (left < self.digits.len) .gt else if (right < other.digits.len) .lt else .eq;
    }
};

pub fn parseObject(allocator: Allocator, bytes: []const u8, limits: foo.wire.json.Limits, malformed: Error) Error!Object {
    foo.wire.json.validate(bytes, limits) catch |err| return switch (err) {
        error.InvalidJson => malformed,
        else => error.LimitExceeded,
    };
    const decoded = std.json.parseFromSliceLeaky(Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => malformed,
    };
    if (decoded != .object) return malformed;
    return decoded.object;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
