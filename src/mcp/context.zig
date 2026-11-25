const std = @import("std");
const foo = @import("foo");
const client_module = @import("client.zig");
const schema = @import("schema.zig");

const Allocator = std.mem.Allocator;
const Object = std.json.ObjectMap;
const Value = std.json.Value;
const Kind = foo.tool.ContextKind;
const Error = schema.Error;

pub const resource_json_mime = "application/vnd.mcp.resources+json";
pub const prompt_json_mime = "application/vnd.mcp.prompt+json";

pub const PageReader = struct {
    client: *client_module.Client,
    operation: foo.io.Context,
    method: []const u8,
    field: []const u8,
    limits: foo.config.Limits,
    arena: std.heap.ArenaAllocator,
    cursors: std.StringHashMapUnmanaged(void) = .empty,
    cursor: ?[]const u8,
    pages: usize = 0,
    bytes: foo.io.Budget,
    finished: bool = false,

    pub const Page = struct {
        items: []const Value,
        completion: client_module.Completion,
    };

    pub fn init(
        allocator: Allocator,
        client: *client_module.Client,
        operation: foo.io.Context,
        limits: foo.config.Limits,
        method: []const u8,
        field: []const u8,
        cursor: ?[]const u8,
    ) Error!PageReader {
        var reader: PageReader = .{
            .client = client,
            .operation = operation,
            .method = method,
            .field = field,
            .limits = limits,
            .arena = .init(allocator),
            .cursor = cursor,
            .bytes = .{ .limit = limits.catalog_bytes },
        };
        errdefer reader.deinit();
        if (cursor) |start| try reader.remember(start);
        return reader;
    }

    pub fn deinit(self: *PageReader) void {
        self.arena.deinit();
    }

    pub fn next(self: *PageReader, scratch: Allocator) Error!?Page {
        if (self.finished) return null;
        try self.operation.check();
        if (self.pages >= self.limits.catalog_pages) return error.LimitExceeded;
        self.pages += 1;
        var params: Object = .empty;
        if (self.cursor) |cursor| try params.put(scratch, "cursor", .{ .string = cursor });
        var delivery: foo.io.Delivery = .unsent;
        const result = try self.client.request(scratch, self.operation, self.method, params, .{}, &delivery);
        if (result.kind != .complete) return error.UnsupportedCapability;
        try self.bytes.take(result.raw.len);
        const items = try array(result.fields, self.field);
        if (result.fields.get("nextCursor")) |cursor| {
            if (cursor != .string or items.len == 0) return error.MalformedPeer;
            try self.remember(cursor.string);
        } else {
            self.finished = true;
        }
        return .{ .items = items, .completion = result };
    }

    fn remember(self: *PageReader, cursor: []const u8) Error!void {
        if (cursor.len > self.limits.catalog_bytes or cursor.len > self.limits.wire_message_bytes)
            return error.LimitExceeded;
        if (self.cursors.contains(cursor)) return error.MalformedPeer;
        const allocator = self.arena.allocator();
        const copy = try allocator.dupe(u8, cursor);
        try self.cursors.put(allocator, copy, {});
        self.cursor = copy;
    }
};

pub const Source = struct {
    client: *client_module.Client,
    server_id: []const u8,
    limits: foo.config.Limits,
    capabilities: client_module.Capabilities,

    pub fn interface(self: *Source) foo.tool.ContextSource {
        return .{ .context = self, .list_fn = list, .get_fn = get };
    }

    fn list(
        context: *anyopaque,
        allocator: Allocator,
        operation: foo.io.Context,
        kind: Kind,
        cursor: ?[]const u8,
    ) foo.io.Error!foo.tool.ContextPage {
        const self: *Source = @ptrCast(@alignCast(context));
        return self.listItems(allocator, operation, kind, cursor) catch |err| return mapped(err);
    }

    fn listItems(self: *Source, allocator: Allocator, operation: foo.io.Context, kind: Kind, cursor: ?[]const u8) Error!foo.tool.ContextPage {
        if (!self.supports(kind)) return error.UnsupportedCapability;
        const route = routes.get(kind);
        var reader = try PageReader.init(allocator, self.client, operation, self.limits, route.method, route.field, cursor);
        defer reader.deinit();
        var scratch: std.heap.ArenaAllocator = .init(allocator);
        defer scratch.deinit();
        const temp = scratch.allocator();
        var items: std.ArrayList(foo.tool.ContextItem) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var item_budget: foo.io.Budget = .{ .limit = self.limits.catalog_bytes };
        while (true) {
            var page_arena: std.heap.ArenaAllocator = .init(allocator);
            defer page_arena.deinit();
            const page = (try reader.next(page_arena.allocator())) orelse break;
            for (page.items) |value| {
                if (value != .object) return error.MalformedPeer;
                const name = try string(value.object, "name");
                const id = try string(value.object, route.id);
                if (id.len == 0 or (kind == .resource and !validUri(id))) return error.MalformedPeer;
                const title = if (value.object.get("title") != null) try string(value.object, "title") else name;
                if (seen.contains(id)) return error.MalformedPeer;
                try item_budget.take(@sizeOf(foo.tool.ContextItem) +| self.server_id.len +| id.len +| title.len);
                const copy = try temp.dupe(u8, id);
                try seen.put(temp, copy, {});
                try items.append(temp, .{
                    .reference = .{ .server = self.server_id, .kind = kind, .id = copy },
                    .title = try temp.dupe(u8, title),
                });
            }
        }
        const result = try allocator.alloc(foo.tool.ContextItem, items.items.len);
        errdefer allocator.free(result);
        var copied: usize = 0;
        errdefer for (result[0..copied]) |item| {
            allocator.free(item.reference.server);
            allocator.free(item.reference.id);
            allocator.free(item.title);
        };
        for (items.items, result) |item, *output| {
            const reference = try copyRef(allocator, item.reference);
            errdefer freeRef(allocator, reference);
            output.* = .{ .reference = reference, .title = try allocator.dupe(u8, item.title) };
            copied += 1;
        }
        return .{ .items = result, .next_cursor = null };
    }

    fn get(
        context: *anyopaque,
        allocator: Allocator,
        operation: foo.io.Context,
        reference: foo.tool.ContextRef,
        arguments_json: []const u8,
    ) foo.io.Error!foo.tool.ContextContent {
        const self: *Source = @ptrCast(@alignCast(context));
        return self.getItem(allocator, operation, reference, arguments_json) catch |err| return mapped(err);
    }

    fn getItem(
        self: *Source,
        allocator: Allocator,
        operation: foo.io.Context,
        reference: foo.tool.ContextRef,
        arguments_json: []const u8,
    ) Error!foo.tool.ContextContent {
        try operation.check();
        if (!eql(self.server_id, reference.server) or reference.id.len == 0) return error.InvalidInput;
        if (reference.id.len > self.limits.catalog_bytes or reference.id.len > self.limits.wire_message_bytes)
            return error.LimitExceeded;
        if (!self.supports(reference.kind)) return error.UnsupportedCapability;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const temp = arena.allocator();
        const arguments = if (arguments_json.len == 0) Object.empty else try schema.parseObject(temp, arguments_json, .{
            .max_bytes = self.limits.tool_argument_bytes,
            .max_depth = self.limits.json_depth,
        }, error.InvalidInput);
        for (arguments.values()) |value| if (value != .string) return error.InvalidInput;

        var resolved = reference;
        if (reference.kind == .resource_template) {
            resolved.kind = .resource;
            resolved.id = try expandUri(temp, reference.id, arguments, self.limits.wire_message_bytes);
        }
        const prompt = resolved.kind == .prompt;
        if (!prompt and !validUri(resolved.id)) return error.InvalidInput;
        if (reference.kind == .resource and arguments.count() != 0) return error.InvalidInput;

        var params: Object = .empty;
        try params.put(temp, if (prompt) "name" else "uri", .{ .string = resolved.id });
        if (prompt and arguments.count() != 0) try params.put(temp, "arguments", .{ .object = arguments });
        var delivery: foo.io.Delivery = .unsent;
        const response = try self.client.request(
            temp,
            operation,
            if (prompt) "prompts/get" else "resources/read",
            params,
            .{ .name = resolved.id },
            &delivery,
        );
        if (response.kind != .complete) return error.UnsupportedCapability;
        const fields = try schema.parseObject(temp, response.raw, .{
            .max_bytes = self.limits.wire_message_bytes,
            .max_depth = self.limits.json_depth,
        }, error.MalformedPeer);

        const data = if (prompt)
            try promptContent(temp, self.limits.tool_output_bytes, fields)
        else
            try resourceContent(temp, self.limits.tool_output_bytes, fields, resolved.id);
        const copy = try copyRef(allocator, resolved);
        errdefer freeRef(allocator, copy);
        const mime = try allocator.dupe(u8, data.mime);
        errdefer allocator.free(mime);
        return .{
            .reference = copy,
            .mime = mime,
            .bytes = try allocator.dupe(u8, data.bytes),
            .truncated = data.truncated,
        };
    }

    fn supports(self: Source, kind: Kind) bool {
        return switch (kind) {
            .resource, .resource_template => self.capabilities.resources,
            .prompt => self.capabilities.prompts,
        };
    }
};

const Route = struct { method: []const u8, field: []const u8, id: []const u8 };
const routes = std.EnumArray(Kind, Route).init(.{
    .resource = .{ .method = "resources/list", .field = "resources", .id = "uri" },
    .resource_template = .{ .method = "resources/templates/list", .field = "resourceTemplates", .id = "uriTemplate" },
    .prompt = .{ .method = "prompts/list", .field = "prompts", .id = "name" },
});
const Data = struct { mime: []const u8, bytes: []const u8, truncated: bool = false };

fn promptContent(allocator: Allocator, limit: usize, fields: Object) Error!Data {
    const messages = try array(fields, "messages");
    for (messages) |message| {
        if (message != .object) return error.MalformedPeer;
        const role = try string(message.object, "role");
        if (!eql(role, "user") and !eql(role, "assistant")) return error.MalformedPeer;
        try verifyBlock(message.object.get("content") orelse return error.MalformedPeer);
    }
    const description = if (fields.contains("description")) try string(fields, "description") else null;
    return .{
        .mime = prompt_json_mime,
        .bytes = try boundedJson(allocator, limit, .{ .description = description, .messages = fields.get("messages").? }),
    };
}

fn resourceContent(allocator: Allocator, limit: usize, fields: Object, requested_uri: []const u8) Error!Data {
    const contents = try array(fields, "contents");
    for (contents) |content| try verifyResource(content);
    if (contents.len == 1) {
        const resource = contents[0].object;
        const uri = try string(resource, "uri");
        const fields_without_metadata: usize = if (resource.contains("mimeType")) 3 else 2;
        if (eql(uri, requested_uri) and resource.count() == fields_without_metadata) {
            const mime = if (resource.contains("mimeType")) try string(resource, "mimeType") else null;
            if (resource.get("text")) |text| {
                const prefix = utf8Prefix(text.string, limit);
                return .{ .mime = mime orelse "text/plain", .bytes = prefix, .truncated = prefix.len != text.string.len };
            }
            const encoded = (try string(resource, "blob"));
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(encoded) catch return error.MalformedPeer;
            if (size > limit) return error.LimitExceeded;
            const decoded = try allocator.alloc(u8, size);
            decoder.decode(decoded, encoded) catch return error.MalformedPeer;
            return .{ .mime = mime orelse "application/octet-stream", .bytes = decoded };
        }
    }
    return .{
        .mime = resource_json_mime,
        .bytes = try boundedJson(allocator, limit, .{ .contents = fields.get("contents").? }),
    };
}

pub fn verifyBlock(value: Value) Error!void {
    if (value != .object) return error.MalformedPeer;
    const object = value.object;
    const kind = try string(object, "type");
    if (eql(kind, "text")) {
        _ = try string(object, "text");
    } else if (eql(kind, "image") or eql(kind, "audio")) {
        try verifyBase64(try string(object, "data"));
        _ = try string(object, "mimeType");
    } else if (eql(kind, "resource_link")) {
        _ = try string(object, "name");
        if (!validUri(try string(object, "uri"))) return error.MalformedPeer;
    } else if (eql(kind, "resource")) {
        try verifyResource(object.get("resource") orelse return error.MalformedPeer);
    } else {
        return error.UnsupportedCapability;
    }
}

fn verifyResource(value: Value) Error!void {
    if (value != .object) return error.MalformedPeer;
    const object = value.object;
    if (!validUri(try string(object, "uri"))) return error.MalformedPeer;
    if (object.contains("mimeType")) _ = try string(object, "mimeType");
    const text = object.get("text");
    const blob = object.get("blob");
    if ((text == null) == (blob == null)) return error.MalformedPeer;
    if (text) |v| if (v != .string) return error.MalformedPeer;
    if (blob != null) try verifyBase64(try string(object, "blob"));
}

fn verifyBase64(text: []const u8) Error!void {
    _ = std.base64.standard.Decoder.calcSizeForSlice(text) catch return error.MalformedPeer;
    const data = std.mem.trimEnd(u8, text, "=");
    if (text.len - data.len > 2) return error.MalformedPeer;
    for (data) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '+' and char != '/') return error.MalformedPeer;
    }
}

fn validUri(uri: []const u8) bool {
    _ = std.Uri.parse(uri) catch return false;
    for (uri) |char| if (char <= ' ' or char >= 0x7f) return false;
    return true;
}

const Operator = struct {
    prefix: []const u8 = "",
    separator: u8 = ',',
    named: bool = false,
    empty_equals: bool = false,
    reserved: bool = false,
};

fn expandUri(allocator: Allocator, template: []const u8, arguments: Object, limit: usize) Error![]const u8 {
    const capacity = @min(limit, (template.len *| (@as(usize, 3) *| (1 +| jsonStringBytes(arguments)))) +| template.len);
    const buffer = try allocator.alloc(u8, capacity);
    var out: std.Io.Writer = .fixed(buffer);
    var used: std.StringHashMapUnmanaged(void) = .empty;
    defer used.deinit(allocator);
    var rest = template;
    while (std.mem.indexOfAny(u8, rest, "{}")) |index| {
        if (rest[index] != '{') return error.InvalidInput;
        out.writeAll(rest[0..index]) catch return error.LimitExceeded;
        const end = std.mem.indexOfScalarPos(u8, rest, index + 1, '}') orelse return error.InvalidInput;
        try expandExpression(allocator, &out, rest[index + 1 .. end], arguments, &used);
        rest = rest[end + 1 ..];
    }
    if (used.count() != arguments.count()) return error.InvalidInput;
    out.writeAll(rest) catch return error.LimitExceeded;
    if (!validUri(out.buffered())) return error.InvalidInput;
    return out.buffered();
}

fn expandExpression(
    allocator: Allocator,
    out: *std.Io.Writer,
    expression: []const u8,
    arguments: Object,
    used: *std.StringHashMapUnmanaged(void),
) Error!void {
    if (expression.len == 0) return error.InvalidInput;
    const op: Operator = switch (expression[0]) {
        '+' => .{ .reserved = true },
        '#' => .{ .prefix = "#", .reserved = true },
        '.' => .{ .prefix = ".", .separator = '.' },
        '/' => .{ .prefix = "/", .separator = '/' },
        ';' => .{ .prefix = ";", .separator = ';', .named = true },
        '?' => .{ .prefix = "?", .separator = '&', .named = true, .empty_equals = true },
        '&' => .{ .prefix = "&", .separator = '&', .named = true, .empty_equals = true },
        else => .{},
    };
    const offset: usize = @intFromBool(std.mem.indexOfScalar(u8, "+#./;?&", expression[0]) != null);
    var vars = std.mem.splitScalar(u8, expression[offset..], ',');
    var first = true;
    while (vars.next()) |variable| {
        var parts = std.mem.splitScalar(u8, variable, ':');
        const raw_name = parts.next().?;
        const name = try decodeVariableName(allocator, raw_name);
        const prefix = if (parts.next()) |part| try prefixLength(part) else null;
        if (parts.next() != null) return error.InvalidInput;
        const argument = arguments.get(name) orelse continue;
        try used.put(allocator, name, {});
        const value = if (prefix) |length| codepointPrefix(argument.string, length) else argument.string;
        if (first) out.writeAll(op.prefix) catch return error.LimitExceeded else out.writeByte(op.separator) catch return error.LimitExceeded;
        first = false;
        if (op.named) {
            out.writeAll(raw_name) catch return error.LimitExceeded;
            if (value.len != 0 or op.empty_equals) out.writeByte('=') catch return error.LimitExceeded;
        }
        try writeEncoded(out, value, op.reserved);
    }
}

fn decodeVariableName(allocator: Allocator, raw: []const u8) Error![]const u8 {
    if (raw.len == 0) return error.InvalidInput;
    var segments = std.mem.splitScalar(u8, raw, '.');
    while (segments.next()) |segment| {
        if (segment.len == 0) return error.InvalidInput;
        var remaining = segment;
        while (remaining.len != 0) {
            const char = remaining[0];
            if (char == '%') {
                if (remaining.len < 3 or !std.ascii.isHex(remaining[1]) or !std.ascii.isHex(remaining[2]))
                    return error.InvalidInput;
                remaining = remaining[3..];
            } else {
                if (!std.ascii.isAlphanumeric(char) and char != '_') return error.UnsupportedCapability;
                remaining = remaining[1..];
            }
        }
    }
    if (std.mem.indexOfScalar(u8, raw, '%') == null) return raw;
    return std.Uri.percentDecodeBackwards(try allocator.alloc(u8, raw.len), raw);
}

fn prefixLength(raw: []const u8) Error!usize {
    if (raw.len == 0 or raw.len > 4 or raw[0] == '0') return error.InvalidInput;
    for (raw) |digit| if (!std.ascii.isDigit(digit)) return error.InvalidInput;
    return std.fmt.parseInt(usize, raw, 10) catch error.InvalidInput;
}

fn codepointPrefix(text: []const u8, length: usize) []const u8 {
    var position: usize = 0;
    for (0..length) |_| {
        if (position == text.len) break;
        position += std.unicode.utf8ByteSequenceLength(text[position]) catch unreachable;
    }
    return text[0..position];
}

fn writeEncoded(out: *std.Io.Writer, value: []const u8, reserved: bool) Error!void {
    const hex = "0123456789ABCDEF";
    var rest = value;
    while (rest.len != 0) {
        const char = rest[0];
        if (reserved and char == '%' and rest.len >= 3 and std.ascii.isHex(rest[1]) and std.ascii.isHex(rest[2])) {
            out.writeAll(rest[0..3]) catch return error.LimitExceeded;
            rest = rest[3..];
            continue;
        }
        const unreserved = std.ascii.isAlphanumeric(char) or std.mem.indexOfScalar(u8, "-._~", char) != null;
        if (unreserved or (reserved and std.mem.indexOfScalar(u8, ":/?#[]@!$&'()*+,;=", char) != null)) {
            out.writeByte(char) catch return error.LimitExceeded;
        } else {
            out.writeAll(&.{ '%', hex[char >> 4], hex[char & 15] }) catch return error.LimitExceeded;
        }
        rest = rest[1..];
    }
}

fn jsonStringBytes(object: Object) usize {
    var bytes: usize = 0;
    for (object.values()) |value| bytes +|= value.string.len;
    return bytes;
}

pub fn boundedJson(allocator: Allocator, limit: usize, data: anytype) Error![]const u8 {
    var writer: std.Io.Writer.Discarding = .init(&.{});
    std.json.Stringify.value(data, .{ .emit_null_optional_fields = false }, &writer.writer) catch unreachable;
    const length = writer.fullCount();
    if (length > limit) return error.LimitExceeded;
    const buffer = try allocator.alloc(u8, @intCast(length));
    var fixed: std.Io.Writer = .fixed(buffer);
    std.json.Stringify.value(data, .{ .emit_null_optional_fields = false }, &fixed) catch unreachable;
    return fixed.buffered();
}

pub fn utf8Prefix(text: []const u8, limit: usize) []const u8 {
    var length = @min(text.len, limit);
    if (length == text.len) return text;
    while (length != 0 and text[length] & 0xc0 == 0x80) length -= 1;
    return text[0..length];
}

fn copyRef(allocator: Allocator, reference: foo.tool.ContextRef) Error!foo.tool.ContextRef {
    const server = try allocator.dupe(u8, reference.server);
    errdefer allocator.free(server);
    return .{ .server = server, .kind = reference.kind, .id = try allocator.dupe(u8, reference.id) };
}

fn freeRef(allocator: Allocator, reference: foo.tool.ContextRef) void {
    allocator.free(reference.server);
    allocator.free(reference.id);
}

pub fn string(object: Object, field: []const u8) Error![]const u8 {
    const value = object.get(field) orelse return error.MalformedPeer;
    if (value != .string) return error.MalformedPeer;
    return value.string;
}

pub fn array(object: Object, field: []const u8) Error![]const Value {
    const value = object.get(field) orelse return error.MalformedPeer;
    if (value != .array) return error.MalformedPeer;
    return value.array.items;
}

fn mapped(err: Error) foo.io.Error {
    return switch (err) {
        error.Cancelled, error.DeadlineExceeded, error.LimitExceeded, error.Unavailable, error.InvalidInput, error.Disconnected, error.IoFailure, error.OutOfMemory => |common| common,
        error.MalformedPeer, error.Untrusted => error.IoFailure,
        else => error.Unavailable,
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
