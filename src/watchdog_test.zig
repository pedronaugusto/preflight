//! The watchdog's waits on a clock the test moves: a test that ends stops
//! the watch, only the whole bound expires a wait, and a watch ends a tree
//! that made no progress for its whole limit, and no tree that did.
const std = @import("std");
const Clock = @import("shakedown").Clock;
const watchdog = @import("preflight_watchdog");

const Watch = struct {
    done: std.Io.Event = .unset,
    expired: ?bool = null,

    fn run(w: *Watch, io: std.Io, limit: std.Io.Duration) void {
        w.expired = watchdog.expired(io, &w.done, limit);
    }
};

/// A real-time bound on each barrier, so a broken watch fails the test
/// rather than hanging it.
const barrier: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } };

test "a test that ends stops the watch with no time passing" {
    var clock: Clock = .init(std.testing.io, .{});
    const io = clock.io();
    var w: Watch = .{};
    const thread = try std.Thread.spawn(.{}, Watch.run, .{ &w, io, std.Io.Duration.fromSeconds(120) });
    try clock.awaitArmed(1, barrier);
    w.done.set(io);
    thread.join();
    try std.testing.expectEqual(false, w.expired.?);
}

test "the watch expires when the whole bound has passed, and not a nanosecond before" {
    var clock: Clock = .init(std.testing.io, .{});
    const io = clock.io();
    const start = clock.read(.awake);
    var w: Watch = .{};
    const thread = try std.Thread.spawn(.{}, Watch.run, .{ &w, io, std.Io.Duration.fromMilliseconds(300) });
    try clock.awaitArmed(1, barrier);
    const deadline = clock.nextDeadline().?;
    try std.testing.expectEqual(start.nanoseconds + 300 * std.time.ns_per_ms, deadline.raw.nanoseconds);
    // A wake that leaves the test running waits on for what is left.
    io.futexWake(std.Io.Event, &w.done, 1);
    clock.advance(.fromNanoseconds(300 * std.time.ns_per_ms - 1));
    try clock.awaitArmed(1, barrier);
    try std.testing.expectEqual(deadline.raw.nanoseconds, clock.nextDeadline().?.raw.nanoseconds);
    clock.advance(.fromNanoseconds(1));
    thread.join();
    try std.testing.expectEqual(true, w.expired.?);
}

test "a job's deadline gives the run what is left of the job, and none once it has passed" {
    var clock: Clock = .init(std.testing.io, .{ .real = .fromNanoseconds(1_000 * std.time.ns_per_s) });
    const io = clock.io();
    const limit: std.Io.Duration = .fromSeconds(120);
    try std.testing.expectEqual(watchdog.Bound{ .limit = limit, .job = null }, watchdog.bound(io, limit, null));
    try std.testing.expectEqual(watchdog.Bound{ .limit = limit, .job = .fromSeconds(30) }, watchdog.bound(io, limit, 1_030));
    try std.testing.expectEqual(watchdog.Bound{ .limit = null, .job = .fromSeconds(0) }, watchdog.bound(io, null, 900));
}

/// A tree's CPU time as the test sets it, or a reading that fails.
const Tree = struct {
    ns: std.atomic.Value(u64) = .init(0),
    fails: bool = false,

    pub fn cpu(tree: *Tree) !u64 {
        if (tree.fails) return error.ProcessTableUnread;
        return tree.ns.load(.acquire);
    }
};

const Watched = struct {
    done: std.Io.Event = .unset,
    ending: ?watchdog.Ending = null,

    fn run(w: *Watched, io: std.Io, b: watchdog.Bound, tree: *Tree) void {
        w.ending = watchdog.watch(io, &w.done, b, tree);
    }
};

test "a tree that uses no CPU time is ended once the whole limit has passed, and not a sample before" {
    var clock: Clock = .init(std.testing.io, .{});
    const io = clock.io();
    const start = clock.read(.awake);
    var tree: Tree = .{};
    var w: Watched = .{};
    const thread = try std.Thread.spawn(.{}, Watched.run, .{ &w, io, watchdog.Bound{ .limit = .fromMilliseconds(800), .job = null }, &tree });
    // Read every eighth of the limit: the eighth reading finds the whole limit gone.
    for (0..8) |_| {
        try clock.awaitArmed(1, barrier);
        try std.testing.expectEqual(null, w.ending);
        _ = clock.advanceToNext();
    }
    thread.join();
    try std.testing.expectEqual(watchdog.Ending.stalled, w.ending.?);
    try std.testing.expectEqual(@as(i96, 800 * std.time.ns_per_ms), start.durationTo(clock.read(.awake)).nanoseconds);
}

test "a tree that keeps using CPU time, however little in each reading, runs on past any number of limits" {
    var clock: Clock = .init(std.testing.io, .{});
    const io = clock.io();
    var tree: Tree = .{};
    var w: Watched = .{};
    const thread = try std.Thread.spawn(.{}, Watched.run, .{ &w, io, watchdog.Bound{ .limit = .fromMilliseconds(800), .job = null }, &tree });
    // 7 ms a reading, under the floor in any one: 56 ms by the limit's end, past it.
    for (0..800) |_| {
        try clock.awaitArmed(1, barrier);
        _ = tree.ns.fetchAdd(7 * std.time.ns_per_ms, .acq_rel);
        _ = clock.advanceToNext();
    }
    try clock.awaitArmed(1, barrier);
    try std.testing.expectEqual(null, w.ending);
    w.done.set(io);
    thread.join();
    try std.testing.expectEqual(watchdog.Ending.done, w.ending.?);
}

test "a tree whose CPU time falls, a process leaving it with its time, makes progress only from there" {
    var clock: Clock = .init(std.testing.io, .{});
    const io = clock.io();
    var tree: Tree = .{};
    tree.ns.store(10 * std.time.ns_per_s, .release);
    var w: Watched = .{};
    const thread = try std.Thread.spawn(.{}, Watched.run, .{ &w, io, watchdog.Bound{ .limit = .fromMilliseconds(800), .job = null }, &tree });
    try clock.awaitArmed(1, barrier);
    tree.ns.store(1 * std.time.ns_per_s, .release);
    _ = clock.advanceToNext();
    // From the fall, 60 ms is progress: the limit starts over at the fifth reading.
    for (0..3) |_| {
        try clock.awaitArmed(1, barrier);
        _ = clock.advanceToNext();
    }
    try clock.awaitArmed(1, barrier);
    tree.ns.store(1 * std.time.ns_per_s + 60 * std.time.ns_per_ms, .release);
    _ = clock.advanceToNext();
    // Past where the first limit ended it still runs, and the whole limit after the progress ends it.
    for (0..7) |_| {
        try clock.awaitArmed(1, barrier);
        try std.testing.expectEqual(null, w.ending);
        _ = clock.advanceToNext();
    }
    try clock.awaitArmed(1, barrier);
    try std.testing.expectEqual(null, w.ending);
    _ = clock.advanceToNext();
    thread.join();
    try std.testing.expectEqual(watchdog.Ending.stalled, w.ending.?);
}

test "a job's deadline ends a run that is still making progress, and one past it never starts" {
    var clock: Clock = .init(std.testing.io, .{});
    const io = clock.io();
    var tree: Tree = .{};
    var w: Watched = .{};
    const start = clock.read(.awake);
    const thread = try std.Thread.spawn(.{}, Watched.run, .{ &w, io, watchdog.Bound{ .limit = .fromSeconds(120), .job = .fromMilliseconds(300) }, &tree });
    try clock.awaitArmed(1, barrier);
    _ = tree.ns.fetchAdd(std.time.ns_per_s, .acq_rel);
    _ = clock.advanceToNext();
    thread.join();
    try std.testing.expectEqual(watchdog.Ending.job_ran_out, w.ending.?);
    try std.testing.expectEqual(@as(i96, 300 * std.time.ns_per_ms), start.durationTo(clock.read(.awake)).nanoseconds);
    var never: Watched = .{};
    never.run(io, .{ .limit = .fromSeconds(120), .job = .fromSeconds(0) }, &tree);
    try std.testing.expectEqual(watchdog.Ending.not_started, never.ending.?);
}

test "a run whose tree's CPU time cannot be read is ended, named, at once" {
    var clock: Clock = .init(std.testing.io, .{});
    const io = clock.io();
    var tree: Tree = .{ .fails = true };
    var w: Watched = .{};
    w.run(io, .{ .limit = .fromSeconds(120), .job = null }, &tree);
    try std.testing.expectEqual(error.ProcessTableUnread, w.ending.?.unread);
}

test "a job's deadline is whole seconds, or unset" {
    try std.testing.expectEqual(@as(?i64, null), try watchdog.parseDeadline(null));
    try std.testing.expectEqual(@as(?i64, 1_700_000_000), try watchdog.parseDeadline("1700000000"));
    try std.testing.expectError(error.InvalidDeadline, watchdog.parseDeadline("soon"));
}

test "a hosted job's deadline is its start and limit, less what it does after its tests" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(@as(?i64, null), try watchdog.jobDeadline(&env));
    try env.put("PREFLIGHT_STARTED", "1700000000");
    try std.testing.expectError(error.IncompleteJobDeadline, watchdog.jobDeadline(&env));
    try env.put("PREFLIGHT_JOB_TIMEOUT", "20");
    try std.testing.expectEqual(@as(?i64, 1700000000 + 20 * 60 - watchdog.after_tests_s), try watchdog.jobDeadline(&env));
    try env.put("PREFLIGHT_JOB_TIMEOUT", "twenty");
    try std.testing.expectError(error.InvalidJobTimeout, watchdog.jobDeadline(&env));
    // Values past i64's seconds are refused, not wrapped.
    try env.put("PREFLIGHT_JOB_TIMEOUT", "9223372036854775807");
    try std.testing.expectError(error.InvalidJobTimeout, watchdog.jobDeadline(&env));
    try env.put("PREFLIGHT_JOB_TIMEOUT", "0");
    try env.put("PREFLIGHT_STARTED", "-9223372036854775808");
    try std.testing.expectError(error.InvalidJobStart, watchdog.jobDeadline(&env));
}
