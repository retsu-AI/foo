const std = @import("std");
const foo = @import("foo");

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
            for (configured.environment, entries) |auth, *entry| {
                entry.* = .{ .name = auth.name, .value = try value(auth.value, environment) };
            }
            return .{ .stdio = .{ .argv = configured.argv, .cwd = cwd, .environment = entries } };
        },
        .http => |configured| {
            const headers = try allocator.alloc(foo.io.Header, configured.headers.len);
            errdefer allocator.free(headers);
            for (configured.headers, headers) |auth, *header| {
                header.* = .{ .name = auth.name, .value = try value(auth.value, environment) };
            }
            return .{ .http = .{ .url = configured.url, .headers = headers } };
        },
    }
}

fn value(reference: foo.config.Value, environment: *const std.process.Environ.Map) foo.io.Error![]const u8 {
    return switch (reference) {
        .literal => |text| text,
        .environment => |key| environment.get(key) orelse error.Unavailable,
    };
}
