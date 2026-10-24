//! Running the commands a gate is made of: once, or retried with backoff
//! where the network may fail them.
const std = @import("std");
const src = @import("source.zig");
const running = @import("running.zig");

/// Runs `argv` in the context's directory and fails unless it exits 0. Its output goes
/// where the context's reports go: a gate job's own file, or this process's streams.
pub fn execute(c: src.Context, argv: []const []const u8) !void {
    const output: std.process.SpawnOptions.StdIo = if (c.output) |file| .{ .file = file } else .inherit;
    // A gate job's command leads a group of its own, which ends with a stopped gate.
    const grouped = running.grouped and c.grouped;
    var child = try std.process.spawn(c.io, .{ .argv = argv, .cwd = c.childCwd(), .environ_map = c.environ_map, .stdout = output, .stderr = output, .pgid = if (grouped) 0 else null });
    // The pid as spawned: `wait` forgets it.
    const leader = if (grouped) child.id.? else undefined;
    if (grouped) running.hold(leader);
    defer if (grouped) running.release(leader);
    const term = try child.wait(c.io);
    if (term != .exited or term.exited != 0) return error.CommandFailed;
}

/// Whether a finished child exited with status 0.
pub fn succeeded(result: std.process.RunResult) bool {
    return result.term == .exited and result.term.exited == 0;
}

/// The waits between attempts: 5 s, then 10 s.
pub const backoff = [_]std.Io.Duration{ .fromSeconds(5), .fromSeconds(10) };

/// Runs `argv` up to three times, waiting `backoff` on `c.io` between
/// attempts, for a fetch the network may fail.
pub fn retry(c: src.Context, argv: []const []const u8) !void {
    for (0..backoff.len + 1) |attempt| {
        execute(c, argv) catch |err| {
            if (attempt == backoff.len) return err;
            c.report("preflight: fetch failed; retry {d}/{d}\n", .{ attempt + 2, backoff.len + 1 });
            try std.Io.sleep(c.io, backoff[attempt], .awake);
            continue;
        };
        return;
    }
}

/// The fetch a job makes: configure the build it runs and build nothing.
/// Zig fetches what that configuration asks for and no more, so a lazy
/// dependency only another job asks for is never fetched and its build
/// script never compiles here (a Zig it does not support cannot stop this
/// job's tests). The first pass takes no arguments: an option a lazy
/// dependency declares (`-Dci-lint`) is unknown until it is fetched, and Zig
/// refuses an unknown option before it fetches anything. The second takes
/// the job's, for what they ask for besides.
pub fn fetches(a: std.mem.Allocator, whole: []const []const u8, build_args: []const u8) ![]const []const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, whole);
    try argv.append(a, "--list-steps");
    const bare = argv.items.len;
    var tokens = std.mem.tokenizeAny(u8, build_args, " \t\r\n");
    while (tokens.next()) |token| try argv.append(a, token);
    if (argv.items.len == bare) return a.dupe([]const []const u8, &.{argv.items});
    return a.dupe([]const []const u8, &.{ argv.items[0..bare], argv.items });
}

test "a fetch is retried twice, after 5 s and then 10 s, on the context's clock" {
    const Clock = @import("shakedown").Clock;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var clock: Clock = .init(std.testing.io, .{});
    const c: src.Context = .{ .a = arena.allocator(), .io = clock.io() };
    const start = clock.read(.awake);
    const Attempt = struct {
        result: anyerror!void = {},
        const Self = @This();
        fn run(context: src.Context, attempt: *Self) void {
            // A fetch of nothing: zig says so in one line and exits nonzero.
            attempt.result = retry(context, &.{ "zig", "fetch" });
        }
    };
    var attempt: Attempt = .{};
    const thread = try std.Thread.spawn(.{}, Attempt.run, .{ c, &attempt });
    const barrier: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } };
    var waited: i96 = 0;
    for (backoff) |wait| {
        try clock.awaitArmed(1, barrier);
        waited += wait.nanoseconds;
        try std.testing.expectEqual(start.nanoseconds + waited, clock.nextDeadline().?.raw.nanoseconds);
        clock.advance(wait);
    }
    thread.join();
    try std.testing.expectError(error.CommandFailed, attempt.result);
    try std.testing.expectEqual(null, clock.nextDeadline());
}

test "the fetch configures the job's build, first with no options, then with its own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const passes = try fetches(arena.allocator(), &.{ "zig", "build" }, " -Doptimize=debug\t-Dci-lint=false\n");
    try std.testing.expectEqual(@as(usize, 2), passes.len);
    try std.testing.expectEqual(@as(usize, 3), passes[0].len);
    try std.testing.expectEqualStrings("--list-steps", passes[0][2]);
    try std.testing.expectEqual(@as(usize, 5), passes[1].len);
    try std.testing.expectEqualStrings("-Dci-lint=false", passes[1][4]);
    try std.testing.expectEqual(@as(usize, 1), (try fetches(arena.allocator(), &.{ "zig", "build" }, "")).len);
}

test "a gate job's command and what it started end when the gate's jobs are ended" {
    if (!running.grouped) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .grouped = true };
    const Job = struct {
        result: anyerror!void = {},
        fn run(context: src.Context, job: *@This()) void {
            // A shell holding a child of its own, which a signal to the shell alone would leave.
            job.result = execute(context, &.{ "sh", "-c", "sleep 300 & wait" });
        }
    };
    var job: Job = .{};
    const started: std.Io.Clock.Timestamp = .now(std.testing.io, .awake);
    const thread = try std.Thread.spawn(.{}, Job.run, .{ c, &job });
    // Ended once it is held, and so running.
    while (true) {
        const held = for (&running.leaders) |*place| {
            if (place.load(.acquire) != 0) break true;
        } else false;
        if (held) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
    }
    try std.Io.sleep(std.testing.io, .fromMilliseconds(200), .awake);
    running.endAll();
    thread.join();
    try std.testing.expectError(error.CommandFailed, job.result);
    // The shell's wait ends only when its sleep does: well short of 300 s, both ended.
    try std.testing.expect(started.untilNow(std.testing.io).raw.toSeconds() < 60);
}
