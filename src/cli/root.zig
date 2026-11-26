const std = @import("std");
const foo = @import("foo");
const builtin = @import("builtin");
const auth = @import("auth");
const builtins = @import("builtins");
const secret_input = @import("secret_input.zig");
const config = @import("configuration");
pub const arguments = @import("arguments.zig");
pub const login = @import("login.zig");
pub const models = @import("models.zig");
const rpc = @import("rpc.zig");

const process = @import("process.zig");

pub const executeProcess = process.execute;
pub const withProcessSignals = process.withSignals;
pub const waitForOperation = process.fileOperation;
pub const SessionMode = arguments.SessionMode;
pub const BindError = foo.io.Error || error{ MissingCredential, SessionUnavailable };

pub const Release = struct {
    context: *anyopaque,
    close_fn: *const fn (*anyopaque, std.Io) void,
};

pub const Binding = struct {
    session: foo.events.SessionId,
    tools: foo.tool.Registry,
    services: foo.host.Services,
    release: ?Release = null,
};

pub const Runtime = struct {
    context: *anyopaque,
    runner: foo.host.Runner,
    bind_fn: *const fn (*anyopaque, std.mem.Allocator, foo.io.Context, config.Effective, SessionMode) BindError!Binding,
};

pub const Streams = struct {
    input: std.Io.File,
    output: std.Io.File,
    diagnostic: std.Io.File,
};

/// Opens the HTTP transport on first use, so commands that never log in skip TLS setup.
pub const Network = struct {
    context: *anyopaque,
    open_fn: *const fn (*anyopaque, foo.io.Context) foo.io.Error!foo.io.HttpTransport,
};

pub const Options = struct {
    cwd: []const u8,
    streams: ?Streams = null,
    environ: ?*const std.process.Environ.Map = null,
    environment_json: ?[]const u8 = null,
    discover_config: bool = false,
    runtime: ?Runtime = null,
    authentication: auth.Resolver = .{},
    network: ?Network = null,
};

pub const Exit = enum(u8) {
    success = 0,
    usage = 2,
    limit = 3,
    provider = 4,
    storage = 5,
    host = 6,
    interrupted = 7,
    cancelled = 130,

    pub fn fromError(err: foo.io.Error) Exit {
        return switch (err) {
            error.InvalidInput => .usage,
            error.DeadlineExceeded, error.LimitExceeded => .limit,
            error.Cancelled => .cancelled,
            else => .host,
        };
    }

    pub fn fromOutcome(outcome: foo.events.Outcome) Exit {
        return switch (outcome.reason) {
            .completed => .success,
            .cancelled => .cancelled,
            .interrupted => .interrupted,
            .limit_reached => .limit,
            .provider_error => .provider,
            .storage_error => .storage,
            .host_error => .host,
        };
    }
};

pub const help =
    \\Usage:
    \\  foo [--approve]          Open the TUI.
    \\  foo run (--prompt TEXT | --stdin) [--resume] [OPTIONS]
    \\  foo rpc [--resume] [OPTIONS]
    \\  foo tui [--resume] [OPTIONS]
    \\  foo acp [OPTIONS]
    \\  foo mcp list KIND SERVER [OPTIONS]
    \\  foo mcp get KIND SERVER ID [--arguments JSON] [OPTIONS]
    \\  KIND is resource, resource_template, or prompt.
    \\  foo config (check | show) [OPTIONS]
    \\  foo models [PROVIDER] [--all] [OPTIONS]
    \\  foo auth login [PROVIDER [--browser | --device | --api-key]]
    \\  foo auth list
    \\  foo auth logout PROVIDER
    \\  foo --help | --version
    \\
    \\Options:
    \\  --approve              Load .foo/config.json from the directory where foo starts.
    \\  --config PATH          Load an explicit JSON config. Repeat in precedence order.
    \\  --preset coding        Select the built-in coding preset.
    \\  --provider ID          Select a provider's default model.
    \\  --model [PROVIDER/]ID  Select a model. Without PROVIDER, keep the selected provider.
    \\  --family FAMILY        Set openai_responses, openai_chat, or anthropic_messages.
    \\  --endpoint URL         Override the complete POST URL of the selected model.
    \\  --credential-env NAME  Read the provider credential from a named environment variable.
    \\  --cwd PATH             Override the configured working directory.
    \\  --resume               Open the existing journal in the configured session directory.
    \\  --all                  List every provider in foo models, not only the ready ones.
    \\
;

pub fn execute(
    allocator: std.mem.Allocator,
    operation: foo.io.Context,
    argv: []const []const u8,
    options: Options,
) Exit {
    const streams = options.streams orelse Streams{
        .input = .stdin(),
        .output = .stdout(),
        .diagnostic = .stderr(),
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    operation.check() catch |err| return failed(streams, operation, err);
    const discovery = if (options.discover_config) options.environ else null;
    const command = arguments.parseWithDiscovery(a, argv, options.cwd, options.environment_json, discovery) catch |err| switch (err) {
        error.InvalidArguments => {
            report(streams, operation.io, "invalid arguments. Use foo --help", .{});
            return .usage;
        },
        else => |e| return failed(streams, operation, e),
    };
    switch (command.action) {
        .help => return print(streams, operation, help),
        .version => return print(streams, operation, "foo " ++ foo.version ++ "\n"),
        .auth => |action| return runAuth(a, operation, streams, options, action),
        else => {},
    }

    var resolver = options.authentication;
    resolver.environment = options.environ;
    var readiness: ReadinessCheck = .{ .a = a, .operation = operation, .resolver = &resolver };
    var input = command.config;
    input.readiness = readiness.interface();
    input.model_optional = command.action == .models;
    var diagnostic: ?config.Diagnostic = null;
    const effective = config.resolve(a, operation, input, &diagnostic) catch |err| {
        if (readiness.failure) |failure| return authFailure(a, operation, streams, resolver.store, failure);
        if (diagnostic) |detail| {
            if (unknownFilter(command, detail)) {
                const message = login.unknownProvider(a, command.action.models.provider.?, "Run foo models --all") catch return failed(streams, operation, error.OutOfMemory);
                report(streams, operation.io, "{s}", .{message});
                return .usage;
            }
            report(streams, operation.io, "config {s} from {s} at {s}{s}{s}", .{
                @tagName(detail.reason),                  @tagName(detail.source),  detail.path,
                if (detail.message != null) ": " else "", detail.message orelse "",
            });
            return if (err == error.LimitExceeded) .limit else .usage;
        }
        return switch (err) {
            error.InvalidConfiguration, error.InvalidJson, error.UnsupportedVersion => .usage,
            else => |e| failed(streams, operation, e),
        };
    };
    switch (command.action) {
        .check => return .success,
        .show => {
            const json = config.effectiveJson(a, effective) catch |err| return switch (err) {
                error.InvalidConfiguration, error.InvalidJson, error.UnsupportedVersion => .usage,
                else => |e| failed(streams, operation, e),
            };
            writeAll(streams.output, operation, json) catch |err| return failed(streams, operation, err);
            return print(streams, operation, "\n");
        },
        .models => |filter| return listModels(a, operation, streams, effective, &resolver, filter),
        .run, .rpc => {},
        .tui, .acp, .mcp => {
            report(streams, operation.io, "frontend is unavailable", .{});
            return .host;
        },
        .help, .version, .auth => unreachable,
    }

    if (command.session == .@"resume" and effective.launch.session.directory == null) {
        report(streams, operation.io, "--resume requires a configured session directory", .{});
        return .usage;
    }
    {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        if (checkCredentials(scratch.allocator(), operation, streams, effective.runtime.model, &resolver)) |exit| return exit;
    }
    const runtime = options.runtime orelse {
        report(streams, operation.io, "runtime is unavailable", .{});
        return .host;
    };
    const text = if (command.action == .run)
        getPrompt(a, operation, streams.input, command.action.run, effective.runtime.limits) catch |err|
            return failed(streams, operation, err)
    else
        "";
    const binding = runtime.bind_fn(runtime.context, a, operation, effective, command.session) catch |err| switch (err) {
        error.MissingCredential => {
            report(streams, operation.io, "runtime credential is unavailable", .{});
            return .usage;
        },
        error.SessionUnavailable => {
            report(streams, operation.io, "session is unavailable", .{});
            return .storage;
        },
        else => |e| return failed(streams, operation, e),
    };
    defer if (binding.release) |release| release.close_fn(release.context, operation.io);
    if (effective.launch.session.directory != null and binding.services.store == null) {
        report(streams, operation.io, "configured session store is unavailable", .{});
        return .storage;
    }

    var invocation: Invocation = .{
        .settings = effective.runtime,
        .binding = binding,
        .runner = runtime.runner,
        .restore_history = command.session == .@"resume",
    };
    if (command.action == .rpc) {
        rpc.serve(allocator, operation, streams.input, streams.output, effective.runtime.limits, .{
            .context = &invocation,
            .run_fn = Invocation.run,
        }) catch |err| return failed(streams, operation, err);
        return .success;
    }
    return runPlain(allocator, operation, streams, &invocation, text);
}

const Invocation = struct {
    settings: foo.config.Resolved,
    binding: Binding,
    runner: foo.host.Runner,
    restore_history: bool,

    fn run(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        operation: foo.io.Context,
        run_id: foo.events.RunId,
        text: []const u8,
        sink: foo.events.Sink,
    ) foo.io.Error!foo.events.Outcome {
        const self: *Invocation = @ptrCast(@alignCast(context));
        try operation.check();
        try validatePrompt(text, self.settings.limits);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var history: []const foo.provider.Message = &.{};
        if (self.binding.services.store) |store| {
            if (self.restore_history) {
                const recovered = store.load_fn(store.context, a, operation) catch |err| switch (err) {
                    error.Cancelled, error.DeadlineExceeded, error.OutOfMemory => |e| return e,
                    else => return .{ .reason = .storage_error },
                };
                if (recovered.uncertain_call_ids.len != 0)
                    return .{ .reason = .interrupted, .uncertain_effects = true };
                history = recovered.messages;
            }
            self.restore_history = true;
        }
        const block: foo.provider.Block = .{ .text = text };
        const messages = try a.alloc(foo.provider.Message, history.len + 1);
        @memcpy(messages[0..history.len], history);
        messages[history.len] = .{ .role = .user, .blocks = (&block)[0..1] };
        return self.runner.run_fn(self.runner.context, allocator, operation, .{
            .session = self.binding.session,
            .run = run_id,
            .settings = self.settings,
            .messages = messages,
            .tools = self.binding.tools,
            .services = self.binding.services,
        }, sink);
    }
};

const Plain = struct {
    output: std.Io.File,
    last: ?u8 = null,
    failure: ?foo.io.Error = null,

    fn emit(context: *anyopaque, operation: foo.io.Context, event: foo.events.Event) foo.io.Error!void {
        const self: *Plain = @ptrCast(@alignCast(context));
        switch (event.data) {
            .message_committed => |committed| {
                if (committed.message.role != .assistant) return;
                for (committed.message.blocks) |block| {
                    if (block != .text or block.text.len == 0) continue;
                    process.fileOperation(operation, writeAll, .{ self.output, operation, block.text }) catch |err| {
                        self.failure = err;
                        return err;
                    };
                    self.last = block.text[block.text.len - 1];
                }
            },
            else => {},
        }
    }
};

fn runPlain(
    a: std.mem.Allocator,
    operation: foo.io.Context,
    streams: Streams,
    invocation: *Invocation,
    text: []const u8,
) Exit {
    var plain: Plain = .{ .output = streams.output };
    const outcome = Invocation.run(invocation, a, operation, @fromBackingInt(@intCast(1)), text, .{
        .context = &plain,
        .emit_fn = Plain.emit,
    }) catch |err| return failed(streams, operation, plain.failure orelse err);
    const status = Exit.fromOutcome(outcome);
    if (outcome.uncertain_effects) report(streams, operation.io, "unresolved tool effects", .{});
    if (plain.failure) |err| return failed(streams, operation, err);
    if (status != .success) {
        if (outcome.detail) |detail| {
            report(streams, operation.io, "{f}", .{detail.reason(invocation.settings.model.credential)});
        } else report(streams, operation.io, "run ended with {s}", .{@tagName(outcome.reason)});
        return status;
    }
    if (plain.last) |last| {
        if (last != '\n') {
            process.fileOperation(operation, writeAll, .{ streams.output, operation, "\n" }) catch |err|
                return failed(streams, operation, err);
        }
    }
    return .success;
}

/// Adapts `auth.Resolver.availability` to the callback config uses for the zero-config pick.
/// A store error is kept in `failure` and ends resolution as `error.Unavailable`, so the caller
/// reports it the same way as an explicit selection would, and never falls through to env.
pub const ReadinessCheck = struct {
    a: std.mem.Allocator,
    operation: foo.io.Context,
    resolver: *const auth.Resolver,
    failure: ?auth.Error = null,

    pub fn interface(self: *ReadinessCheck) config.Readiness {
        return .{ .context = self, .ready_fn = ready };
    }

    fn ready(context: *anyopaque, credential: foo.config.SecretRef) foo.io.Error!bool {
        const self: *ReadinessCheck = @ptrCast(@alignCast(context));
        const availability = self.resolver.availability(self.a, self.operation, credential) catch |err| switch (err) {
            error.InvalidStore, error.UnsafeStore, error.InsecurePermissions, error.Authentication => {
                self.failure = err;
                return error.Unavailable;
            },
            else => |e| return e,
        };
        return availability != .missing;
    }
};

/// `foo models nope`: the PROVIDER is unknown, which config reports as an invalid `provider`
/// from the PROVIDER argument with no further message. Conflicts carry a message and stay as is.
fn unknownFilter(command: arguments.Command, detail: config.Diagnostic) bool {
    if (command.action != .models or command.action.models.provider == null or detail.message != null) return false;
    const location = detail.location orelse return false;
    return detail.reason == .invalid_value and std.mem.eql(u8, detail.path, "provider") and std.mem.eql(u8, location, "PROVIDER");
}

fn listModels(a: std.mem.Allocator, operation: foo.io.Context, streams: Streams, effective: config.Effective, resolver: *const auth.Resolver, filter: arguments.ModelsCommand) Exit {
    const listing = models.list(a, operation, effective, resolver, .{ .provider = filter.provider, .all = filter.all }) catch |err|
        return authFailure(a, operation, streams, resolver.store, err);
    var widths: [2]usize = .{ 0, 0 };
    for (listing.rows) |row| {
        widths[0] = @max(widths[0], row.provider.len + 1 + row.id.len);
        widths[1] = @max(widths[1], row.name.len);
    }
    var out: std.Io.Writer.Allocating = .init(a);
    for (listing.rows) |row| {
        var context: [16]u8 = undefined;
        const window = if (row.context) |tokens| models.humanize(&context, tokens) else "";
        out.writer.print("{s} {s}/{s}", .{ if (row.selected) "*" else " ", row.provider, row.id }) catch return failed(streams, operation, error.OutOfMemory);
        out.writer.splatByteAll(' ', widths[0] - row.provider.len - row.id.len + 1) catch return failed(streams, operation, error.OutOfMemory);
        out.writer.print("{s}", .{row.name}) catch return failed(streams, operation, error.OutOfMemory);
        out.writer.splatByteAll(' ', widths[1] - row.name.len + 2) catch return failed(streams, operation, error.OutOfMemory);
        out.writer.print("{s:<6} {f}\n", .{ window, row.status }) catch return failed(streams, operation, error.OutOfMemory);
    }
    writeAll(streams.output, operation, out.written()) catch |err| return failed(streams, operation, err);
    if (listing.hidden_providers != 0) {
        const plural = listing.hidden_providers != 1;
        report(streams, operation.io, "{d} more provider{s} need{s} a credential. Run foo models --all or foo auth login PROVIDER", .{
            listing.hidden_providers, if (plural) "s" else "", if (plural) "" else "s",
        });
    }
    return .success;
}

pub fn missingCredential(a: std.mem.Allocator, operation: foo.io.Context, model: foo.config.Model, resolver: *const auth.Resolver) auth.Error!?foo.config.SecretRef {
    if (model.credential != .none) {
        _ = resolver.interface().resolve(a, operation, model.credential) catch |err| switch (err) {
            error.Authentication => return model.credential,
            else => |e| return e,
        };
    }
    for (model.headers) |header| {
        if (header.value != .environment) continue;
        const missing: foo.config.SecretRef = .{ .environment = header.value.environment };
        const value = auth.resolveValue(resolver.environment, header.value) catch return missing;
        if (!auth.validHeaderValue(value)) return missing;
    }
    return null;
}

pub fn checkCredentials(a: std.mem.Allocator, operation: foo.io.Context, streams: Streams, model: foo.config.Model, resolver: *const auth.Resolver) ?Exit {
    const missing = missingCredential(a, operation, model, resolver) catch |err|
        return authFailure(a, operation, streams, resolver.store, err);
    return switch (missing orelse return null) {
        .environment => |name| missingEnvironment(streams, operation, name),
        .auth => |id| missingLogin(a, streams, operation, id),
        .literal => failed(streams, operation, error.InvalidInput),
        .none => unreachable,
    };
}

fn missingEnvironment(streams: Streams, operation: foo.io.Context, name: []const u8) Exit {
    report(streams, operation.io, "missing or invalid credential in environment variable {s}. Set {s}", .{ name, name });
    return .usage;
}

fn missingLogin(a: std.mem.Allocator, streams: Streams, operation: foo.io.Context, id: []const u8) Exit {
    const argument = shellArgument(a, id) catch return failed(streams, operation, error.OutOfMemory);
    const variables = auth.fallbackVariables(id);
    if (variables.len != 0) {
        report(streams, operation.io, "no credential for {s}. Run foo auth login {s} or set {s}", .{ id, argument, variables[0] });
    } else {
        report(streams, operation.io, "missing or invalid stored credential. Run foo auth login {s}", .{argument});
    }
    return .provider;
}

fn shellArgument(a: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    for (text) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "-_./", byte) == null) {
            if (builtin.os.tag == .windows) {
                // Quote using PowerShell syntax on Windows.
                const escaped = try std.mem.replaceOwned(u8, a, text, "'", "''");
                return std.fmt.allocPrint(a, "'{s}'", .{escaped});
            }
            const escaped = try std.mem.replaceOwned(u8, a, text, "'", "'\\''");
            return std.fmt.allocPrint(a, "'{s}'", .{escaped});
        }
    }
    return text;
}

pub fn authFailure(a: std.mem.Allocator, operation: foo.io.Context, streams: Streams, store: ?auth.Store, err: auth.Error) Exit {
    switch (err) {
        error.InsecurePermissions => {
            const directory = store.?.directory;
            if (builtin.os.tag == .windows) {
                report(streams, operation.io, "unsafe authentication permissions in {s}. Restrict access to your Windows account", .{directory});
            } else {
                const path = std.fs.path.join(a, &.{ directory, "auth.json" }) catch return failed(streams, operation, error.OutOfMemory);
                const argument = shellArgument(a, path) catch return failed(streams, operation, error.OutOfMemory);
                report(streams, operation.io, "unsafe authentication permissions. Run chmod 600 {s}", .{argument});
            }
            return .storage;
        },
        error.InvalidStore, error.UnsafeStore => {
            report(streams, operation.io, "cannot use authentication store in {s}: {s}", .{ store.?.directory, @errorName(err) });
            return .storage;
        },
        error.Authentication => {
            report(streams, operation.io, "authentication failed", .{});
            return .provider;
        },
        else => |e| return failed(streams, operation, e),
    }
}

fn runAuth(a: std.mem.Allocator, operation: foo.io.Context, streams: Streams, options: Options, command: arguments.AuthCommand) Exit {
    var resolver = options.authentication;
    resolver.environment = options.environ;
    if (command == .providers) return listProviders(a, operation, streams, resolver.registry);
    const login_fn = if (command == .login) choice: {
        const id = command.login.provider;
        const chosen = login.plan(a, id, command.login.method, auth.findFlow(resolver.registry, id), builtins.find(id) != null) catch
            return failed(streams, operation, error.OutOfMemory);
        break :choice switch (chosen) {
            .oauth => |flow_login| flow_login,
            .api_key => null,
            .refuse => |message| {
                report(streams, operation.io, "{s}", .{message});
                return .usage;
            },
        };
    } else null;
    const store = resolver.store orelse {
        report(streams, operation.io, "no user configuration directory. Set FOO_CONFIG_DIR to an absolute path", .{});
        return .usage;
    };
    return switch (command) {
        .providers => unreachable,
        .login => |request| login_entry: {
            var buffer: [auth.max_secret_bytes]u8 = undefined;
            defer std.crypto.secureZero(u8, &buffer);
            const entry: auth.Entry = if (login_fn) |flow_login| oauth: {
                const network = options.network orelse {
                    report(streams, operation.io, "network is unavailable", .{});
                    return .host;
                };
                const http = network.open_fn(network.context, operation) catch |err| return failed(streams, operation, err);
                var prompt: LoginPrompt = .{ .streams = streams };
                break :oauth .{ .oauth = flow_login(.{
                    .a = a,
                    .operation = operation,
                    .http = http,
                    .prompt = .{ .context = &prompt, .show_fn = LoginPrompt.show },
                }) catch |err| switch (err) {
                    error.Authentication => {
                        report(streams, operation.io, "login for {s} was not completed", .{request.provider});
                        return .provider;
                    },
                    error.DeadlineExceeded => {
                        report(streams, operation.io, "login for {s} timed out", .{request.provider});
                        return .limit;
                    },
                    else => |e| return authFailure(a, operation, streams, store, e),
                } };
            } else key: {
                const prompt = std.fmt.allocPrint(a, "{s} API key: ", .{request.provider}) catch return failed(streams, operation, error.OutOfMemory);
                const key = process.fileOperation(operation, secret_input.read, .{ operation, streams.input, streams.diagnostic, prompt, &buffer }) catch |err| switch (err) {
                    error.TerminalRequired => {
                        report(streams, operation.io, "--api-key requires an interactive terminal", .{});
                        return .usage;
                    },
                    else => |e| return failed(streams, operation, e),
                };
                break :key .{ .api_key = key };
            };
            store.put(a, operation, request.provider, entry) catch |err| return authFailure(a, operation, streams, store, err);
            break :login_entry .success;
        },
        .list => list: {
            var snapshot = store.read(a, operation) catch |err| return authFailure(a, operation, streams, store, err);
            defer snapshot.deinit();
            const now_ms = std.Io.Timestamp.now(operation.io, .real).toMilliseconds();
            var out: std.Io.Writer.Allocating = .init(a);
            for (snapshot.entries.keys(), snapshot.entries.values()) |provider, entry| {
                const expiry = switch (entry) {
                    .api_key => "no expiry",
                    .oauth => |oauth| std.fmt.allocPrint(a, "expires in {d}h", .{
                        std.math.divCeil(i64, @max(0, oauth.expires_ms -| @as(i64, @intCast(now_ms))), 3_600_000) catch unreachable,
                    }) catch return failed(streams, operation, error.OutOfMemory),
                };
                out.writer.print("{s}  {s}  {s}\n", .{ provider, @tagName(entry), expiry }) catch return failed(streams, operation, error.OutOfMemory);
            }
            // Built-ins with a variable set and nothing stored are credentials too.
            for (builtins.all) |entry| {
                if (snapshot.entries.contains(entry.record.id)) continue;
                const name = auth.availableVariable(options.environ, entry.record.id) orelse continue;
                out.writer.print("{s}  env  {s}\n", .{ entry.record.id, name }) catch return failed(streams, operation, error.OutOfMemory);
            }
            writeAll(streams.output, operation, out.written()) catch |err| return failed(streams, operation, err);
            break :list .success;
        },
        .logout => |provider| logout: {
            store.remove(a, operation, provider) catch |err| return authFailure(a, operation, streams, store, err);
            break :logout .success;
        },
    };
}

/// The `foo auth login` table. Derived from the registry and the flows, never hand-written.
fn listProviders(a: std.mem.Allocator, operation: foo.io.Context, streams: Streams, registry: []const auth.Flow) Exit {
    var out: std.Io.Writer.Allocating = .init(a);
    var widths: [3]usize = .{ "PROVIDER".len, "NAME".len, "LOGIN".len };
    for (builtins.all) |entry| {
        widths[0] = @max(widths[0], entry.record.id.len);
        widths[1] = @max(widths[1], entry.record.name.len);
        widths[2] = @max(widths[2], loginMethods(auth.findFlow(registry, entry.record.id)).len);
    }
    const Line = struct {
        fn write(writer: *std.Io.Writer, cols: [3]usize, cells: [3][]const u8, env: []const []const u8) std.Io.Writer.Error!void {
            for (cells, cols) |cell, width| {
                try writer.writeAll(cell);
                try writer.splatByteAll(' ', width - cell.len + 2);
            }
            for (env, 0..) |name, i| {
                if (i != 0) try writer.writeByte(' ');
                try writer.writeAll(name);
            }
            try writer.writeByte('\n');
        }
    };
    Line.write(&out.writer, widths, .{ "PROVIDER", "NAME", "LOGIN" }, &.{"ENVIRONMENT"}) catch return failed(streams, operation, error.OutOfMemory);
    for (builtins.all) |entry| {
        const methods = loginMethods(auth.findFlow(registry, entry.record.id));
        Line.write(&out.writer, widths, .{ entry.record.id, entry.record.name, methods }, entry.record.env) catch return failed(streams, operation, error.OutOfMemory);
    }
    return print(streams, operation, out.written());
}

fn loginMethods(flow: ?auth.Flow) []const u8 {
    const f = flow orelse return "api-key";
    if (f.browser != null and f.device != null) return "browser, device, api-key";
    return if (f.browser != null) "browser, api-key" else "device, api-key";
}

const LoginPrompt = struct {
    streams: Streams,

    fn show(raw: *anyopaque, operation: foo.io.Context, notice: auth.Notice) auth.Error!void {
        const self: *LoginPrompt = @ptrCast(@alignCast(raw));
        const parts: []const []const u8 = switch (notice) {
            .url => |url| &.{ "Open this URL to log in:\n  ", url, "\n" },
            .device_code => |device| &.{ "Open ", device.uri, " and enter code ", device.code, "\n" },
        };
        for (parts) |part| try writeAll(self.streams.diagnostic, operation, part);
    }
};

fn promptLimit(limits: foo.config.Limits) usize {
    return @min(arguments.max_prompt_bytes, limits.transcript_bytes);
}

fn validatePrompt(text: []const u8, limits: foo.config.Limits) foo.io.Error!void {
    if (text.len > promptLimit(limits)) return error.LimitExceeded;
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return error.InvalidInput;
}

fn getPrompt(
    a: std.mem.Allocator,
    operation: foo.io.Context,
    input: std.Io.File,
    prompt: arguments.Prompt,
    limits: foo.config.Limits,
) foo.io.Error![]const u8 {
    const text = switch (prompt) {
        .argument => |value| value,
        .stdin => try process.fileOperation(operation, readPrompt, .{ a, operation, input, promptLimit(limits) }),
    };
    try validatePrompt(text, limits);
    return text;
}

fn readPrompt(a: std.mem.Allocator, operation: foo.io.Context, input: std.Io.File, limit: usize) foo.io.Error![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    var buffer: [8192]u8 = undefined;
    while (true) {
        try operation.check();
        const capacity = @min(buffer.len, limit - text.items.len + 1);
        const n = input.readStreaming(operation.io, &.{buffer[0..capacity]}) catch |err| switch (err) {
            error.EndOfStream => return text.items,
            error.Canceled => return error.Cancelled,
            else => return error.IoFailure,
        };
        if (n > limit - text.items.len) return error.LimitExceeded;
        try text.appendSlice(a, buffer[0..n]);
    }
}

fn writeAll(output: std.Io.File, operation: foo.io.Context, bytes: []const u8) foo.io.Error!void {
    var remaining = bytes;
    while (remaining.len != 0) {
        try operation.check();
        const n = output.writeStreaming(operation.io, &.{}, &.{remaining}, 1) catch |err| switch (err) {
            error.Canceled => return error.Cancelled,
            error.BrokenPipe => return error.Disconnected,
            else => return error.IoFailure,
        };
        if (n == 0) return error.IoFailure;
        remaining = remaining[n..];
    }
}

fn print(streams: Streams, operation: foo.io.Context, bytes: []const u8) Exit {
    writeAll(streams.output, operation, bytes) catch |err| return failed(streams, operation, err);
    return .success;
}

fn failed(streams: Streams, operation: foo.io.Context, err: foo.io.Error) Exit {
    report(streams, operation.io, "{s}", .{@errorName(err)});
    return Exit.fromError(err);
}

fn report(streams: Streams, io: std.Io, comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const bytes = std.fmt.bufPrint(&buffer, "foo: " ++ format ++ "\n", args) catch "foo: command failed\n";
    streams.diagnostic.writeStreamingAll(io, bytes) catch {};
}

test {
    _ = arguments;
    _ = login;
    _ = models;
}
