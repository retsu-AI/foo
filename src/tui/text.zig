const std = @import("std");
const data = @import("unicode_data.zig");

pub const replacement = "\xef\xbf\xbd";

const Rune = struct { value: u21, length: usize, valid: bool = true };

pub fn decode(input: []const u8) Rune {
    const byte = input[0];
    if (byte < 0x80) return .{ .value = byte, .length = 1 };
    const invalid: Rune = .{ .value = 0xfffd, .length = 1, .valid = false };
    const length = std.unicode.utf8ByteSequenceLength(byte) catch return invalid;
    if (input.len < length) return invalid;
    const cp = std.unicode.utf8Decode(input[0..length]) catch return invalid;
    return .{ .value = cp, .length = length };
}

fn lookup(comptime T: type, ranges: []const data.Range(T), value: u21) ?T {
    var start: usize = 0;
    var end = ranges.len;
    while (start < end) {
        const middle = start + (end - start) / 2;
        const range = ranges[middle];
        if (value < range.first) {
            end = middle;
        } else if (value > range.last) {
            start = middle + 1;
        } else return range.value;
    }
    return null;
}

fn grapheme(cp: u21) data.Grapheme {
    if (cp >= 0xac00 and cp <= 0xd7a3) return if ((cp - 0xac00) % 28 == 0) .lv else .lvt;
    if (cp >= 0x20 and cp <= 0x7e) return .other;
    return lookup(data.Grapheme, &data.grapheme, cp) orelse .other;
}

fn control(kind: data.Grapheme) bool {
    return kind == .cr or kind == .lf or kind == .control;
}

pub fn safe(cp: u21) bool {
    return !control(grapheme(cp));
}

const Segment = struct {
    previous: data.Grapheme = .other,
    regional_pair: bool = false,
    emoji_chain: enum { none, pictographic, joined } = .none,
    indic_chain: enum { none, consonant, linked } = .none,

    fn joined(self: Segment, next: data.Grapheme, pictographic: bool, indic: data.Indic) bool {
        const prev = self.previous;
        if (prev == .cr and next == .lf) return true;
        if (control(prev) or control(next)) return false;
        if (prev == .l and (next == .l or next == .v or next == .lv or next == .lvt)) return true;
        if ((prev == .lv or prev == .v) and (next == .v or next == .t)) return true;
        if ((prev == .lvt or prev == .t) and next == .t) return true;
        if (next == .extend or next == .zwj or next == .spacingmark or prev == .prepend) return true;
        if (indic == .consonant and self.indic_chain == .linked) return true;
        if (pictographic and self.emoji_chain == .joined) return true;
        return next == .regional_indicator and prev == .regional_indicator and self.regional_pair;
    }

    fn accept(self: *Segment, kind: data.Grapheme, pictographic: bool, indic: data.Indic) void {
        self.previous = kind;
        self.regional_pair = kind == .regional_indicator and !self.regional_pair;
        self.emoji_chain = if (pictographic)
            .pictographic
        else if (self.emoji_chain == .pictographic and kind == .extend)
            .pictographic
        else if (self.emoji_chain == .pictographic and kind == .zwj)
            .joined
        else
            .none;
        self.indic_chain = switch (indic) {
            .consonant => .consonant,
            .linker => if (self.indic_chain == .none) .none else .linked,
            .extend => self.indic_chain,
            .none => .none,
        };
    }
};

pub const Cluster = struct { length: usize, width: usize, display: []const u8, line_break: bool = false };

pub fn cluster(input: []const u8) Cluster {
    const first = decode(input);
    if (!first.valid) return .{ .length = first.length, .width = 1, .display = replacement };
    if (first.value == '\n' or first.value == '\r')
        return .{ .length = if (std.mem.startsWith(u8, input, "\r\n")) 2 else 1, .width = 0, .display = "", .line_break = true };
    if (first.value == '\t') return .{ .length = 1, .width = 1, .display = " " };
    if (!safe(first.value)) return .{ .length = first.length, .width = 0, .display = "" };

    var state: Segment = .{};
    var length: usize = 0;
    var width: usize = 0;
    while (length < input.len) {
        const rune = decode(input[length..]);
        if (!rune.valid) break;
        const cp = rune.value;
        const kind = grapheme(cp);
        const ascii = cp < 0x80;
        const pictographic = !ascii and lookup(void, &data.pictographic, cp) != null;
        const indic = if (ascii) .none else lookup(data.Indic, &data.indic, cp) orelse .none;
        if (length > 0 and !state.joined(kind, pictographic, indic)) break;
        state.accept(kind, pictographic, indic);
        width = @max(width, switch (kind) {
            .extend, .zwj => if ((cp == 0xfe0f or cp == 0x20e3) and width != 0) @as(usize, 2) else 0,
            .prepend, .spacingmark => 0,
            else => if (!ascii and (lookup(void, &data.wide, cp) != null or
                lookup(void, &data.emoji_presentation, cp) != null)) @as(usize, 2) else 1,
        });
        length += rune.length;
    }
    if (length > 64 or width == 0) return .{ .length = length, .width = 1, .display = replacement };
    return .{ .length = length, .width = width, .display = input[0..length] };
}

pub fn previous(input: []const u8, cursor: usize) usize {
    var index: usize = 0;
    while (index < cursor) {
        const next = index + cluster(input[index..]).length;
        if (next >= cursor) break;
        index = next;
    }
    return index;
}

test "terminal clusters and controls" {
    inline for ([_][]const u8{ "界", "👩‍💻", "🇺🇸", "1️⃣" }) |sample| {
        const item = cluster(sample ++ "!");
        try std.testing.expectEqual(sample.len, item.length);
        try std.testing.expectEqual(@as(usize, 2), item.width);
    }
    inline for ([_][]const u8{ "á", "क्‍ष" }) |sample| {
        const item = cluster(sample ++ "!");
        try std.testing.expectEqual(sample.len, item.length);
        try std.testing.expectEqual(@as(usize, 1), item.width);
    }
    try std.testing.expectEqualStrings("", cluster("\x1b[0m").display);
    try std.testing.expectEqualStrings("", cluster("\xc2\x9b[0m").display);
    try std.testing.expectEqualStrings(replacement, cluster("\xff").display);
}
