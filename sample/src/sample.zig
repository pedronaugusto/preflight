const std = @import("std");

pub fn sum(a: u32, b: u32) u32 {
    return a + b;
}

test "sum" {
    try std.testing.expectEqual(5, sum(2, 3));
}
