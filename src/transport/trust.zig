const std = @import("std");
const io = @import("../contracts/io.zig");
const Certificate = std.crypto.Certificate;

pub const Trust = union(enum) {
    platform,
    pem: []const u8,
};

pub const Override = struct {
    variable: []const u8,
    path: []const u8,
};

pub fn override(environ: *const std.process.Environ.Map) ?Override {
    for ([_][]const u8{ "FOO_CA_FILE", "SSL_CERT_FILE" }) |variable| {
        if (environ.get(variable)) |path| return .{ .variable = variable, .path = path };
    }
    return null;
}

pub fn platformPem(allocator: std.mem.Allocator, system_io: std.Io, now: std.Io.Timestamp) io.Error![]u8 {
    var bundle: Certificate.Bundle = .empty;
    defer bundle.deinit(allocator);
    bundle.rescan(allocator, system_io, now) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.IoFailure,
    };
    if (bundle.map.count() == 0) return error.Unavailable;
    return encodeBundle(allocator, bundle) catch error.OutOfMemory;
}

fn encodeBundle(allocator: std.mem.Allocator, bundle: Certificate.Bundle) error{WriteFailed}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var starts = bundle.map.valueIterator();
    while (starts.next()) |start| {
        // The bundle parses every certificate before indexing it.
        const certificate = Certificate.der.Element.parse(bundle.bytes.items, start.*) catch unreachable;
        try writePem(&out.writer, bundle.bytes.items[start.*..certificate.slice.end]);
    }
    return out.toOwnedSlice() catch error.WriteFailed;
}

fn writePem(writer: *std.Io.Writer, der: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll("-----BEGIN CERTIFICATE-----\n");
    var rest = der;
    while (rest.len > 0) {
        const chunk = rest[0..@min(48, rest.len)];
        var line: [64]u8 = undefined;
        try writer.writeAll(std.base64.standard.Encoder.encode(&line, chunk));
        try writer.writeByte('\n');
        rest = rest[chunk.len..];
    }
    try writer.writeAll("-----END CERTIFICATE-----\n");
}

test "re-encodes a DER root as its PEM file" {
    const allocator = std.testing.allocator;
    const expected = @embedFile("fixture-ca");
    const begin = "-----BEGIN CERTIFICATE-----\n";
    const end = "-----END CERTIFICATE-----\n";
    const body = expected[begin.len .. expected.len - end.len];
    const decoder = std.base64.standard.decoderWithIgnore("\n");
    var bundle: Certificate.Bundle = .empty;
    defer bundle.deinit(allocator);
    const der = try bundle.bytes.addManyAsSlice(allocator, decoder.calcSizeUpperBound(body.len));
    bundle.bytes.items.len = try decoder.decode(der, body);
    try bundle.parseCert(allocator, 0, std.Io.Timestamp.now(std.testing.io, .real).toSeconds());
    try std.testing.expectEqual(@as(u32, 1), bundle.map.count());

    const actual = try encodeBundle(allocator, bundle);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}
