//! The shards' assignment, tested through the module the runner imports, so the tests run under
//! the runner they belong to.
const std = @import("std");
const order = @import("preflight_order");
const Shard = order.Shard;
const assign = order.assign;

test "a shard is i of n, one-based, and nothing else" {
    try std.testing.expectEqual(Shard{ .index = 1, .count = 5 }, try Shard.parse("2/5"));
    try std.testing.expectEqual(Shard.all, try Shard.parse(""));
    for ([_][]const u8{ "0/5", "6/5", "2", "a/b", "2/", "/5" }) |text| try std.testing.expectError(error.InvalidShard, Shard.parse(text));
}

test "every test runs on exactly one shard, by its name, whatever else the binary holds" {
    const a = std.testing.allocator;
    var names: [64][]const u8 = undefined;
    var storage: [64][16]u8 = undefined;
    for (&names, &storage, 0..) |*name, *bytes, i| name.* = try std.mem.print(bytes, "root.test.{d}", .{i});
    var seen: [64]u8 = @splat(0);
    var busy: usize = 0;
    for (0..4) |index| {
        const selected = try assign(a, &names, try Shard.init(index, 4));
        defer a.free(selected);
        if (selected.len != 0) busy += 1;
        for (selected, 0..) |test_index, n| {
            seen[test_index] += 1;
            // In index order, as the runner shuffles them after.
            if (n > 0) try std.testing.expect(selected[n - 1] < test_index);
        }
    }
    for (seen) |count| try std.testing.expectEqual(@as(u8, 1), count);
    try std.testing.expectEqual(@as(usize, 4), busy);
    // A test keeps its shard as another is added before it.
    const first = try assign(a, names[1..], try Shard.init(2, 4));
    defer a.free(first);
    const again = try assign(a, &names, try Shard.init(2, 4));
    defer a.free(again);
    try std.testing.expectEqual(first.len + @intFromBool(std.hash.Wyhash.hash(0, names[0]) % 4 == 2), again.len);
    for (first, again[again.len - first.len ..]) |x, y| try std.testing.expectEqual(x + 1, y);
}

test "shard boundaries reject a zero count and an index past it" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidShard, assign(a, &.{"one"}, .{ .index = 1, .count = 1 }));
    try std.testing.expectError(error.InvalidShard, assign(a, &.{}, .{ .index = 0, .count = 0 }));
    const empty = try assign(a, &.{}, Shard.all);
    defer a.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    const whole = try assign(a, &.{ "a", "b" }, Shard.all);
    defer a.free(whole);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, whole);
}

test "an unsharded binary runs whole on shard 1/n and not at all on the others" {
    try std.testing.expectEqual(Shard.all, order.share(try Shard.init(0, 4), true).?);
    for (1..4) |index| try std.testing.expectEqual(null, order.share(try Shard.init(index, 4), true));
    // Unsharded and unsplit, or sharded as usual, a binary runs the share its shard names.
    try std.testing.expectEqual(Shard.all, order.share(.all, true).?);
    try std.testing.expectEqual(try Shard.init(2, 4), order.share(try Shard.init(2, 4), false).?);
}
