//! The watchdog's wait on a clock the test moves: a test that ends stops
//! the watch, and only the whole bound expires it.
const std = @import("std");
const Clock = @import("shakedown").Clock;
const watchdog = @import("watchdog.zig");

const Watch = struct {
    done: std.atomic.Value(u32) = .init(0),
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
    w.done.store(1, .release);
    io.futexWake(u32, &w.done.raw, 1);
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
    io.futexWake(u32, &w.done.raw, 1);
    clock.advance(.fromNanoseconds(300 * std.time.ns_per_ms - 1));
    try clock.awaitArmed(1, barrier);
    try std.testing.expectEqual(deadline.raw.nanoseconds, clock.nextDeadline().?.raw.nanoseconds);
    clock.advance(.fromNanoseconds(1));
    thread.join();
    try std.testing.expectEqual(true, w.expired.?);
}
