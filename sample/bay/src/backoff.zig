//! Retries an operation on whatever `Io` it is given, waiting one second after
//! the first failure and twice as long after each one after it.
const std = @import("std");
const Io = std.Io;
const aegis = @import("aegis");

/// The stack a task that runs `retry` needs, for a runtime that sizes the
/// stacks of its tasks.
pub const task_stack: aegis.units.Bytes(usize) = .fromRaw(64 * 1024);

/// Calls `operation(context)` until it succeeds or has failed `tries` times,
/// and then returns its last error.
pub fn retry(io: Io, tries: u32, context: anytype, comptime operation: fn (@TypeOf(context)) anyerror!void) anyerror!void {
    std.debug.assert(tries > 0);
    var wait: Io.Duration = .fromSeconds(1);
    var failed: u32 = 0;
    while (true) {
        if (operation(context)) |_| return else |err| {
            failed += 1;
            if (failed == tries) return err;
        }
        try io.sleep(wait, .awake);
        wait = .fromNanoseconds(wait.nanoseconds * 2);
    }
}

test "an operation that succeeds at once is called once" {
    var calls: u32 = 0;
    try retry(std.testing.io, 3, &calls, struct {
        fn call(count: *u32) anyerror!void {
            count.* += 1;
        }
    }.call);
    try std.testing.expectEqual(@as(u32, 1), calls);
}
