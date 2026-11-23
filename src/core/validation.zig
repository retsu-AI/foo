const std = @import("std");
const foo = @import("foo");
const provider = foo.provider;

pub const Error = error{ InvalidInput, IncompatibleReplay, LimitExceeded, OutOfMemory };
pub const CallIds = std.StringHashMapUnmanaged(enum { pending, completed });

pub fn context(allocator: std.mem.Allocator, messages: []const provider.Message, model: foo.config.Model, byte_limit: usize, ids: *CallIds) Error!usize {
    var budget: foo.io.Budget = .{ .limit = byte_limit };
    var pending: usize = 0;
    for (messages) |message| {
        budget.take(messageBytes(message)) catch return error.LimitExceeded;
        if (pending != 0 and message.role != .tool) return error.InvalidInput;
        var has_result = false;
        for (message.blocks) |block| {
            try checkBlock(message.role, block, model);
            switch (block) {
                .tool_call => |call| {
                    const entry = try ids.getOrPut(allocator, call.id);
                    if (entry.found_existing) return error.InvalidInput;
                    entry.value_ptr.* = .pending;
                    pending += 1;
                },
                .tool_result => |result| {
                    const state = ids.getPtr(result.call_id) orelse return error.InvalidInput;
                    if (state.* != .pending) return error.InvalidInput;
                    state.* = .completed;
                    pending -= 1;
                    has_result = true;
                },
                else => {},
            }
        }
        if (message.role == .tool and !has_result) return error.InvalidInput;
    }
    if (pending != 0) return error.InvalidInput;
    return budget.used;
}

pub fn checkBlock(role: provider.Role, block: provider.Block, model: foo.config.Model) error{ InvalidInput, IncompatibleReplay }!void {
    switch (block) {
        .text => if (role == .tool) return error.InvalidInput,
        .reasoning => if (role != .assistant) return error.InvalidInput,
        .tool_call => |call| if (role != .assistant or call.id.len == 0) return error.InvalidInput,
        .tool_result => |result| if (role != .tool or result.call_id.len == 0) return error.InvalidInput,
        .replay => |replay| if (!replay.compatible(model)) return error.IncompatibleReplay,
    }
}

pub const block_overhead = @sizeOf(provider.Message) + @sizeOf(provider.Block);

pub fn messageBytes(message: provider.Message) usize {
    return @sizeOf(provider.Message) +| (message.blocks.len *| @sizeOf(provider.Block)) +| payloadBytes(message);
}

pub fn payloadBytes(message: provider.Message) usize {
    var bytes: usize = 0;
    for (message.blocks) |block| {
        bytes +|= switch (block) {
            .text => |value| value.len,
            .reasoning => |value| value.text.len +| (if (value.signature) |signature| signature.len else 0),
            .tool_call => |value| value.id.len +| value.name.len +| value.arguments_json.len,
            .tool_result => |value| value.call_id.len +| value.content.len,
            .replay => |value| value.endpoint.len +| value.model.len +| value.bytes.len,
        };
    }
    return bytes;
}

pub fn jsonObject(allocator: std.mem.Allocator, bytes: []const u8, depth: usize) error{OutOfMemory}!bool {
    var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
    defer scanner.deinit();
    const start = scanner.next() catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => false,
    };
    if (start != .object_begin) return false;
    while (scanner.stackHeight() <= depth) {
        const token = scanner.next() catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => false,
        };
        if (token == .end_of_document) return true;
    }
    return false;
}
