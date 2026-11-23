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
    const wire_filter = b.option([]const u8, "wire-test-filter", "Run wire tests whose names contain this text");
    const wire_tests = b.addTest(.{
        .root_module = wire_root,
        .filters = if (wire_filter) |filter| &.{filter} else &.{},
    });
    const run_wire_tests = b.addRunArtifact(wire_tests);
    if (transport_prefix) |prefix| {
        if (builtin.os.tag == .windows) addTransportPath(b, run_wire_tests, prefix);
    }

    const selected = b.option([]const u8, "module", "Test module") orelse "contracts";
    const include_codemode = b.option(bool, "codemode", "Build the optional Code Mode module and include it in check") orelse false;
    const native = addProcessSuites(b, foo, support, target, optimize, include_codemode or std.mem.eql(u8, selected, "codemode"));
    const mcp_test = addMcpSuite(b, foo, native.spawner, native.guardian, target, optimize, transport_prefix);
    const module_names = [_][]const u8{
        "contracts",   "transport", "wire", "core",   "providers", "tools", "platform-process",
        "mcp",         "session",   "acp",  "config", "cli",       "tui",   "platform-terminal",
        "integration", "codemode",
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
    } else if (std.mem.eql(u8, selected, "tools")) {
        test_step.dependOn(native.tools);
    } else if (std.mem.eql(u8, selected, "platform-process")) {
        test_step.dependOn(native.process);
    } else if (std.mem.eql(u8, selected, "codemode")) {
        if (native.codemode) |code_tests| test_step.dependOn(code_tests);
    } else if (std.mem.eql(u8, selected, "mcp")) {
        test_step.dependOn(mcp_test);
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
    check.dependOn(native.tools);
    check.dependOn(native.process);
    check.dependOn(mcp_test);
    if (native.codemode) |code_tests| check.dependOn(code_tests);
    for ([_][]const u8{ "acceptance", "acceptance-live", "bench", "release" }) |name| {
        b.step(name, "Reserved; unavailable until the owning work package lands").dependOn(
            &b.addFail(b.fmt("'{s}' is unavailable in the contracts bootstrap", .{name})).step,
        );
    }
}

fn addProcessSuites(
    b: *std.Build,
    foo: *std.Build.Module,
    support: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    include_codemode: bool,
) struct {
    tools: *std.Build.Step,
    process: *std.Build.Step,
    codemode: ?*std.Build.Step,
    spawner: *std.Build.Module,
    guardian: ?*std.Build.Step.Compile,
} {
    const use_guardian = target.result.os.tag == .linux or target.result.os.tag == .macos;
    const process = b.addModule("foo-process", .{
        .root_source_file = b.path("src/platform/process/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = use_guardian,
    });
    process.addImport("foo", foo);
    if (use_guardian) process.addCSourceFile(.{ .file = b.path("src/platform/process/posix_native.c") });

    const tools = b.addModule("foo-tools", .{
        .root_source_file = b.path("src/tools/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = use_guardian,
    });
    tools.addImport("foo", foo);
    const suite = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/tools/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "foo", .module = foo },
            .{ .name = "tools", .module = tools },
            .{ .name = "support", .module = support },
        },
    }) });
    const exec = b.createModule(.{
        .root_source_file = b.path("src/tools/exec.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "foo", .module = foo }},
    });
    const probe = b.addExecutable(.{
        .name = "process-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/platform-process/probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "foo", .module = foo },
                .{ .name = "process", .module = process },
                .{ .name = "exec", .module = exec },
            },
        }),
    });
    const fixtures = b.addSystemCommand(&.{if (builtin.os.tag == .windows) "python" else "python3"});
    fixtures.addFileArg(b.path("tests/platform-process/fixtures.py"));
    fixtures.addArtifactArg(probe);
    const guardian = if (use_guardian) artifact: {
        const executable = b.addExecutable(.{
            .name = "foo-process-guardian",
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
        });
        executable.root_module.addCSourceFiles(.{ .files = &.{
            "src/platform/process/guardian.c",
            "src/platform/process/posix_native.c",
        } });
        b.installArtifact(executable);
        fixtures.addArtifactArg(executable);
        break :artifact executable;
    } else null;
    return .{
        .tools = &b.addRunArtifact(suite).step,
        .process = &fixtures.step,
        .spawner = process,
        .guardian = guardian,
        .codemode = if (include_codemode) addCodeModeSuite(b, foo, tools, target, optimize) else null,
    };
}

fn addCodeModeSuite(
    b: *std.Build,
    foo: *std.Build.Module,
    tools: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
) ?*std.Build.Step {
    const os = target.result.os.tag;
    if (os != .linux and os != .macos and os != .windows)
        return &b.addFail("Code Mode supports Linux, macOS, and Windows").step;

    const interpreter = b.lazyDependency("quickjs", .{}) orelse return null;
    const codemode = b.addModule("foo-codemode", .{
        .root_source_file = b.path("src/codemode/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "foo", .module = foo }},
    });
    codemode.addIncludePath(interpreter.path(""));
    codemode.addCSourceFiles(.{
        .root = interpreter.path(""),
        .files = &.{ "quickjs.c", "dtoa.c", "libregexp.c", "libunicode.c" },
        .flags = if (os == .windows)
            &.{ "-std=gnu11", "-O1", "-DWIN32_LEAN_AND_MEAN", "-funsigned-char" }
        else
            &.{ "-std=gnu11", "-O1", "-D_GNU_SOURCE", "-funsigned-char" },
    });
    codemode.addCSourceFile(.{ .file = b.path("src/codemode/vm.c") });
    if (os == .linux) {
        codemode.linkSystemLibrary("m", .{});
        codemode.linkSystemLibrary("pthread", .{});
    }
    const session = b.createModule(.{
        .root_source_file = b.path("src/session/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "foo", .module = foo }},
    });
    const core = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "foo", .module = foo }},
    });
    const suite = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/codemode/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "foo", .module = foo },
            .{ .name = "codemode", .module = codemode },
            .{ .name = "tools", .module = tools },
            .{ .name = "session", .module = session },
            .{ .name = "core", .module = core },
        },
    }) });
    return &b.addRunArtifact(suite).step;
}

fn addMcpSuite(
    b: *std.Build,
    foo: *std.Build.Module,
    process: *std.Build.Module,
    guardian: ?*std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    transport_prefix: ?[]const u8,
) *std.Build.Step {
    const mcp = b.addModule("foo-mcp", .{
        .root_source_file = b.path("src/mcp/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "foo", .module = foo }},
    });
    const suite = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/mcp/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "foo", .module = foo }, .{ .name = "mcp", .module = mcp } },
    }) });
    const peer_tests = b.step("test-mcp", "Run the MCP protocol and native peer fixtures");
    const run_tests = b.addRunArtifact(suite);
    peer_tests.dependOn(&run_tests.step);

    const probe = b.addExecutable(.{
        .name = "mcp-stdio-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/mcp/stdio_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "foo", .module = foo },
                .{ .name = "mcp", .module = mcp },
                .{ .name = "process", .module = process },
            },
        }),
    });
    const python = if (builtin.os.tag == .windows) "python" else "python3";
    const stdio = b.addSystemCommand(&.{python});
    stdio.addFileArg(b.path("tests/mcp/stdio_fixtures.py"));
    stdio.addArtifactArg(probe);
    if (guardian) |executable| stdio.addArtifactArg(executable);
    peer_tests.dependOn(&stdio.step);

    if (transport_prefix) |prefix| {
        const http_probe = b.addExecutable(.{
            .name = "mcp-http-probe",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/mcp/http_probe.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{ .{ .name = "foo", .module = foo }, .{ .name = "mcp", .module = mcp } },
            }),
        });
        const http = b.addSystemCommand(&.{python});
        http.addFileArg(b.path("tests/mcp/http_fixtures.py"));
        http.addArtifactArg(http_probe);
        if (builtin.os.tag == .windows) {
            addTransportPath(b, run_tests, prefix);
            addTransportPath(b, stdio, prefix);
            addTransportPath(b, http, prefix);
        }
        peer_tests.dependOn(&http.step);
    }
    return peer_tests;
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
