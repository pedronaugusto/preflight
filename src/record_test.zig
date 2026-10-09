//! The runner-bound property of `record.zig`'s test timeout, on shakedown.
const std = @import("std");
const shake = @import("shakedown");
const TestTimeout = @import("record.zig").TestTimeout;

test "timeout boundary preserves representable bounds and rejects overflow" {
    try shake.check(std.testing.allocator, {}, struct {
        fn run(_: void, c: *shake.Case) !void {
            const ns = shake.gen.int(c.source, i96);
            const actual = TestTimeout.duration(.{ .bound = .{ .limit = .fromNanoseconds(ns), .reason = "boundary property" } });
            if (ns > std.math.maxInt(u64)) {
                try std.testing.expectEqual(@as(?std.Io.Duration, null), actual);
            } else {
                try std.testing.expectEqual(@max(ns, 1), actual.?.toNanoseconds());
            }
        }
    }.run, .{ .cases = 256 });
    const largest: std.Io.Duration = .fromNanoseconds(std.math.maxInt(u64));
    try std.testing.expectEqual(largest, TestTimeout.duration(.{ .bound = .{ .limit = largest, .reason = "maximum runner bound" } }).?);
}
