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
    const transport_prefix = b.option([]const u8, "transport-prefix", "Installation prefix for the pinned curl profile") orelse env: {
        b.graph.poisonCache();
        break :env b.graph.environ_map.get("FOO_TRANSPORT_PREFIX");
    };
    const transport_test = if (transport_prefix) |prefix|
        addTransportSuite(b, foo, target, optimize, prefix)
    else
        &b.addFail("Transport requires FOO_TRANSPORT_PREFIX or -Dtransport-prefix; use nix develop .#ci or build the pinned native profile").step;
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
    if (transport_prefix) |prefix| {
        if (builtin.os.tag == .windows) addTransportPath(b, run, prefix);
    }
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
    if (transport_prefix) |prefix| {
        if (builtin.os.tag == .windows) addTransportPath(b, run_tests, prefix);
    }
    const wire_root = b.createModule(.{
        .root_source_file = b.path("tests/wire/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    wire_root.addImport("foo", foo);
    wire_root.addImport("support", support);
    const wire_tests = b.addTest(.{ .root_module = wire_root });
    const run_wire_tests = b.addRunArtifact(wire_tests);
    if (transport_prefix) |prefix| {
        if (builtin.os.tag == .windows) addTransportPath(b, run_wire_tests, prefix);
    }

    const selected = b.option([]const u8, "module", "Test module (contracts, transport, or wire)") orelse "contracts";
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
    } else if (std.mem.eql(u8, selected, "transport")) {
        test_step.dependOn(transport_test);
    } else if (std.mem.eql(u8, selected, "wire")) {
        test_step.dependOn(&run_wire_tests.step);
    } else if (!std.mem.eql(u8, selected, "contracts")) {
        test_step.dependOn(&b.addFail(b.fmt("Module '{s}' is unavailable: its implementation and test root have not landed", .{selected})).step);
    } else {
        test_step.dependOn(&run_tests.step);
    }
    const test_compile = b.step("test-compile", "Compile contract and wire tests without claiming native execution");
    test_compile.dependOn(&tests.step);
    test_compile.dependOn(&wire_tests.step);
    const fmt = b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src"), b.path("tests") },
        .check = true,
    });
    const bootstrap = b.step("check-bootstrap", "Check formatting, compile the executable, and run contract tests");
    bootstrap.dependOn(&fmt.step);
    bootstrap.dependOn(&exe.step);
    bootstrap.dependOn(&run_tests.step);
    const check = b.step("check", "Check formatting, compile the executable, and run implemented suites");
    check.dependOn(bootstrap);
    check.dependOn(transport_test);
    check.dependOn(&run_wire_tests.step);
    for ([_][]const u8{ "acceptance", "acceptance-live", "bench", "release" }) |name| {
        b.step(name, "Reserved; unavailable until the owning work package lands").dependOn(
            &b.addFail(b.fmt("'{s}' is unavailable in the contracts bootstrap", .{name})).step,
        );
    }
}

fn addTransportSuite(
    b: *std.Build,
    foo: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    prefix: []const u8,
) *std.Build.Step {
    const include = b.pathJoin(&.{ prefix, "include" });
    const lib = b.pathJoin(&.{ prefix, "lib" });
    const translate = b.addTranslateC(.{
        .root_source_file = b.graph.cwdRelativePath(b.pathJoin(&.{ include, "curl", "curl.h" })),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(b.graph.cwdRelativePath(include));
    const curl = translate.createModule();
    const library = switch (target.result.os.tag) {
        .linux => "libcurl.so",
        .macos => "libcurl.dylib",
        .windows => "libcurl_imp.lib",
        else => return &b.addFail("The curl profile supports Linux, macOS, and Windows").step,
    };
    curl.addObjectFile(b.graph.cwdRelativePath(b.pathJoin(&.{ lib, library })));
    if (target.result.os.tag != .windows) curl.addRPath(b.graph.cwdRelativePath(lib));
    foo.addImport("curl", curl);

    const probe = b.addExecutable(.{
        .name = "transport-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/transport/probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    probe.root_module.addImport("foo", foo);
    const fixtures = b.addSystemCommand(&.{if (builtin.os.tag == .windows) "python" else "python3"});
    fixtures.addFileArg(b.path("tests/transport/fixtures.py"));
    fixtures.addArtifactArg(probe);
    if (builtin.os.tag == .windows) addTransportPath(b, fixtures, prefix);
    return &fixtures.step;
}

fn addTransportPath(b: *std.Build, run: *std.Build.Step.Run, prefix: []const u8) void {
    const bin = b.pathJoin(&.{ prefix, "bin" });
    b.graph.poisonCache();
    const path = b.graph.environ_map.get("PATH") orelse "";
    run.setEnvironmentVariable("PATH", b.fmt("{s};{s}", .{ bin, path }));
}
