const std = @import("std");
const foo = @import("foo");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    const command = args.next();
    if (command) |value| {
        if (args.next() == null) {
            if (std.mem.eql(u8, value, "--version")) {
                try std.Io.File.stdout().writeStreamingAll(init.io, "foo " ++ foo.version ++ "\n");
                return;
            }
            if (std.mem.eql(u8, value, "--help") or std.mem.eql(u8, value, "-h")) {
                try std.Io.File.stdout().writeStreamingAll(init.io,
                    \\foo: configurable Zig agent harness (contracts bootstrap)
                    \\Usage: foo --help | --version
                    \\run, tui, rpc, acp, and config are not implemented yet.
                    \\
                );
                return;
            }
        }
    }
    try std.Io.File.stderr().writeStreamingAll(init.io, "foo: unavailable in the contracts bootstrap; use --help\n");
    std.process.exit(2);
}
