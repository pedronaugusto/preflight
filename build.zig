const std = @import("std");
pub const addCi = @import("src/build.zig").addCi;
pub const Config = @import("src/build.zig").Config;

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Run the shared check regression suite");
    const run = b.addSystemCommand(&.{ "python3", "-m", "unittest", "discover", "-s", "tests", "-v" });
    run.setCwd(b.path("."));
    test_step.dependOn(&run.step);
}
