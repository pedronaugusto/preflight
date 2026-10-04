const std = @import("std");
const preflight = @import("preflight");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/sample.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const step = b.step("test", "Run the sample tests");
    step.dependOn(&b.addRunArtifact(tests).step);
    b.step("check", "Compile the sample").dependOn(&tests.step);
    preflight.addCi(b, .{ .tests = step });
}
