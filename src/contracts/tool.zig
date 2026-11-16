const std = @import("std");
const io = @import("io.zig");
const provider = @import("provider.zig");

pub const Identity = struct { backend: []const u8, server: ?[]const u8 = null, name: []const u8 };
pub const Declaration = struct { identity: Identity, spec: provider.ToolSpec, generation: u64 };
pub const Effect = enum { not_started, observed, uncertain };
pub const Status = enum { success, failure, denied, cancelled, catalog_changed };
pub const Artifact = struct { relative_path: []const u8, bytes: u64 };
pub const Result = struct {
    call_id: []const u8,
    status: Status,
    effect: Effect,
    content: []const u8,
    truncated: bool = false,
    artifact: ?Artifact = null,
};
pub const Invocation = struct { declaration: Declaration, call: provider.ToolCall };
pub const Registry = struct {
    context: *anyopaque,
    /// Borrowed immutable declarations remain valid until run teardown.
    declarations: []const Declaration,
    /// Validate schema, current membership/generation, and permissions before
    /// effects. Disabled tools are absent from both declarations and dispatch.
    /// Returned slices belong to result_allocator. Transport failure after send
    /// must be returned as an uncertain Result, not hidden by a retry.
    invoke_fn: *const fn (*anyopaque, std.mem.Allocator, io.Context, Invocation) io.Error!Result,
};

pub const ContextKind = enum { resource, resource_template, prompt };
pub const ContextRef = struct { server: []const u8, kind: ContextKind, id: []const u8 };
pub const ContextItem = struct { reference: ContextRef, title: []const u8 };
pub const ContextPage = struct { items: []const ContextItem, next_cursor: ?[]const u8 };
pub const ContextContent = struct { reference: ContextRef, mime: []const u8, bytes: []const u8, truncated: bool };
pub const ContextSource = struct {
    context: *anyopaque,
    list_fn: *const fn (*anyopaque, std.mem.Allocator, io.Context, ContextKind, ?[]const u8) io.Error!ContextPage,
    /// Arguments encode explicit template/prompt parameters; remote text is data.
    get_fn: *const fn (*anyopaque, std.mem.Allocator, io.Context, ContextRef, []const u8) io.Error!ContextContent,
};
