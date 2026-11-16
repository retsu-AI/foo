const std = @import("std");

test "toolchain can parse a provider-shaped JSON message" {
    const parsed = try std.json.parseFromSlice(
        struct { content: []const u8 },
        std.testing.allocator,
        "{\"content\":\"foo\"}",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("foo", parsed.value.content);
}
