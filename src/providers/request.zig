const std = @import("std");
const foo = @import("foo");
const c = @import("common.zig");
const p = foo.provider;

pub fn encode(a: std.mem.Allocator, request: p.Request) p.Error![]const u8 {
    try validate(request);
    const j: c.Json = .{ .a = a };
    var root = try options(j, request);
    try j.text(&root, "model", request.model.id);
    try j.put(&root, "stream", .{ .bool = true });
    const chat_config = try chatOptions(a, request);
    _ = root.object.swapRemove("chat_token_limit");
    _ = root.object.swapRemove("chat_include_usage");
    _ = root.object.swapRemove("chat_reasoning_content");
    _ = root.object.swapRemove("chat_litellm");
    const tokens = switch (request.model.family) {
        .openai_responses => "max_output_tokens",
        .openai_chat => chat_config.token_limit,
        .anthropic_messages => "max_tokens",
    };
    try j.put(&root, tokens, .{ .integer = request.model.max_output_tokens });
    switch (request.model.family) {
        .openai_responses => {
            try j.put(&root, "store", .{ .bool = false });
            var include = j.list();
            try j.add(&include, .{ .string = "reasoning.encrypted_content" });
            try j.put(&root, "include", include);
            try j.put(&root, "input", try responses(j, request));
        },
        .openai_chat => {
            if (chat_config.include_usage) {
                var stream_options = j.object();
                try j.put(&stream_options, "include_usage", .{ .bool = true });
                try j.put(&root, "stream_options", stream_options);
            }
            try j.put(&root, "messages", try chat(j, request));
        },
        .anthropic_messages => {
            const messages = try anthropic(j, request);
            try j.put(&root, "messages", messages.messages);
            if (messages.system.array.items.len != 0) try j.put(&root, "system", messages.system);
        },
    }
    if (request.tools.len != 0) {
        var tools = j.list();
        for (request.tools) |tool| {
            var function = j.object();
            try j.text(&function, "name", tool.name);
            try j.text(&function, "description", tool.description);
            const schema = try parseInput(a, tool.schema_json, request.limits);
            if (schema != .object) return error.InvalidInput;
            try j.put(&function, if (request.model.family == .anthropic_messages) "input_schema" else "parameters", schema);
            if (request.model.family == .openai_chat) {
                var wrapped = try j.typed("function");
                try j.put(&wrapped, "function", function);
                try j.add(&tools, wrapped);
            } else {
                if (request.model.family == .openai_responses) {
                    try j.text(&function, "type", "function");
                    try j.put(&function, "strict", .{ .bool = false });
                }
                try j.add(&tools, function);
            }
        }
        try j.put(&root, "tools", tools);
    }
    const encoded = try j.encode(root, request.limits.wire_message_bytes);
    foo.wire.json.validate(encoded, .{ .max_bytes = request.limits.wire_message_bytes, .max_depth = request.limits.json_depth }) catch return error.LimitExceeded;
    return encoded;
}

fn validate(request: p.Request) p.Error!void {
    if (request.model.id.len == 0 or request.model.endpoint.len == 0 or request.model.max_output_tokens == 0) return error.InvalidInput;
    var budget: foo.io.Budget = .{ .limit = request.limits.transcript_bytes };
    try countText(&budget, request.model.id);
    try countText(&budget, request.model.endpoint);
    try budget.take(request.model.options_json.len);
    for (request.messages) |message| {
        try budget.take(@sizeOf(p.Message));
        for (message.blocks) |block| {
            try budget.take(@sizeOf(p.Block));
            switch (block) {
                .text => |v| try countText(&budget, v),
                .reasoning => return error.Rejected,
                .tool_call => |v| {
                    if (message.role != .assistant or v.id.len == 0 or v.name.len == 0) return error.InvalidInput;
                    if (v.arguments_json.len > request.limits.tool_argument_bytes) return error.LimitExceeded;
                    try countText(&budget, v.id);
                    try countText(&budget, v.name);
                    try countText(&budget, v.arguments_json);
                },
                .tool_result => |v| {
                    if (message.role != .tool or v.call_id.len == 0) return error.InvalidInput;
                    if (v.content.len > request.limits.tool_output_bytes) return error.LimitExceeded;
                    try countText(&budget, v.call_id);
                    try countText(&budget, v.content);
                },
                .replay => |v| {
                    if (!v.compatible(request.model)) return error.IncompatibleReplay;
                    if (message.role != .assistant) return error.InvalidInput;
                    try budget.take(v.bytes.len);
                    try budget.take(v.endpoint.len);
                    try budget.take(v.model.len);
                },
            }
        }
    }
    for (request.tools) |tool| {
        if (tool.name.len == 0) return error.InvalidInput;
        try budget.take(@sizeOf(p.ToolSpec));
        try countText(&budget, tool.name);
        try countText(&budget, tool.description);
        try budget.take(tool.schema_json.len);
    }
}

fn options(j: c.Json, request: p.Request) p.Error!c.Value {
    const root = c.parse(j.a, request.model.options_json, request.limits) catch |err| return if (err == error.Protocol) error.InvalidInput else err;
    if (root != .object) return error.InvalidInput;
    var it = root.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (c.eq(key, "temperature") or c.eq(key, "top_p")) {
            const n: f64 = switch (value) {
                .integer => @floatFromInt(value.integer),
                .float => value.float,
                else => return error.InvalidInput,
            };
            const max: f64 = if (c.eq(key, "top_p") or request.model.family == .anthropic_messages) 1 else 2;
            if (!std.math.isFinite(n) or n < 0 or n > max) return error.InvalidInput;
        } else if (c.eq(key, "parallel_tool_calls") and request.model.family != .anthropic_messages) {
            if (value != .bool) return error.InvalidInput;
        } else if (c.eq(key, "reasoning_effort") and request.model.family == .openai_chat) {
            try oneOf(value, &.{ "none", "minimal", "low", "medium", "high", "max", "xhigh" });
        } else if (c.eq(key, "reasoning") and request.model.family == .openai_responses) {
            if (value != .object) return error.InvalidInput;
            var reasoning = value.object.iterator();
            while (reasoning.next()) |option| {
                if (c.eq(option.key_ptr.*, "effort")) {
                    try oneOf(option.value_ptr.*, &.{ "none", "minimal", "low", "medium", "high", "max", "xhigh" });
                } else if (c.eq(option.key_ptr.*, "summary")) {
                    try oneOf(option.value_ptr.*, &.{ "auto", "concise", "detailed" });
                } else return error.Rejected;
            }
        } else if (c.eq(key, "chat_token_limit")) {
            // chat_* keys tune openai_chat only. Other families accept and strip them, so one
            // provider options block can serve routed models of several protocols.
            try oneOf(value, &.{ "max_completion_tokens", "max_tokens" });
        } else if (c.eq(key, "chat_include_usage") or c.eq(key, "chat_reasoning_content") or c.eq(key, "chat_litellm")) {
            if (value != .bool) return error.InvalidInput;
        } else if (c.eq(key, "thinking") and request.model.family == .openai_chat) {
            if (value != .object or value.object.count() != 1) return error.InvalidInput;
            try oneOf(c.field(value, "type") orelse return error.InvalidInput, &.{ "enabled", "disabled" });
        } else if (c.eq(key, "thinking") and request.model.family == .anthropic_messages) {
            const kind = c.str(value, "type") catch return error.InvalidInput;
            if (c.eq(kind, "enabled")) {
                const tokens = c.number(c.field(value, "budget_tokens") orelse return error.InvalidInput) catch return error.InvalidInput;
                if (tokens < 1024 or tokens >= request.model.max_output_tokens or value.object.count() != 2) return error.InvalidInput;
            } else if (c.eq(kind, "disabled") or c.eq(kind, "adaptive")) {
                if (value.object.count() != 1) return error.InvalidInput;
            } else return error.Rejected;
        } else if (c.eq(key, "output_config") and request.model.family == .anthropic_messages) {
            if (value != .object or value.object.count() != 1) return error.Rejected;
            try oneOf(c.field(value, "effort") orelse return error.Rejected, &.{ "low", "medium", "high", "max" });
        } else return error.InvalidInput;
    }
    return root;
}

fn oneOf(value: c.Value, choices: []const []const u8) p.Error!void {
    const text = c.string(value) catch return error.InvalidInput;
    for (choices) |choice| if (c.eq(text, choice)) return;
    return error.Rejected;
}

fn textBlock(j: c.Json, kind: []const u8, text: []const u8) p.Error!c.Value {
    var block = try j.typed(kind);
    try j.text(&block, "text", text);
    return block;
}

fn responses(j: c.Json, request: p.Request) p.Error!c.Value {
    var input = j.list();
    for (request.messages) |message| {
        var snapshot: ?c.Value = null;
        for (message.blocks) |block| if (block == .replay) {
            if (snapshot != null) return error.IncompatibleReplay;
            snapshot = try parseReplay(j.a, block.replay.bytes, request.limits);
        };
        if (snapshot) |native| {
            try checkResponsesReplay(message, native);
            for (native.array.items) |item| {
                try j.add(&input, item);
            }
            continue;
        }
        for (message.blocks) |block| switch (block) {
            .text => |text| {
                if (message.role == .tool) return error.InvalidInput;
                var item = j.object();
                try j.text(&item, "role", @tagName(message.role));
                try j.text(&item, "content", text);
                try j.add(&input, item);
            },
            .tool_call => |call| {
                var item = try j.typed("function_call");
                try j.text(&item, "call_id", call.id);
                try j.text(&item, "name", call.name);
                try j.text(&item, "arguments", call.arguments_json);
                try j.add(&input, item);
            },
            .tool_result => |result| {
                var item = try j.typed("function_call_output");
                try j.text(&item, "call_id", result.call_id);
                try j.text(&item, "output", result.content);
                try j.add(&input, item);
            },
            else => return error.Rejected,
        };
    }
    return input;
}

fn chat(j: c.Json, request: p.Request) p.Error!c.Value {
    const flags = try chatOptions(j.a, request);
    var messages = j.list();
    for (request.messages) |message| {
        if (message.role == .tool) {
            for (message.blocks) |block| {
                if (block != .tool_result) return error.InvalidInput;
                var item = j.object();
                try j.text(&item, "role", "tool");
                try j.text(&item, "tool_call_id", block.tool_result.call_id);
                try j.text(&item, "content", block.tool_result.content);
                try j.add(&messages, item);
            }
            continue;
        }
        var item = j.object();
        try j.text(&item, "role", @tagName(message.role));
        var content: std.ArrayList(u8) = .empty;
        var calls = j.list();
        var native_replay: ?c.Value = null;
        for (message.blocks) |block| switch (block) {
            .text => |text| try content.appendSlice(j.a, text),
            .tool_call => |call| {
                var function = j.object();
                try j.text(&function, "name", call.name);
                try j.text(&function, "arguments", call.arguments_json);
                var tool = try j.typed("function");
                try j.text(&tool, "id", call.id);
                try j.put(&tool, "function", function);
                try j.add(&calls, tool);
            },
            .replay => |replay| {
                if (native_replay != null) return error.IncompatibleReplay;
                native_replay = try parseReplay(j.a, replay.bytes, request.limits);
            },
            else => return error.Rejected,
        };
        if (native_replay) |native| chatReplay(j, native, &item, &calls, flags) catch |err| return if (err == error.Protocol) error.IncompatibleReplay else err;
        if (content.items.len != 0) try j.text(&item, "content", content.items) else try j.put(&item, "content", .null);
        if (calls.array.items.len != 0) try j.put(&item, "tool_calls", calls);
        try j.add(&messages, item);
    }
    return messages;
}

pub const ChatOptions = struct {
    token_limit: []const u8 = "max_completion_tokens",
    include_usage: bool = true,
    reasoning_content: bool = false,
    litellm: bool = false,
};

pub fn chatOptions(a: std.mem.Allocator, request: p.Request) p.Error!ChatOptions {
    var result: ChatOptions = .{};
    if (request.model.family != .openai_chat) return result;
    const value = try c.parse(a, request.model.options_json, request.limits);
    if (value != .object) return error.InvalidInput;
    if (c.field(value, "chat_token_limit")) |v| result.token_limit = try c.string(v);
    if (c.field(value, "chat_include_usage")) |v| {
        if (v != .bool) return error.InvalidInput;
        result.include_usage = v.bool;
    }
    if (c.field(value, "chat_reasoning_content")) |v| {
        if (v != .bool) return error.InvalidInput;
        result.reasoning_content = v.bool;
    }
    if (c.field(value, "chat_litellm")) |v| {
        if (v != .bool) return error.InvalidInput;
        result.litellm = v.bool;
    }
    return result;
}

fn chatReplay(j: c.Json, native: c.Value, item: *c.Value, calls: *c.Value, flags: ChatOptions) p.Error!void {
    if (native != .object) return error.IncompatibleReplay;
    var fields = native.object.iterator();
    while (fields.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (c.eq(key, "reasoning_content")) {
            if (!flags.reasoning_content) return error.IncompatibleReplay;
            try j.text(item, key, try c.string(value));
        } else if (c.eq(key, "provider_specific_fields")) {
            if (!flags.litellm or value != .object) return error.IncompatibleReplay;
            try j.put(item, key, value);
        } else if (c.eq(key, "tool_calls")) {
            if (!flags.litellm) return error.IncompatibleReplay;
            for (try c.array(value)) |metadata| {
                const id = try c.str(metadata, "id");
                const extras = try c.required(metadata, "provider_specific_fields");
                if (metadata.object.count() != 2 or extras != .object) return error.IncompatibleReplay;
                var matched = false;
                for (calls.array.items) |*call| if (c.eq(try c.str(call.*, "id"), id)) {
                    if (c.field(call.*, "provider_specific_fields") != null) return error.IncompatibleReplay;
                    try j.put(call, "provider_specific_fields", extras);
                    matched = true;
                    break;
                };
                if (!matched) return error.IncompatibleReplay;
            }
        } else return error.IncompatibleReplay;
    }
}

fn anthropic(j: c.Json, request: p.Request) p.Error!struct { messages: c.Value, system: c.Value } {
    var messages = j.list();
    var system = j.list();
    var previous_role: ?p.Role = null;
    for (request.messages) |message| {
        if (message.role == .system) {
            for (message.blocks) |block| {
                if (block != .text) return error.Rejected;
                try j.add(&system, try textBlock(j, "text", block.text));
            }
            continue;
        }
        const role: p.Role = if (message.role == .tool) .user else message.role;
        if (role != .assistant and role != .user) return error.InvalidInput;
        var content = j.list();
        for (message.blocks) |block| switch (block) {
            .text => |text| {
                if (message.role == .tool) return error.InvalidInput;
                try j.add(&content, try textBlock(j, "text", text));
            },
            .tool_call => |call| {
                var item = try j.typed("tool_use");
                try j.text(&item, "id", call.id);
                try j.text(&item, "name", call.name);
                const arguments = try parseInput(j.a, call.arguments_json, request.limits);
                if (arguments != .object) return error.InvalidInput;
                try j.put(&item, "input", arguments);
                try j.add(&content, item);
            },
            .tool_result => |result| {
                var item = try j.typed("tool_result");
                try j.text(&item, "tool_use_id", result.call_id);
                try j.text(&item, "content", result.content);
                try j.put(&item, "is_error", .{ .bool = result.is_error });
                try j.add(&content, item);
            },
            .replay => |replay| {
                const item = try parseReplay(j.a, replay.bytes, request.limits);
                const kind = c.str(item, "type") catch return error.IncompatibleReplay;
                if (!c.eq(kind, "thinking") and !c.eq(kind, "redacted_thinking")) return error.IncompatibleReplay;
                if (c.eq(kind, "thinking")) {
                    _ = c.str(item, "thinking") catch return error.IncompatibleReplay;
                    const signature = c.str(item, "signature") catch return error.IncompatibleReplay;
                    if (signature.len == 0 or item.object.count() != 3) return error.IncompatibleReplay;
                } else {
                    _ = c.str(item, "data") catch return error.IncompatibleReplay;
                    if (item.object.count() != 2) return error.IncompatibleReplay;
                }
                try j.add(&content, item);
            },
            else => return error.Rejected,
        };
        if (previous_role == role) {
            const previous = &messages.array.items[messages.array.items.len - 1];
            const old = previous.object.getPtr("content").?;
            for (content.array.items) |part| try j.add(old, part);
        } else {
            var item = j.object();
            try j.text(&item, "role", @tagName(role));
            try j.put(&item, "content", content);
            try j.add(&messages, item);
        }
        previous_role = role;
    }
    return .{ .messages = messages, .system = system };
}

fn parseReplay(a: std.mem.Allocator, bytes: []const u8, limits: foo.config.Limits) p.Error!c.Value {
    return c.parse(a, bytes, limits) catch |err| return if (err == error.Protocol) error.IncompatibleReplay else err;
}

fn parseInput(a: std.mem.Allocator, bytes: []const u8, limits: foo.config.Limits) p.Error!c.Value {
    return c.parse(a, bytes, limits) catch |err| return if (err == error.Protocol) error.InvalidInput else err;
}

fn countText(budget: *foo.io.Budget, bytes: []const u8) p.Error!void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidInput;
    try budget.take(bytes.len);
}

fn checkResponsesReplay(message: p.Message, native: c.Value) p.Error!void {
    checkResponsesBlocks(message, native) catch return error.IncompatibleReplay;
}

fn checkResponsesBlocks(message: p.Message, native: c.Value) p.Error!void {
    var cursor: usize = 0;
    for (try c.array(native)) |item| {
        const kind = try c.str(item, "type");
        if (c.eq(kind, "reasoning")) continue;
        if (c.eq(kind, "function_call")) {
            const block = nextNormalized(message, &cursor) orelse return error.IncompatibleReplay;
            if (block != .tool_call) return error.IncompatibleReplay;
            if (!c.eq(block.tool_call.id, try c.str(item, "call_id")) or
                !c.eq(block.tool_call.name, try c.str(item, "name")) or
                !c.eq(block.tool_call.arguments_json, try c.str(item, "arguments"))) return error.IncompatibleReplay;
        } else if (c.eq(kind, "message")) {
            if (!c.eq(try c.str(item, "role"), "assistant")) return error.IncompatibleReplay;
            for (try c.array(try c.required(item, "content"))) |content| {
                const content_type = try c.str(content, "type");
                const key = if (c.eq(content_type, "output_text")) "text" else if (c.eq(content_type, "refusal")) "refusal" else return error.IncompatibleReplay;
                const block = nextNormalized(message, &cursor) orelse return error.IncompatibleReplay;
                if (block != .text or !c.eq(block.text, try c.str(content, key))) return error.IncompatibleReplay;
            }
        } else return error.IncompatibleReplay;
    }
    if (nextNormalized(message, &cursor) != null) return error.IncompatibleReplay;
}

fn nextNormalized(message: p.Message, cursor: *usize) ?p.Block {
    while (cursor.* < message.blocks.len) {
        const block = message.blocks[cursor.*];
        cursor.* += 1;
        if (block != .replay) return block;
    }
    return null;
}
