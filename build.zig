const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.17.1"))
        @panic("foo requires Zig 0.17.1 (see .zig-version and nix/toolchain.nix)");
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
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
    const core = leaf(b, target, optimize, "src/core/root.zig", &.{.{ .name = "foo", .module = foo }});
    const providers = leaf(b, target, optimize, "src/providers/root.zig", &.{.{ .name = "foo", .module = foo }});
    const journal = leaf(b, target, optimize, "src/session/root.zig", &.{.{ .name = "foo", .module = foo }});
    const configuration = leaf(b, target, optimize, "src/config/root.zig", &.{.{ .name = "foo", .module = foo }});
    const terminal = leaf(b, target, optimize, "src/platform/terminal/root.zig", &.{});
    terminal.link_libc = target.result.os.tag != .windows;
    const cli = leaf(b, target, optimize, "src/cli/root.zig", &.{
        .{ .name = "foo", .module = foo },
        .{ .name = "configuration", .module = configuration },
    });
    const tui = leaf(b, target, optimize, "src/tui/root.zig", &.{
        .{ .name = "foo", .module = foo },
        .{ .name = "configuration", .module = configuration },
        .{ .name = "terminal", .module = terminal },
    });
    const acp = leaf(b, target, optimize, "src/acp/root.zig", &.{.{ .name = "foo", .module = foo }});

    const run_step = b.step("run", "Run foo");
    const release_step = b.step("release", "Build an unpublished native candidate archive");
    const integration = b.step("test-integration", "Exercise the production executable");
    if (transport_prefix) |prefix| {
        const exe = b.addExecutable(.{
            .name = "foo",
            .root_module = leaf(b, target, optimize, "src/main.zig", &.{
                .{ .name = "foo", .module = foo },
                .{ .name = "core", .module = core },
                .{ .name = "providers", .module = providers },
                .{ .name = "journal", .module = journal },
                .{ .name = "configuration", .module = configuration },
                .{ .name = "cli", .module = cli },
                .{ .name = "tui", .module = tui },
                .{ .name = "terminal", .module = terminal },
                .{ .name = "acp", .module = acp },
                .{ .name = "mcp", .module = mcp_test.module },
                .{ .name = "tools", .module = native.registry },
                .{ .name = "process", .module = native.spawner },
            }),
        });
        const install_exe = b.addInstallArtifact(exe, .{});
        if (native.guardian_install) |guardian| install_exe.step.dependOn(&guardian.step);
        b.getInstallStep().dependOn(&install_exe.step);

        const installed_bin: std.Build.LazyPath = .{ .relative = .{ .base = .install_bin, .sub_path = exe.out_filename } };
        const run = std.Build.Step.Run.create(b, "Run installed foo");
        run.addFileArg(installed_bin);
        run.addPassthruArgs();
        run.step.dependOn(&install_exe.step);
        if (builtin.os.tag == .windows) addTransportPath(b, run, prefix);
        run_step.dependOn(&run.step);

        const smoke = pythonCommand(b, "tests/integration/check.py");
        smoke.addFileArg(installed_bin);
        smoke.step.dependOn(&install_exe.step);
        if (builtin.os.tag == .windows) addTransportPath(b, smoke, prefix);
        integration.dependOn(&smoke.step);

        var baseline_query = target.query;
        baseline_query.cpu_model = .baseline;
        baseline_query.cpu_features_add = .empty;
        baseline_query.cpu_features_sub = .empty;
        const release_cpu = b.resolveTargetQuery(baseline_query).result.cpu;
        if (optimize != .safe) {
            release_step.dependOn(&b.addFail("Use -Doptimize=ReleaseSafe to build a candidate").step);
        } else if (target.result.cpu.model != release_cpu.model or !target.result.cpu.features.eql(release_cpu.features)) {
            release_step.dependOn(&b.addFail("Use -Dcpu=baseline to build a portable candidate").step);
        } else {
            const pack = pythonCommand(b, ".github/scripts/package-candidate.py");
            pack.addFileArg(installed_bin);
            pack.addDirectoryArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "" } });
            pack.addArgs(&.{ prefix, target.result.zigTriple(b.allocator) catch @panic("out of memory"), release_cpu.model.name });
            pack.step.dependOn(&install_exe.step);
            release_step.dependOn(&pack.step);
        }
    } else {
        b.getInstallStep().dependOn(transport_test);
        run_step.dependOn(transport_test);
        release_step.dependOn(transport_test);
        integration.dependOn(transport_test);
    }

    const tui_tests = pythonSuite(b, "tests/tui/run.py", optimize);
    const modules = [_]struct { name: []const u8, step: *std.Build.Step }{
        .{ .name = "contracts", .step = &run_tests.step },
        .{ .name = "transport", .step = transport_test },
        .{ .name = "wire", .step = &run_wire_tests.step },
        .{ .name = "core", .step = addZigSuite(b, target, optimize, "tests/core/root.zig", &.{
            .{ .name = "foo", .module = foo },
            .{ .name = "core", .module = core },
            .{ .name = "support", .module = support },
        }) },
        .{ .name = "providers", .step = addZigSuite(b, target, optimize, "tests/providers/root.zig", &.{
            .{ .name = "foo", .module = foo },
            .{ .name = "providers", .module = providers },
            .{ .name = "support", .module = support },
        }) },
        .{ .name = "tools", .step = native.tools },
        .{ .name = "platform-process", .step = native.process },
        .{ .name = "mcp", .step = mcp_test.step },
        .{ .name = "session", .step = pythonSuite(b, "tests/session/check.py", optimize) },
        .{ .name = "acp", .step = pythonSuite(b, "tests/acp/run.py", optimize) },
        .{ .name = "config", .step = addZigSuite(b, target, optimize, "tests/config/root.zig", &.{
            .{ .name = "foo", .module = foo },
            .{ .name = "configuration", .module = configuration },
            .{ .name = "support", .module = support },
        }) },
        .{ .name = "cli", .step = pythonSuite(b, "tests/cli/check.py", optimize) },
        .{ .name = "tui", .step = tui_tests },
        .{ .name = "platform-terminal", .step = tui_tests },
        .{ .name = "integration", .step = integration },
    };

    const test_compile = b.step("test-compile", "Compile contract and wire tests without claiming native execution");
    test_compile.dependOn(&tests.step);
    test_compile.dependOn(&wire_tests.step);
    const fmt = b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src"), b.path("tests") },
        .check = true,
    });
    const bootstrap = b.step("check-bootstrap", "Check formatting and contracts without native transport");
    bootstrap.dependOn(&fmt.step);
    bootstrap.dependOn(&run_tests.step);
    const check = b.step("check", "Run all registered deterministic suites");
    check.dependOn(bootstrap);

    const test_step = b.step("test", "Run a registered module's tests");
    var selected_step: ?*std.Build.Step = null;
    for (modules) |module| {
        if (!std.mem.eql(u8, module.name, "platform-terminal")) check.dependOn(module.step);
        if (std.mem.eql(u8, selected, module.name)) selected_step = module.step;
    }
    if (native.codemode) |code_tests| {
        if (include_codemode) check.dependOn(code_tests);
        if (std.mem.eql(u8, selected, "codemode")) selected_step = code_tests;
    }
    if (!std.mem.eql(u8, selected, "codemode") or selected_step != null) {
        test_step.dependOn(selected_step orelse &b.addFail(b.fmt("Unknown test module: {s}", .{selected})).step);
    }
    for ([_]struct { name: []const u8, lane: []const u8, description: []const u8 }{
        .{ .name = "acceptance", .lane = "offline", .description = "Run the offline corpus against a pinned native archive" },
        .{ .name = "acceptance-live", .lane = "live", .description = "Run explicitly configured live interoperability checks" },
        .{ .name = "bench", .lane = "bench", .description = "Measure the pinned native candidate" },
    }) |qualification| {
        const command = pythonCommand(b, "tests/acceptance/qualify.py");
        command.addArg(qualification.lane);
        command.addPassthruArgs();
        b.step(qualification.name, qualification.description).dependOn(&command.step);
    }
}

fn leaf(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    path: []const u8,
    imports: []const std.Build.Module.Import,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
}

fn addZigSuite(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    path: []const u8,
    imports: []const std.Build.Module.Import,
) *std.Build.Step {
    return &b.addRunArtifact(b.addTest(.{ .root_module = leaf(b, target, optimize, path, imports) })).step;
}

fn pythonCommand(b: *std.Build, script: []const u8) *std.Build.Step.Run {
    const command = b.addSystemCommand(&.{if (builtin.os.tag == .windows) "python" else "python3"});
    command.addFileArg(b.path(script));
    return command;
}

fn pythonSuite(b: *std.Build, script: []const u8, optimize: std.builtin.Optimize) *std.Build.Step {
    const command = pythonCommand(b, script);
    command.addArgs(&.{ "--optimize", switch (optimize) {
        .debug => "Debug",
        .safe => "ReleaseSafe",
        else => @tagName(optimize),
    } });
    return &command.step;
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
    registry: *std.Build.Module,
    guardian_install: ?*std.Build.Step.InstallArtifact,
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
        fixtures.addArtifactArg(executable);
        break :artifact executable;
    } else null;
    return .{
        .tools = &b.addRunArtifact(suite).step,
        .process = &fixtures.step,
        .spawner = process,
        .registry = tools,
        .guardian_install = if (guardian) |exe| b.addInstallArtifact(exe, .{}) else null,
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
) struct { module: *std.Build.Module, step: *std.Build.Step } {
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
    return .{ .module = mcp, .step = peer_tests };
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
