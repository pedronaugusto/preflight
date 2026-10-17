//! The shards' assignment and the durations that weigh it, tested through the
//! module the runner imports, so the tests run under the runner they belong to.
const std = @import("std");
const order = @import("preflight_order");
const Shard = order.Shard;
const assign = order.assign;
const weigh = order.weigh;
const floor_seconds = order.floor_seconds;

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
        const selected = try assign(a, &names, &weights, try Shard.init(index, 3));
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
        const selected = try assign(a, &names, &weights, try Shard.init(index, 2));
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
            const selected = try assign(a, &names, &.{1}, try Shard.init(index, 4));
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
        const selected = try assign(a, &many, &weights, try Shard.init(index, 4));
        defer a.free(selected);
        try std.testing.expectEqual(@as(usize, 2), selected.len);
    }
}

test "shard boundaries reject zero escaped indices and impossible load storage" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidShard, Shard.init(0, 0));
    try std.testing.expectError(error.InvalidShard, Shard.init(3, 3));
    try std.testing.expectError(error.InvalidShard, assign(a, &.{}, &.{}, .{ .index = 0, .count = std.math.maxInt(usize) }));
    try std.testing.expectError(error.InvalidShard, assign(a, &.{"one"}, &.{1}, .{ .index = 1, .count = 1 }));
    try std.testing.expectError(error.InvalidShard, assign(a, &.{}, &.{}, .{ .index = 0, .count = 0 }));
    try std.testing.expectError(error.InvalidWeights, assign(a, &.{"one"}, &.{}, Shard.all));
    try std.testing.expectError(error.InvalidShard, Shard.parse("999999999999999999999999999999999999/1"));
    const empty = try assign(a, &.{}, &.{}, Shard.all);
    defer a.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
