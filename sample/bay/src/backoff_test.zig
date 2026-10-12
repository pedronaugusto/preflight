//! `retry` on a shakedown `Sim`, whose tasks run on the stack the package asks
//! for: the size is aegis's `Bytes`, the package's and shakedown's alike, so
//! the build links one aegis or does not compile.
const std = @import("std");
const shakedown = @import("shakedown");
const backoff = @import("bay_sample");

const Flaky = struct {
    failures: u32,
    calls: u32 = 0,

    fn call(flaky: *Flaky) anyerror!void {
        flaky.calls += 1;
        if (flaky.calls <= flaky.failures) return error.Unavailable;
    }
};

fn retryFlaky(io: std.Io, tries: u32, flaky: *Flaky) anyerror!void {
    return backoff.retry(io, tries, flaky, Flaky.call);
}

test "the waits double between tries, and the run takes their sum" {
    const sim = try shakedown.Sim.init(std.testing.allocator, .{ .seed = 1, .stack_size = backoff.task_stack });
    defer sim.deinit();
    var flaky: Flaky = .{ .failures = 3 };
    const began = sim.now(.awake);
    try std.testing.expectEqual(shakedown.Sim.Outcome.finished, sim.run(retryFlaky, .{ sim.io(), 4, &flaky }));
    try std.testing.expectEqual(@as(u32, 4), flaky.calls);
    try std.testing.expectEqual(@as(i96, 7 * std.time.ns_per_s), began.durationTo(sim.now(.awake)).nanoseconds);
}

test "the last error comes back once the tries are spent" {
    const sim = try shakedown.Sim.init(std.testing.allocator, .{ .seed = 2, .stack_size = backoff.task_stack });
    defer sim.deinit();
    var flaky: Flaky = .{ .failures = 5 };
    try std.testing.expectEqual(shakedown.Sim.Outcome{ .failed = error.Unavailable }, sim.run(retryFlaky, .{ sim.io(), 2, &flaky }));
    try std.testing.expectEqual(@as(u32, 2), flaky.calls);
}
