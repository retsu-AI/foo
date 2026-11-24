const std = @import("std");
const builtin = @import("builtin");
const foo = @import("foo");
const cli = @import("cli");
const configuration = @import("configuration");
const core = @import("core");
const providers = @import("providers");
const journal = @import("journal");
const tools = @import("tools");
const process = @import("process");
const mcp = @import("mcp");
const alloc = std.mem.Allocator;
const io = foo.io;

pub const App = struct {
    allocator: alloc,
    environ: *const std.process.Environ.Map,
    native: process.Native,
    engine: core.Engine = .{},
    transport: ?foo.transport.Runtime = null,
    roots: ?[]const u8 = null,
    cli_session: ?*Session = null,

    pub fn deinit(self: *App) void {
        if (self.transport) |transport| transport.deinit();
        if (self.roots) |roots| self.allocator.free(roots);
        if (self.native.guardian_path) |path| self.allocator.free(path);
    }

    pub fn cliRuntime(self: *App) cli.Runtime {
        return .{
            .context = self,
            .runner = .{ .context = self, .run_fn = runCli },
            .bind_fn = bindCli,
        };
    }

    fn runCli(raw: *anyopaque, a: alloc, operation: io.Context, input: foo.host.RunInput, sink: foo.events.Sink) io.Error!foo.events.Outcome {
        const self: *App = @ptrCast(@alignCast(raw));
        const session = self.cli_session orelse return error.Unavailable;
        return session.run(a, operation, input, sink);
    }

    fn bindCli(raw: *anyopaque, _: alloc, operation: io.Context, settings: configuration.Effective, mode: cli.SessionMode) cli.BindError!cli.Binding {
        const self: *App = @ptrCast(@alignCast(raw));
        const session = try Session.open(self, operation, settings, @fromBackingInt(1), .{}, switch (mode) {
            .fresh => .fresh,
            .@"resume" => .@"resume",
        });
        self.cli_session = session;
        return .{
            .session = session.id,
            .tools = session.emptyRegistry(),
            .services = session.services(),
            .release = .{ .context = self, .close_fn = closeCli },
        };
    }

    fn closeCli(raw: *anyopaque, std_io: std.Io) void {
        const self: *App = @ptrCast(@alignCast(raw));
        const session = self.cli_session.?;
        self.cli_session = null;
        const cancel: io.Cancellation = .{};
        session.closeAfter(.{ .io = std_io, .clock = session.clock, .cancellation = &cancel });
    }

    fn httpClient(self: *App, operation: io.Context) io.Error!foo.transport.Client {
        if (self.transport == null) {
            const roots = if (self.environ.get("FOO_CA_FILE")) |path| try loadRoots(self.allocator, operation, path) else null;
            errdefer if (roots) |pem| self.allocator.free(pem);
            self.transport = try foo.transport.Runtime.init();
            self.roots = roots;
        }
        return self.transport.?.client(self.allocator, .{ .ca_pem = self.roots });
    }

    fn spawner(self: *App, operation: io.Context) io.Error!io.Spawner {
        if (builtin.os.tag != .windows and self.native.guardian_path == null) {
            const path = try executableGuardian(self.allocator, operation.io);
            self.native.guardian_path = path;
        }
        return self.native.interface();
    }
};

const Local = struct { dir: std.Io.Dir, store: journal.Store };
pub const OpenMode = union(enum) { fresh, @"resume", editor: []const u8 };
pub const Session = struct {
    app: *App,
    id: foo.events.SessionId,
    settings: configuration.Effective,
    host: foo.host.Host,
    launch_cwd: []const u8,
    clock: io.Clock,
    transport: foo.transport.Client,
    provider: providers.Adapter,
    local: ?Local = null,
    peers: ?[]Peer = null,
    operation_ids: std.atomic.Value(u64) = .init(1),

    pub fn open(app: *App, operation: io.Context, effective: configuration.Effective, id: foo.events.SessionId, host: foo.host.Host, mode: OpenMode) (io.Error || error{SessionUnavailable})!*Session {
        try operation.check();
        const cwd = std.Io.Dir.openDirAbsolute(operation.io, effective.runtime.cwd, .{}) catch |err| return fileError(err);
        cwd.close(operation.io);
        const self = try app.allocator.create(Session);
        errdefer app.allocator.destroy(self);
        self.* = .{
            .app = app,
            .id = id,
            .settings = effective,
            .host = host,
            .launch_cwd = if (mode == .editor) mode.editor else effective.runtime.cwd,
            .clock = operation.clock,
            .transport = try app.httpClient(operation),
            .provider = undefined,
        };
        errdefer self.transport.deinit();
        self.provider = .{
            .transport = self.transport.interface(),
            .environment = app.environ,
            .retry_attempts = effective.runtime.retry_attempts,
            .scratch_allocator = app.allocator,
        };
        if (effective.launch.session.directory) |path| {
            self.local = self.openJournal(operation, path, mode) catch |err| return switch (err) {
                error.Canceled, error.Cancelled => error.Cancelled,
                error.OutOfMemory => error.OutOfMemory,
                else => error.SessionUnavailable,
            };
        }
        return self;
    }

    fn openJournal(self: *Session, operation: io.Context, path: []const u8, mode: OpenMode) !Local {
        const std_io = operation.io;
        var dir = try std.Io.Dir.openDirAbsolute(std_io, path, .{ .iterate = true });
        if (mode == .editor) {
            const parent = dir;
            defer parent.close(std_io);
            var nonce: [16]u8 = undefined;
            try std_io.randomSecure(&nonce);
            const hex = std.fmt.bytesToHex(nonce, .lower);
            var name: [36]u8 = undefined;
            @memcpy(name[0..4], "acp-");
            @memcpy(name[4..], &hex);
            const permissions: std.Io.Dir.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
            try parent.createDir(std_io, &name, permissions);
            dir = try parent.openDir(std_io, &name, .{ .iterate = true });
        }
        errdefer dir.close(std_io);
        const limit = self.settings.launch.session.limits;
        const limits: journal.Limits = .{
            .max_record_bytes = limit.max_record_bytes,
            .max_journal_bytes = limit.max_journal_bytes,
            .max_context_bytes = limit.max_context_bytes,
            .max_artifact_bytes = limit.max_artifact_bytes,
            .max_artifacts = limit.max_artifacts,
        };
        const settings = self.settings.runtime;
        var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
        const endpoint = std.mem.sliceTo(settings.model.endpoint, '?');
        for ([_][]const u8{ @tagName(settings.model.family), endpoint, settings.model.id, settings.cwd }) |part| {
            var size: [8]u8 = undefined;
            std.mem.writeInt(u64, &size, part.len, .little);
            hash.update(&size);
            hash.update(part);
        }
        const identity = std.fmt.bytesToHex(hash.finalResult(), .lower);
        const store = try switch (mode) {
            .fresh, .editor => journal.Store.create(self.app.allocator, std_io, dir, &identity, limits),
            .@"resume" => journal.Store.open(self.app.allocator, std_io, dir, &identity, limits),
        };
        return .{ .dir = dir, .store = store };
    }

    pub fn deinit(self: *Session, operation: io.Context) io.Error!void {
        defer self.app.allocator.destroy(self);
        defer self.transport.deinit();
        const shield = operation.io.swapCancelProtection(.blocked);
        defer _ = operation.io.swapCancelProtection(shield);
        if (self.local) |*local| {
            local.store.deinit();
            local.dir.close(operation.io);
        }
        if (self.peers) |peers| {
            defer self.app.allocator.free(peers);
            var failure: ?io.Error = null;
            for (peers) |*peer| peer.deinit(operation) catch |err| {
                failure = err;
            };
            if (failure) |err| return err;
        }
    }

    pub fn closeAfter(self: *Session, operation: io.Context) void {
        const cancel: io.Cancellation = .{};
        self.deinit(cleanupContext(operation, &cancel, self.settings.launch.process.cleanup_ms)) catch {
            std.Io.File.stderr().writeStreamingAll(operation.io, "foo: MCP cleanup could not be confirmed\n") catch {};
        };
    }

    pub fn runner(self: *Session) foo.host.Runner {
        return .{ .context = self, .run_fn = runSession };
    }

    pub fn emptyRegistry(self: *Session) foo.tool.Registry {
        return .{ .context = self, .declarations = &.{}, .invoke_fn = noTool };
    }

    pub fn services(self: *Session) foo.host.Services {
        return .{
            .provider = self.provider.interface(),
            .store = if (self.local) |*local| local.store.interface() else null,
            .host = self.host,
        };
    }

    fn noTool(_: *anyopaque, _: alloc, _: io.Context, _: foo.tool.Invocation) io.Error!foo.tool.Result {
        return error.Unavailable;
    }

    fn runSession(raw: *anyopaque, a: alloc, operation: io.Context, input: foo.host.RunInput, sink: foo.events.Sink) io.Error!foo.events.Outcome {
        const self: *Session = @ptrCast(@alignCast(raw));
        return self.run(a, operation, input, sink);
    }

    fn run(self: *Session, a: alloc, operation: io.Context, input: foo.host.RunInput, sink: foo.events.Sink) io.Error!foo.events.Outcome {
        var turn = input;
        const selected = turn.settings.enabled_tools;
        if (selected.len == 0) return (try self.app.engine.run(a, operation, turn, sink)).outcome;

        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        const launch = self.settings.launch;
        const settings = turn.settings;
        var locals: std.ArrayList([]const u8) = .empty;
        var reserved: std.ArrayList([]const u8) = .empty;
        var descriptors: std.ArrayList(tools.Descriptor) = .empty;
        var use_builtin_exec = false;
        var remote_aliases: std.ArrayList([]const u8) = .empty;
        for (selected) |name| {
            if (std.meta.stringToEnum(tools.builtin_tools.Kind, name)) |kind| {
                try reserved.append(scratch, name);
                if (!permittedBackend(turn, kind)) continue;
                try locals.append(scratch, name);
                use_builtin_exec = use_builtin_exec or kind == .exec;
                continue;
            }
            for (launch.custom_tools) |custom| {
                if (!std.mem.eql(u8, name, custom.name)) continue;
                try reserved.append(scratch, name);
                if (settings.process_backend == .client) break;
                try locals.append(scratch, name);
                try descriptors.append(scratch, .{
                    .name = custom.name,
                    .description = custom.description,
                    .schema_json = custom.schema_json,
                    .argv = custom.argv,
                    .environment = try environment(scratch, self.app.environ, custom.environment),
                    .inherit_environment = custom.inherit_environment,
                    .timeout_ms = custom.timeout_ms,
                });
                break;
            } else try remote_aliases.append(scratch, name);
        }
        var local: ?tools.Registry = null;
        defer if (local) |*registry| registry.deinit();
        var registries: std.ArrayList(foo.tool.Registry) = .empty;
        if (locals.items.len != 0) {
            var local_settings = settings;
            local_settings.enabled_tools = locals.items;
            const launch_process = launch.process;
            const local_exec = use_builtin_exec and settings.process_backend == .local;
            const spawner = if (local_exec or descriptors.items.len != 0)
                try self.app.spawner(operation)
            else
                self.app.native.interface();
            local = try tools.Registry.init(a, local_settings, descriptors.items, .{
                .spawner = spawner,
                .session = self.id,
                .run = input.run,
                .generation = @backingInt(input.run),
                .permissions = self.host.permissions,
                .host = self.host,
                .cleanup_ms = launch_process.cleanup_ms,
                .builtins = .{
                    .file_bytes = launch_process.file_bytes,
                    .environment = if (use_builtin_exec) try environment(scratch, self.app.environ, launch_process.environment) else &.{},
                    .inherit_environment = launch_process.inherit_environment,
                    .timeout_ms = launch_process.timeout_ms,
                },
            });
            try registries.append(scratch, local.?.interface());
        }
        const peers: []Peer = if (remote_aliases.items.len == 0) &.{} else try self.openPeers(operation, remote_aliases.items);
        const remote = try scratch.alloc(mcp.Registry, peers.len);
        var opened: usize = 0;
        defer for (remote[0..opened]) |*registry| registry.deinit();
        for (peers, remote) |*peer, *registry| {
            registry.* = mcp.Registry.init(a, operation, &peer.client, .{
                .enabled_aliases = selected,
                .reserved_aliases = reserved.items,
                .generation = @backingInt(input.run),
                .session = self.id,
                .run = input.run,
                .limits = settings.limits,
                .permission_mode = settings.permissions,
                .permissions = self.host.permissions,
                .operation_ids = &self.operation_ids,
            }) catch |err| return mcpError(err);
            opened += 1;
            try registries.append(scratch, registry.interface());
        }
        var set = mcp.RegistrySet.init(a, registries.items, settings.limits.catalog_bytes) catch |err| return mcpError(err);
        defer set.deinit();
        if (set.declarations.len < locals.items.len + remote_aliases.items.len) return error.Unavailable;
        turn.tools = set.interface();
        return (try self.app.engine.run(a, operation, turn, sink)).outcome;
    }

    fn openPeers(self: *Session, operation: io.Context, aliases: []const []const u8) io.Error![]Peer {
        if (self.peers) |peers| return peers;
        const servers = self.settings.runtime.mcp_servers;
        const a = self.app.allocator;
        var selected: usize = 0;
        for (servers) |server| {
            if (suppliesTool(server, aliases)) selected += 1;
        }
        if (selected == 0) return error.InvalidInput;
        const peers = try a.alloc(Peer, selected);
        errdefer a.free(peers);
        var count: usize = 0;
        errdefer {
            const token: io.Cancellation = .{};
            const cleanup = cleanupContext(operation, &token, self.settings.launch.process.cleanup_ms);
            for (peers[0..count]) |*peer| peer.deinit(cleanup) catch {};
        }
        for (servers) |server| {
            if (!suppliesTool(server, aliases)) continue;
            try peers[count].open(self, operation, server);
            count += 1;
        }
        self.peers = peers;
        return peers;
    }
};

fn suppliesTool(server: foo.config.McpServer, aliases: []const []const u8) bool {
    for (aliases) |alias| {
        if (mcp.catalog.maySupplyAlias(server.id, alias)) return true;
    }
    return false;
}

fn permittedBackend(input: foo.host.RunInput, kind: tools.builtin_tools.Kind) bool {
    const caps = input.services.host.capabilities;
    if (kind == .exec) return input.settings.process_backend == .local or caps.terminal;
    if (input.settings.files_backend == .local) return true;
    return switch (kind) {
        .read => caps.read_file,
        .write => caps.write_file,
        .edit => false,
        .exec => unreachable,
    };
}

const Peer = struct {
    app: *App,
    client: mcp.Client,
    link: union(enum) { stdio: *mcp.Stdio, http: HttpPeer },
    listener: ?std.Io.Future(void) = null,
    listening: io.Cancellation = .{},

    fn open(self: *Peer, session: *Session, operation: io.Context, server: foo.config.McpServer) io.Error!void {
        const app = session.app;
        const limits = session.settings.runtime.limits;
        self.* = .{ .app = app, .client = undefined, .link = undefined };
        const resolved = try mcp.connection_config.resolve(app.allocator, server, session.launch_cwd, app.environ);
        switch (resolved) {
            .stdio => |spec| {
                defer app.allocator.free(spec.environment);
                const spawner = try app.spawner(operation);
                self.link = .{ .stdio = mcp.Stdio.init(app.allocator, operation, spawner, spec, .{ .limits = limits }) catch |err| return mcpError(err) };
            },
            .http => |spec| {
                errdefer app.allocator.free(spec.headers);
                self.link = .{ .http = undefined };
                try self.link.http.open(app, operation, spec.url, spec.headers, limits);
            },
        }
        const token: io.Cancellation = .{};
        const cleanup = cleanupContext(operation, &token, session.settings.launch.process.cleanup_ms);
        errdefer self.closeLink(cleanup) catch {};
        const link = switch (self.link) {
            .stdio => |stdio| stdio.interface(),
            .http => |*http| http.adapter.interface(),
        };
        self.client = mcp.Client.init(link, .{ .server_id = server.id, .revision = server.revision, .limits = limits }) catch |err| return mcpError(err);
        const profile = self.client.connect(app.allocator, operation) catch |err| return mcpError(err);
        errdefer self.client.shutdown(cleanup) catch {};
        if (profile.capabilities.tools_changed) {
            const background: io.Context = .{ .io = operation.io, .clock = operation.clock, .cancellation = &self.listening };
            self.listener = operation.io.concurrent(listen, .{ self, background }) catch return error.Unavailable;
        }
    }

    fn listen(self: *Peer, operation: io.Context) void {
        self.client.listen(self.app.allocator, operation) catch {};
    }

    fn deinit(self: *Peer, operation: io.Context) io.Error!void {
        if (self.listener) |*listener| {
            self.listening.request();
            listener.cancel(operation.io);
        }
        const outcome: io.Error!void = self.client.shutdown(operation) catch |err| mcpError(err);
        try self.closeLink(operation);
        try outcome;
    }

    fn closeLink(self: *Peer, operation: io.Context) io.Error!void {
        switch (self.link) {
            .stdio => |stdio| stdio.deinit(operation) catch |err| return mcpError(err),
            .http => |*http| http.deinit(self.app.allocator),
        }
    }
};

const HttpPeer = struct {
    clients: [3]foo.transport.Client,
    adapter: mcp.Http,
    headers: []const io.Header,

    fn open(self: *HttpPeer, app: *App, operation: io.Context, url: []const u8, headers: []const io.Header, limits: foo.config.Limits) io.Error!void {
        self.headers = headers;
        var count: usize = 0;
        errdefer for (self.clients[0..count]) |*client| client.deinit();
        for (&self.clients) |*client| {
            client.* = try app.httpClient(operation);
            count += 1;
        }
        self.adapter = mcp.Http.init(.{
            .url = url,
            .headers = headers,
            .transport = self.clients[0].interface(),
            .listener = self.clients[1].interface(),
            .housekeeping = self.clients[2].interface(),
            .max_message_bytes = limits.wire_message_bytes,
            .max_stream_bytes = @max(limits.wire_message_bytes, limits.transcript_bytes),
            .scratch_allocator = app.allocator,
        }) catch |err| return mcpError(err);
    }

    fn deinit(self: *HttpPeer, allocator: alloc) void {
        self.adapter.deinit();
        for (&self.clients) |*client| client.deinit();
        allocator.free(self.headers);
    }
};

fn loadRoots(allocator: alloc, operation: io.Context, path: []const u8) io.Error![]const u8 {
    const max_bytes = 1024 * 1024;
    const dir: std.Io.Dir = .cwd();
    const stat = dir.statFile(operation.io, path, .{}) catch |err| return fileError(err);
    if (stat.kind != .file or stat.size == 0) return error.InvalidInput;
    if (stat.size > max_bytes) return error.LimitExceeded;
    return dir.readFileAlloc(operation.io, path, allocator, .limited(max_bytes + 1)) catch |err| return switch (err) {
        error.StreamTooLong => error.LimitExceeded,
        else => fileError(err),
    };
}

fn executableGuardian(a: alloc, std_io: std.Io) io.Error![]u8 {
    const dir = std.process.executableDirPathAlloc(std_io, a) catch |err| return fileError(err);
    defer a.free(dir);
    return std.fs.path.join(a, &.{ dir, "foo-process-guardian" });
}

fn environment(a: alloc, environ: *const std.process.Environ.Map, values: []const foo.config.Environment) io.Error![]const io.Environment {
    const result = try a.alloc(io.Environment, values.len);
    for (values, result) |entry, *resolved| resolved.* = .{
        .name = entry.name,
        .value = try environmentValue(environ, entry.value),
    };
    return result;
}

pub fn environmentValue(environ: *const std.process.Environ.Map, value: foo.config.Value) io.Error![]const u8 {
    return switch (value) {
        .literal => |text| text,
        .environment => |name| environ.get(name) orelse error.Unavailable,
    };
}

fn cleanupContext(operation: io.Context, cancellation: *const io.Cancellation, max_ms: u64) io.Context {
    return .{
        .io = operation.io,
        .clock = operation.clock,
        .cancellation = cancellation,
        .deadline_ms = operation.clock.now() +| max_ms,
    };
}

fn fileError(err: anyerror) io.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled, error.Cancelled => error.Cancelled,
        else => error.IoFailure,
    };
}

fn mcpError(err: anyerror) io.Error {
    return switch (err) {
        error.InvalidInput, error.AliasCollision => error.InvalidInput,
        error.Cancelled => error.Cancelled,
        error.DeadlineExceeded => error.DeadlineExceeded,
        error.LimitExceeded => error.LimitExceeded,
        error.OutOfMemory => error.OutOfMemory,
        error.Disconnected => error.Disconnected,
        error.IoFailure => error.IoFailure,
        else => error.Unavailable,
    };
}
