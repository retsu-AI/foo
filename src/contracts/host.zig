const std = @import("std");
const io = @import("io.zig");
const config = @import("config.zig");
const events = @import("events.zig");
const provider = @import("provider.zig");
const tool = @import("tool.zig");
const session = @import("session.zig");

pub const PreparedOperation = struct {
    session: events.SessionId,
    run: events.RunId,
    operation_id: u64,
    invocation: tool.Invocation,
    targets: []const []const u8,
};
pub const Decision = enum { allow_once, deny_once, cancelled };
pub const PermissionHandler = struct {
    context: *anyopaque,
    /// Decision authorizes only the exact immutable prepared operation.
    decide_fn: *const fn (*anyopaque, io.Context, PreparedOperation) io.Error!Decision,
};
pub const Files = struct {
    context: *anyopaque,
    read_fn: *const fn (*anyopaque, std.mem.Allocator, io.Context, events.SessionId, []const u8, usize) io.Error![]const u8,
    /// ACP writes lack compare-and-swap; adapters must not claim local atomicity.
    write_fn: *const fn (*anyopaque, io.Context, events.SessionId, []const u8, []const u8) io.Error!void,
};
pub const CommandId = enum(u64) { _ };
pub const Env = struct { name: []const u8, value: []const u8 };
pub const Command = struct { argv: []const []const u8, cwd: []const u8, environment: []const Env = &.{} };
pub const CommandStatus = union(enum) { running, exited: i32, signalled: u32, cleanup_unconfirmed };
pub const CommandOutput = struct { bytes: []const u8, truncated: bool };
pub const Processes = struct {
    context: *anyopaque,
    start_fn: *const fn (*anyopaque, io.Context, Command) io.Error!CommandId,
    output_fn: *const fn (*anyopaque, std.mem.Allocator, io.Context, CommandId, u64, usize) io.Error!CommandOutput,
    wait_fn: *const fn (*anyopaque, io.Context, CommandId) io.Error!CommandStatus,
    kill_fn: *const fn (*anyopaque, io.Context, CommandId) io.Error!void,
    /// Separate cleanup context: cancellation must not prevent cleanup itself.
    release_fn: *const fn (*anyopaque, io.Context, CommandId) io.Error!void,
};
pub const Capabilities = struct { read_file: bool = false, write_file: bool = false, terminal: bool = false };
pub const Host = struct {
    capabilities: Capabilities = .{},
    files: ?Files = null,
    processes: ?Processes = null,
    permissions: ?PermissionHandler = null,
};
pub const RunInput = struct {
    session: events.SessionId,
    run: events.RunId,
    settings: config.Resolved,
    messages: []const provider.Message,
    tools: tool.Registry,
    services: Services,
};
pub const Services = struct {
    provider: provider.Provider,
    store: ?session.Store = null,
    host: Host = .{},
    preparation: ?RequestPreparation = null,
};
pub const Runner = struct {
    context: *anyopaque,
    /// Synchronous lifetime: input lives until return, callbacks borrow only.
    run_fn: *const fn (*anyopaque, std.mem.Allocator, io.Context, RunInput, events.Sink) io.Error!events.Outcome,
};
pub const RequestPreparation = struct {
    context: *anyopaque,
    prepare_fn: *const fn (*anyopaque, std.mem.Allocator, io.Context, provider.Request) io.Error!provider.Request,
};
