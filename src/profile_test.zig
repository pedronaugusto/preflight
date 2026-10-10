const std = @import("std");
const facts = @import("facts.zig");
const configuration = @import("facts/configuration.zig");
const fixture = @import("facts_test.zig");
const shakedown = @import("shakedown");

test "bounded protocol and configuration fuzzer" {
    try shakedown.check(std.testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) !void {
            const s = case.source;
            const a = case.gpa;
            var bytes: [256]u8 = undefined;
            const input = bytes[0..shakedown.gen.intRange(s, usize, 0, bytes.len)];
            s.bytes(input);
            var reader = std.Io.Reader.fixed(input);
            _ = facts.notification(a, &reader) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {},
            };
            const seed = try fixture.seed(a);
            const mutated = try a.dupe(u8, seed);
            const position = shakedown.gen.intRange(s, usize, 0, mutated.len - 1);
            mutated[position] = shakedown.gen.int(s, u8);
            _ = configuration.load(a, mutated) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {},
            };
        }
    }.one, .{});
}

test "the protocol reader takes the shortest inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "", "seed", "\x00\xff" }) |input| {
        var reader = std.Io.Reader.fixed(input);
        _ = facts.notification(arena.allocator(), &reader) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {},
        };
    }
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
