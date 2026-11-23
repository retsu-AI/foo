//! Bounded validation and typed decoding of a complete JSON value.
const std = @import("std");

pub const Limits = struct {
    max_bytes: usize = 8 * 1024 * 1024,
    /// Counts open arrays and objects, including the root container.
    /// The effective limit is capped at max_supported_depth.
    max_depth: usize = 64,
};

pub const max_supported_depth = 256;
pub const ValidationError = error{ InvalidJson, MessageTooLarge, NestingTooDeep };

// Scanner stores one bit per container. The buffer includes room for the
// bit stack's growth rounding in the pinned Zig toolchain.
pub const ScannerBuffer = struct {
    bytes: [std.ArrayList(u8).growCapacity((max_supported_depth + 7) / 8)]u8 = undefined,
    scratch: std.heap.FixedBufferAllocator = undefined,

    pub fn init(self: *ScannerBuffer, input: []const u8) std.json.Scanner {
        self.scratch = .init(&self.bytes);
        return .initCompleteInput(self.scratch.allocator(), input);
    }
};

/// Validates UTF-8, JSON syntax, and limits without allocating parsed values.
pub fn validate(input: []const u8, limits: Limits) ValidationError!void {
    if (input.len > limits.max_bytes) return error.MessageTooLarge;
    const depth = @min(limits.max_depth, max_supported_depth);
    var buffer: ScannerBuffer = .{};
    var scanner = buffer.init(input);
    defer scanner.deinit();
    while (true) {
        switch (scanner.peekNextTokenType() catch return error.InvalidJson) {
            .object_begin, .array_begin => if (scanner.stackHeight() == depth) return error.NestingTooDeep,
            .end_of_document => return,
            else => {},
        }
        _ = scanner.next() catch |err| switch (err) {
            error.OutOfMemory => unreachable, // The depth check bounds the bit stack.
            else => return error.InvalidJson,
        };
    }
}

/// The returned value can borrow input and caller scratch. Keep both alive and
/// keep the allocator at a stable address until the value is no longer in use.
/// Reuse scratch by resetting it after the last value expires.
pub fn decode(
    comptime T: type,
    input: []const u8,
    scratch: *std.heap.FixedBufferAllocator,
    limits: Limits,
    options: std.json.ParseOptions,
) !T {
    try validate(input, limits);
    const checkpoint = scratch.end_index;
    errdefer scratch.end_index = checkpoint;
    var buffer: ScannerBuffer = .{};
    var scanner = buffer.init(input);
    defer scanner.deinit();
    return std.json.parseFromTokenSourceLeaky(T, scratch.allocator(), &scanner, options);
}
