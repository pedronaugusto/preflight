const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("zero", .{ .root_source_file = b.path("src/zero.zig"), .target = target, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = module });
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    if (b.lazyImport(@This(), "preflight")) |preflight| preflight.addCi(b, .{ .tests = test_step });
}
