const std = @import("std");
const ci = @import("src/build.zig");
/// Adds the package's local gate and the steps the hosted gate runs.
pub const addCi = ci.addCi;
/// What `addCi` checks and how its tests run.
pub const Config = ci.Config;
/// The benchmarks `addCi` builds, runs and smoke-tests.
pub const Bench = ci.Bench;
/// The watchdog's bound on one test: the default, another with its reason, or none.
pub const TestTimeout = ci.TestTimeout;
/// Builds, tests and runs a repository check program as one step.
pub const addCheck = ci.addCheck;
/// Adds `check-consumer`: a project that depends on the package with nothing fetched.
pub const addConsumerCheck = ci.consumer.add;
/// What `addConsumerCheck` builds.
pub const ConsumerOptions = ci.consumer.Options;

pub fn build(b: *std.Build) void {
    // Declared before the lazy gantry can end the script, so the first
    // pass on an empty package cache accepts it.
    const repo_root = b.option([]const u8, "repo-root", "Repository checked by the hosted runner");
    const test_filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this") orelse &.{};
    const target = ci.ciTarget(b);
    const gantry_dep = b.dependencyLazy("gantry", .{ .target = target, .optimize = .debug }) catch return;
    const gantry = gantry_dep.module("gantry");
    const test_step = b.step("test", "Run the shared check regression suite");
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/checks.zig"),
        .target = target,
        .optimize = .debug,
        .imports = &.{.{ .name = "gantry", .module = gantry }},
    }), .filters = test_filters });
    const options = b.addOptions();
    options.addOptionPathUntracked("root", b.path("."));
    options.addOptionPathUntracked("zig_std", b.graph.path(.zig_lib, "std"));
    tests.root_module.addOptions("test_options", options);
    // The gate below gives the suite preflight's runner, as it does a
    // consumer's tests; the order module the runner imports runs its own
    // tests beside it.
    const suite = &b.addRunArtifact(tests).step;
    const order = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/order.zig"), .target = target, .optimize = .debug }) });
    const order_run = b.addRunArtifact(order);
    test_step.dependOn(suite);
    test_step.dependOn(&order_run.step);
    const executable = b.addExecutable(.{ .name = "preflight", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .safe,
        .imports = &.{.{ .name = "gantry", .module = gantry }},
    }) });
    b.installArtifact(executable);
    if (repo_root == null) {
        // preflight gates its own sources with the checks it ships.
        ci.addOwnCi(b, .{ .tests = suite });
        const verify = b.step("verify", "Check format, sources, checker regressions and the hosted runner");
        verify.dependOn(&b.top_level_steps.get("ci").?.step);
        verify.dependOn(&order_run.step);
        verify.dependOn(&b.addFmt(.{ .paths = b.pathList(&.{"."}), .check = true }).step);
        verify.dependOn(&executable.step);
    }
    const root = repo_root orelse ".";
    for ([_][]const u8{ "plan", "setup", "fetch", "run", "cache", "docs", "profile", "attest", "skip", "findings" }) |name| {
        if (b.top_level_steps.contains(name)) continue;
        const command = b.addRunArtifact(executable);
        command.addArg(name);
        command.setCwd(.{ .cwd_relative = root });
        command.addPassthruArgs();
        b.step(name, name).dependOn(&command.step);
    }
}
