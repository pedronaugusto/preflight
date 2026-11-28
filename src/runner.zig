//! Zig's test protocol with per-root test counts, shard selection, a
//! watchdog and the package's log level. The fuzzer is upstream's; a fuzz test
//! that never reaches it in the fuzzing build fails by name.
const std = @import("std");
const builtin = @import("builtin");
const upstream = @import("preflight_default_test_runner");
const timings = @import("preflight_timings");
const order_module = @import("preflight_order");
const options = @import("preflight_runner_options");
const bound = @import("preflight_watchdog");
const inbound = @import("runner/input.zig");
const process_tree = @import("runner/tree.zig");
const cpu_time = @import("preflight_cputime");
const test_timeout: std.Io.Duration = .fromNanoseconds(options.test_timeout_ns);
const testing = std.testing;
const io = std.Io.Threaded.global_single_threaded.io();
pub const std_options: std.Options = .{ .logFn = log };
/// std.debug's, whose stack captures are no cancelation point (`runner/debug_io.zig`).
pub const std_options_debug_io: std.Io = @import("runner/debug_io.zig").of(std.Io.Threaded.global_single_threaded.io());
/// The options module carries its own copy of the enum.
const log_level = @field(std.log.Level, @tagName(options.test_log_level));
var errors: std.atomic.Value(usize) = .init(0);
var order: []usize = &.{};
/// The job's deadline, `PREFLIGHT_DEADLINE`, which a hosted job's runner sets.
var job_deadline: ?i64 = null;
/// The tests' process tree, whose CPU time the watchdog reads as a test's progress.
var tests_tree: cpu_time.Root = undefined;
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
/// was one; the fuzzing build asks it again of each test it runs (`Fuzzing`).
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

/// The fuzzing build's side of the protocol. The build finds its fuzz tests
/// in their unfuzzed build, then hands their names to this one, which runs
/// upstream's fuzzer over them as upstream's runner does, but for one thing.
/// A test spends its share of a bounded campaign only inside the fuzzer, so
/// one that ends here without calling `std.testing.fuzz`, as a test that
/// skips when `builtin.fuzz` is set does, would be selected again forever:
/// upstream's runner returns from such a skip quietly. Here it fails, by name.
const Fuzzing = if (builtin.fuzz) struct {
    const abi = std.Build.abi.fuzz;
    var arg_buffer: [8192]u8 = undefined;
    var input: [4096]u8 = undefined;
    var output: [4096]u8 = undefined;
    var reader: std.Io.File.Reader = undefined;
    var writer: std.Io.File.Writer = undefined;
    var server: std.zig.Server = undefined;
    var process: std.process.Init.Minimal = undefined;
    /// The Io the fuzzer's own tasks run on: the poller of the build's inputs.
    var threaded: std.Io.Threaded = undefined;
    var poller: std.Io.Future(std.Io.Cancelable!void) = undefined;
    /// The fuzz tests the build named, as indexes into the test functions.
    var indexes: []u32 = &.{};
    const gpa = std.heap.page_allocator;

    fn main(init: std.process.Init.Minimal) void {
        @disableInstrumentation();
        listen(init) catch |err| std.debug.panic("preflight test runner, fuzzing: {t}", .{err});
    }

    fn listen(init: std.process.Init.Minimal) !void {
        @disableInstrumentation();
        process = init;
        var fixed: std.heap.FixedBufferAllocator = .init(&arg_buffer);
        const args = try init.args.toSlice(fixed.allocator());
        var cache_dir: ?[]const u8 = null;
        for (args[1..]) |arg| {
            if (std.mem.startsWith(u8, arg, "--seed=")) testing.random_seed = try std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0);
            if (std.mem.startsWith(u8, arg, "--cache-dir=")) cache_dir = arg["--cache-dir=".len..];
        }
        abi.fuzzer_init(.fromSlice(cache_dir orelse return error.MissingCacheDir));
        const protocol = try Protocol.claim();
        reader = inbound.protocol(io, protocol.in, &input);
        writer = protocol.out.writerStreaming(io, &output);
        server = .{ .in = &reader.interface, .out = &writer.interface };
        try server.serveStringMessage(.zig_version, builtin.zig_version_string);
        while (true) {
            const header = try server.receiveMessage();
            switch (header.tag) {
                .exit => std.process.exit(0),
                .start_fuzzing => return start(),
                // The build runs the tests themselves in their unfuzzed build.
                else => return error.UnexpectedRunnerMessage,
            }
        }
    }

    fn start() !void {
        @disableInstrumentation();
        threaded = .init(gpa, .{ .argv0 = .init(process.args), .environ = process.environ });
        const mode: abi.LimitKind = @fromBackingInt(@intCast(try server.receiveBody_u8()));
        const amount = try server.receiveBody_u64();
        // One process of a bounded campaign, or the first of an unbounded one.
        const main_instance = mode == .iterations or amount == 0;
        if (main_instance) {
            const coverage = abi.fuzzer_coverage();
            try server.serveCoverageIdMessage(coverage.id, coverage.runs, coverage.unique, coverage.seen);
        }
        const count = try server.receiveBody_u32();
        indexes = try gpa.alloc(u32, count);
        var long_name: std.ArrayList(u8) = .empty;
        defer long_name.deinit(gpa);
        for (indexes) |*index| {
            const length = try server.receiveBody_u32();
            const name = if (length <= server.in.buffer.len) try server.in.take(length) else long: {
                try long_name.resize(gpa, length);
                try server.in.readSliceAll(long_name.items);
                break :long long_name.items;
            };
            index.* = for (builtin.test_functions, 0..) |test_fn, i| {
                if (std.mem.eql(u8, name, test_fn.name)) break @intCast(i); // safe: test functions are counted in u32
            } else std.debug.panic("preflight: fuzz test {s} no longer exists", .{name});
            if (main_instance) try server.serveU64Message(.fuzz_start_addr, abi.fuzzer_unslide_address(@intFromPtr(builtin.test_functions[index.*].func)));
        }
        abi.fuzzer_main(count, testing.random_seed, mode, amount);
        // An unbounded campaign runs until the build ends it.
        std.process.exit(0);
    }

    fn fail(comptime format: []const u8, args: anytype) noreturn {
        @disableInstrumentation();
        report(format, args);
        std.process.exit(1);
    }

    export fn runner_test_run(i: u32) void {
        @disableInstrumentation();
        server.serveU32Message(.fuzz_test_change, i) catch |err| fail("preflight test runner, fuzzing: {t}\n", .{err});
        const test_fn = builtin.test_functions[indexes[i]];
        testing.environ = testsEnviron(process.environ);
        testing.log_level = log_level;
        testing.allocator_instance = .init(Backing.begin(), allocator_options);
        testing.io_instance = .init(testing.allocator, .{ .argv0 = .init(process.args), .environ = testing.environ });
        errors.store(0, .monotonic);
        fuzz_called = false;
        const outcome: anyerror!void = test_fn.func();
        testing.io_instance.deinit();
        const leaks = testing.allocator_instance.deinit();
        Backing.end();
        outcome catch |err| if (err != error.SkipZigTest) {
            report("{s}: {t}; seed {d}\n", .{ test_fn.name, err, testing.random_seed });
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.process.exit(1);
        };
        if (!fuzz_called) fail("preflight: fuzz test {s} {s} without calling std.testing.fuzz in the fuzzing build, though it called it in the unfuzzed one, where the build found it a fuzz test; the fuzzer would select it again forever\n", .{ test_fn.name, if (outcome == error.SkipZigTest) "skipped" else "ended" });
        if (leaks != 0) fail("preflight: fuzz test {s} leaked {d} allocations\n", .{ test_fn.name, leaks });
        if (errors.load(.monotonic) != 0) fail("preflight: fuzz test {s} logged {d} errors\n", .{ test_fn.name, errors.load(.monotonic) });
    }

    export fn runner_test_name(i: u32) abi.Slice {
        @disableInstrumentation();
        return .fromSlice(builtin.test_functions[indexes[i]].name);
    }

    export fn runner_broadcast_input(test_i: u32, bytes: abi.Slice) void {
        @disableInstrumentation();
        server.serveBroadcastFuzzInputMessage(test_i, bytes.toSlice()) catch |err| fail("preflight test runner, fuzzing: {t}\n", .{err});
    }

    export fn runner_start_input_poller() void {
        @disableInstrumentation();
        poller = threaded.io().concurrent(poll, .{}) catch fail("preflight test runner, fuzzing: no thread to read the build's inputs on\n", .{});
    }

    export fn runner_stop_input_poller() void {
        @disableInstrumentation();
        // The poller ends only when canceled, or when reading fails, which ends the process:
        // held in every build, as the fuzzer's next step relies on it.
        const ended = poller.cancel(threaded.io());
        if (ended != error.Canceled) fail("preflight test runner, fuzzing: the build's inputs stopped before their poller was canceled\n", .{});
    }

    export fn runner_futex_wait(ptr: *const u32, expected: u32) bool {
        @disableInstrumentation();
        return threaded.io().futexWait(u32, ptr, expected) == error.Canceled;
    }

    export fn runner_futex_wake(ptr: *const u32, waiters: u32) void {
        @disableInstrumentation();
        threaded.io().futexWake(u32, ptr, waiters);
    }

    /// Hands the fuzzer each input another process of the campaign found,
    /// as the build forwards it, until the campaign ends.
    fn poll() std.Io.Cancelable!void {
        @disableInstrumentation();
        switch (receiveInputs()) {
            error.Canceled => |e| return e,
            error.ReadFailed => {
                const err = reader.err.?;
                if (err == error.Canceled) return error.Canceled;
                fail("preflight test runner, fuzzing: reading the build's inputs: {t}\n", .{err});
            },
            error.EndOfStream => fail("preflight test runner, fuzzing: the build's stream ended\n", .{}),
        }
    }

    fn receiveInputs() (std.Io.Cancelable || std.Io.Reader.Error) {
        @disableInstrumentation();
        var long_input: std.ArrayList(u8) = .empty;
        defer long_input.deinit(gpa);
        while (true) {
            const header = try server.receiveMessage();
            if (header.tag != .new_fuzz_input) fail("preflight test runner, fuzzing: unexpected message {x}\n", .{@backingInt(header.tag)});
            const test_i = try server.receiveBody_u32();
            const length = header.bytes_len - 4;
            const bytes = if (length <= server.in.buffer.len) try server.in.take(length) else long: {
                long_input.resize(gpa, length) catch fail("preflight test runner, fuzzing: out of memory for an input\n", .{});
                try server.in.readSliceAll(long_input.items);
                break :long long_input.items;
            };
            if (abi.fuzzer_receive_input(test_i, .fromSlice(bytes))) return error.Canceled;
        }
    }
} else void;

/// The runner's own lines on stderr, under the lock `std.log` takes.
fn report(comptime format: []const u8, args: anytype) void {
    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    // stderr is where the runner reports: a line lost there is counted as an error logged, so
    // the test it was about fails rather than passing with what it said lost.
    stderr.file_writer.interface.print(format, args) catch {
        _ = errors.fetchAdd(1, .monotonic);
    };
}

/// Ends the process when one test, its Io teardown included, makes no progress for the
/// package's `test_timeout` (its process tree uses no CPU time: a deadlock, a wait nothing
/// completes), or runs when the job's deadline comes, and says which test and phase it was in.
/// A test on a busy machine still uses CPU time, however slowly, and runs on.
const Watchdog = struct {
    name: []const u8,
    phase: std.atomic.Value(Phase) = .init(.body),
    done: std.Io.Event = .unset,
    thread: ?std.Thread = null,

    const Phase = enum(u8) { body, io_teardown, reporting };

    fn start(watchdog: *Watchdog) !void {
        // The build refuses a single-threaded build with a watchdog.
        if (builtin.single_threaded or options.test_timeout_ns == 0) return;
        watchdog.thread = try std.Thread.spawn(.{}, watch, .{watchdog});
    }

    fn stop(watchdog: *Watchdog) void {
        const thread = watchdog.thread orelse return;
        watchdog.done.set(io);
        thread.join();
    }

    fn watch(watchdog: *Watchdog) void {
        const wait = bound.bound(io, test_timeout, job_deadline);
        // The global single-threaded Io never cancels a wait.
        const ending = bound.watch(io, &watchdog.done, wait, Progress{});
        if (ending == .done) return;
        // Not through the stderr lock: a test stalled in a crash handler
        // that hangs holds it, and the watchdog must still say what ran
        // out and end the process.
        var line: [512]u8 = undefined;
        var text: std.Io.Writer = .fixed(&line);
        const name = watchdog.name;
        const phase = watchdog.phase.load(.acquire);
        // A line longer than the buffer is written as far as it fits, and ends marked cut.
        switch (ending) {
            .done => unreachable,
            .not_started => text.print("\npreflight: watchdog: {s} did not start: the job's time had run out before its turn; seed {d}\n", .{ name, testing.random_seed }) catch cut(&text),
            .job_ran_out => text.print("\npreflight: watchdog: {s} was running when the job's time ran out, {f} into it; phase {t}; seed {d}\n", .{ name, wait.job.?, phase, testing.random_seed }) catch cut(&text),
            .stalled => text.print("\npreflight: watchdog: {s} made no progress for {f}: its processes used under {f} of CPU time in it; phase {t}; seed {d}\n", .{ name, test_timeout, bound.progress_floor, phase, testing.random_seed }) catch cut(&text),
            .unread => |err| text.print("\npreflight: watchdog: {s}: its processes' CPU time is unread ({t}), so its progress is unknown; phase {t}; seed {d}\n", .{ name, err, phase, testing.random_seed }) catch cut(&text),
        }
        var stderr = std.Io.File.stderr().writerStreaming(io, &.{});
        // The process ends next either way: a line lost on stderr has nowhere else to go.
        stderr.interface.writeAll(text.buffered()) catch std.process.exit(1);
        std.process.exit(1);
    }

    /// A test's progress: the CPU time of the tests' process tree, less the watchdog thread's
    /// own, whose reading is no work of the test's. Read before this thread's, so the reading's
    /// own cost is taken off whole.
    const Progress = struct {
        pub fn cpu(_: Progress) !u64 {
            const used = try cpu_time.tree(io, std.heap.page_allocator, tests_tree);
            const watching = std.Io.Clock.cpu_thread.now(io).nanoseconds;
            return used -| (std.math.cast(u64, watching) orelse 0);
        }
    };

    /// Ends a line that filled `text`, a fixed buffer, with a mark that it was cut.
    fn cut(text: *std.Io.Writer) void {
        const mark = "...\n";
        const at = @min(text.end, text.buffer.len - mark.len);
        @memcpy(text.buffer[at..][0..mark.len], mark);
        text.end = at + mark.len;
    }
};

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();
    if (builtin.fuzz) return Fuzzing.main(init);
    var arg_buffer: [8192]u8 = undefined;
    var allocator: std.heap.FixedBufferAllocator = .init(&arg_buffer);
    const args = init.args.toSlice(allocator.allocator()) catch @panic("test runner arguments");
    var listen = false;
    var lifeline: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--listen=-")) listen = true;
        if (std.mem.startsWith(u8, arg, "--cache-dir=")) build_cache = arg["--cache-dir=".len..];
        if (std.mem.startsWith(u8, arg, Supervisor.flag)) lifeline = arg[Supervisor.flag.len..];
    }
    if (Supervisor.possible) if (lifeline) |handle| Supervisor.follow(handle) catch |err| std.debug.panic("preflight test runner: the supervisor's lifeline: {t}", .{err});
    if (listen and lifeline == null and Supervisor.possible) Supervisor.run(init, args);
    if (!builtin.single_threaded and options.test_timeout_ns != 0) tests_tree = cpu_time.own() catch |err| std.debug.panic("preflight test runner: the tests' process tree, for the watchdog to read: {t}", .{err});
    order = order_module.init(io, init, args, builtin.test_functions, !listen, options.unsharded) catch |err| std.debug.panic("test runner seed, shard and order: {t}", .{err});
    job_deadline = readDeadline(init.environ) catch |err| std.debug.panic("test runner PREFLIGHT_DEADLINE: {t}", .{err});
    FuzzNames.read(init.environ) catch |err| std.debug.panic("test runner PREFLIGHT_FUZZ_NAMES: {t}", .{err});
    if (!listen) return terminal(init) catch |err| std.debug.panic("preflight test runner: {t}", .{err});
    serve(init) catch |err| std.debug.panic("preflight test runner: {t}", .{err});
}

/// A fuzz campaign's claims on its fuzz tests' names. Zig keeps a fuzz
/// test's corpus by the test's name alone, so two test binaries of one
/// campaign with a fuzz test of the same name contend for it, and the second
/// fuzzer panics mid-campaign ("corpus of ... is in use by another fuzzer").
/// `fuzz-campaign` names a directory of its own in `PREFLIGHT_FUZZ_NAMES`; in
/// the unfuzzed run, where the build finds its fuzz tests, each binary claims
/// the names of its own there, and a name another binary holds fails its test,
/// naming both, before any fuzzer starts.
const FuzzNames = struct {
    var directory: ?[]const u8 = null;
    var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    /// This run's claim: a number of its own, then its executable's path.
    /// Two runs of one binary contend as two binaries do.
    var claim_buffer: [17 + std.Io.Dir.max_path_bytes]u8 = undefined;
    var own: []const u8 = &.{};

    fn read(environ: std.process.Environ) !void {
        var env = try environ.createMap(std.heap.page_allocator);
        defer env.deinit();
        const value = env.get("PREFLIGHT_FUZZ_NAMES") orelse return;
        if (value.len > directory_buffer.len) return error.NameTooLong;
        @memcpy(directory_buffer[0..value.len], value);
        directory = directory_buffer[0..value.len];
        var run: [8]u8 = undefined;
        io.random(&run);
        const prefix = try std.mem.print(&claim_buffer, "{x} ", .{&run});
        own = claim_buffer[0 .. prefix.len + try std.process.executablePath(io, claim_buffer[prefix.len..])];
    }

    /// Claims `name` for this run; the executable of the run that holds it
    /// already, if another does ("another test binary" before it has
    /// written its claim).
    fn claim(name: []const u8, buffer: []u8) !?[]const u8 {
        const path = directory orelse return null;
        var dir = try std.Io.Dir.openDirAbsolute(io, path, .{});
        defer dir.close(io);
        var key_buffer: [16]u8 = undefined;
        const key = try std.mem.print(&key_buffer, "{x:0>16}", .{std.hash.Wyhash.hash(0, name)});
        if (dir.createFile(io, key, .{ .exclusive = true })) |file| {
            defer file.close(io);
            try file.writeStreamingAll(io, own);
            return null;
        } else |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        }
        const holder = try inbound.file(io, dir, key, buffer);
        if (std.mem.eql(u8, holder, own)) return null;
        const space = std.mem.findScalar(u8, holder, ' ') orelse return "another test binary";
        return holder[space + 1 ..];
    }
};

/// The environment the tests run in, and so what a process a test starts inherits: the
/// runner's without preflight's controls (`PREFLIGHT_` and a name). This run's shard, seed and
/// deadline, and the hosted job's settings, are the runner's, read before any test runs; a
/// build a test starts is a run of its own. One that inherited the shard ran its share of its
/// tests alone and passed with the rest unrun. On Windows the environment is the process's
/// own, so the controls leave it.
fn testsEnviron(environ: std.process.Environ) std.process.Environ {
    if (tests_environ) |made| return made;
    const gpa = std.heap.page_allocator;
    var env = environ.createMap(gpa) catch |err| std.debug.panic("preflight test runner: the tests' environment: {t}", .{err});
    var controls: std.ArrayList([]const u8) = .empty;
    for (env.keys()) |name| if (std.mem.startsWith(u8, name, control_prefix)) controls.append(gpa, name) catch @panic("OOM");
    if (builtin.target.os.tag == .windows) {
        for (controls.items) |name| {
            const wide = std.unicode.wtf8ToWtf16LeAllocZ(gpa, name) catch |err| std.debug.panic("preflight test runner: {s}: {t}", .{ name, err });
            if (SetEnvironmentVariableW(wide, null) == .FALSE) std.debug.panic("preflight test runner: {s} stays in the tests' environment", .{name});
        }
        tests_environ = environ;
    } else {
        for (controls.items) |name| _ = env.swapRemove(name);
        tests_environ = .{ .block = env.createPosixBlock(gpa, .{}) catch @panic("OOM") };
    }
    return tests_environ.?;
}
var tests_environ: ?std.process.Environ = null;
const control_prefix = "PREFLIGHT_";
extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) std.os.windows.BOOL;

fn readDeadline(environ: std.process.Environ) !?i64 {
    var env = try environ.createMap(std.heap.page_allocator);
    defer env.deinit();
    return bound.parseDeadline(env.get("PREFLIGHT_DEADLINE"));
}

fn serve(init: std.process.Init.Minimal) !void {
    var input: [4096]u8 = undefined;
    var output: [4096]u8 = undefined;
    const protocol = try Protocol.claim();
    var reader = inbound.protocol(io, protocol.in, &input);
    var writer = protocol.out.writerStreaming(io, &output);
    var server: std.zig.Server = .{ .in = &reader.interface, .out = &writer.interface };
    try server.serveStringMessage(.zig_version, builtin.zig_version_string);
    progress = .open(io, init.environ, options.artifact);
    defer progress.close(io);
    const started: std.Io.Clock.Timestamp = .now(io, .awake);
    while (true) {
        const header = try server.receiveMessage();
        switch (header.tag) {
            .exit => {
                progress.line(io, "{d} tests in {d:.1}s, the {d} under a second taking {d:.1}s of it", .{ tests_timed, seconds(started.untilNow(io).raw.nanoseconds), tests_timed - tests_slow, seconds(quick_ns) });
                return;
            },
            .query_test_metadata => {
                try metadata(&server);
                try counted(init);
            },
            .run_test => try runTest(&server, init),
            else => return error.UnexpectedRunnerMessage,
        }
    }
}

/// The process the build starts, when the runner serves the build and can
/// start a process. It runs the tests in a process of their own, which takes
/// the build's protocol from it (`Protocol`) and writes everything else, its
/// own and its tests' output and a crash's report alike, into a pipe this
/// process forwards to the build. A process a test started that outlives the
/// tests holds that pipe, never the build's stderr: the build would wait for
/// it, and kill the runner a minute later outside any test (conduit's
/// ThreadSanitizer job). Here the tests' process ending is the end: what it
/// wrote is forwarded whole, a process still holding the pipe a moment later
/// is named and fails the run, and the tests' ending, an exit or a signal,
/// becomes this process's own.
const Supervisor = struct {
    /// What the supervisor adds to the tests' process's arguments, before
    /// the lifeline's descriptor (handle, on Windows) in decimal.
    const flag = "--preflight-supervised=";
    /// Starting a process, and forwarding while waiting for one, take threads.
    const possible = std.process.can_spawn and !builtin.single_threaded;
    /// How long a process the tests left may hold their output after the
    /// tests' process has ended: one that is ending lets go well within it.
    const release: std.Io.Duration = .fromSeconds(2);

    fn run(init: std.process.Init.Minimal, args: []const [:0]const u8) noreturn {
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{ .environ = init.environ });
        const sio = threaded.io();
        const ending = supervise(sio, args) catch |err| std.debug.panic("preflight test runner: supervising the tests: {t}", .{err});
        exitAs(ending);
    }

    const Ending = struct {
        term: std.process.Child.Term,
        /// Windows' exit status whole, where `term` keeps its low byte.
        status: u32,
        /// Whether a process the tests started still held their output.
        held: bool,
    };

    fn supervise(sio: std.Io, args: []const [:0]const u8) !Ending {
        const gpa = std.heap.page_allocator;
        const self = try std.process.executablePathAlloc(sio, gpa);
        defer gpa.free(self);
        const argv = try gpa.alloc([]const u8, args.len + 1);
        defer gpa.free(argv);
        argv[0] = self;
        for (args[1..], argv[1..args.len]) |arg, *slot| slot.* = arg;
        // The tests' process ends with this one, however this one ends: the
        // build kills it, not the tests', when a test outlasts a timeout given
        // by hand. The lifeline's write end is this process's alone, so its
        // read end ends as this process does.
        const lifeline = try Lifeline.open();
        defer lifeline.write.close(sio);
        var number: [32]u8 = undefined;
        argv[args.len] = try std.mem.print(&number, flag ++ "{d}", .{Lifeline.number(lifeline.read)});
        var child = spawn: {
            defer lifeline.read.close(sio);
            break :spawn try std.process.spawn(sio, .{
                .argv = argv,
                .stderr = .pipe,
                .inherit_files = &.{lifeline.read},
                .pgid = if (builtin.target.os.tag == .windows) null else 0,
                .start_suspended = builtin.target.os.tag == .windows,
            });
        };
        // Ends what is left of the tests' processes when this returns: after
        // the holders of their output are named.
        const tree = try Tree.hold(&child);
        defer tree.end(sio);
        // The pipe is this process's, not the child's: `wait` closes what the
        // child still names, and the forwarding outlives the wait.
        const output = child.stderr.?;
        child.stderr = null;
        defer output.close(sio);
        const stderr = std.Io.File.stderr();
        var forwarding = try sio.concurrent(pump, .{ sio, output, stderr, .none });
        // Everything the tests' process wrote is in the pipe once it has
        // ended. The forwarding stops then, losing nothing it read, and the
        // rest is read here, until the pipe ends or stays quiet for `release`
        // with a process still holding it.
        const status = process_tree.waitStatus(&child);
        const term = try child.wait(sio);
        const forwarded = try forwarding.cancel(sio);
        const held = switch (forwarded) {
            .ended => false,
            .quiet => unreachable, // forwarding has no quiet bound
            .canceled => try pump(sio, output, stderr, .{ .duration = .{ .raw = release, .clock = .awake } }) == .quiet,
        };
        if (held) try nameHolders(sio, output, stderr);
        return .{ .term = term, .status = status, .held = held };
    }

    const Tree = process_tree.Tree;

    /// A pipe whose write end only the supervisor holds; the tests' process
    /// holds the read end, which ends when the supervisor does.
    const Lifeline = struct {
        read: std.Io.File,
        write: std.Io.File,

        /// Both ends close on exec and are not inherited; the spawn passes the
        /// read end alone.
        fn open() !Lifeline {
            if (builtin.target.os.tag == .windows) {
                var read: std.os.windows.HANDLE = std.os.windows.INVALID_HANDLE_VALUE;
                var write: std.os.windows.HANDLE = std.os.windows.INVALID_HANDLE_VALUE;
                if (CreatePipe(&read, &write, null, 0) == .FALSE) return error.LifelineUnopened;
                return .{ .read = file(read), .write = file(write) };
            }
            const ends = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
            return .{ .read = file(ends[0]), .write = file(ends[1]) };
        }

        fn file(handle: std.Io.File.Handle) std.Io.File {
            return .{ .handle = handle, .flags = .{ .nonblocking = false } };
        }

        fn number(end: std.Io.File) usize {
            return if (builtin.target.os.tag == .windows) @intFromPtr(end.handle) else @intCast(end.handle);
        }

        extern "kernel32" fn CreatePipe(read: *std.os.windows.HANDLE, write: *std.os.windows.HANDLE, security: ?*std.os.windows.SECURITY_ATTRIBUTES, size: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
    };

    /// In the tests' process: keeps the lifeline from every process it starts,
    /// and ends this process when the lifeline ends, the supervisor gone.
    fn follow(text: []const u8) !void {
        const value = std.fmt.parseUnsigned(usize, text, 10) catch return error.InvalidLifeline;
        const end: std.Io.File = if (builtin.target.os.tag == .windows)
            Lifeline.file(@ptrFromInt(value))
        else
            Lifeline.file(std.math.cast(std.posix.fd_t, value) orelse return error.InvalidLifeline);
        if (builtin.target.os.tag == .windows) {
            if (Protocol.SetHandleInformation(end.handle, Protocol.handle_flag_inherit, 0) == .FALSE) return error.InvalidLifeline;
        } else if (std.posix.errno(std.posix.system.fcntl(end.handle, std.posix.F.SETFD, @as(usize, std.posix.FD_CLOEXEC))) != .SUCCESS) return error.InvalidLifeline;
        const watch = try std.Thread.spawn(.{}, awaitEnd, .{end});
        watch.detach();
    }

    fn awaitEnd(end: std.Io.File) void {
        var byte: [1]u8 = undefined;
        // Nothing is ever written: a read returns when the write end closes.
        if (inbound.chunk(io, end, &byte)) |_| {
            // A byte, which nothing writes, still means the lifeline is done.
        } else |err| switch (err) {
            error.EndOfStream => {},
            // A read that failed leaves the supervisor unheard: ended on as if it were gone.
            else => |e| report("preflight test runner: the lifeline failed ({t}): ending the tests as their supervisor would\n", .{e}),
        }
        // The supervisor is gone and cannot end the tree: this process leads
        // its group, and ends with every process in it. On Windows the job
        // did when the supervisor's handle to it closed.
        if (builtin.target.os.tag != .windows) _ = std.posix.system.kill(0, .KILL);
        std.process.exit(1);
    }

    /// How forwarding stopped.
    const Pumped = enum { ended, quiet, canceled };

    /// Forwards `from` to `to` until `from` ends, nothing comes for `quiet`
    /// (`.none`: never), or the task is canceled. Every byte read is written
    /// however it stops: a read is canceled through its batch, which still
    /// yields a read that completed as it was canceled, and the write that
    /// follows is never canceled.
    fn pump(sio: std.Io, from: std.Io.File, to: std.Io.File, quiet: std.Io.Timeout) !Pumped {
        var buffer: [4096]u8 = @splat(0);
        const data: [1][]u8 = .{&buffer};
        var storage: [1]std.Io.Operation.Storage = undefined;
        var batch: std.Io.Batch = .init(&storage);
        defer batch.cancel(sio);
        while (true) {
            batch.addAt(0, inbound.streaming(from, &data));
            var stop: ?Pumped = null;
            batch.awaitConcurrent(sio, quiet) catch |err| switch (err) {
                error.Timeout => stop = .quiet,
                error.Canceled => stop = .canceled,
                else => |e| return e,
            };
            const protection = sio.swapCancelProtection(.blocked);
            defer _ = sio.swapCancelProtection(protection);
            if (stop != null) batch.cancel(sio);
            const read = batch.next() orelse return stop orelse error.ReadVanished;
            const n = read.result.file_read_streaming catch |err| switch (err) {
                error.EndOfStream => return .ended,
                else => |e| return e,
            };
            try to.writeStreamingAll(sio, buffer[0..n]);
            // Bytes came, so it was not quiet; a cancel still stops here.
            if (stop == .canceled) return .canceled;
        }
    }

    /// Says that processes the tests started hold their output, and on Linux
    /// which, by the processes whose descriptors name the pipe.
    fn nameHolders(sio: std.Io, output: std.Io.File, to: std.Io.File) !void {
        var buffer: [1024]u8 = undefined;
        var writer = to.writerStreaming(sio, &buffer);
        const w = &writer.interface;
        try w.print("\npreflight: the tests' process ended, and processes it started still hold its output {f} later:\n", .{release});
        switch (builtin.target.os.tag) {
            .linux => try listHolders(sio, output, w),
            .macos => try Darwin.listHolders(output, w),
            else => try w.writeAll("  (this system does not say which)\n"),
        }
        try w.flush();
    }

    fn listHolders(sio: std.Io, output: std.Io.File, w: *std.Io.Writer) !void {
        const stat = try output.stat(sio);
        var name: [64]u8 = undefined;
        const pipe = try std.mem.print(&name, "pipe:[{d}]", .{stat.inode});
        var proc = try std.Io.Dir.openDirAbsolute(sio, "/proc", .{ .iterate = true });
        defer proc.close(sio);
        var processes = proc.iterate();
        var own_number: [16]u8 = undefined;
        const own_pid = try std.mem.print(&own_number, "{d}", .{std.os.linux.getpid()});
        while (try processes.next(sio)) |process| {
            // A process's entry is named by its number; the others (self, net) are no process.
            const pid = process.name;
            if (pid.len == 0 or std.mem.findNone(u8, pid, "0123456789") != null) continue;
            if (std.mem.eql(u8, pid, own_pid)) continue;
            var path: [64]u8 = undefined;
            var fds = proc.openDir(sio, try std.mem.print(&path, "{s}/fd", .{pid}), .{ .iterate = true }) catch |err| switch (err) {
                // A process that ended since the listing has no descriptors left to read, and
                // another user's are not this one's to read.
                error.FileNotFound, error.AccessDenied, error.PermissionDenied => continue,
                error.Canceled => |e| return e,
                else => |e| {
                    try w.print("  pid {s}: its descriptors unread: {t}\n", .{ pid, e });
                    continue;
                },
            };
            defer fds.close(sio);
            var descriptors = fds.iterate();
            const holds = while (descriptors.next(sio) catch |err| switch (err) {
                error.Canceled => |e| return e,
                // A process that ends mid-listing leaves the rest of its descriptors unread.
                else => null,
            }) |fd| {
                var target: [64]u8 = @splat(0);
                const named = inbound.link(sio, fds, fd.name, &target) catch |err| switch (err) {
                    // A descriptor closed since the listing names nothing, and one whose
                    // target outgrows the buffer is no pipe: a pipe's name fits it.
                    error.FileNotFound, error.NameTooLong => continue,
                    error.Canceled => |e| return e,
                    else => |e| {
                        try w.print("  pid {s}: descriptor {s} unread: {t}\n", .{ pid, fd.name, e });
                        continue;
                    },
                };
                if (std.mem.eql(u8, named, pipe)) break true;
            } else false;
            if (!holds) continue;
            var line: [512]u8 = @splat(0);
            const command = inbound.file(sio, proc, try std.mem.print(&path, "{s}/cmdline", .{pid}), &line) catch line[0..0];
            for (command) |*byte| if (byte.* == 0) {
                byte.* = ' ';
            };
            try w.print("  pid {s}: {s}\n", .{ pid, std.mem.trimEnd(u8, command, " ") });
        }
    }

    /// libproc's view of the processes holding a pipe: a writer's descriptor
    /// names the read end this process holds as its peer.
    const Darwin = struct {
        const list_fds = 1; // PROC_PIDLISTFDS
        const pipe_info = 6; // PROC_PIDFDPIPEINFO
        const fd_type_pipe = 6; // PROX_FDTYPE_PIPE
        const FdInfo = extern struct { fd: i32, type: u32 };
        /// `struct pipe_fdinfo`: a `proc_fileinfo`, then `pipe_info` with a
        /// `vinfo_stat` before the two ends' handles.
        const PipeFdInfo = extern struct {
            file: [24]u8,
            stat: [136]u8,
            handle: u64,
            peer: u64,
            status: i32,
            reserved: i32,
        };
        extern "c" fn proc_listallpids(buffer: ?*anyopaque, size: c_int) c_int;
        extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, size: c_int) c_int;
        extern "c" fn proc_pidfdinfo(pid: c_int, fd: c_int, flavor: c_int, buffer: ?*anyopaque, size: c_int) c_int;

        fn listHolders(output: std.Io.File, w: *std.Io.Writer) !void {
            const own = pipeOf(std.c.getpid(), output.handle) orelse return error.PipeUnnamed;
            var pids: [8192]c_int = @splat(0);
            const count = proc_listallpids(&pids, @sizeOf(@TypeOf(pids)));
            if (count <= 0) return error.ProcessesUnlisted;
            const arguments = try argumentBuffer();
            defer std.heap.page_allocator.free(arguments);
            for (pids[0..@min(@as(usize, @intCast(count)), pids.len)]) |pid| {
                if (pid == std.c.getpid() or !holds(pid, own.handle)) continue;
                try w.print("  pid {d}: {s}\n", .{ pid, commandLine(pid, arguments) });
            }
        }

        /// A buffer as long as the system's longest arguments and environment
        /// (`kern.argmax`), as `ps` reads them: `kern.procargs2` copies a
        /// process's arguments with its environment, which on a hosted runner
        /// outgrows any fixed buffer, and a shorter one names nothing.
        fn argumentBuffer() ![]u8 {
            var mib = [_]c_int{ std.c.CTL.KERN, std.c.KERN.ARGMAX };
            var argmax: c_int = 0;
            var size: usize = @sizeOf(c_int);
            if (std.c.sysctl(&mib, mib.len, &argmax, &size, null, 0) != 0 or argmax <= 0) return error.ArgumentsUnsized;
            return std.heap.page_allocator.alloc(u8, @intCast(argmax));
        }

        fn holds(pid: c_int, handle: u64) bool {
            var fds: [512]FdInfo = std.mem.zeroes([512]FdInfo);
            const size = proc_pidinfo(pid, list_fds, 0, &fds, @sizeOf(@TypeOf(fds)));
            if (size <= 0) return false;
            for (fds[0..@min(@as(usize, @intCast(size)) / @sizeOf(FdInfo), fds.len)]) |fd| {
                if (fd.type != fd_type_pipe) continue;
                const pipe = pipeOf(pid, fd.fd) orelse continue;
                if (pipe.peer == handle) return true;
            }
            return false;
        }

        fn pipeOf(pid: c_int, fd: c_int) ?PipeFdInfo {
            var info: PipeFdInfo = std.mem.zeroes(PipeFdInfo);
            if (proc_pidfdinfo(pid, fd, pipe_info, &info, @sizeOf(PipeFdInfo)) != @sizeOf(PipeFdInfo)) return null;
            return info;
        }

        /// The process's arguments, from `kern.procargs2`: the argument count,
        /// the executable's path, then the arguments, each ending in a zero.
        fn commandLine(pid: c_int, buffer: []u8) []const u8 {
            var mib = [_]c_int{ std.c.CTL.KERN, std.c.KERN.PROCARGS2, pid };
            var size: usize = buffer.len;
            if (std.c.sysctl(&mib, mib.len, buffer.ptr, &size, null, 0) != 0 or size < @sizeOf(c_int)) return "(its arguments unread)";
            const argc: usize = @intCast(@max(std.mem.readInt(c_int, buffer[0..@sizeOf(c_int)], .little), 0));
            var rest = buffer[@sizeOf(c_int)..size];
            // The executable's path, then the zeros that align the arguments.
            rest = rest[(std.mem.findScalar(u8, rest, 0) orelse return "")..];
            rest = rest[(std.mem.findNone(u8, rest, &.{0}) orelse return "")..];
            var length: usize = 0;
            var seen: usize = 0;
            while (seen < argc and length < rest.len) : (seen += 1) {
                length += (std.mem.findScalar(u8, rest[length..], 0) orelse (rest.len - length)) + 1;
            }
            const line = rest[0..@min(length, rest.len)];
            for (line) |*byte| if (byte.* == 0) {
                byte.* = ' ';
            };
            return std.mem.trimEnd(u8, line, " ");
        }
    };

    /// Ends this process as the tests' process ended: with its exit status,
    /// or by its signal, so the build reads the tests' ending as its own.
    /// Held output fails a run that would have passed.
    fn exitAs(ending: Ending) noreturn {
        const status: u32 = if (ending.status == 0 and ending.held) 1 else ending.status;
        const term: std.process.Child.Term = switch (ending.term) {
            .exited => |code| .{ .exited = if (code == 0 and ending.held) 1 else code },
            else => ending.term,
        };
        process_tree.exitAs(term, status, "preflight test runner: the tests' process");
    }
};

/// The build's protocol, on streams of the runner's own. Zig hands the runner
/// the protocol as its stdin and stdout, which every process a test starts
/// with inherited streams would share: a descendant still running after the
/// last test holds the build's end open, so the build waits for an ending that
/// never comes and kills the runner a minute later, outside any test and past
/// the watchdog (conduit's ThreadSanitizer job); one that writes to its stdout
/// writes into the protocol. The runner keeps the protocol on streams no
/// process inherits, and gives the tests an empty stdin and its stderr as
/// their stdout, where what they and their processes write reaches the build
/// as a test's output.
const Protocol = struct {
    in: std.Io.File,
    out: std.Io.File,

    fn claim() !Protocol {
        if (builtin.target.os.tag == .windows) return claimWindows();
        const in = try private(std.posix.STDIN_FILENO);
        const out = try private(std.posix.STDOUT_FILENO);
        const empty = try std.Io.Dir.cwd().openFile(io, "/dev/null", .{});
        defer empty.close(io);
        try std.Io.Threaded.dup2(empty.handle, std.posix.STDIN_FILENO);
        try std.Io.Threaded.dup2(std.posix.STDERR_FILENO, std.posix.STDOUT_FILENO);
        return .{ .in = .{ .handle = in, .flags = .{ .nonblocking = false } }, .out = .{ .handle = out, .flags = .{ .nonblocking = false } } };
    }

    /// F_DUPFD_CLOEXEC: Zig 0.17's OpenBSD table has none, and OpenBSD's
    /// <sys/fcntl.h> defines it as 10.
    const dupfd_cloexec = if (builtin.target.os.tag == .openbsd and !@hasDecl(std.c.F, "DUPFD_CLOEXEC")) 10 else std.c.F.DUPFD_CLOEXEC;

    /// A copy of `fd` above the standard streams that closes on exec.
    fn private(fd: std.posix.fd_t) !std.posix.fd_t {
        const rc = if (builtin.target.os.tag == .linux)
            std.os.linux.fcntl(fd, std.os.linux.F.DUPFD_CLOEXEC, 3)
        else
            std.c.fcntl(fd, dupfd_cloexec, @as(c_int, 3));
        if (std.posix.errno(rc) != .SUCCESS) return error.ProtocolStream;
        return @intCast(rc); // safe: a successful fcntl(F_DUPFD_CLOEXEC) returns a descriptor
    }

    /// On Windows a process starts with what its parent names as its standard
    /// handles and every inheritable handle: the protocol's handles stop being
    /// inheritable, the process's standard input becomes the null device and
    /// its standard output its standard error.
    fn claimWindows() !Protocol {
        const windows = std.os.windows;
        const parameters = windows.peb().ProcessParameters;
        const in = parameters.hStdInput;
        const out = parameters.hStdOutput;
        for ([_]windows.HANDLE{ in, out }) |handle| {
            if (SetHandleInformation(handle, handle_flag_inherit, 0) == .FALSE) return error.ProtocolStream;
        }
        var inherited: windows.SECURITY_ATTRIBUTES = .{ .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = .TRUE };
        const empty = CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("NUL"), generic_read, file_share_read | file_share_write, &inherited, open_existing, 0, null);
        if (empty == windows.INVALID_HANDLE_VALUE) return error.ProtocolStream;
        parameters.hStdInput = empty;
        parameters.hStdOutput = parameters.hStdError;
        return .{ .in = .{ .handle = in, .flags = .{ .nonblocking = false } }, .out = .{ .handle = out, .flags = .{ .nonblocking = false } } };
    }

    const handle_flag_inherit = 0x1;
    const generic_read = 0x80000000;
    const file_share_read = 0x1;
    const file_share_write = 0x2;
    const open_existing = 3;
    extern "kernel32" fn SetHandleInformation(handle: std.os.windows.HANDLE, mask: std.os.windows.DWORD, flags: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn CreateFileW(
        name: [*:0]const u16,
        access: std.os.windows.DWORD,
        share: std.os.windows.DWORD,
        security: ?*std.os.windows.SECURITY_ATTRIBUTES,
        disposition: std.os.windows.DWORD,
        flags: std.os.windows.DWORD,
        template: ?std.os.windows.HANDLE,
    ) callconv(.winapi) std.os.windows.HANDLE;
};

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

/// The build's cache, which the build names to a run of the tests (`--cache-dir`), where it
/// replays them too; null for a binary run by hand.
var build_cache: ?[]const u8 = null;

/// The count of this binary's tests, for the build's count of its tests per root: written
/// when the build asks which tests there are, so a run that starts writes it.
fn counted(init: std.process.Init.Minimal) !void {
    const cache = build_cache orelse return;
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const stem = std.mem.print(&buffer, "{s}/{s}", .{ cache, options.counts }) catch return error.NameTooLong;
    try timings.count(io, init.environ, stem, .{ .root = options.root, .artifact = options.artifact, .filtered = options.filtered, .tests = builtin.test_functions.len, .selected = order.len });
}

/// This process's progress file, which a hosted job prints as it lands (`timings.Progress`), and
/// what it has timed: the tests, the slow ones among them, and the time the rest took.
var progress: timings.Progress = .{};
var tests_timed: usize = 0;
var tests_slow: usize = 0;
var quick_ns: i96 = 0;

fn seconds(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

fn runTest(server: *std.zig.Server, init: std.process.Init.Minimal) !void {
    const index = try server.receiveBody_u32();
    const test_fn = builtin.test_functions[order[index]];
    var watchdog: Watchdog = .{ .name = test_fn.name };
    try watchdog.start();
    defer watchdog.stop();
    testing.environ = testsEnviron(init.environ);
    testing.log_level = log_level;
    testing.allocator_instance = .init(Backing.begin(), allocator_options);
    testing.io_instance = .init(testing.allocator, .{ .argv0 = .init(init.args), .environ = testing.environ });
    errors.store(0, .monotonic);
    fuzz_called = false;
    try server.serveStringMessage(.test_started, &.{});
    const started: std.Io.Clock.Timestamp = .now(io, .awake);
    const outcome = test_fn.func();
    const took = started.untilNow(io).raw.nanoseconds;
    tests_timed += 1;
    if (took >= timings.slow_ns) {
        tests_slow += 1;
        progress.line(io, "{s}: {d:.1}s", .{ test_fn.name, seconds(took) });
    } else quick_ns += took;
    var status: std.zig.Server.Message.TestResults.Status = if (outcome) |_| .pass else |err| switch (err) {
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
    if (fuzz_called) {
        var holder_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const holder = FuzzNames.claim(test_fn.name, &holder_buffer) catch |err| std.debug.panic("preflight test runner: claiming fuzz test {s} in the campaign: {t}", .{ test_fn.name, err });
        if (holder) |other| {
            report("preflight: fuzz test {s} runs twice in this campaign, in {s} and in {s}; Zig keeps a fuzz test's corpus by its name, so their fuzzers would contend for it. Give the test to one test run alone\n", .{ test_fn.name, other, FuzzNames.own[std.mem.findScalar(u8, FuzzNames.own, ' ').? + 1 ..] });
            status = .fail;
            // Not a fuzz test of this run: the build would still fuzz it here.
            fuzz_called = false;
        }
    }
    try server.serveTestResults(.{ .index = index, .flags = .{
        .status = status,
        .fuzz = fuzz_called,
        .log_err_count = std.math.lossyCast(@FieldType(std.zig.Server.Message.TestResults.Flags, "log_err_count"), errors.load(.monotonic)),
        .leak_count = std.math.lossyCast(@FieldType(std.zig.Server.Message.TestResults.Flags, "leak_count"), leaks),
    } });
}

fn terminal(init: std.process.Init.Minimal) !void {
    try counted(init);
    var failures: usize = 0;
    for (order) |index| {
        const test_fn = builtin.test_functions[index];
        var watchdog: Watchdog = .{ .name = test_fn.name };
        try watchdog.start();
        defer watchdog.stop();
        testing.environ = testsEnviron(init.environ);
        testing.log_level = log_level;
        testing.allocator_instance = .init(Backing.begin(), allocator_options);
        testing.io_instance = .init(testing.allocator, .{ .argv0 = .init(init.args), .environ = testing.environ });
        errors.store(0, .monotonic);
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
        if (std.mem.eql(u8, status, "fail") or leaks != 0 or errors.load(.monotonic) != 0) failures += 1;
    }
    if (failures != 0) {
        report("preflight: {d} failed tests; seed {d}\n", .{ failures, testing.random_seed });
        std.process.exit(1);
    }
}
