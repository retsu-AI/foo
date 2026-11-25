const std = @import("std");
const foo = @import("foo");
const auth = @import("auth");

pub const ResolvedTransport = union(enum) {
    stdio: foo.io.Spawn,
    http: struct { url: []const u8, headers: []const foo.io.Header },
};

/// Resolve credentials at the launch edge. The caller owns the array storage.
/// Values borrow the configured server or the process environment snapshot.
pub fn resolve(allocator: std.mem.Allocator, server: foo.config.McpServer, cwd: []const u8, environment: *const std.process.Environ.Map) foo.io.Error!ResolvedTransport {
    switch (server.transport) {
        .stdio => |configured| {
            const entries = try allocator.alloc(foo.io.Environment, configured.environment.len);
            errdefer allocator.free(entries);
            for (configured.environment, entries) |configured_entry, *entry| {
                entry.* = .{ .name = configured_entry.name, .value = try auth.resolveValue(environment, configured_entry.value) };
            }
            return .{ .stdio = .{ .argv = configured.argv, .cwd = cwd, .environment = entries } };
        },
        .http => |configured| {
            const headers = try allocator.alloc(foo.io.Header, configured.headers.len);
            errdefer allocator.free(headers);
            for (configured.headers, headers) |configured_header, *header| {
                header.* = .{ .name = configured_header.name, .value = try auth.resolveValue(environment, configured_header.value) };
            }
            return .{ .http = .{ .url = configured.url, .headers = headers } };
        },
    }
}
