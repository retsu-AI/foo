const std = @import("std");
const foo = @import("foo");
const config = @import("configuration");
const text = @import("text.zig");

pub const max_columns = 192;
pub const max_rows = 100;
pub const preview_bytes = 16 * 1024;
const row_bytes = max_columns * 8;
const scrollback = 384;
const entries_count = 256;
const entries_bytes = 256 * 1024;
const entry_bytes = 16 * 1024;

pub const Style = enum { normal, assistant, tool, @"error", status };
const Row = struct {
    bytes: [row_bytes]u8 = undefined,
    length: usize = 0,
    columns: usize = 0,
    style: Style = .normal,

    const empty: Row = .{};

    fn visible(self: *const Row) []const u8 {
        return self.bytes[0..self.length];
    }

    fn same(self: *const Row, other: *const Row) bool {
        return self.style == other.style and std.mem.eql(u8, self.visible(), other.visible());
    }
};

const Layout = struct {
    rows: []Row,
    width: usize = 0,
    total: usize = 0,
    limit: usize = std.math.maxInt(usize),

    fn reset(self: *Layout, width: usize) void {
        self.width = width;
        self.total = 0;
        self.limit = std.math.maxInt(usize);
    }

    fn start(self: *Layout, style: Style) void {
        self.rows[self.total % self.rows.len] = .{ .style = style };
        self.total += 1;
    }

    fn row(self: Layout, index: usize) *Row {
        return &self.rows[index % self.rows.len];
    }

    fn cells(self: *Layout, bytes: []const u8, cursor: ?usize) ?Position {
        var at: usize = 0;
        var position: ?Position = null;
        while (at < bytes.len and self.total <= self.limit) {
            const cluster = text.cluster(bytes[at..]);
            const style = self.row(self.total - 1).style;
            const width = @min(cluster.width, self.width);
            if (self.row(self.total - 1).columns + width > self.width) self.start(style);
            if (cursor) |point| {
                if (point >= at and point < at + cluster.length)
                    position = .{ .line = self.total - 1, .column = self.row(self.total - 1).columns };
            }
            if (cluster.line_break) {
                self.start(style);
            } else if (width != 0) {
                const current = self.row(self.total - 1);
                const spare = self.width - current.columns - width;
                const display = if (width != cluster.width or cluster.display.len > row_bytes - current.length - spare)
                    "?"
                else
                    cluster.display;
                @memcpy(current.bytes[current.length..][0..display.len], display);
                current.length += display.len;
                current.columns += if (display.ptr == cluster.display.ptr) width else 1;
            }
            at += cluster.length;
        }
        if (cursor == bytes.len)
            position = .{ .line = self.total - 1, .column = self.row(self.total - 1).columns };
        return position;
    }
};

pub const Position = struct { line: usize, column: usize };

pub const Log = struct {
    allocator: std.mem.Allocator,
    entries: [entries_count]Entry = undefined,
    first: usize = 0,
    count: usize = 0,
    bytes: usize = 0,
    layout: Layout,

    const Entry = struct { style: Style, text: []const u8 };

    pub fn init(a: std.mem.Allocator) !Log {
        return .{ .allocator = a, .layout = .{ .rows = try a.alloc(Row, scrollback) } };
    }

    pub fn deinit(self: *Log) void {
        while (self.count != 0) self.evict();
        self.allocator.free(self.layout.rows);
    }

    fn evict(self: *Log) void {
        const oldest = self.entries[self.first];
        self.first = (self.first + 1) % entries_count;
        self.count -= 1;
        self.bytes -= oldest.text.len;
        self.allocator.free(oldest.text);
    }

    pub fn resize(self: *Log, width: usize) void {
        if (width == self.layout.width) return;
        self.layout.reset(width);
        for (0..self.count) |i| {
            const entry = self.entries[(self.first + i) % entries_count];
            self.layout.start(entry.style);
            _ = self.layout.cells(entry.text, null);
        }
    }

    pub fn add(self: *Log, style: Style, prefix: []const u8, body: []const u8) !void {
        const slice = recentText(body, entry_bytes - prefix.len);
        const entry = try std.mem.concat(self.allocator, u8, &.{ prefix, if (slice.len != body.len) "[…] " else "", slice });
        while (self.count == entries_count or entry.len > entries_bytes - self.bytes) self.evict();
        self.entries[(self.first + self.count) % entries_count] = .{ .style = style, .text = entry };
        self.count += 1;
        self.bytes += entry.len;
        self.layout.start(style);
        _ = self.layout.cells(entry, null);
    }

    pub fn message(self: *Log, value: foo.provider.Message) !void {
        for (value.blocks) |block| switch (block) {
            .text => |raw| try self.add(if (value.role == .assistant) .assistant else .normal, switch (value.role) {
                .user => "You: ",
                .assistant => "Assistant: ",
                .system => "System: ",
                .tool => "Tool: ",
            }, raw),
            .tool_call => |call| {
                var buffer: [260]u8 = undefined;
                const label = std.fmt.bufPrint(&buffer, "Tool: {s} (pending)", .{call.name[0..@min(call.name.len, 240)]}) catch unreachable;
                try self.add(.tool, label, "");
            },
            .tool_result => |item| try self.add(if (item.is_error) .@"error" else .tool, "Tool result: ", item.content),
            .reasoning, .replay => {},
        };
    }

    pub fn result(self: *Log, value: foo.tool.Result) !void {
        const id = value.call_id[0..@min(value.call_id.len, 48)];
        const status = if (value.status == .success) "ok" else @tagName(value.status);
        var buffer: [160]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "Tool result: {s} ({s}){s}{s}", .{
            id,
            status,
            if (value.truncated) " [truncated]" else "",
            if (value.effect == .uncertain) " [uncertain]" else "",
        }) catch unreachable;
        try self.add(if (value.status == .success) .tool else .@"error", label, "");
        if (value.content.len != 0) try self.add(.tool, "", value.content);
    }
};

pub fn recentText(bytes: []const u8, limit: usize) []const u8 {
    if (bytes.len <= limit) return bytes;
    var offset = bytes.len - limit;
    while (offset < bytes.len and bytes[offset] & 0xc0 == 0x80) offset += 1;
    return bytes[offset..];
}

pub const Frame = struct {
    allocator: std.mem.Allocator,
    last: []Row,
    size: Size = .{ .columns = 0, .rows = 0 },
    last_cursor: ?Position = null,
    preview: Layout,
    editor: Layout,
    status: Layout,
    scroll: usize = 0,

    pub const Size = struct { columns: usize, rows: usize };
    const View = struct { start: usize, padding: usize };

    pub fn init(a: std.mem.Allocator) !Frame {
        const rows = try a.alloc(Row, max_rows + scrollback + max_rows + 1);
        return .{
            .allocator = a,
            .last = rows[0..max_rows],
            .preview = .{ .rows = rows[max_rows..][0..scrollback] },
            .editor = .{ .rows = rows[max_rows + scrollback ..][0..max_rows] },
            .status = .{ .rows = rows[rows.len - 1 ..] },
        };
    }

    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.last.ptr[0 .. max_rows + scrollback + max_rows + 1]);
    }

    pub fn render(
        self: *Frame,
        output: *std.ArrayList(u8),
        size: Size,
        log: *const Log,
        preview: []const u8,
        editor: []const u8,
        cursor: usize,
        status: []const u8,
        status_error: bool,
        colors: ?@FieldType(config.Tui, "colors"),
    ) !void {
        const a = self.allocator;
        const width = size.columns;
        const resized = !std.meta.eql(self.size, size);
        if (resized) try output.appendSlice(a, "\x1b[2J");
        self.preview.reset(width);
        if (preview.len != 0) {
            self.preview.start(.assistant);
            _ = self.preview.cells("Assistant: ", null);
            _ = self.preview.cells(preview, null);
        }
        self.editor.reset(width);
        self.editor.start(.normal);
        _ = self.editor.cells("> ", null);
        const point = self.editor.cells(editor, cursor).?;
        self.status.reset(width);
        self.status.start(if (status_error) .@"error" else .status);
        const status_slice = status[0..@min(width, status.len)];
        _ = self.status.cells(status_slice, null);

        const editor_height = @min(self.editor.total, @min(4, @max(1, size.rows / 3)));
        const editor_start = @min(point.line -| (editor_height - 1), self.editor.total - editor_height);
        if (editor_start < self.editor.total -| self.editor.rows.len) {
            self.editor.reset(width);
            self.editor.limit = editor_start + editor_height;
            self.editor.start(.normal);
            _ = self.editor.cells("> ", null);
            _ = self.editor.cells(editor, null);
        }
        const status_height: usize = @intFromBool(size.rows >= 2);
        const height = size.rows - editor_height - status_height;
        const available = @min(log.layout.total, scrollback) + @min(self.preview.total, scrollback);
        const pane = self.viewport(height, available);
        const editor_cursor: Position = .{ .line = height + point.line - editor_start, .column = point.column };
        for (0..size.rows) |line| {
            const row: *const Row = if (line < height)
                self.transcriptRow(log, pane, line)
            else if (line < height + editor_height)
                self.editor.row(editor_start + line - height)
            else
                self.status.row(0);
            if (resized or !self.last[line].same(row)) {
                try cup(a, output, .{ .line = line, .column = 0 });
                try output.appendSlice(a, "\x1b[2K");
                if (row.length != 0) {
                    if (colors) |theme| {
                        const color = switch (row.style) {
                            .normal => .default,
                            .assistant => theme.assistant,
                            .tool => theme.tool,
                            .@"error" => theme.@"error",
                            .status => theme.status,
                        };
                        if (color != .default) try print(a, output, "\x1b[{d}m", .{sgr(color)});
                        try output.appendSlice(a, row.visible());
                        if (color != .default) try output.appendSlice(a, "\x1b[0m");
                    } else try output.appendSlice(a, row.visible());
                }
                self.last[line] = row.*;
            }
        }
        if (output.items.len != 0 or self.last_cursor == null or !std.meta.eql(self.last_cursor.?, editor_cursor)) {
            try cup(a, output, editor_cursor);
            self.last_cursor = editor_cursor;
        }
        self.size = size;
    }

    fn viewport(self: *Frame, height: usize, available: usize) View {
        self.scroll = @min(self.scroll, available -| height);
        return .{ .start = (available - self.scroll) -| height, .padding = height -| available };
    }

    fn transcriptRow(self: Frame, log: *const Log, pane: View, line: usize) *const Row {
        if (line < pane.padding) return &Row.empty;
        const index = pane.start + line - pane.padding;
        const committed = @min(log.layout.total, scrollback);
        if (index < committed) return log.layout.row(log.layout.total - committed + index);
        return self.preview.row((self.preview.total -| scrollback) + index - committed);
    }
};

fn cup(a: std.mem.Allocator, output: *std.ArrayList(u8), cursor: Position) !void {
    try print(a, output, "\x1b[{d};{d}H", .{ cursor.line + 1, cursor.column + 1 });
}

fn print(a: std.mem.Allocator, output: *std.ArrayList(u8), comptime format: []const u8, args: anytype) !void {
    var buffer: [48]u8 = undefined;
    try output.appendSlice(a, std.fmt.bufPrint(&buffer, format, args) catch unreachable);
}

fn sgr(color: config.Color) usize {
    const value = @backingInt(color);
    return if (value <= 8) 29 + @as(usize, value) else 81 + @as(usize, value);
}
