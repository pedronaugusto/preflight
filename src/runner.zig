//! Zig's test protocol with per-test timing records, shard selection, a
//! watchdog and the package's log level. Fuzzing stays upstream's.
const std = @import("std");
const builtin = @import("builtin");
const upstream = @import("preflight_default_test_runner");
const timings = @import("preflight_timings");
const order_module = @import("preflight_order");
const options = @import("preflight_runner_options");
const bound = @import("watchdog.zig");
const test_timeout = bound.Nanoseconds.fromRaw(options.test_timeout_ns);
const testing = std.testing;
const io = std.Io.Threaded.global_single_threaded.io();
pub const std_options: std.Options = .{ .logFn = log };
/// The options module carries its own copy of the enum.
const log_level = @field(std.log.Level, @tagName(options.test_log_level));
var errors: std.atomic.Value(usize) = .init(0);
var order: []usize = &.{};
/// As upstream's runner sets up `std.testing.allocator` for each test.
const allocator_options: std.heap.SafeAllocator.Options = .{ .canary = 0xc3a701ba, .check_write_after_free = true };

pub fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (level == .err) _ = errors.fetchAdd(1, .monotonic);
    upstream.log(level, scope, format, args);
}

// A fuzz test reports itself only to a build with fuzzing, which upstream's runner serves.
pub const fuzz = upstream.fuzz;

/// The runner's own lines on stderr, under the lock `std.log` takes.
fn report(comptime format: []const u8, args: anytype) void {
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    stderr.file_writer.interface.print(format, args) catch return;
}

/// Ends the process when one test, its Io teardown included, outlasts the
/// package's `test_timeout`, and says which test and phase it was in.
const Watchdog = struct {
    name: []const u8,
    phase: std.atomic.Value(Phase) = .init(.body),
    done: std.atomic.Value(u32) = .init(0),
    thread: ?std.Thread = null,

    const Phase = enum(u8) { body, io_teardown, reporting };

    fn start(watchdog: *Watchdog) !void {
        // The build refuses a single-threaded build with a watchdog.
        if (builtin.single_threaded or options.test_timeout_ns == 0) return;
        watchdog.thread = try std.Thread.spawn(.{}, watch, .{watchdog});
    }

    fn stop(watchdog: *Watchdog) void {
        const thread = watchdog.thread orelse return;
        watchdog.done.store(1, .release);
        io.futexWake(u32, &watchdog.done.raw, 1);
        thread.join();
    }

    fn watch(watchdog: *Watchdog) void {
        // The global single-threaded Io never cancels a wait.
        if (!bound.expired(io, &watchdog.done, test_timeout.toIoDuration() catch unreachable)) return; // unreachable: u64 nanoseconds fit std i96 duration
        report("\npreflight: watchdog: {s} exceeded {d} ms; phase {t}; seed {d}\n", .{
            watchdog.name, (test_timeout.convert(.millisecond, u64, .down) catch unreachable).raw(), watchdog.phase.load(.acquire), testing.random_seed, // unreachable: dividing unsigned nanoseconds fits u64
        });
        std.process.exit(1);
    }
};

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();
    if (builtin.fuzz) return upstream.main(init);
    var arg_buffer: [8192]u8 = undefined;
    var allocator: std.heap.FixedBufferAllocator = .init(&arg_buffer);
    const args = init.args.toSlice(allocator.allocator()) catch @panic("test runner arguments");
    var listen = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--listen=-")) listen = true;
    }
    order = order_module.init(io, init, args, builtin.test_functions, options.durations) catch |err| std.debug.panic("test runner seed, shard and order: {t}", .{err});
    if (!listen) return terminal(init) catch |err| std.debug.panic("preflight test runner: {t}", .{err});
    serve(init) catch |err| std.debug.panic("preflight test runner: {t}", .{err});
}

fn serve(init: std.process.Init.Minimal) !void {
    var input: [4096]u8 = undefined;
    var output: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &input);
    var writer = std.Io.File.stdout().writerStreaming(io, &output);
    var server: std.zig.Server = .{ .in = &reader.interface, .out = &writer.interface };
    try server.serveStringMessage(.zig_version, builtin.zig_version_string);
    const recorder = try timings.Recorder.init(io, init.environ, options.timings, order_module.key);
    defer recorder.deinit(io);
    while (true) {
        const header = try server.receiveMessage();
        switch (header.tag) {
            .exit => return,
            .query_test_metadata => try metadata(&server),
            .run_test => try runTest(&server, recorder, init),
            else => return error.UnexpectedRunnerMessage,
        }
    }
}

fn metadata(server: *std.zig.Server) !void {
    const a = std.heap.page_allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try bytes.append(a, 0);
    const names = try a.alloc(u32, order.len);
    defer a.free(names);
    const panics = try a.alloc(u32, order.len);
    defer a.free(panics);
    @memset(panics, 0);
    for (order, names) |index, *name| {
        const test_fn = builtin.test_functions[index];
        name.* = @intCast(bytes.items.len);
        try bytes.appendSlice(a, test_fn.name);
        try bytes.append(a, 0);
    }
    try server.serveTestMetadata(.{ .names = names, .expected_panic_msgs = panics, .string_bytes = bytes.items });
}

fn runTest(server: *std.zig.Server, recorder: timings.Recorder, init: std.process.Init.Minimal) !void {
    const index = try server.receiveBody_u32();
    const test_fn = builtin.test_functions[order[index]];
    var watchdog: Watchdog = .{ .name = test_fn.name };
    try watchdog.start();
    defer watchdog.stop();
    testing.environ = init.environ;
    testing.log_level = log_level;
    testing.allocator_instance = .init(std.heap.page_allocator, allocator_options);
    testing.io_instance = .init(testing.allocator, .{ .argv0 = .init(init.args), .environ = init.environ });
    errors.store(0, .monotonic);
    try server.serveStringMessage(.test_started, &.{});
    const start: std.Io.Clock.Timestamp = .now(io, .awake);
    const status: std.zig.Server.Message.TestResults.Status = if (test_fn.func()) |_| .pass else |err| switch (err) {
        error.SkipZigTest => .skip,
        else => failure: {
            report("{s}: {t}; seed {d}\n", .{ test_fn.name, err, testing.random_seed });
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            break :failure .fail;
        },
    };
    watchdog.phase.store(.io_teardown, .release);
    testing.io_instance.deinit();
    const leaks = testing.allocator_instance.deinit();
    if (leaks != 0 or errors.load(.monotonic) != 0) report("preflight: failed test {s}; seed {d}\n", .{ test_fn.name, testing.random_seed });
    watchdog.phase.store(.reporting, .release);
    const elapsed: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
    try recorder.record(io, test_fn.name, elapsed, @tagName(status));
    try server.serveTestResults(.{ .index = index, .flags = .{
        .status = status,
        .fuzz = false,
        .log_err_count = std.math.lossyCast(@FieldType(std.zig.Server.Message.TestResults.Flags, "log_err_count"), errors.load(.monotonic)),
        .leak_count = std.math.lossyCast(@FieldType(std.zig.Server.Message.TestResults.Flags, "leak_count"), leaks),
    } });
}

fn terminal(init: std.process.Init.Minimal) !void {
    const recorder = try timings.Recorder.init(io, init.environ, options.timings, order_module.key);
    defer recorder.deinit(io);
    var failures: usize = 0;
    for (order) |index| {
        const test_fn = builtin.test_functions[index];
        var watchdog: Watchdog = .{ .name = test_fn.name };
        try watchdog.start();
        defer watchdog.stop();
        testing.environ = init.environ;
        testing.log_level = log_level;
        testing.allocator_instance = .init(std.heap.page_allocator, allocator_options);
        testing.io_instance = .init(testing.allocator, .{ .argv0 = .init(init.args), .environ = init.environ });
        errors.store(0, .monotonic);
        const start: std.Io.Clock.Timestamp = .now(io, .awake);
        const status: []const u8 = if (test_fn.func()) |_| "pass" else |err| switch (err) {
            error.SkipZigTest => "skip",
            else => failed: {
                report("{s}: {t}; seed {d}\n", .{ test_fn.name, err, testing.random_seed });
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
                break :failed "fail";
            },
        };
        watchdog.phase.store(.io_teardown, .release);
        testing.io_instance.deinit();
        const leaks = testing.allocator_instance.deinit();
        watchdog.phase.store(.reporting, .release);
        try recorder.record(io, test_fn.name, @intCast(start.untilNow(io).raw.nanoseconds), status);
        if (std.mem.eql(u8, status, "fail") or leaks != 0 or errors.load(.monotonic) != 0) failures += 1;
    }
    if (failures != 0) {
        report("preflight: {d} failed tests; seed {d}\n", .{ failures, testing.random_seed });
        std.process.exit(1);
    }
}
