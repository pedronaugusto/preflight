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
    _ = b.addModule("rules", .{ .root_source_file = b.path("src/rules.zig"), .target = target, .imports = &.{.{ .name = "gantry", .module = gantry }} });
    // A package consumer needs only the family policies. Its gate installs
    // the tools through addCi; our suite and benchmarks belong to this checkout.
    if (b.pkg_hash.len != 0) return;
    // The test doubles are shakedown's, which only preflight's own suite
    // imports: a build that runs preflight for another repository never
    // fetches it.
    const shakedown = if (repo_root == null) (b.dependencyLazy("shakedown", .{ .target = target, .optimize = .debug }) catch return).module("shakedown") else null;
    const test_step = b.step("test", "Run the shared check regression suite");
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/checks.zig"),
        .target = target,
        .optimize = .debug,
        .imports = &.{.{ .name = "gantry", .module = gantry }},
    }), .filters = test_filters });
    if (shakedown) |module| tests.root_module.addImport("shakedown", module);
    const options = b.addOptions();
    options.addOptionPathUntracked("root", b.path("."));
    options.addOptionPathUntracked("zig_std", b.graph.path(.zig_lib, "std"));
    tests.root_module.addOptions("test_options", options);
    // The gate below gives the suite preflight's runner, as it does a
    // consumer's tests; the order module and the watchdog the runner
    // imports run their own tests beside it.
    const suite = &b.addRunArtifact(tests).step;
    const order = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/order.zig"), .target = target, .optimize = .debug }) });
    const order_run = b.addRunArtifact(order);
    test_step.dependOn(suite);
    test_step.dependOn(&order_run.step);
    const watch_run: ?*std.Build.Step = if (shakedown) |module| run: {
        const watch = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/watchdog_test.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "shakedown", .module = module }},
        }), .filters = test_filters });
        const run = &b.addRunArtifact(watch).step;
        test_step.dependOn(run);
        break :run run;
    } else null;
    const executable = b.addExecutable(.{ .name = "preflight", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .safe,
        .imports = &.{.{ .name = "gantry", .module = gantry }},
    }) });
    b.installArtifact(executable);
    if (repo_root == null) {
        const lint_tool = b.dependencyLazy("ziglint", .{ .target = target, .optimize = .safe }) catch return;
        options.addOptionPath("ziglint", lint_tool.artifact("ziglint").getEmittedBin());
        // preflight gates its own sources with the checks it ships.
        ci.addOwnCi(b, .{ .tests = suite, .bench = .{
            .programs = &.{ .{ .name = "source", .source = "bench/source.zig" }, .{ .name = "workflow", .source = "bench/workflow.zig" } },
            .imports = benchImports,
            .target = target,
            .optimize = .debug,
        } });
        const check = b.step("check", "Compile the shared checks and runner without running tests");
        check.dependOn(&tests.step);
        check.dependOn(&order.step);
        check.dependOn(&executable.step);
        const verify = b.step("verify", "Check format, sources, checker regressions and the hosted runner");
        verify.dependOn(&b.top_level_steps.get("ci").?.step);
        verify.dependOn(&order_run.step);
        if (watch_run) |run| verify.dependOn(run);
        verify.dependOn(&b.addFmt(.{ .paths = b.pathList(&.{"."}), .check = true }).step);
        verify.dependOn(&executable.step);
        // preflight, gantry and sweep name no other package of the family.
        const toolchain = b.createModule(.{ .root_source_file = b.path("ci/toolchain.zig"), .target = target, .optimize = .debug, .imports = &.{.{ .name = "gantry", .module = gantry }} });
        const closure = b.addRunArtifact(b.addExecutable(.{ .name = "check-toolchain", .root_module = toolchain }));
        for ([_]struct { []const u8, std.Build.LazyPath }{
            .{ "preflight", b.path("build.zig.zon") },
            .{ "gantry", gantry_dep.path("build.zig.zon") },
            .{ "sweep", gantry_dep.builder.dependency("sweep", .{ .target = target, .optimize = .debug }).path("build.zig.zon") },
        }) |package| {
            closure.addArg(package[0]);
            closure.addFileArg(package[1]);
        }
        const check_toolchain = b.step("check-toolchain", "Check that the toolchain names no other package of the family");
        check_toolchain.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = toolchain })).step);
        check_toolchain.dependOn(&closure.step);
    }
    const root = repo_root orelse ".";
    for ([_][]const u8{ "plan", "setup", "prepare", "fetch", "run", "cache", "docs", "profile", "attest", "skip", "findings" }) |name| {
        if (b.top_level_steps.contains(name)) continue;
        const command = b.addRunArtifact(executable);
        command.addArg(name);
        command.setCwd(.{ .cwd_relative = root });
        command.addPassthruArgs();
        b.step(name, name).dependOn(&command.step);
    }
}

fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const gantry = (b.dependencyLazy("gantry", .{ .target = target, .optimize = optimize }) catch unreachable).module("gantry"); // unreachable: build returns before addOwnCi if gantry is not available
    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "checks", .module = b.createModule(.{
        .root_source_file = b.path("src/checks.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "gantry", .module = gantry }},
    }) }}) catch @panic("OOM");
}
