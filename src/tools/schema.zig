const std = @import("std");
const foo = @import("foo");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const JsonLimits = foo.wire.json.Limits;

pub const Schema = union(enum) {
    object: Object,
    array: ?*const Schema,
    string,
    boolean,
    null,
    number,
    integer,

    const Object = struct {
        properties: std.StringHashMapUnmanaged(Property) = .empty,
        additional_properties: bool = true,
    };

    const Property = struct {
        schema: Schema,
        required: bool = false,
    };

    pub fn compile(allocator: Allocator, scratch: Allocator, input: []const u8, limits: JsonLimits) foo.io.Error!Schema {
        const value = try parse(scratch, input, limits);
        const schema = try compileNode(allocator, value);
        if (schema != .object) return error.InvalidInput;
        return schema;
    }

    pub fn validate(self: Schema, allocator: Allocator, input: []const u8, limits: JsonLimits) foo.io.Error!void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const value = try parse(arena.allocator(), input, limits);
        if (!self.accepts(value)) return error.InvalidInput;
    }

    fn accepts(self: Schema, value: Value) bool {
        return switch (self) {
            .object => |object| value == .object and acceptsObject(object, value.object),
            .array => |items| value == .array and acceptsItems(items, value.array.items),
            .string => value == .string,
            .boolean => value == .bool,
            .null => value == .null,
            .number => value == .number_string,
            .integer => value == .number_string and isInteger(value.number_string),
        };
    }

    fn acceptsObject(schema: Object, object: std.json.ObjectMap) bool {
        var fields = schema.properties.iterator();
        while (fields.next()) |field| {
            const property = field.value_ptr.*;
            if (object.get(field.key_ptr.*)) |value| {
                if (!property.schema.accepts(value)) return false;
            } else if (property.required) return false;
        }
        if (!schema.additional_properties) {
            for (object.keys()) |name| if (!schema.properties.contains(name)) return false;
        }
        return true;
    }

    fn acceptsItems(items: ?*const Schema, values: []const Value) bool {
        const item = items orelse return true;
        for (values) |value| if (!item.accepts(value)) return false;
        return true;
    }

    fn compileNode(allocator: Allocator, value: Value) foo.io.Error!Schema {
        if (value != .object) return error.InvalidInput;
        const spec = value.object;
        const kind = spec.get("type") orelse return error.InvalidInput;
        if (kind != .string) return error.InvalidInput;
        const tag = std.meta.stringToEnum(std.meta.Tag(Schema), kind.string) orelse return error.InvalidInput;

        var fields = spec.iterator();
        while (fields.next()) |field| {
            const key = field.key_ptr.*;
            if (eql(key, "type")) continue;
            if (eql(key, "description") and field.value_ptr.* == .string) continue;
            if (tag == .object and (eql(key, "properties") or eql(key, "required") or eql(key, "additionalProperties"))) continue;
            if (tag == .array and eql(key, "items")) continue;
            return error.InvalidInput;
        }

        return switch (tag) {
            .object => .{ .object = try compileObject(allocator, spec) },
            .array => .{ .array = if (spec.get("items")) |child| node: {
                const item = try allocator.create(Schema);
                item.* = try compileNode(allocator, child);
                break :node item;
            } else null },
            .string => .string,
            .boolean => .boolean,
            .null => .null,
            .number => .number,
            .integer => .integer,
        };
    }

    fn compileObject(allocator: Allocator, spec: std.json.ObjectMap) foo.io.Error!Object {
        var result: Object = .{};
        if (spec.get("additionalProperties")) |value| {
            if (value != .bool) return error.InvalidInput;
            result.additional_properties = value.bool;
        }
        if (spec.get("properties")) |value| {
            if (value != .object) return error.InvalidInput;
            var properties = value.object.iterator();
            while (properties.next()) |property| {
                const name = try allocator.dupe(u8, property.key_ptr.*);
                const schema = try compileNode(allocator, property.value_ptr.*);
                try result.properties.put(allocator, name, .{ .schema = schema });
            }
        }
        if (spec.get("required")) |value| {
            if (value != .array) return error.InvalidInput;
            for (value.array.items) |name| {
                if (name != .string) return error.InvalidInput;
                const property = result.properties.getPtr(name.string) orelse return error.InvalidInput;
                if (property.required) return error.InvalidInput;
                property.required = true;
            }
        }
        return result;
    }
};

fn parse(allocator: Allocator, input: []const u8, limits: JsonLimits) foo.io.Error!Value {
    foo.wire.json.validate(input, limits) catch |err| return switch (err) {
        error.MessageTooLarge, error.NestingTooDeep => error.LimitExceeded,
        error.InvalidJson => error.InvalidInput,
    };
    return std.json.parseFromSliceLeaky(Value, allocator, input, .{
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidInput,
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isInteger(number: []const u8) bool {
    const exponent_at = std.mem.indexOfAny(u8, number, "eE") orelse number.len;
    const significand = number[0..exponent_at];
    const last_nonzero = std.mem.lastIndexOfAny(u8, significand, "123456789") orelse return true;
    const decimal_at = std.mem.indexOfScalar(u8, significand, '.') orelse significand.len;
    const decimal_places: i128 = @as(i128, @intCast(last_nonzero)) - @as(i128, @intCast(decimal_at)) +
        @intFromBool(last_nonzero < decimal_at);

    const power = if (exponent_at == number.len) 0 else power: {
        const exponent = number[exponent_at + 1 ..];
        break :power std.fmt.parseInt(i128, exponent, 10) catch return exponent[0] != '-';
    };
    return power >= decimal_places;
}
