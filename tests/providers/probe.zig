const std = @import("std");
const foo = @import("foo");
const providers = @import("providers");

const lookup: foo.provider.ToolSpec = .{
    .name = "lookup",
    .description = "Return a fixture value.",
    .schema_json = "{\"type\":\"object\",\"properties\":{\"key\":{\"type\":\"string\"}}}",
};
pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    const family = std.meta.stringToEnum(foo.config.Family, args.next() orelse return error.MissingFamily) orelse
        return error.UnknownFamily;
    const endpoint = args.next() orelse return error.MissingEndpoint;
    const model = args.next() orelse return error.MissingModel;
    const credential = args.next() orelse "-";
    const options = args.next() orelse "{}";
    const exercise_tool = if (args.next()) |mode| std.mem.eql(u8, mode, "fixture-tool") else false;

    const runtime = try foo.transport.Runtime.init();
    defer runtime.deinit();
    var client = try runtime.client(init.gpa, init.io, .{});
    defer client.deinit();
    var adapter: providers.Adapter = .{ .transport = client.interface(), .environment = init.environ_map };
    const provider = adapter.interface();
    var clock_io = init.io;
    const cancellation: foo.io.Cancellation = .{};
    const operation: foo.io.Context = .{
        .io = init.io,
        .cancellation = &cancellation,
        .clock = .{ .context = &clock_io, .now_fn = now },
        .deadline_ms = now(&clock_io) + 60_000,
    };
    const sink: foo.provider.Sink = .{ .context = &clock_io, .emit_fn = emit };
    const prompt: foo.provider.Message = .{ .role = .user, .blocks = &.{.{ .text = "Say hello in one short sentence." }} };
    var request: foo.provider.Request = .{
        .model = .{
            .family = family,
            .endpoint = endpoint,
            .id = model,
            .credential = if (std.mem.eql(u8, credential, "-")) .none else .{ .environment = credential },
            .options_json = options,
            .max_output_tokens = 1024,
        },
        .messages = &.{prompt},
        .tools = if (exercise_tool) &.{lookup} else &.{},
    };
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    var delivery: foo.io.Delivery = .unsent;
    var response = try provider.stream_fn(provider.context, allocator, operation, request, sink, &delivery);
    if (exercise_tool) {
        if (response.stop != .tool_use) return error.WantedFixtureTool;
        var selected_call: ?foo.provider.ToolCall = null;
        for (response.message.blocks) |block| {
            if (block != .tool_call) continue;
            if (selected_call != null or !std.mem.eql(u8, block.tool_call.name, lookup.name))
                return error.WantedFixtureTool;
            selected_call = block.tool_call;
        }
        const call = selected_call orelse return error.WantedFixtureTool;
        const result: foo.provider.Message = .{ .role = .tool, .blocks = &.{.{ .tool_result = .{
            .call_id = call.id,
            .content = "Fixture value.",
            .is_error = false,
        } }} };
        const history = [_]foo.provider.Message{ prompt, response.message, result };
        request.messages = &history;
        response = try provider.stream_fn(provider.context, allocator, operation, request, sink, &delivery);
        if (response.stop != .end_turn) return error.WantedEndTurn;
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    const report = try std.json.Stringify.valueAlloc(allocator, .{
        .stop = response.stop,
        .usage = response.usage,
    }, .{});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

fn now(context: *anyopaque) u64 {
    const system_io: *std.Io = @ptrCast(@alignCast(context));
    return @intCast(std.Io.Clock.awake.now(system_io.*).toMilliseconds());
}

fn emit(_: *anyopaque, operation: foo.io.Context, delta: foo.provider.Delta) foo.io.Error!void {
    if (delta != .text) return;
    std.Io.File.stdout().writeStreamingAll(operation.io, delta.text) catch return error.IoFailure;
}
