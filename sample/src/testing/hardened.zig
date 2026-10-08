const std = @import("std");

test "bounded byte corpus" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) !void {
            var bytes: [64]u8 = undefined;
            smith.bytes(&bytes);
            const copy = try std.testing.allocator.dupe(u8, &bytes);
            defer std.testing.allocator.free(copy);
            try std.testing.expectEqualSlices(u8, &bytes, copy);
        }
    }.one, .{ .corpus = &.{ "", "seed", "\x00\xff" } });
}

test "thread safety synchronized counter" {
    var counter: std.atomic.Value(u32) = .init(0);
    const worker = struct {
        fn run(c: *std.atomic.Value(u32)) void {
            for (0..1000) |_| _ = c.fetchAdd(1, .monotonic);
        }
    };
    const a = try std.Thread.spawn(.{}, worker.run, .{&counter});
    const b = try std.Thread.spawn(.{}, worker.run, .{&counter});
    a.join();
    b.join();
    try std.testing.expectEqual(@as(u32, 2000), counter.load(.monotonic));
}
