const std = @import("std");
const preflight = @import("preflight");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("preflight_sample", .{
        .root_source_file = b.path("src/sample.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = module });
    const step = b.step("test", "Run the sample tests");
    step.dependOn(&b.addRunArtifact(tests).step);
    b.step("check", "Compile the sample").dependOn(&tests.step);
    preflight.addCi(b, .{ .tests = step, .portable_tests = true });
    preflight.addConsumerCheck(b, .{ .package = "preflight_sample", .program = b.path("ci/consumer.zig"), .use_llvm = "needsLlvm" });
}

/// Whether the sample needs LLVM for a target and mode: never.
pub fn needsLlvm(target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?bool {
    _ = target;
    _ = optimize;
    return null;
}
