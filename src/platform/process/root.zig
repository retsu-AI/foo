const builtin = @import("builtin");

pub const Native = switch (builtin.os.tag) {
    .linux, .macos => @import("posix.zig").Native,
    .windows => @import("windows.zig").Native,
    else => @compileError("Native process ownership requires Linux, macOS, or Windows"),
};
