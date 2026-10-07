//! One seed orders the tests and seeds std.testing on every runner. A shard
//! runs its share of the tests, balanced by the durations the package records.
const std = @import("std");
const builtin = @import("builtin");

/// The column of `ci/durations.json` this test binary reads.
pub const key = @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.mode);

/// A test that records no time still costs its process a little.
const floor_seconds = 0.001;

pub const Shard = struct {
    /// Zero-based.
    index: usize,
    count: usize,

    pub const all: Shard = .{ .index = 0, .count = 1 };

    /// Reads `i/n`, one-based, as the hosted matrix writes it. Empty is all.
    pub fn parse(text: []const u8) error{InvalidShard}!Shard {
        if (text.len == 0) return all;
        const slash = std.mem.findScalar(u8, text, '/') orelse return error.InvalidShard;
        const number = std.fmt.parseUnsigned(usize, text[0..slash], 10) catch return error.InvalidShard;
        const count = std.fmt.parseUnsigned(usize, text[slash + 1 ..], 10) catch return error.InvalidShard;
        if (number == 0 or number > count) return error.InvalidShard;
        return .{ .index = number - 1, .count = count };
    }
};

/// Seeds std.testing and returns the indices of this shard's tests in seeded
/// order. `PREFLIGHT_SHARD` (`i/n`) selects the shard; `durations`, the text of
/// the package's `ci/durations.json` or empty, balances the split.
pub fn init(io: std.Io, process: std.process.Init.Minimal, args: []const []const u8, tests: []const std.lang.TestFn, durations: []const u8) ![]usize {
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
    const shard = try Shard.parse(env.get("PREFLIGHT_SHARD") orelse "");
    const names = try a.alloc([]const u8, tests.len);
    defer a.free(names);
    for (tests, names) |test_fn, *name| name.* = test_fn.name;
    const weights = try weigh(a, if (shard.count > 1 and durations.len > 0) durations else "{}", names, key);
    defer a.free(weights);
    const selected = try assign(a, names, weights, shard);
    var random = std.Random.DefaultPrng.init(seed);
    random.random().shuffle(usize, selected);
    var buffer: [256]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
    try stderr.interface.print("preflight: test seed {d} (reproduce with PREFLIGHT_TEST_SEED={d})\n", .{ seed, seed });
    if (shard.count > 1) try stderr.interface.print("preflight: shard {d}/{d} runs {d} of {d} tests\n", .{ shard.index + 1, shard.count, selected.len, tests.len });
    try stderr.interface.flush();
    return selected;
}

/// Each test's recorded seconds in `column`. A test without a record weighs
/// the mean of those with one; with no records every test weighs the same,
/// so the shards split by count.
pub fn weigh(a: std.mem.Allocator, json: []const u8, names: []const []const u8, column: []const u8) ![]f64 {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    if (value != .object) return error.InvalidDurations;
    const index: ?usize = if (value.object.get("keys")) |keys| position: {
        if (keys != .array) return error.InvalidDurations;
        for (keys.array.items, 0..) |item, i| if (item == .string and std.mem.eql(u8, item.string, column)) break :position i;
        break :position null;
    } else null;
    const tests = value.object.get("tests");
    if (tests != null and tests.? != .object) return error.InvalidDurations;
    const weights = try a.alloc(f64, names.len);
    errdefer a.free(weights);
    var known: f64 = 0;
    var count: usize = 0;
    for (names, weights) |name, *weight| {
        weight.* = -1;
        const column_index = index orelse continue;
        const row = (tests orelse continue).object.get(name) orelse continue;
        if (row != .array or row.array.items.len <= column_index) return error.InvalidDurations;
        const seconds: f64 = switch (row.array.items[column_index]) {
            .null => continue,
            .integer => |integer| @floatFromInt(integer),
            .float => |float| float,
            else => return error.InvalidDurations,
        };
        if (!(seconds >= 0)) return error.InvalidDurations;
        weight.* = @max(seconds, floor_seconds);
        known += weight.*;
        count += 1;
    }
    const mean = if (count == 0) 1 else known / @as(f64, @floatFromInt(count));
    for (weights) |*weight| if (weight.* < 0) {
        weight.* = mean;
    };
    return weights;
}

/// The tests `shard` runs, in index order: longest first onto the least
/// loaded shard. Every shard computes the same split from the same names
/// and weights; the names choose where ties start, so a package's small
/// test binaries do not all land on the first shard.
pub fn assign(a: std.mem.Allocator, names: []const []const u8, weights: []const f64, shard: Shard) ![]usize {
    std.debug.assert(names.len == weights.len);
    std.debug.assert(shard.index < shard.count);
    const order = try a.alloc(usize, weights.len);
    defer a.free(order);
    for (order, 0..) |*index, i| index.* = i;
    std.mem.sort(usize, order, weights, struct {
        fn longer(w: []const f64, x: usize, y: usize) bool {
            return w[x] > w[y] or (w[x] == w[y] and x < y);
        }
    }.longer);
    const loads = try a.alloc(f64, shard.count);
    defer a.free(loads);
    @memset(loads, 0);
    var hash: std.hash.Wyhash = .init(0);
    for (names) |name| {
        hash.update(name);
        hash.update(&.{0});
    }
    const start: usize = @intCast(hash.final() % shard.count);
    var selected: std.ArrayList(usize) = .empty;
    errdefer selected.deinit(a);
    for (order) |test_index| {
        var least = start;
        for (1..shard.count) |step| {
            const candidate = (start + step) % shard.count;
            if (loads[candidate] < loads[least]) least = candidate;
        }
        loads[least] += weights[test_index];
        if (least == shard.index) try selected.append(a, test_index);
    }
    std.mem.sort(usize, selected.items, {}, std.sort.asc(usize));
    return selected.toOwnedSlice(a);
}

test "a shard is i of n, one-based, and nothing else" {
    try std.testing.expectEqual(Shard{ .index = 1, .count = 5 }, try Shard.parse("2/5"));
    try std.testing.expectEqual(Shard.all, try Shard.parse(""));
    for ([_][]const u8{ "0/5", "6/5", "2", "a/b", "2/", "/5" }) |text| try std.testing.expectError(error.InvalidShard, Shard.parse(text));
}

test "every test runs on exactly one shard and the measured loads come out even" {
    const a = std.testing.allocator;
    const names = [_][]const u8{ "a", "b", "c", "d", "e", "f" };
    const weights = [_]f64{ 1, 2, 3, 4, 5, 6 };
    var seen: [names.len]usize = @splat(0);
    for (0..3) |index| {
        const selected = try assign(a, &names, &weights, .{ .index = index, .count = 3 });
        defer a.free(selected);
        var total: f64 = 0;
        for (selected) |test_index| {
            seen[test_index] += 1;
            total += weights[test_index];
        }
        try std.testing.expectEqual(@as(f64, 7), total);
    }
    for (seen) |count| try std.testing.expectEqual(@as(usize, 1), count);
}

test "one long test does not pull its neighbours onto the same shard" {
    const a = std.testing.allocator;
    const names = [_][]const u8{ "long", "s1", "s2", "s3", "s4" };
    const weights = [_]f64{ 10, 2, 2, 2, 2 };
    var alone = false;
    for (0..2) |index| {
        const selected = try assign(a, &names, &weights, .{ .index = index, .count = 2 });
        defer a.free(selected);
        if (std.mem.eql(usize, selected, &.{0})) alone = true;
    }
    try std.testing.expect(alone);
}

test "durations weigh recorded tests, the mean weighs new ones, and no record splits by count" {
    const a = std.testing.allocator;
    const names = [_][]const u8{ "old", "zero", "new" };
    const json =
        \\{"keys":["linux-Debug","windows-Debug"],"tests":{"old":[1,4],"zero":[0,null]}}
    ;
    const windows = try weigh(a, json, &names, "windows-Debug");
    defer a.free(windows);
    try std.testing.expectEqualSlices(f64, &.{ 4, 4, 4 }, windows);
    const linux = try weigh(a, json, &names, "linux-Debug");
    defer a.free(linux);
    try std.testing.expectEqual(@as(f64, 1), linux[0]);
    try std.testing.expectEqual(floor_seconds, linux[1]);
    try std.testing.expectEqual(@as(f64, (1 + floor_seconds) / 2.0), linux[2]);
    const absent = try weigh(a, json, &names, "macos-Debug");
    defer a.free(absent);
    try std.testing.expectEqualSlices(f64, &.{ 1, 1, 1 }, absent);
    const empty = try weigh(a, "{}", &names, "linux-Debug");
    defer a.free(empty);
    try std.testing.expectEqualSlices(f64, &.{ 1, 1, 1 }, empty);
    try std.testing.expectError(error.InvalidDurations, weigh(a, "{\"keys\":[\"k\"],\"tests\":{\"old\":[-1]}}", &names, "k"));
    try std.testing.expectError(error.InvalidDurations, weigh(a, "[]", &names, "k"));
}

test "unmeasured binaries split by count, and their single tests spread over the shards" {
    const a = std.testing.allocator;
    var firsts: [4]bool = @splat(false);
    for ([_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta" }) |name| {
        const names = [_][]const u8{name};
        for (0..4) |index| {
            const selected = try assign(a, &names, &.{1}, .{ .index = index, .count = 4 });
            defer a.free(selected);
            if (selected.len == 1) firsts[index] = true;
        }
    }
    var used: usize = 0;
    for (firsts) |used_shard| used += @intFromBool(used_shard);
    try std.testing.expect(used > 1);
    const many = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8" };
    const weights = [_]f64{ 1, 1, 1, 1, 1, 1, 1, 1 };
    for (0..4) |index| {
        const selected = try assign(a, &many, &weights, .{ .index = index, .count = 4 });
        defer a.free(selected);
        try std.testing.expectEqual(@as(usize, 2), selected.len);
    }
}
