const std = @import("std");
const config = @import("configuration");
const text = @import("text.zig");

pub const Action = union(enum) {
    key: config.Key,
    literal: []const u8,
    edit: Edit,
};
pub const Edit = enum { left, right, up, down, home, end, backspace, delete, page_up, page_down };

const paste_end = "\x1b[201~";

pub const Parser = struct {
    mode: enum { normal, escape, csi, ss3, discard_csi, paste } = .normal,
    sequence: [24]u8 = undefined,
    sequence_len: usize = 0,
    escape_at: u64 = 0,
    paste_prefix: usize = 0,
    paste_cr: bool = false,
    utf: [4]u8 = undefined,
    utf_len: usize = 0,
    utf_need: usize = 0,

    pub fn idle(self: *Parser, now: u64, receiver: anytype) !void {
        if (now -| self.escape_at < 45) return;
        switch (self.mode) {
            .escape => {
                self.mode = .normal;
                try receiver.input(.{ .key = .escape });
            },
            .csi, .ss3, .discard_csi => self.mode = .normal,
            else => {},
        }
    }

    pub fn feed(self: *Parser, byte: u8, now: u64, receiver: anytype) !void {
        switch (self.mode) {
            .paste => {
                if (byte == paste_end[self.paste_prefix]) {
                    self.paste_prefix += 1;
                    if (self.paste_prefix == paste_end.len) {
                        self.paste_prefix = 0;
                        self.mode = .normal;
                        try self.finishUtf(receiver);
                    }
                    return;
                }
                for (paste_end[0..self.paste_prefix]) |part| try self.pasted(part, receiver);
                self.paste_prefix = 0;
                if (byte == paste_end[0]) {
                    self.paste_prefix = 1;
                } else try self.pasted(byte, receiver);
            },
            .normal => switch (byte) {
                0x1b => {
                    try self.finishUtf(receiver);
                    self.mode = .escape;
                    self.escape_at = now;
                },
                '\r', '\n', 0x03, 0x04, 0x11 => {
                    try self.finishUtf(receiver);
                    try receiver.input(.{ .key = switch (byte) {
                        '\r' => .enter,
                        '\n' => .@"ctrl+j",
                        0x03 => .@"ctrl+c",
                        0x04 => .@"ctrl+d",
                        0x11 => .@"ctrl+q",
                        else => unreachable,
                    } });
                },
                0x08, 0x7f, 0x01, 0x05 => {
                    try self.finishUtf(receiver);
                    try receiver.input(.{ .edit = switch (byte) {
                        0x01 => .home,
                        0x05 => .end,
                        else => .backspace,
                    } });
                },
                '\t' => {
                    try self.finishUtf(receiver);
                    try receiver.input(.{ .literal = " " });
                },
                else => try self.literal(byte, receiver),
            },
            .escape => {
                self.mode = .normal;
                switch (byte) {
                    '[', 'O' => {
                        self.mode = if (byte == '[') .csi else .ss3;
                        self.sequence_len = 0;
                        self.escape_at = now;
                    },
                    '\r', '\n' => try receiver.input(.{ .key = .@"alt+enter" }),
                    else => {
                        try receiver.input(.{ .key = .escape });
                        try self.feed(byte, now, receiver);
                    },
                }
            },
            .csi, .ss3 => {
                if (byte >= 0x40 and byte <= 0x7e) {
                    self.mode = .normal;
                    const parameters = self.sequence[0..self.sequence_len];
                    if (byte == '~' and std.mem.eql(u8, parameters, "200")) {
                        self.mode = .paste;
                        self.paste_cr = false;
                        return;
                    }
                    if (sequenceAction(byte, parameters)) |action| try receiver.input(action);
                } else if (self.sequence_len == self.sequence.len) {
                    self.mode = .discard_csi;
                } else {
                    self.sequence[self.sequence_len] = byte;
                    self.sequence_len += 1;
                }
            },
            .discard_csi => if (byte >= 0x40 and byte <= 0x7e) {
                self.mode = .normal;
            },
        }
    }

    fn pasted(self: *Parser, byte: u8, receiver: anytype) !void {
        defer self.paste_cr = byte == '\r';
        switch (byte) {
            '\r', '\n' => {
                try self.finishUtf(receiver);
                if (byte != '\n' or !self.paste_cr) try receiver.input(.{ .literal = "\n" });
            },
            '\t' => {
                try self.finishUtf(receiver);
                try receiver.input(.{ .literal = " " });
            },
            else => try self.literal(byte, receiver),
        }
    }

    fn finishUtf(self: *Parser, receiver: anytype) !void {
        if (self.utf_len != 0) {
            self.utf_len = 0;
            try receiver.input(.{ .literal = text.replacement });
        }
    }

    fn literal(self: *Parser, byte: u8, receiver: anytype) !void {
        if (self.utf_len != 0) {
            if (byte & 0xc0 == 0x80) {
                self.utf[self.utf_len] = byte;
                self.utf_len += 1;
                if (self.utf_len != self.utf_need) return;
                const bytes = self.utf[0..self.utf_len];
                self.utf_len = 0;
                const rune = text.decode(bytes);
                if (!rune.valid) return receiver.input(.{ .literal = text.replacement });
                if (text.safe(rune.value)) try receiver.input(.{ .literal = bytes });
                return;
            }
            try self.finishUtf(receiver);
        }
        if (byte < 0x80) {
            if (text.safe(byte)) try receiver.input(.{ .literal = (&byte)[0..1] });
            return;
        }
        self.utf_need = std.unicode.utf8ByteSequenceLength(byte) catch
            return receiver.input(.{ .literal = text.replacement });
        self.utf[0] = byte;
        self.utf_len = 1;
    }
};

fn sequenceAction(final: u8, data: []const u8) ?Action {
    var params = std.mem.splitScalar(u8, data, ';');
    const first = params.next() orelse "";
    const second = params.next() orelse "";
    const third = params.next() orelse "";
    if (final == 'u' or (final == '~' and std.mem.eql(u8, first, "27"))) {
        const modifier = std.fmt.parseInt(u8, second, 10) catch return null;
        const code = std.fmt.parseInt(u8, if (final == 'u') first else third, 10) catch return null;
        const key: config.Key = switch (modifier) {
            1 => switch (code) {
                13 => .enter,
                27 => .escape,
                else => return null,
            },
            3 => if (code == 13) .@"alt+enter" else return null,
            5 => switch (code) {
                13 => .@"ctrl+enter",
                99 => .@"ctrl+c",
                100 => .@"ctrl+d",
                106 => .@"ctrl+j",
                113 => .@"ctrl+q",
                else => return null,
            },
            else => return null,
        };
        return .{ .key = key };
    }
    const edit: Edit = switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        '~' => switch (std.fmt.parseInt(u8, first, 10) catch return null) {
            1, 7 => .home,
            3 => .delete,
            4, 8 => .end,
            5 => .page_up,
            6 => .page_down,
            else => return null,
        },
        else => return null,
    };
    return .{ .edit = edit };
}
