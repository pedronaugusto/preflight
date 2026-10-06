//! Fixture data for the sample's tests; it sits in no layer.
pub const Case = struct { a: u32, b: u32, sum: u32 };

pub const cases = [_]Case{
    .{ .a = 2, .b = 3, .sum = 5 },
    .{ .a = 0, .b = 7, .sum = 7 },
};
