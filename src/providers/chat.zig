const std = @import("std");
const c = @import("common.zig");

pub const Reducer = struct {
    const Call = struct { index: usize, id: std.ArrayList(u8) = .empty, name: std.ArrayList(u8) = .empty, arguments: std.ArrayList(u8) = .empty, metadata: ?[]const u8 = null };
    text: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(Call) = .empty,
    reasoning_content: bool = false,
    litellm: bool = false,
    metadata: ?[]const u8 = null,
    refusal: bool = false,
    usage_seen: bool = false,

    pub fn event(self: *Reducer, s: *c.State, value: c.Value) c.Error!void {
        if (s.terminal) return error.Protocol;
        if (c.field(value, "error") != null) return c.apiError(value);
        const choices = try c.array(try c.required(value, "choices"));
        if (choices.len == 0) {
            if (s.stop == null or self.usage_seen) return error.Protocol;
            const usage = try c.required(value, "usage");
            if (usage == .null) return error.Protocol;
            try c.openAiUsage(usage, &s.usage, .chat);
            self.usage_seen = true;
            return;
        }
        if (s.stop != null or choices.len != 1) return error.Protocol;
        const choice = choices[0];
        if (try c.index(choice) != 0) return error.Rejected;
        const delta = try c.required(choice, "delta");
        if (delta != .object) return error.Protocol;
        var fields = delta.object.iterator();
        while (fields.next()) |entry| {
            const key = entry.key_ptr.*;
            const v = entry.value_ptr.*;
            if (v == .null) continue;
            if (c.eq(key, "role")) {
                if (!c.eq(try c.string(v), "assistant")) return error.Protocol;
            } else if (c.eq(key, "content") or c.eq(key, "refusal")) {
                const bytes = try c.string(v);
                if (c.eq(key, "refusal") and bytes.len != 0) self.refusal = true;
                try s.append(&self.text, bytes);
                try s.emit(.{ .text = bytes });
            } else if (c.eq(key, "reasoning_content")) {
                if (!self.reasoning_content) return error.Rejected;
                const bytes = try c.string(v);
                try s.append(&self.reasoning, bytes);
                try s.emit(.{ .reasoning = bytes });
            } else if (c.eq(key, "tool_calls")) {
                for (try c.array(v)) |tool| try self.call(s, tool);
            } else if (c.eq(key, "provider_specific_fields")) {
                if (!self.litellm) return error.Rejected;
                try keepMetadata(s, &self.metadata, v);
            } else return error.Rejected;
        }
        if (c.field(choice, "finish_reason")) |finish| if (finish != .null) {
            const reason = try c.string(finish);
            if (c.eq(reason, "stop")) s.stop = if (self.refusal) .refusal else .end_turn else if (c.eq(reason, "tool_calls")) s.stop = .tool_use else if (c.eq(reason, "length")) s.stop = .output_limit else if (c.eq(reason, "content_filter")) s.stop = .refusal else return error.Rejected;
        };
        if (c.field(value, "usage")) |usage| if (usage != .null) try c.openAiUsage(usage, &s.usage, .chat);
    }

    fn call(self: *Reducer, s: *c.State, value: c.Value) c.Error!void {
        const index = try c.index(value);
        var found: ?*Call = null;
        for (self.calls.items) |*call_value| if (call_value.index == index) {
            found = call_value;
            break;
        };
        if (found == null) {
            if (index >= s.limits.tool_calls) return error.LimitExceeded;
            try s.tool();
            try s.budget.take(@sizeOf(Call));
            try self.calls.append(s.a, .{ .index = index });
            found = &self.calls.items[self.calls.items.len - 1];
        }
        const target = found.?;
        if (c.field(value, "provider_specific_fields")) |extras| if (extras != .null) {
            if (!self.litellm) return error.Rejected;
            try keepMetadata(s, &target.metadata, extras);
        };
        if (c.field(value, "type")) |kind| if (!c.eq(try c.string(kind), "function")) return error.Rejected;
        if (c.field(value, "id")) |id| {
            const bytes = try c.string(id);
            if (target.arguments.items.len != 0 and bytes.len != 0) return error.Protocol;
            try s.append(&target.id, bytes);
        }
        if (c.field(value, "function")) |function| {
            if (c.field(function, "name")) |name| try s.append(&target.name, try c.string(name));
            if (c.field(function, "arguments")) |args| {
                const bytes = try c.string(args);
                if (bytes.len > s.limits.tool_argument_bytes -| target.arguments.items.len) return error.LimitExceeded;
                if (bytes.len != 0 and target.id.items.len == 0) return error.Protocol;
                try s.append(&target.arguments, bytes);
                if (bytes.len != 0) try s.emit(.{ .tool_arguments = .{ .call_id = target.id.items, .bytes = bytes } });
            }
        }
    }

    pub fn done(self: *Reducer, s: *c.State) c.Error!void {
        if (s.terminal or s.stop == null) return error.Protocol;
        if (self.text.items.len != 0) try s.block(.{ .text = self.text.items });
        std.mem.sort(Call, self.calls.items, {}, struct {
            fn less(_: void, a: Call, b: Call) bool {
                return a.index < b.index;
            }
        }.less);
        for (self.calls.items, 0..) |call_value, index| {
            if (call_value.index != index) return error.Protocol;
            try s.block(.{ .tool_call = .{ .id = call_value.id.items, .name = call_value.name.items, .arguments_json = call_value.arguments.items } });
        }
        const j: c.Json = .{ .a = s.a };
        var native = j.object();
        if (self.reasoning.items.len != 0) try j.text(&native, "reasoning_content", self.reasoning.items);
        if (self.metadata) |bytes| try j.put(&native, "provider_specific_fields", try c.parse(s.a, bytes, s.limits));
        var metadata_calls = j.list();
        for (self.calls.items) |call_value| if (call_value.metadata) |bytes| {
            var metadata_call = j.object();
            try j.text(&metadata_call, "id", call_value.id.items);
            try j.put(&metadata_call, "provider_specific_fields", try c.parse(s.a, bytes, s.limits));
            try j.add(&metadata_calls, metadata_call);
        };
        if (metadata_calls.array.items.len != 0) try j.put(&native, "tool_calls", metadata_calls);
        if (native.object.count() != 0) {
            try s.replay(native);
        }
        s.terminal = true;
    }

    fn keepMetadata(s: *c.State, destination: *?[]const u8, value: c.Value) c.Error!void {
        if (value != .object) return error.Protocol;
        const bytes = try (c.Json{ .a = s.a }).encode(value, @min(s.limits.wire_message_bytes, s.budget.limit -| s.budget.used));
        try s.budget.take(bytes.len);
        if (destination.*) |existing| {
            if (!c.eq(existing, bytes)) return error.Rejected;
        } else destination.* = bytes;
    }
};
