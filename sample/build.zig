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
    const profile = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/testing/hardened.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const profile_step = b.step("profile-tests", "Run native fuzz and concurrent test consumers");
    profile_step.dependOn(&b.addRunArtifact(profile).step);
    preflight.addCi(b, .{
        .tests = step,
        .portable_tests = true,
        .hardened = .{ .fuzz_step = "profile-tests", .tsan_step = "profile-tests", .fuzz_iterations = 1000 },
    });
    preflight.addConsumerCheck(b, .{ .package = "preflight_sample", .program = b.path("ci/consumer.zig") });
}

fn sampleBench(target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) preflight.Bench {
    return .{ .programs = &.{.{ .name = "sum", .source = "bench/sum.zig" }}, .imports = benchImports, .target = target, .optimize = optimize };
}
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "sample", .module = b.createModule(.{ .root_source_file = b.path("src/sample.zig"), .target = target, .optimize = optimize }) }}) catch @panic("OOM");
}
