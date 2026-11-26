//! Decides how `foo auth login PROVIDER [--browser | --device | --api-key]` logs in. Pure, so the
//! table is tested without I/O.
const std = @import("std");
const auth = @import("auth");
const builtins = @import("builtins");
const arguments = @import("arguments.zig");

pub const Plan = union(enum) {
    oauth: *const fn (auth.Login) auth.Error!auth.OAuth,
    api_key,
    /// Exit 2 with this message.
    refuse: []const u8,
};

pub fn plan(a: std.mem.Allocator, id: []const u8, method: arguments.LoginMethod, flow: ?auth.Flow, known: bool) std.mem.Allocator.Error!Plan {
    const browser = if (flow) |f| f.browser else null;
    const device = if (flow) |f| f.device else null;
    return switch (method) {
        .api_key => .api_key,
        .browser => if (browser) |f| .{ .oauth = f } else .{ .refuse = try std.fmt.allocPrint(a, "{s} has no browser login. Use foo auth login {s}", .{ id, id }) },
        .device => if (device) |f| .{ .oauth = f } else .{ .refuse = try std.fmt.allocPrint(a, "{s} has no device login. Use foo auth login {s}", .{ id, id }) },
        .auto => if (browser orelse device) |f|
            .{ .oauth = f }
        else if (known)
            .api_key
        else
            .{ .refuse = try unknownProvider(a, id, "Run foo auth login to list providers, or add --api-key to store a key under this name") },
    };
}

/// "unknown provider X (did you mean Y?). <hint>", with the suggestion when one id is close.
pub fn unknownProvider(a: std.mem.Allocator, id: []const u8, hint: []const u8) std.mem.Allocator.Error![]const u8 {
    if (suggestion(id)) |close| return std.fmt.allocPrint(a, "unknown provider {s} (did you mean {s}?). {s}", .{ id, close, hint });
    return std.fmt.allocPrint(a, "unknown provider {s}. {s}", .{ id, hint });
}

const max_edits = 2;

pub fn suggestion(id: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = max_edits + 1;
    for (builtins.all) |builtin| {
        const distance = editDistance(id, builtin.record.id);
        if (distance < best_distance) {
            best = builtin.record.id;
            best_distance = distance;
        }
    }
    return best;
}

/// Damerau-Levenshtein with adjacent transpositions, so "antrhopic" is one edit from "anthropic".
fn editDistance(left: []const u8, right: []const u8) usize {
    if (left.len > 64 or right.len > 64) return @max(left.len, right.len);
    var rows: [3][65]usize = undefined;
    for (0..right.len + 1) |j| rows[1][j] = j;
    for (0..left.len) |i| {
        const prev = &rows[(i + 1) % 3];
        const cur = &rows[(i + 2) % 3];
        const before = &rows[i % 3];
        cur[0] = i + 1;
        for (0..right.len) |j| {
            const cost: usize = if (left[i] == right[j]) 0 else 1;
            var best = @min(prev[j + 1] + 1, @min(cur[j] + 1, prev[j] + cost));
            if (i > 0 and j > 0 and left[i] == right[j - 1] and left[i - 1] == right[j]) best = @min(best, before[j - 1] + 1);
            cur[j + 1] = best;
        }
    }
    return rows[(left.len + 1) % 3][right.len];
}

test "typos within two edits suggest the built-in" {
    try std.testing.expectEqualStrings("anthropic", suggestion("antrhopic").?);
    try std.testing.expectEqualStrings("openai", suggestion("opena").?);
    try std.testing.expectEqualStrings("xai", suggestion("xAi").?);
    try std.testing.expectEqual(null, suggestion("mygateway"));
}
