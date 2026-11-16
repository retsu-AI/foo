const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.17.1"))
        @panic("foo requires Zig 0.17.1 (see .zig-version and nix/toolchain.nix)");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const foo = b.addModule("foo", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "foo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("foo", foo);
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the bootstrap executable").dependOn(&run.step);

    const support = b.createModule(.{
        .root_source_file = b.path("tests/support/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    support.addImport("foo", foo);
    const test_root = b.createModule(.{
        .root_source_file = b.path("tests/contracts/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_root.addImport("foo", foo);
    test_root.addImport("support", support);
    const tests = b.addTest(.{ .root_module = test_root });
    const run_tests = b.addRunArtifact(tests);
    const selected = b.option([]const u8, "module", "Test module (contracts is currently implemented)") orelse "contracts";
    const module_names = [_][]const u8{
        "contracts",   "transport", "wire", "core",   "providers", "tools", "platform-process",
        "mcp",         "session",   "acp",  "config", "cli",       "tui",   "platform-terminal",
        "integration",
    };
    var known = false;
    for (module_names) |name| {
        if (std.mem.eql(u8, name, selected)) known = true;
    }
    const test_step = b.step("test", "Run a registered module's tests");
    if (!known) {
        test_step.dependOn(&b.addFail(b.fmt("Unknown test module: {s}", .{selected})).step);
    } else if (!std.mem.eql(u8, selected, "contracts")) {
        test_step.dependOn(&b.addFail(b.fmt("Module '{s}' is unavailable: its implementation and test root have not landed", .{selected})).step);
    } else {
        test_step.dependOn(&run_tests.step);
    }
    b.step("test-compile", "Compile contract tests without claiming native execution").dependOn(&tests.step);
    const fmt = b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src"), b.path("tests") },
        .check = true,
    });
    const check = b.step("check", "Check formatting, compile the executable, and run implemented suites");
    check.dependOn(&fmt.step);
    check.dependOn(&exe.step);
    check.dependOn(&run_tests.step);
    for ([_][]const u8{ "acceptance", "acceptance-live", "bench", "release" }) |name| {
        b.step(name, "Reserved; unavailable until the owning work package lands").dependOn(
            &b.addFail(b.fmt("'{s}' is unavailable in the contracts bootstrap", .{name})).step,
        );
    }
}
