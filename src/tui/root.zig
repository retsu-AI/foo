const std = @import("std");
const foo = @import("foo");
const config = @import("configuration");
const terminal = @import("terminal");
const keys = @import("input.zig");
const text = @import("text.zig");
const view = @import("view.zig");
const runtime = @import("runtime.zig");

const prompt_capacity = 16 * 1024;
const poll_ms = 12;
const frame_interval_ms = 16;

pub const Streams = struct {
    input: std.Io.File,
    output: std.Io.File,
};

pub const Options = struct {
    runner: foo.host.Runner,
    input: foo.host.RunInput,
    settings: config.Tui = .{},
    streams: ?Streams = null,
    environ: ?*const std.process.Environ.Map = null,
    plain: bool = false,
    no_color: bool = false,
};

/// Borrows the supplied session, settings, history and services through teardown.
/// Uses input.run as the first run ID. Initial messages are the committed history.
pub fn run(a: std.mem.Allocator, operation: foo.io.Context, options: Options) foo.io.Error!?foo.events.Outcome {
    try operation.check();
    const environment = options.environ;
    const plain = options.plain or if (environment) |env|
        std.mem.eql(u8, env.get("TERM") orelse "", "dumb")
    else
        false;
    const streams = options.streams orelse Streams{ .input = .stdin(), .output = .stdout() };
    if (plain) return runPlain(a, operation, options, streams);

    var native = (terminal.Terminal.open(operation.io, streams.input, streams.output) catch return error.IoFailure) orelse
        return runPlain(a, operation, options, streams);
    defer native.restore();
    const no_color = options.no_color or if (environment) |env| env.get("NO_COLOR") != null else false;
    return interactive(a, operation, options, &native, no_color);
}

const History = struct {
    messages: std.ArrayList(foo.provider.Message) = .empty,
    owned: std.ArrayList(runtime.Stored) = .empty,
    budget: foo.io.Budget,

    fn deinit(self: *History, a: std.mem.Allocator) void {
        for (self.owned.items) |*stored| stored.deinit();
        self.owned.deinit(a);
        self.messages.deinit(a);
    }

    fn commit(self: *History, a: std.mem.Allocator, value: runtime.Stored) !void {
        try self.messages.ensureUnusedCapacity(a, 1);
        try self.owned.append(a, value);
        self.messages.appendAssumeCapacity(value.message);
    }
};

const Ui = struct {
    allocator: std.mem.Allocator,
    options: Options,
    operation: foo.io.Context,
    history: History,
    log: view.Log,
    frame: view.Frame,
    editor: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    preview: std.ArrayList(u8) = .empty,
    active: ?*runtime.Run = null,
    last: ?foo.events.Outcome = null,
    history_incomplete: bool = false,
    next_run: ?u64,
    quit: bool = false,
    dirty: bool = true,
    notice: ?[]const u8 = null,
    reason: [1024]u8 = undefined,

    fn closeRun(self: *Ui) void {
        const active = self.active orelse return;
        active.end(self.allocator, self.operation.io);
        self.active = null;
    }

    fn submit(self: *Ui) foo.io.Error!void {
        if (self.active != null or self.editor.items.len == 0) return;
        if (self.history_incomplete) {
            self.notice = "Conversation interrupted";
            return;
        }
        if (runtime.promptBytes(self.editor.items.len) > self.history.budget.limit - self.history.budget.used) {
            self.notice = "Conversation limit reached";
            return;
        }
        const run_id = self.next_run orelse {
            self.notice = "Run ID limit reached";
            return;
        };
        var invocation = self.options.input;
        invocation.run = @fromBackingInt(run_id);
        invocation.messages = self.history.messages.items;
        self.active = try runtime.Run.start(self.allocator, self.operation, self.options.runner, invocation, self.editor.items, self.history.budget);
        self.next_run = std.math.add(u64, run_id, 1) catch null;
        self.editor.clearRetainingCapacity();
        self.cursor = 0;
        self.frame.scroll = 0;
    }

    pub fn input(self: *Ui, action: keys.Action) foo.io.Error!void {
        self.notice = null;
        self.dirty = true;
        switch (action) {
            .key => |key| {
                const bindings = self.options.settings.keys;
                if (key == bindings.submit) return self.submit();
                if (key == bindings.newline) return self.insert("\n");
                if (key == bindings.quit) self.quit = true;
                if (key == bindings.cancel) {
                    if (self.active) |active| active.cancellation.request();
                }
            },
            .literal => |bytes| try self.insert(bytes),
            .edit => |command| self.edit(command),
        }
    }

    fn insert(self: *Ui, bytes: []const u8) foo.io.Error!void {
        const limit = @min(prompt_capacity, self.history.budget.limit -| runtime.promptBytes(0));
        if (bytes.len > limit - self.editor.items.len) {
            self.notice = "Input limit reached";
            return;
        }
        try self.editor.insertSlice(self.allocator, self.cursor, bytes);
        self.cursor += bytes.len;
    }

    fn edit(self: *Ui, command: keys.Edit) void {
        const bytes = self.editor.items;
        if (self.cursor != 0 and self.cursor < bytes.len) {
            const previous = text.previous(bytes, self.cursor);
            self.cursor = @max(self.cursor, previous + text.cluster(bytes[previous..]).length);
        }
        const start = lineStart(bytes, self.cursor);
        switch (command) {
            .left => self.cursor = text.previous(bytes, self.cursor),
            .right => if (self.cursor < bytes.len) {
                self.cursor += text.cluster(bytes[self.cursor..]).length;
            },
            .home => self.cursor = start,
            .end => self.cursor = lineEnd(bytes, self.cursor),
            .backspace => {
                const previous = text.previous(bytes, self.cursor);
                self.editor.replaceRangeAssumeCapacity(previous, self.cursor - previous, "");
                self.cursor = previous;
            },
            .delete => if (self.cursor < bytes.len) {
                self.editor.replaceRangeAssumeCapacity(self.cursor, text.cluster(bytes[self.cursor..]).length, "");
            },
            .up => if (start != 0) {
                const before = lineStart(bytes, start - 1);
                self.cursor = sameColumn(bytes, before, start - 1, self.cursor - start);
            },
            .down => {
                const end = lineEnd(bytes, self.cursor);
                if (end < bytes.len)
                    self.cursor = sameColumn(bytes, end + 1, lineEnd(bytes, end + 1), self.cursor - start);
            },
            .page_up => self.frame.scroll +|= @max(1, self.frame.size.rows -| 3),
            .page_down => self.frame.scroll -|= @max(1, self.frame.size.rows -| 3),
        }
    }

    fn receive(self: *Ui) foo.io.Error!void {
        const active = self.active orelse return;
        const done = active.done.load(.acquire);
        for (0..active.buffer.len) |_| {
            var update: runtime.Update = undefined;
            const count = active.queue.getUncancelable(self.operation.io, (&update)[0..1], 0) catch unreachable;
            if (count == 0) break;
            self.dirty = true;
            switch (update) {
                .text => |*chunk| try self.appendPreview(chunk.bytes[0..chunk.length]),
                .committed => |*stored| {
                    if (stored.message.role == .assistant) self.preview.clearRetainingCapacity();
                    const before = self.log.layout.total;
                    self.project(stored.*) catch |err| {
                        stored.deinit();
                        return err;
                    };
                    if (self.frame.scroll != 0) self.frame.scroll +|= self.log.layout.total - before;
                },
            }
        }
        if (done) {
            self.last = active.outcome;
            self.history.budget = active.budget;
            self.history_incomplete = active.receive_error != null or active.outcome.uncertain_effects or
                active.outcome.reason == .storage_error or active.outcome.reason == .interrupted;
            self.preview.clearRetainingCapacity();
            self.dirty = true;
            self.closeRun();
        }
    }

    fn project(self: *Ui, stored: runtime.Stored) !void {
        if (stored.result) |result| {
            try self.log.result(result);
        } else try self.log.message(stored.message);
        try self.history.commit(self.allocator, stored);
    }

    fn appendPreview(self: *Ui, bytes: []const u8) !void {
        const remaining = view.preview_bytes - bytes.len;
        if (self.preview.items.len > remaining) {
            const keep = view.recentText(self.preview.items, remaining);
            std.mem.copyForwards(u8, self.preview.items, keep);
            self.preview.shrinkRetainingCapacity(keep.len);
        }
        try self.preview.appendSlice(self.allocator, bytes);
    }

    fn status(self: *Ui) struct { label: []const u8, failed: bool = false } {
        if (self.notice) |notice| return .{ .label = notice, .failed = true };
        if (self.active) |active| return .{ .label = if (active.cancellation.requested.load(.acquire)) "Cancelling" else "Running" };
        const outcome = self.last orelse return .{ .label = "Ready" };
        if (outcome.uncertain_effects) return .{ .label = "Interrupted (uncertain tool effects)", .failed = true };
        if (outcome.detail) |detail| {
            if (std.fmt.bufPrint(&self.reason, "{f}", .{detail.reason(self.options.input.settings.model.credential)})) |label|
                return .{ .label = label, .failed = true }
            else |_| {}
        }
        return switch (outcome.reason) {
            .completed => .{ .label = "Completed" },
            .cancelled => .{ .label = "Cancelled" },
            .interrupted => .{ .label = "Interrupted", .failed = true },
            .limit_reached => .{ .label = if (outcome.provider_stop == .output_limit) "Output limit reached" else "Limit reached", .failed = true },
            .provider_error => .{ .label = if (outcome.provider_stop == .refusal) "Provider error (refusal)" else "Provider error", .failed = true },
            .storage_error => .{ .label = "Storage error", .failed = true },
            .host_error => .{ .label = "Host error", .failed = true },
        };
    }
};

fn lineStart(bytes: []const u8, cursor: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, bytes[0..cursor], '\n')) |newline| newline + 1 else 0;
}

fn lineEnd(bytes: []const u8, cursor: usize) usize {
    return if (std.mem.findScalar(u8, bytes[cursor..], '\n')) |newline| cursor + newline else bytes.len;
}

fn sameColumn(bytes: []const u8, start: usize, end: usize, offset: usize) usize {
    var position = start;
    while (position < end) {
        const next = position + text.cluster(bytes[position..end]).length;
        if (next - start > offset) break;
        position = next;
    }
    return position;
}

fn interactive(a: std.mem.Allocator, operation: foo.io.Context, options: Options, native: *terminal.Terminal, no_color: bool) foo.io.Error!?foo.events.Outcome {
    var frame = try view.Frame.init(a);
    const log = view.Log.init(a) catch |err| {
        frame.deinit();
        return err;
    };
    var ui: Ui = .{
        .allocator = a,
        .options = options,
        .operation = operation,
        .history = .{ .budget = .{ .limit = options.input.settings.limits.transcript_bytes } },
        .log = log,
        .frame = frame,
        .next_run = @backingInt(options.input.run),
    };
    defer ui.history.deinit(a);
    defer ui.log.deinit();
    defer ui.frame.deinit();
    defer ui.editor.deinit(a);
    defer ui.preview.deinit(a);
    defer ui.closeRun();
    for (options.input.messages) |message| {
        try ui.history.budget.take(runtime.messageBytes(message));
        try ui.log.message(message);
    }
    try ui.history.messages.appendSlice(a, options.input.messages);

    var writer: runtime.Writer = .{};
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    var writing = try writer.start(operation.io, native);
    defer {
        writer.queue.close(operation.io);
        writing.cancel(operation.io);
    }

    var parser: keys.Parser = .{};
    var bytes: [4096]u8 = undefined;
    var next_frame: u64 = 0;
    var next_size: u64 = 0;
    var size: view.Frame.Size = .{ .columns = 0, .rows = 1 };
    while (!ui.quit) {
        try operation.check();
        const now = operation.clock.now();
        if (now >= next_size) {
            const measured = native.size() catch return error.IoFailure;
            const actual: view.Frame.Size = .{
                .columns = @min(view.max_columns, measured.columns -| 1),
                .rows = std.math.clamp(measured.rows, 1, view.max_rows),
            };
            if (!std.meta.eql(actual, size)) {
                size = actual;
                ui.log.resize(size.columns);
                ui.dirty = true;
            }
            next_size = now +| 30;
        }
        try ui.receive();
        switch (writer.status.load(.acquire)) {
            .failed => return error.IoFailure,
            .pending => {},
            .idle => if (ui.dirty and now >= next_frame) {
                const status = ui.status();
                output.clearRetainingCapacity();
                try ui.frame.render(&output, size, &ui.log, ui.preview.items, ui.editor.items, ui.cursor, status.label, status.failed, if (no_color) null else options.settings.colors);
                if (output.items.len != 0) writer.send(operation.io, output.items);
                ui.dirty = false;
                next_frame = now +| frame_interval_ms;
            },
        }
        switch (native.read(&bytes, poll_ms) catch return error.IoFailure) {
            .bytes => |count| for (bytes[0..count]) |byte| {
                if (ui.quit) break;
                try parser.feed(byte, operation.clock.now(), &ui);
            },
            .timeout => try parser.idle(operation.clock.now(), &ui),
            .eof => break,
            .terminated => return error.Cancelled,
        }
    }
    try ui.receive();
    if (ui.active != null) return .{ .reason = .cancelled };
    return ui.last;
}

const Plain = struct {
    output: std.Io.File,
    last: ?u8 = null,

    fn emit(context: *anyopaque, operation: foo.io.Context, event: foo.events.Event) foo.io.Error!void {
        const self: *Plain = @ptrCast(@alignCast(context));
        if (event.data != .message_committed) return;
        const message = event.data.message_committed.message;
        if (message.role != .assistant) return;
        var buffer: [4096]u8 = undefined;
        var length: usize = 0;
        for (message.blocks) |block| {
            if (block != .text) continue;
            var bytes = block.text;
            while (bytes.len != 0) {
                const cluster = text.cluster(bytes);
                bytes = bytes[cluster.length..];
                const safe = if (cluster.line_break) "\n" else cluster.display;
                if (safe.len == 0) continue;
                if (safe.len > buffer.len - length) {
                    try write(self.output, operation, buffer[0..length]);
                    length = 0;
                }
                @memcpy(buffer[length..][0..safe.len], safe);
                length += safe.len;
                self.last = safe[safe.len - 1];
            }
        }
        try write(self.output, operation, buffer[0..length]);
    }
};

fn runPlain(a: std.mem.Allocator, operation: foo.io.Context, options: Options, streams: Streams) foo.io.Error!?foo.events.Outcome {
    var limits: foo.io.Budget = .{ .limit = options.input.settings.limits.transcript_bytes };
    for (options.input.messages) |message| try limits.take(runtime.messageBytes(message));
    const limit = limits.limit - limits.used -| runtime.promptBytes(0);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    var buffer: [4096]u8 = undefined;
    while (true) {
        try operation.check();
        const capacity = @min(buffer.len, (limit - bytes.items.len) +| 1);
        const count = streams.input.readStreaming(operation.io, &.{buffer[0..capacity]}) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Canceled => return error.Cancelled,
            else => return error.IoFailure,
        };
        if (count > limit - bytes.items.len) return error.LimitExceeded;
        try bytes.appendSlice(a, buffer[0..count]);
    }
    if (bytes.items.len == 0 or !std.unicode.utf8ValidateSlice(bytes.items)) return error.InvalidInput;
    var invocation = options.input;
    const block: foo.provider.Block = .{ .text = bytes.items };
    const messages = try a.alloc(foo.provider.Message, invocation.messages.len + 1);
    defer a.free(messages);
    @memcpy(messages[0..invocation.messages.len], invocation.messages);
    messages[invocation.messages.len] = .{ .role = .user, .blocks = (&block)[0..1] };
    invocation.messages = messages;
    var projection: Plain = .{ .output = streams.output };
    const outcome = try options.runner.run_fn(options.runner.context, a, operation, invocation, .{ .context = &projection, .emit_fn = Plain.emit });
    if (projection.last) |last| {
        if (last != '\n') try write(projection.output, operation, "\n");
    }
    return outcome;
}

fn write(output: std.Io.File, operation: foo.io.Context, bytes: []const u8) foo.io.Error!void {
    try operation.check();
    output.writeStreamingAll(operation.io, bytes) catch |err| switch (err) {
        error.BrokenPipe => return error.Disconnected,
        error.Canceled => return error.Cancelled,
        else => return error.IoFailure,
    };
}
