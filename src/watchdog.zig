//! The bound on one test: the wait a watchdog thread makes, on any `Io`'s
//! awake clock, until the test is done or its time is up.
const std = @import("std");

/// Waits until `done` is nonzero or `limit` has passed on `io`'s awake
/// clock, from when this is called. Returns whether the limit passed first.
/// A wake that leaves `done` at zero waits on for what is left.
pub fn expired(io: std.Io, done: *std.atomic.Value(u32), limit: std.Io.Duration) bool {
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = limit, .clock = .awake });
    while (done.load(.acquire) == 0) {
        if (deadline.untilNow(io).raw.nanoseconds >= 0) return true;
        io.futexWaitTimeout(u32, &done.raw, 0, .{ .deadline = deadline }) catch |err| switch (err) {
            // Nothing but the watched test may end the watch.
            error.Canceled => return false,
        };
    }
    return false;
}
