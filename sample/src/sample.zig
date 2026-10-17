const std = @import("std");
const builtin = @import("builtin");

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

test "the riscv64 machine has the Alpine package the sample's build declares" {
    if (builtin.cpu.arch != .riscv64 or builtin.os.tag != .linux) return error.SkipZigTest;
    // Only preflight's machine: an Alpine system made for the tests.
    std.Io.Dir.cwd().access(std.testing.io, "/etc/alpine-release", .{}) catch return error.SkipZigTest;
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "tree", "--version" } });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "tree v"));
}

test {
    _ = @import("testing/hardened.zig");
}
