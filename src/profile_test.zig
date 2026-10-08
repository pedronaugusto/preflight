const std = @import("std");
const facts = @import("facts.zig");
const configuration = @import("facts/configuration.zig");
const fixture = @import("facts_test.zig");

test "bounded protocol and configuration fuzzer" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) !void {
            var bytes: [256]u8 = undefined;
            smith.bytes(&bytes);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var reader = std.Io.Reader.fixed(&bytes);
            _ = facts.notification(arena.allocator(), &reader) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {},
            };
            const seed = try fixture.seed(arena.allocator());
            const mutated = try arena.allocator().dupe(u8, seed);
            const position = smith.valueRangeLessThan(u32, 0, @intCast(mutated.len));
            mutated[position] = smith.value(u8);
            _ = configuration.load(arena.allocator(), mutated) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {},
            };
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
