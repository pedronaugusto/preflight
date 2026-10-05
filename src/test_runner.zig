//! Zig's test protocol with per-test timing records. Fuzzing stays upstream's.
const std = @import("std");
const builtin = @import("builtin");
const upstream = @import("preflight_default_test_runner");
const timings = @import("preflight_timings");
const shuffle = @import("preflight_order");
const testing = std.testing;
const io = std.Io.Threaded.global_single_threaded.io();
pub const std_options: std.Options = .{ .logFn = log };
var errors: std.atomic.Value(usize) = .init(0);
var fuzz_test: bool = false;
var order: []usize = &.{};

pub fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (level == .err) _ = errors.fetchAdd(1, .monotonic);
    upstream.log(level, scope, format, args);
}

pub fn fuzz(context: anytype, comptime testOne: fn (@TypeOf(context), *testing.Smith) anyerror!void, input: testing.FuzzInputOptions) anyerror!void {
    fuzz_test = true;
    return upstream.fuzz(context, testOne, input);
}

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
    order = shuffle.init(io, init, args, builtin.test_functions.len) catch @panic("test runner seed and order");
    if (!listen) return terminal(init) catch |err| std.debug.panic("preflight test runner: {t}", .{err});
    serve(init) catch |err| std.debug.panic("preflight test runner: {t}", .{err});
}

fn serve(init: std.process.Init.Minimal) !void {
    var input: [4096]u8 = undefined;
    var output: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &input);
    var writer = std.Io.File.stdout().writerStreaming(io, &output);
    var server = try std.zig.Server.init(.{ .in = &reader.interface, .out = &writer.interface, .zig_version = builtin.zig_version_string });
    const recorder = try timings.Recorder.init(io, init.environ);
    defer recorder.deinit();
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
    const names = try a.alloc(u32, builtin.test_functions.len);
    defer a.free(names);
    const panics = try a.alloc(u32, builtin.test_functions.len);
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
    testing.environ = init.environ;
    testing.allocator_instance = .{};
    testing.io_instance = .init(testing.allocator, .{ .argv0 = .init(init.args), .environ = init.environ });
    errors.store(0, .monotonic);
    fuzz_test = false;
    try server.serveStringMessage(.test_started, &.{});
    const start: std.Io.Clock.Timestamp = .now(io, .awake);
    const status: std.zig.Server.Message.TestResults.Status = if (test_fn.func()) |_| .pass else |err| switch (err) {
        error.SkipZigTest => .skip,
        else => failure: {
            std.debug.print("{s}: {t}; seed {d}\n", .{ test_fn.name, err, testing.random_seed });
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            break :failure .fail;
        },
    };
    testing.io_instance.deinit();
    const leaks = testing.allocator_instance.detectLeaks();
    if (leaks != 0 or errors.load(.monotonic) != 0) std.debug.print("preflight: failed test {s}; seed {d}\n", .{ test_fn.name, testing.random_seed });
    testing.allocator_instance.deinitWithoutLeakChecks();
    const elapsed: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
    try recorder.record(test_fn.name, elapsed, @tagName(status));
    try server.serveTestResults(.{ .index = index, .flags = .{
        .status = status,
        .fuzz = fuzz_test,
        .log_err_count = std.math.lossyCast(@FieldType(std.zig.Server.Message.TestResults.Flags, "log_err_count"), errors.load(.monotonic)),
        .leak_count = std.math.lossyCast(@FieldType(std.zig.Server.Message.TestResults.Flags, "leak_count"), leaks),
    } });
}

fn terminal(init: std.process.Init.Minimal) !void {
    const recorder = try timings.Recorder.init(io, init.environ);
    defer recorder.deinit();
    var failures: usize = 0;
    for (order) |index| {
        const test_fn = builtin.test_functions[index];
        testing.environ = init.environ;
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{ .argv0 = .init(init.args), .environ = init.environ });
        errors.store(0, .monotonic);
        const start: std.Io.Clock.Timestamp = .now(io, .awake);
        const status: []const u8 = if (test_fn.func()) |_| "pass" else |err| switch (err) {
            error.SkipZigTest => "skip",
            else => failed: {
                std.debug.print("{s}: {t}; seed {d}\n", .{ test_fn.name, err, testing.random_seed });
                if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
                break :failed "fail";
            },
        };
        testing.io_instance.deinit();
        const leaks = testing.allocator_instance.detectLeaks();
        testing.allocator_instance.deinitWithoutLeakChecks();
        try recorder.record(test_fn.name, @intCast(start.untilNow(io).raw.nanoseconds), status);
        if (std.mem.eql(u8, status, "fail") or leaks != 0 or errors.load(.monotonic) != 0) failures += 1;
    }
    if (failures != 0) {
        std.debug.print("preflight: {d} failed tests; seed {d}\n", .{ failures, testing.random_seed });
        std.process.exit(1);
    }
}
