//! A project with no preflight configuration at all: what a stranger's
//! repository looks like on the day it adopts preflight.
const std = @import("std");

/// The sum of `values`.
pub fn sum(values: []const u32) u64 {
    var total: u64 = 0;
    for (values) |value| total += value;
    return total;
}

test "sum adds every value" {
    try std.testing.expectEqual(@as(u64, 6), sum(&.{ 1, 2, 3 }));
    try std.testing.expectEqual(@as(u64, 0), sum(&.{}));
}
