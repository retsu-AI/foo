const std = @import("std");
const c = @import("common.zig");

const Usage = struct {
    fresh_input: ?u64 = null,
    cache_creation: u64 = 0,
    cache_read: ?u64 = null,
    output: ?u64 = null,

    fn update(self: *Usage, value: c.Value) c.Error!void {
        if (value == .null) return;
        if (value != .object) return error.Protocol;
        if (try c.optionalCount(value, "input_tokens")) |count| self.fresh_input = count;
        if (try c.optionalCount(value, "cache_creation_input_tokens")) |count| self.cache_creation = count;
        if (try c.optionalCount(value, "cache_read_input_tokens")) |count| self.cache_read = count;
        if (try c.optionalCount(value, "output_tokens")) |count| self.output = count;
    }

    fn total(self: Usage) c.Error!c.p.Usage {
        const input = if (self.fresh_input) |fresh| sum: {
            const cached = std.math.add(u64, self.cache_creation, self.cache_read orelse 0) catch return error.Protocol;
            break :sum std.math.add(u64, cached, fresh) catch return error.Protocol;
        } else null;
        return .{ .input_tokens = input, .output_tokens = self.output, .cache_read_tokens = self.cache_read };
    }
};

pub const Reducer = struct {
    const Kind = enum { text, thinking, redacted_thinking, tool_use };
    const Content = struct {
        kind: Kind,
        text: std.ArrayList(u8) = .empty,
        signature: std.ArrayList(u8) = .empty,
        id: []const u8 = "",
        name: []const u8 = "",
        initial_input: []const u8 = "{}",
        initial_empty: bool = true,
        redacted: []const u8 = "",
    };
    usage: Usage = .{},
    started: bool = false,
    next_index: usize = 0,
    active: ?Content = null,

    pub fn event(self: *Reducer, s: *c.State, value: c.Value) c.Error!void {
        if (s.terminal) return error.Protocol;
        const kind = try c.str(value, "type");
        if (c.eq(kind, "error")) return c.apiError(value);
        if (c.eq(kind, "ping")) return;
        if (c.eq(kind, "message_start")) {
            if (self.started) return error.Protocol;
            const message = try c.required(value, "message");
            if (!c.eq(try c.str(message, "role"), "assistant")) return error.Protocol;
            if ((try c.array(try c.required(message, "content"))).len != 0) return error.Protocol;
            if (c.field(message, "usage")) |usage| try self.usage.update(usage);
            self.started = true;
            return;
        }
        if (!self.started) return error.Protocol;
        if (c.eq(kind, "message_delta")) {
            if (self.active != null) return error.Protocol;
            const change = try c.required(value, "delta");
            if (c.field(change, "stop_reason")) |reason_value| if (reason_value != .null) {
                if (s.stop != null) return error.Protocol;
                const reason = try c.string(reason_value);
                if (c.eq(reason, "end_turn") or c.eq(reason, "stop_sequence")) s.stop = .end_turn else if (c.eq(reason, "tool_use")) s.stop = .tool_use else if (c.eq(reason, "max_tokens") or c.eq(reason, "model_context_window_exceeded")) s.stop = .output_limit else if (c.eq(reason, "refusal")) s.stop = .refusal else return error.Rejected;
            };
            if (c.field(value, "usage")) |usage| try self.usage.update(usage);
            return;
        }
        if (c.eq(kind, "message_stop")) {
            if (self.active != null or s.stop == null) return error.Protocol;
            s.usage = try self.usage.total();
            s.terminal = true;
            return;
        }
        if (s.stop != null) return error.Protocol;
        if (c.eq(kind, "content_block_start")) {
            if (self.active != null or try c.index(value) != self.next_index) return error.Protocol;
            try self.start(s, try c.required(value, "content_block"));
        } else if (c.eq(kind, "content_block_delta")) {
            if (self.active == null or try c.index(value) != self.next_index) return error.Protocol;
            try self.delta(s, try c.required(value, "delta"));
        } else if (c.eq(kind, "content_block_stop")) {
            if (self.active == null or try c.index(value) != self.next_index) return error.Protocol;
            try self.stop(s);
            self.active = null;
            self.next_index += 1;
        } else return error.Rejected;
    }

    fn start(self: *Reducer, s: *c.State, value: c.Value) c.Error!void {
        const kind = try c.str(value, "type");
        try s.budget.take(@sizeOf(Content));
        var content: Content = .{ .kind = std.meta.stringToEnum(Kind, kind) orelse return error.Rejected };
        switch (content.kind) {
            .text => {
                const text = try c.str(value, "text");
                try s.append(&content.text, text);
                if (text.len != 0) try s.emit(.{ .text = text });
            },
            .thinking => {
                const text = try c.str(value, "thinking");
                try s.append(&content.text, text);
                if (c.field(value, "signature")) |signature| try s.append(&content.signature, try c.string(signature));
                if (text.len != 0) try s.emit(.{ .reasoning = text });
            },
            .redacted_thinking => content.redacted = try s.copy(try c.str(value, "data")),
            .tool_use => {
                try s.tool();
                content.id = try s.copy(try c.str(value, "id"));
                content.name = try s.copy(try c.str(value, "name"));
                const input = try c.required(value, "input");
                if (input != .object) return error.Protocol;
                content.initial_empty = input.object.count() == 0;
                content.initial_input = try (c.Json{ .a = s.a }).encode(input, @min(s.limits.wire_message_bytes, s.limits.tool_argument_bytes));
                try s.budget.take(content.initial_input.len);
            },
        }
        self.active = content;
    }

    fn delta(self: *Reducer, s: *c.State, value: c.Value) c.Error!void {
        const content = &self.active.?;
        const kind = try c.str(value, "type");
        if (c.eq(kind, "text_delta") and content.kind == .text) {
            const text = try c.str(value, "text");
            try s.append(&content.text, text);
            try s.emit(.{ .text = text });
        } else if (c.eq(kind, "thinking_delta") and content.kind == .thinking) {
            const text = try c.str(value, "thinking");
            if (content.signature.items.len != 0) return error.Protocol;
            try s.append(&content.text, text);
            try s.emit(.{ .reasoning = text });
        } else if (c.eq(kind, "signature_delta") and content.kind == .thinking) {
            try s.append(&content.signature, try c.str(value, "signature"));
        } else if (c.eq(kind, "input_json_delta") and content.kind == .tool_use) {
            if (!content.initial_empty) return error.Protocol;
            const bytes = try c.str(value, "partial_json");
            if (bytes.len > s.limits.tool_argument_bytes -| content.text.items.len) return error.LimitExceeded;
            try s.append(&content.text, bytes);
            if (content.id.len == 0) return error.Protocol;
            try s.emit(.{ .tool_arguments = .{ .call_id = content.id, .bytes = bytes } });
        } else return error.Rejected;
    }

    fn stop(self: *Reducer, s: *c.State) c.Error!void {
        const content = self.active.?;
        const j: c.Json = .{ .a = s.a };
        switch (content.kind) {
            .text => try s.block(.{ .text = content.text.items }),
            .tool_use => try s.block(.{ .tool_call = .{ .id = content.id, .name = content.name, .arguments_json = if (content.text.items.len == 0) content.initial_input else content.text.items } }),
            .thinking => {
                if (content.signature.items.len == 0) return error.Protocol;
                var native = try j.typed("thinking");
                try j.text(&native, "thinking", content.text.items);
                try j.text(&native, "signature", content.signature.items);
                try s.replay(native);
            },
            .redacted_thinking => {
                var native = try j.typed("redacted_thinking");
                try j.text(&native, "data", content.redacted);
                try s.replay(native);
            },
        }
    }
};
