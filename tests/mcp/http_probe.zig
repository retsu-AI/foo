const std = @import("std");
const foo = @import("foo");
const mcp = @import("mcp");
const io = foo.io;
const link = mcp.link;

const Mode = enum { modern, legacy };
const modern_revision: foo.config.McpRevision = .@"2026-07-28";
const legacy_revision: foo.config.McpRevision = .@"2025-11-25";
const modern_metadata =
    \\"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"foo-fixture","version":"1"},"io.modelcontextprotocol/clientCapabilities":{}
;

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    const mode = std.meta.stringToEnum(Mode, args.next() orelse return error.MissingProbeMode) orelse
        return error.UnknownProbeMode;
    const url = args.next() orelse return error.MissingUrl;

    const runtime = try foo.transport.Runtime.init();
    defer runtime.deinit();
    var transport = try runtime.client(init.gpa, init.io, .{});
    defer transport.deinit();
    var http = try mcp.Http.init(.{ .url = url, .transport = transport.interface() });
    defer http.deinit();

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    var system_io = init.io;
    var cancellation: io.Cancellation = .{};
    const probe: Probe = .{
        .client = http.interface(),
        .allocator = arena.allocator(),
        .context = .{
            .io = init.io,
            .cancellation = &cancellation,
            .clock = .{ .context = &system_io, .now_fn = now },
        },
    };
    switch (mode) {
        .modern => try modern(probe),
        .legacy => try legacy(probe),
    }
    try probe.client.shutdown(probe.operation());
}

fn modern(probe: Probe) !void {
    try probe.expectResult(.{
        .revision = modern_revision,
        .id = .{ .number = 1 },
        .method = "server/discover",
        .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{\"_meta\":{" ++ modern_metadata ++ "}}}",
    }, null,
        \\{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"native-fixture","version":"1"}}}
    );

    var progress: usize = 0;
    try probe.expectResult(.{
        .revision = modern_revision,
        .id = .{ .number = 2 },
        .method = "tools/call",
        .name = "héllo",
        .headers = &.{.{ .name = "Mcp-Param-Region", .value = " west " }},
        .body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"_meta\":{" ++ modern_metadata ++
            ",\"progressToken\":\"http-fixture\"},\"name\":\"héllo\",\"arguments\":{\"region\":\" west \"}}}",
    }, .{ .context = &progress, .notify_fn = notify }, "{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"stream\"}]}");
    if (progress != 1) return error.UnexpectedProgressCount;
}

fn legacy(probe: Probe) !void {
    try probe.expectResult(.{
        .revision = legacy_revision,
        .id = .{ .number = 1 },
        .method = "initialize",
        .body =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"foo-fixture","version":"1"},"capabilities":{}}}
        ,
    }, null, "{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"native-fixture\",\"version\":\"1\"}}");
    const ack = try probe.exchange(.{
        .revision = legacy_revision,
        .id = null,
        .method = "notifications/initialized",
        .body = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
    }, null);
    if (ack != .accepted) return error.UnexpectedInitializedAcknowledgment;
    try probe.expectResult(.{
        .revision = legacy_revision,
        .id = .{ .number = 2 },
        .method = "tools/call",
        .body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"fixture\"}}",
    }, null, "{\"content\":[{\"type\":\"text\",\"text\":\"resumed\"}]}");
}

const Probe = struct {
    client: link.Link,
    allocator: std.mem.Allocator,
    context: io.Context,

    fn operation(self: Probe) io.Context {
        var op = self.context;
        op.deadline_ms = op.clock.now() +| 5000;
        return op;
    }

    fn exchange(self: Probe, request: link.Request, observer: ?link.Observer) !link.Reply {
        var delivery: io.Delivery = .unsent;
        const reply = try self.client.exchange(self.allocator, self.operation(), request, observer, &delivery);
        if (delivery != .possibly_sent) return error.IncorrectDeliveryCertainty;
        return reply;
    }

    fn expectResult(self: Probe, request: link.Request, observer: ?link.Observer, expected: []const u8) !void {
        const result = switch (try self.exchange(request, observer)) {
            .success => |value| value,
            .accepted => return error.UnexpectedEmptyReply,
            .failure => return error.UnexpectedRpcError,
        };
        if (!std.mem.eql(u8, expected, result)) return error.UnexpectedRpcResult;
    }
};

fn notify(raw: *anyopaque, _: io.Context, request: foo.jsonrpc.Request) io.Error!void {
    const count: *usize = @ptrCast(@alignCast(raw));
    if (!std.mem.eql(u8, request.method, "notifications/progress")) return error.InvalidInput;
    count.* += 1;
}

fn now(raw: *anyopaque) u64 {
    const system_io: *std.Io = @ptrCast(@alignCast(raw));
    return @intCast(std.Io.Clock.awake.now(system_io.*).toMilliseconds());
}
