const std = @import("std");
const c = @import("common.zig");

pub const Reducer = struct {
    const Call = struct { index: u64, id: []const u8, name: []const u8, bytes: usize = 0 };
    calls: std.ArrayList(Call) = .empty,

    pub fn event(self: *Reducer, s: *c.State, value: c.Value) c.Error!void {
        if (s.terminal) return error.Protocol;
        const kind = try c.str(value, "type");
        if (c.eq(kind, "error")) return c.apiError(value);
        if (c.eq(kind, "response.failed")) return c.apiError(try c.required(value, "response"));
        if (c.eq(kind, "response.completed") or c.eq(kind, "response.incomplete")) {
            const response = try c.required(value, "response");
            const incomplete = c.eq(kind, "response.incomplete");
            if (!c.eq(try c.str(response, "status"), if (incomplete) "incomplete" else "completed")) return error.Protocol;
            if (incomplete) {
                const reason = try c.str(try c.required(response, "incomplete_details"), "reason");
                if (c.eq(reason, "max_output_tokens")) s.stop = .output_limit else if (c.eq(reason, "content_filter")) s.stop = .refusal else return error.Rejected;
            }
            const items = try c.required(response, "output");
            try self.output(s, items);
            if (s.stop == null) s.stop = if (s.calls != 0) .tool_use else .end_turn;
            if (c.field(response, "usage")) |v| try c.openAiUsage(v, &s.usage, .responses);
            s.terminal = true;
            return;
        }
        if (c.eq(kind, "response.output_item.added")) {
            const item = try c.required(value, "item");
            const item_kind = try c.str(item, "type");
            if (c.eq(item_kind, "function_call")) {
                const index = try c.number(try c.required(value, "output_index"));
                for (self.calls.items) |call| if (call.index == index) return error.Protocol;
                if ((try c.str(item, "call_id")).len == 0 or (try c.str(item, "name")).len == 0) return error.Protocol;
                try s.tool();
                try s.budget.take(@sizeOf(Call));
                try self.calls.append(s.a, .{ .index = index, .id = try s.copy(try c.str(item, "call_id")), .name = try s.copy(try c.str(item, "name")) });
            } else if (!c.eq(item_kind, "message") and !c.eq(item_kind, "reasoning")) return error.Rejected;
            return;
        }
        if (c.eq(kind, "response.function_call_arguments.delta")) {
            const index = try c.number(try c.required(value, "output_index"));
            const delta = try c.str(value, "delta");
            for (self.calls.items) |*call| if (call.index == index) {
                if (delta.len > s.limits.tool_argument_bytes -| call.bytes) return error.LimitExceeded;
                try s.budget.take(delta.len);
                call.bytes += delta.len;
                return s.emit(.{ .tool_arguments = .{ .call_id = call.id, .bytes = delta } });
            };
            return error.Protocol;
        }
        if (c.eq(kind, "response.output_text.delta") or c.eq(kind, "response.refusal.delta")) {
            const delta = try c.str(value, "delta");
            try s.budget.take(delta.len);
            return s.emit(.{ .text = delta });
        }
        if (c.eq(kind, "response.reasoning_summary_text.delta") or c.eq(kind, "response.reasoning_text.delta")) {
            const delta = try c.str(value, "delta");
            try s.budget.take(delta.len);
            return s.emit(.{ .reasoning = delta });
        }
        const passive = [_][]const u8{
            "response.created",                     "response.in_progress",                  "response.output_item.done",
            "response.content_part.added",          "response.content_part.done",            "response.output_text.done",
            "response.refusal.done",                "response.function_call_arguments.done", "response.reasoning_summary_part.added",
            "response.reasoning_summary_part.done", "response.reasoning_summary_text.done",  "response.reasoning_text.done",
            "response.metadata",
        };
        for (passive) |allowed| if (c.eq(kind, allowed)) return;
        return error.Rejected;
    }

    fn output(self: *Reducer, s: *c.State, value: c.Value) c.Error!void {
        s.calls = 0;
        for (try c.array(value), 0..) |item, output_index| {
            const kind = try c.str(item, "type");
            if (c.eq(kind, "message")) {
                if (!c.eq(try c.str(item, "role"), "assistant")) return error.Protocol;
                for (try c.array(try c.required(item, "content"))) |content| {
                    const content_kind = try c.str(content, "type");
                    if (c.eq(content_kind, "output_text")) {
                        try s.block(.{ .text = try s.copy(try c.str(content, "text")) });
                    } else if (c.eq(content_kind, "refusal")) {
                        try s.block(.{ .text = try s.copy(try c.str(content, "refusal")) });
                        if (s.stop != .output_limit) s.stop = .refusal;
                    } else return error.Rejected;
                }
            } else if (c.eq(kind, "function_call")) {
                try s.tool();
                const id = try c.str(item, "call_id");
                const name = try c.str(item, "name");
                const arguments = try c.str(item, "arguments");
                if (arguments.len > s.limits.tool_argument_bytes) return error.LimitExceeded;
                for (self.calls.items) |call| if (call.index == output_index) {
                    if (!c.eq(call.id, id) or !c.eq(call.name, name)) return error.Protocol;
                };
                try s.block(.{ .tool_call = .{ .id = try s.copy(id), .name = try s.copy(name), .arguments_json = try s.copy(arguments) } });
            } else if (c.eq(kind, "reasoning")) {
                if (c.field(item, "encrypted_content")) |encrypted| if (encrypted != .null) {
                    _ = try c.string(encrypted);
                };
            } else return error.Rejected;
        }
        try s.replay(value);
    }
};
