const std = @import("std");

pub fn sum(a: u32, b: u32) u32 {
    return a + b;
}

test "sum" {
    try std.testing.expectEqual(5, sum(2, 3));
}

test "sum of each fixture case" {
    const fixture = @import("testing/cases.zig");
    for (fixture.cases) |case| try std.testing.expectEqual(case.sum, sum(case.a, case.b));
}
