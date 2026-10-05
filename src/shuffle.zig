//! One seed controls test order and std.testing randomness on every runner.
const std = @import("std");

pub fn init(io: std.Io, process: std.process.Init.Minimal, args: []const []const u8, count: usize) ![]usize {
    const a = std.heap.page_allocator;
    var bytes: [4]u8 = undefined;
    std.Io.random(io, &bytes);
    var seed = std.mem.readInt(u32, &bytes, .little);
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--seed=")) seed = try std.fmt.parseUnsigned(u32, arg[7..], 0);
    }
    var env = try process.environ.createMap(a);
    defer env.deinit();
    if (env.get("PREFLIGHT_TEST_SEED")) |value| seed = try std.fmt.parseUnsigned(u32, value, 0);
    std.testing.random_seed = seed;
    const order = try permutation(a, count, seed);
    std.debug.print("preflight: test seed {d} (reproduce with PREFLIGHT_TEST_SEED={d})\n", .{ seed, seed });
    return order;
}

pub fn permutation(a: std.mem.Allocator, count: usize, seed: u32) ![]usize {
    const order = try a.alloc(usize, count);
    for (order, 0..) |*index, i| index.* = i;
    var random = std.Random.DefaultPrng.init(seed);
    random.random().shuffle(usize, order);
    return order;
}

test "same seed reproduces a permutation and a different seed changes order" {
    const a = std.testing.allocator;
    const first = try permutation(a, 32, 42);
    defer a.free(first);
    const repeated = try permutation(a, 32, 42);
    defer a.free(repeated);
    const other = try permutation(a, 32, 43);
    defer a.free(other);
    try std.testing.expectEqualSlices(usize, first, repeated);
    try std.testing.expect(!std.mem.eql(usize, first, other));
    var seen: [32]bool = @splat(false);
    for (first) |i| {
        try std.testing.expect(!seen[i]);
        seen[i] = true;
    }
}
