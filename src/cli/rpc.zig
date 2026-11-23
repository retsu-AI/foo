const std = @import("std");
const foo = @import("foo");
const protocol = @import("rpc_protocol.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Operation = foo.io.Context;
const Error = foo.io.Error;
const Outcome = foo.events.Outcome;

const max_frame_bytes = 8 * 1024 * 1024;
const max_events = 64;
const max_controls = 16;
const check_interval: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } };
const drain_interval: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } };

pub const max_prompt_bytes = protocol.max_prompt_bytes;

pub const Target = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque, Allocator, Operation, foo.events.RunId, []const u8, foo.events.Sink) Error!Outcome,
};

pub fn serve(a: Allocator, operation: Operation, input: Io.File, output: Io.File, limits: foo.config.Limits, target: Target) Error!void {
    try operation.check();
    if (limits.wire_message_bytes == 0 or limits.pending_events == 0 or limits.json_depth == 0)
        return error.InvalidInput;

    const io = operation.io;
    var shared: SharedAllocator = .{ .backing = a, .io = io };
    const alloc = shared.allocator();
    const frame_bytes = @min(max_frame_bytes, limits.wire_message_bytes);
    const input_buffer = try alloc.alloc(u8, frame_bytes);
    defer alloc.free(input_buffer);
    const event_buffer = try alloc.alloc(u8, frame_bytes);
    defer alloc.free(event_buffer);
    var state: State = .{
        .a = alloc,
        .operation = operation,
        .limits = limits,
        .target = target,
        .event_buffer = event_buffer,
    };
    defer state.deinit();

    var reader = io.concurrent(readInput, .{ &state, input, input_buffer }) catch return error.Unavailable;
    defer reader.cancel(io);
    var writer = io.concurrent(writeOutput, .{ &state, output }) catch return error.Unavailable;
    defer writer.cancel(io);
    var run: ?Io.Future(Outcome) = null;
    defer {
        state.mutex.lockUncancelable(io);
        state.aborting = true;
        if (state.job) |job| job.cancellation.request();
        state.changed.broadcast(io);
        state.mutex.unlock(io);
        if (run) |*future| _ = joinWorker(io, future);
    }

    while (true) {
        switch (try state.next()) {
            .start => |job| {
                run = io.concurrent(runPrompt, .{ &state, job }) catch {
                    try state.finish(.{ .reason = .host_error });
                    continue;
                };
            },
            .finish => {
                const outcome = if (run) |*future| joinWorker(io, future) else Outcome{ .reason = .cancelled };
                run = null;
                try state.finish(outcome);
            },
            .end => return,
        }
    }
}

fn joinWorker(io: Io, future: *Io.Future(Outcome)) Outcome {
    // The caller's I/O cancellation must not interrupt the worker's cleanup.
    const previous = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous);
    return future.await(io);
}

const Frame = struct { bytes: []u8, class: enum { event, control, terminal } };

const Job = struct {
    id: []u8,
    prompt: []u8,
    run: foo.events.RunId,
    cancellation: foo.io.Cancellation = .{},
    phase: enum { pending, running, returned } = .pending,

    fn deinit(job: *Job, a: Allocator) void {
        a.free(job.id);
        a.free(job.prompt);
        a.destroy(job);
    }
};

const Action = union(enum) { start: *Job, finish, end };

const State = struct {
    a: Allocator,
    operation: Operation,
    limits: foo.config.Limits,
    target: Target,
    event_buffer: []u8,
    mutex: Io.Mutex = .init,
    changed: Io.Condition = .init,
    input_end: union(enum) { open, eof, failed: Error } = .open,
    output_failure: ?Error = null,
    writer_done: bool = false,
    aborting: bool = false,
    drain: ?Io.Timeout = null,
    queue: [max_events + max_controls + 1]Frame = undefined,
    queued: usize = 0,
    event_count: usize = 0,
    event_bytes: usize = 0,
    control_count: usize = 0,
    next_run: u64 = 1,
    job: ?*Job = null,

    fn deinit(state: *State) void {
        if (state.job) |job| job.deinit(state.a);
        for (state.queue[0..state.queued]) |frame| state.a.free(frame.bytes);
    }

    fn next(state: *State) Error!Action {
        const io = state.operation.io;
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        while (true) {
            try state.operation.check();
            if (state.output_failure) |err| return err;
            if (state.job) |job| {
                switch (job.phase) {
                    .returned => return .finish,
                    .pending => {
                        if (job.cancellation.requested.load(.acquire)) return .finish;
                        job.phase = .running;
                        return .{ .start = job };
                    },
                    .running => {},
                }
            } else if (state.input_end != .open) {
                if (state.writer_done) return switch (state.input_end) {
                    .open => unreachable,
                    .eof => .end,
                    .failed => |err| err,
                };
                if (state.drain == null) state.drain = drain_interval.toDeadline(io);
                state.changed.waitTimeout(io, &state.mutex, state.drain.?) catch |err| return switch (err) {
                    error.Canceled => error.Cancelled,
                    error.Timeout => error.Disconnected,
                };
                continue;
            }
            state.changed.waitTimeout(io, &state.mutex, check_interval) catch |err| switch (err) {
                error.Canceled => return error.Cancelled,
                error.Timeout => {},
            };
        }
    }

    fn finish(state: *State, outcome: Outcome) Error!void {
        const io = state.operation.io;
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        const job = state.job.?;
        try state.reply(.{
            .id = job.id,
            .run = @backingInt(job.run),
            .type = .result,
            .outcome = outcome,
        }, .terminal);
        state.job = null;
        job.deinit(state.a);
        state.changed.broadcast(io);
    }

    fn reply(state: *State, record: protocol.Reply, class: @FieldType(Frame, "class")) Error!void {
        if (class == .control and state.control_count >= max_controls) {
            state.output_failure = error.LimitExceeded;
            state.changed.broadcast(state.operation.io);
            return error.LimitExceeded;
        }
        var buffer: [protocol.control_bytes]u8 = undefined;
        try state.append(try protocol.encode(&buffer, record), class);
    }

    fn append(state: *State, bytes: []const u8, class: @FieldType(Frame, "class")) Error!void {
        std.debug.assert(state.queued < state.queue.len);
        const owned = try state.a.dupe(u8, bytes);
        state.queue[state.queued] = .{ .bytes = owned, .class = class };
        state.queued += 1;
        switch (class) {
            .event => {
                state.event_count += 1;
                state.event_bytes += bytes.len;
            },
            .control, .terminal => state.control_count += 1,
        }
        state.changed.broadcast(state.operation.io);
    }

    fn take(state: *State) Io.Cancelable!?Frame {
        const io = state.operation.io;
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        while (true) {
            if (state.aborting or state.output_failure != null) return null;
            if (state.queued != 0) {
                const value = state.queue[0];
                state.queued -= 1;
                std.mem.copyForwards(Frame, state.queue[0..state.queued], state.queue[1 .. state.queued + 1]);
                switch (value.class) {
                    .event => {
                        state.event_count -= 1;
                        state.event_bytes -= value.bytes.len;
                    },
                    .control, .terminal => state.control_count -= 1,
                }
                state.changed.broadcast(io);
                return value;
            }
            if (state.input_end != .open and state.job == null) return null;
            try state.changed.wait(io, &state.mutex);
        }
    }

    fn receive(context: *anyopaque, _: Operation, record: []const u8) Error!void {
        const state: *State = @ptrCast(@alignCast(context));
        var arena = std.heap.ArenaAllocator.init(state.a);
        defer arena.deinit();
        const request = try protocol.decode(arena.allocator(), record, state.limits);
        const io = state.operation.io;
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        if (state.aborting or state.output_failure != null) return error.Disconnected;
        switch (request.command) {
            .prompt => |prompt| {
                if (state.job) |job| return state.reply(.{
                    .id = request.id,
                    .run = @backingInt(job.run),
                    .type = .@"error",
                    .code = .busy,
                }, .control);
                if (state.next_run == std.math.maxInt(u64)) return error.LimitExceeded;
                const id = try state.a.dupe(u8, request.id.?);
                errdefer state.a.free(id);
                const owned_prompt = try state.a.dupe(u8, prompt);
                errdefer state.a.free(owned_prompt);
                const job = try state.a.create(Job);
                errdefer state.a.destroy(job);
                job.* = .{ .id = id, .prompt = owned_prompt, .run = @fromBackingInt(@intCast(state.next_run)) };
                try state.reply(.{ .id = id, .run = state.next_run, .type = .accepted }, .control);
                state.job = job;
                state.next_run += 1;
            },
            .cancel => |run| {
                if (state.job) |job| {
                    if (@backingInt(job.run) == run and job.phase != .returned) {
                        try state.reply(.{ .id = request.id, .run = run, .type = .cancel_ack }, .control);
                        job.cancellation.request();
                        return;
                    }
                }
                try state.reply(.{ .id = request.id, .run = run, .type = .@"error", .code = .no_active_run }, .control);
            },
            .reject => |code| try state.reply(.{ .id = request.id, .type = .@"error", .code = code }, .control),
        }
    }

    fn emit(context: *anyopaque, operation: Operation, event: foo.events.Event) Error!void {
        const state: *State = @ptrCast(@alignCast(context));
        const job = state.job.?;
        if (event.run != job.run) return error.InvalidInput;
        const public = protocol.Event.from(event) orelse return;
        try operation.check();
        const bytes = try protocol.encode(state.event_buffer, .{
            .id = job.id,
            .run = @backingInt(job.run),
            .type = .event,
            .event = public,
        });

        const io = state.operation.io;
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        while (true) {
            try operation.check();
            if (state.aborting or state.output_failure != null) return error.Disconnected;
            if (state.event_count < @min(max_events, state.limits.pending_events) and
                bytes.len <= state.event_buffer.len - state.event_bytes)
                return state.append(bytes, .event);
            try job.cancellation.check();
            const timeout = if (operation.deadline_ms != null) check_interval else .none;
            state.changed.waitTimeout(io, &state.mutex, timeout) catch |err| switch (err) {
                error.Canceled => return error.Cancelled,
                error.Timeout => {},
            };
        }
    }
};

fn readInput(state: *State, input: Io.File, storage: []u8) void {
    const io = state.operation.io;
    var framer = foo.wire.framing.Ndjson.init(storage, .skip);
    const sink: foo.io.ByteSink = .{ .context = state, .write_fn = State.receive };
    const read_error = readFrames(input, &framer, state.operation, sink);
    state.mutex.lockUncancelable(io);
    defer state.mutex.unlock(io);
    state.input_end = if (read_error) |err| .{ .failed = err } else .eof;
    if (state.job) |job| job.cancellation.request();
    state.changed.broadcast(io);
    if (!state.aborting and state.output_failure == null) {
        const code: protocol.ErrorCode = switch (read_error orelse return) {
            error.InvalidInput => .invalid_command,
            error.LimitExceeded => .limit_exceeded,
            else => return,
        };
        state.reply(.{ .id = null, .type = .@"error", .code = code }, .control) catch {};
    }
}

fn readFrames(input: Io.File, framer: *foo.wire.framing.Ndjson, operation: Operation, sink: foo.io.ByteSink) ?Error {
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = input.readStreaming(operation.io, &.{&buffer}) catch |err| switch (err) {
            error.Canceled => return error.Cancelled,
            error.EndOfStream => break,
            error.ConnectionResetByPeer, error.SocketUnconnected, error.NotOpenForReading => return error.Disconnected,
            else => return error.IoFailure,
        };
        framer.feed(operation, buffer[0..count], sink) catch |err| return framingError(err);
    }
    framer.finish(operation) catch |err| return framingError(err);
    return null;
}

fn framingError(err: foo.wire.framing.Error) Error {
    return switch (err) {
        error.TruncatedFrame, error.MalformedFrame => error.InvalidInput,
        error.Closed, error.Busy => error.IoFailure,
        else => |other| other,
    };
}

fn writeOutput(state: *State, output: Io.File) void {
    const io = state.operation.io;
    defer {
        state.mutex.lockUncancelable(io);
        state.writer_done = true;
        state.changed.broadcast(io);
        state.mutex.unlock(io);
    }
    while (state.take() catch return) |frame| {
        defer state.a.free(frame.bytes);
        output.writeStreamingAll(io, frame.bytes) catch |err| {
            state.mutex.lockUncancelable(io);
            defer state.mutex.unlock(io);
            state.output_failure = switch (err) {
                error.Canceled => error.Cancelled,
                error.BrokenPipe, error.NotOpenForWriting, error.NoDevice => error.Disconnected,
                else => error.IoFailure,
            };
            if (state.job) |job| job.cancellation.request();
            state.changed.broadcast(io);
            return;
        };
    }
}

fn runPrompt(state: *State, job: *Job) Outcome {
    const io = state.operation.io;
    defer {
        state.mutex.lockUncancelable(io);
        job.phase = .returned;
        state.changed.broadcast(io);
        state.mutex.unlock(io);
    }
    var operation = state.operation;
    operation.cancellation = &job.cancellation;
    const sink: foo.events.Sink = .{ .context = state, .emit_fn = State.emit };
    return state.target.run_fn(state.target.context, state.a, operation, job.run, job.prompt, sink) catch |err| .{
        .reason = switch (err) {
            error.Cancelled => .cancelled,
            error.DeadlineExceeded, error.LimitExceeded => .limit_reached,
            else => .host_error,
        },
    };
}

const SharedAllocator = struct {
    backing: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,

    fn allocator(state: *SharedAllocator) Allocator {
        return .{ .ptr = state, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn lock(context: *anyopaque) *SharedAllocator {
        const state: *SharedAllocator = @ptrCast(@alignCast(context));
        state.mutex.lockUncancelable(state.io);
        return state;
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const state = lock(context);
        defer state.mutex.unlock(state.io);
        return state.backing.rawAlloc(len, alignment, ret);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const state = lock(context);
        defer state.mutex.unlock(state.io);
        return state.backing.rawResize(memory, alignment, len, ret);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const state = lock(context);
        defer state.mutex.unlock(state.io);
        return state.backing.rawRemap(memory, alignment, len, ret);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const state = lock(context);
        defer state.mutex.unlock(state.io);
        state.backing.rawFree(memory, alignment, ret);
    }
};
