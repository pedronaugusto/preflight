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
    const handshake = machineSide(b, step, target, optimize);
    const profile = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/testing/hardened.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const profile_step = b.step("profile-tests", "Run native fuzz and concurrent test consumers");
    profile_step.dependOn(&b.addRunArtifact(profile).step);
    preflight.addCi(b, b, .{
        .tests = step,
        .portable_tests = true,
        .bench = sampleBench(target, optimize),
        .hardened = .{ .fuzz_step = "profile-tests", .tsan_step = "profile-tests", .fuzz_iterations = 1000 },
        .vm_packages = &.{"tree"},
    });
    preflight.addConsumerCheck(b, b, .{ .package = "preflight_sample", .program = b.path("ci/consumer.zig") });
    if (handshake) |sides| sides.afterMachine();
}

/// The FreeBSD run's two sides: the tests' run and the host's `change`, which waits for a
/// test with a bound.
const Handshake = struct {
    run_tests: *std.Build.Step.Run,
    change: *std.Build.Step.Run,

    /// `change` starts once everything the tests' run needs is built: the tests, and the
    /// machine's image and runner, which `addCi` puts in front of the run (-Dci-vm). Its
    /// bound then counts the machine's boot and the tests alone: started with the build, a
    /// cold one used it up (preflight's run 44308680866: 741 s to build, the bound 600).
    fn afterMachine(sides: Handshake) void {
        for (sides.run_tests.step.dependencies.items) |needed| {
            for (sides.change.step.dependencies.items) |had| {
                if (had == needed) break;
            } else sides.change.step.dependOn(needed);
        }
    }
};

/// The tests of the FreeBSD machine's directories (src/testing/machine.zig), a root of their
/// own, which skip off the machine, and their host's side (ci/machine.zig), which the tests
/// step compiles on any target and, on FreeBSD, runs: the channel made before the tests, the
/// share changed while they run, and what they made beside their scratch read after them.
fn machineSide(b: *std.Build, step: *std.Build.Step, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) ?Handshake {
    const tests = b.addTest(.{ .name = "machine-tests", .root_module = b.createModule(.{
        .root_source_file = b.path("src/testing/machine.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_tests = b.addRunArtifact(tests);
    step.dependOn(&run_tests.step);
    const names = b.createModule(.{ .root_source_file = b.path("src/testing/machine.zig") });
    const tool = b.addExecutable(.{ .name = "sample-machine", .root_module = b.createModule(.{
        .root_source_file = b.path("ci/machine.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "machine", .module = names }},
    }) });
    step.dependOn(&tool.step);
    if (target.result.os.tag != .freebsd) return null;
    const prepare = b.addRunArtifact(tool);
    prepare.addArg("prepare");
    run_tests.step.dependOn(&prepare.step);
    const change = b.addRunArtifact(tool);
    change.addArg("change");
    change.step.dependOn(&prepare.step);
    step.dependOn(&change.step);
    const reads = b.addRunArtifact(tool);
    reads.addArg("check");
    reads.step.dependOn(&run_tests.step);
    step.dependOn(&reads.step);
    return .{ .run_tests = run_tests, .change = change };
}

fn sampleBench(target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) preflight.Bench {
    return .{ .programs = &.{.{ .name = "sum", .source = "bench/sum.zig" }}, .imports = preflight.Bench.importsFrom(benchImports), .target = target, .optimize = optimize };
}
/// The benchmarks' imports hold no state of their own: a function is the whole of it.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "sample", .module = b.createModule(.{ .root_source_file = b.path("src/sample.zig"), .target = target, .optimize = optimize }) }}) catch @panic("OOM");
}
