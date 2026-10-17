//! Zig's test protocol with per-test timing records, shard selection, a
//! watchdog and the package's log level. Fuzzing stays upstream's.
const std = @import("std");
const builtin = @import("builtin");
const upstream = @import("preflight_default_test_runner");
const timings = @import("preflight_timings");
const order_module = @import("preflight_order");
const options = @import("preflight_runner_options");
const bound = @import("watchdog.zig");
const test_timeout: std.Io.Duration = .fromNanoseconds(options.test_timeout_ns);
const testing = std.testing;
const io = std.Io.Threaded.global_single_threaded.io();
pub const std_options: std.Options = .{ .logFn = log };
/// The options module carries its own copy of the enum.
const log_level = @field(std.log.Level, @tagName(options.test_log_level));
var errors: std.atomic.Value(usize) = .init(0);
var order: []usize = &.{};
/// The job's deadline, `PREFLIGHT_DEADLINE`, which a hosted job's runner sets.
var job_deadline: ?i64 = null;
/// As upstream's runner sets up `std.testing.allocator` for each test.
const allocator_options: std.heap.SafeAllocator.Options = .{ .canary = 0xc3a701ba, .check_write_after_free = true };

/// What `std.testing.allocator` takes its memory from, one per test: the page
/// allocator, as upstream's runner does, or in the hardened run the package's
/// shakedown's quarantine, a mapping per block with an inaccessible page after it,
/// whose address is never handed out again. Then a block std's allocator takes
/// whole (one larger than three quarters of its buckets) faults at the line on a
/// read or write after it is freed or past the page it ends on, and a bucket of
/// smaller blocks does once every block in it is freed; std's allocator still
/// reports leaks, double frees and a damaged block footer. Every run fails the same way.
const Backing = struct {
    const Quarantine = if (options.quarantine) @import("preflight_quarantine").alloc.Quarantine else void;
    var quarantine: Quarantine = undefined;

    fn begin() std.mem.Allocator {
        if (!options.quarantine) return std.heap.page_allocator;
        quarantine = .init(.{ .guard = .after });
        return quarantine.allocator();
    }

    fn end() void {
        if (options.quarantine) quarantine.deinit();
    }
};

pub fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (level == .err) _ = errors.fetchAdd(1, .monotonic);
    // Upstream's log counts errors in a counter only upstream's own loop
    // resets. This loop runs every test but a fuzzing build's, so here the
    // count is `errors`, reset per test: through upstream's, one failed
    // test's error would still be counted when a later test fuzzes, and
    // upstream's `fuzz` panics on it, crashing a test that did nothing
    // wrong and every test after it in the process.
    if (builtin.fuzz) return upstream.log(level, scope, format, args);
    if (@backingInt(level) > @backingInt(testing.log_level)) return;
    report("[" ++ @tagName(scope) ++ "] (" ++ @tagName(level) ++ "): " ++ format ++ "\n", args);
}

/// Whether the test running now called `std.testing.fuzz`. A build finds
/// its fuzz tests by running them unfuzzed first and asking each whether it
/// was one; the fuzzing build itself is upstream's runner's to serve.
var fuzz_called: bool = false;

pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), *std.testing.Smith) anyerror!void,
    fuzz_options: testing.FuzzInputOptions,
) anyerror!void {
    @disableInstrumentation();
    fuzz_called = true;
    return upstream.fuzz(context, testOne, fuzz_options);
}

/// The runner's own lines on stderr, under the lock `std.log` takes.
fn report(comptime format: []const u8, args: anytype) void {
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    stderr.file_writer.interface.print(format, args) catch return;
}

/// Ends the process when one test, its Io teardown included, outlasts the
/// package's `test_timeout`, or runs when the job's deadline comes, and says
/// which test and phase it was in.
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
        const wait = bound.bound(io, test_timeout, job_deadline);
        // The global single-threaded Io never cancels a wait.
        if (!bound.expired(io, &watchdog.done, wait.limit)) return;
        // Not through the stderr lock: a test stalled in a crash handler
        // that hangs holds it, and the watchdog must still say what ran
        // out and end the process.
        var line: [512]u8 = undefined;
        var text: std.Io.Writer = .fixed(&line);
        const name = watchdog.name;
        const limit_ms = options.test_timeout_ns / std.time.ns_per_ms;
        const phase = watchdog.phase.load(.acquire);
        if (wait.job) {
            // glint-ignore: Z026 -- a line longer than the buffer is cut, and what fits is still written
            text.print("\npreflight: watchdog: {s} was running when the job's time ran out, {d} ms into it; phase {t}; seed {d}\n", .{ name, wait.limit.toMilliseconds(), phase, testing.random_seed }) catch {};
        } else {
            // glint-ignore: Z026 -- a line longer than the buffer is cut, and what fits is still written
            text.print("\npreflight: watchdog: {s} exceeded {d} ms; phase {t}; seed {d}\n", .{ name, limit_ms, phase, testing.random_seed }) catch {};
        }
        var stderr = std.Io.File.stderr().writerStreaming(io, &.{});
        // glint-ignore: Z026 -- the process ends next either way; a lost line cannot be reported anywhere else
        stderr.interface.writeAll(text.buffered()) catch {};
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
    order = order_module.init(io, init, args, builtin.test_functions, options.durations, !listen) catch |err| std.debug.panic("test runner seed, shard and order: {t}", .{err});
    job_deadline = readDeadline(init.environ) catch |err| std.debug.panic("test runner PREFLIGHT_DEADLINE: {t}", .{err});
    if (!listen) return terminal(init) catch |err| std.debug.panic("preflight test runner: {t}", .{err});
    serve(init) catch |err| std.debug.panic("preflight test runner: {t}", .{err});
}

fn readDeadline(environ: std.process.Environ) !?i64 {
    var env = try environ.createMap(std.heap.page_allocator);
    defer env.deinit();
    return bound.parseDeadline(env.get("PREFLIGHT_DEADLINE"));
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
    testing.allocator_instance = .init(Backing.begin(), allocator_options);
    testing.io_instance = .init(testing.allocator, .{ .argv0 = .init(init.args), .environ = init.environ });
    errors.store(0, .monotonic);
    fuzz_called = false;
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
    Backing.end();
    if (leaks != 0 or errors.load(.monotonic) != 0) report("preflight: failed test {s}; seed {d}\n", .{ test_fn.name, testing.random_seed });
    watchdog.phase.store(.reporting, .release);
    const elapsed: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
    try recorder.record(io, test_fn.name, elapsed, @tagName(status));
    try server.serveTestResults(.{ .index = index, .flags = .{
        .status = status,
        .fuzz = fuzz_called,
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
        testing.allocator_instance = .init(Backing.begin(), allocator_options);
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
        Backing.end();
        watchdog.phase.store(.reporting, .release);
        try recorder.record(io, test_fn.name, @intCast(start.untilNow(io).raw.nanoseconds), status);
        if (std.mem.eql(u8, status, "fail") or leaks != 0 or errors.load(.monotonic) != 0) failures += 1;
    }
    if (failures != 0) {
        report("preflight: {d} failed tests; seed {d}\n", .{ failures, testing.random_seed });
        std.process.exit(1);
    }
}
