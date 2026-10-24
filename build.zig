const std = @import("std");
const ci = @import("src/build.zig");
/// Adds preflight's gate to a build, over a package: from `dev` with bay, or from `build`.
pub const addCi = ci.addCi;
/// What `addCi` checks and how its tests run.
pub const Config = ci.Config;
/// The benchmarks `addCi` builds, runs and smoke-tests.
pub const Bench = ci.Bench;
/// Opt-in native safety, fuzzer and ThreadSanitizer checks.
pub const Hardened = ci.Hardened;
/// The watchdog's bound on one test: the default, another with its reason, or none.
pub const TestTimeout = ci.TestTimeout;
/// Builds, tests and runs a repository check program as one step.
pub const addCheck = ci.addCheck;
/// A program the tests run, named to them by its path from the package root,
/// which holds where portable tests replay.
pub const addTestProgram = ci.addTestProgram;
/// Adds `check-consumer`: a project that depends on the package with nothing fetched.
pub const addConsumerCheck = ci.consumer.add;
/// What `addConsumerCheck` builds.
pub const ConsumerOptions = ci.consumer.Options;
/// Assembles a build nested in the package under the cache, its manifest written from the
/// package's own pins, and runs it.
pub const addNestedBuild = ci.nested.add;
/// What `addNestedBuild` assembles and runs.
pub const NestedBuild = ci.nested.Options;

/// What a package that depends on preflight, and the hosted runner, build: the
/// preflight program, built from gantry and glint, and the commands the runner
/// calls in the repository it checks. preflight's own tests and gate are `dev`'s.
pub fn build(b: *std.Build) void {
    // Declared before the lazy gantry can end the script, so the first
    // pass on an empty package cache accepts it.
    const repo_root = b.option([]const u8, "repo-root", "Repository checked by the hosted runner");
    // A package that depends on preflight builds nothing of it here: its gate
    // installs the tools through addCi.
    if (b.pkg_hash.len != 0) return;
    const executable = program(b, b, ci.ciTarget(b)) orelse return;
    b.installArtifact(executable);
    if (!addToolchain(b)) return;
    addCommands(b, executable, repo_root orelse ".");
}

/// preflight's development: the regression suites, which take shakedown's test
/// doubles, and preflight's gate over its own sources with the checks it ships.
pub fn dev(b: *std.Build, _: type) void {
    const test_filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this") orelse &.{};
    const package = b.dependency("preflight", .{}).builder;
    const target = ci.ciTarget(b);
    const gantry_dep = package.dependencyLazy("gantry", .{ .target = target, .optimize = .debug, .zig = true }) catch return pending(b);
    const gantry = ci.dependencyModule(gantry_dep, "gantry") orelse return pending(b);
    const gantry_zig = ci.dependencyModule(gantry_dep, "gantry.zig") orelse return pending(b);
    // Code rules are glint's; the checks import it as a library. A module that
    // sets no optimize mode takes its importer's, so the tests, which build
    // aegis in Debug for themselves, take glint in Debug and share it.
    const glint = (package.dependencyLazy("glint", .{ .target = target, .optimize = .debug }) catch return pending(b)).module("glint");
    // The command line's tests hold the forms the build and the workflows call it with.
    const ensign = (package.dependencyLazy("ensign", .{ .target = target, .optimize = .debug }) catch return pending(b)).module("ensign");
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = .debug }).module("shakedown");
    // aegis as glint is built with it: one aegis in the program.
    const aegis = glint.import_table.get("aegis") orelse @panic("glint imports aegis");
    const test_step = b.step("test", "Run the shared check regression suite");
    // The integration tests run fixture packages the way their authors do: through bay; and
    // the checks read CHANGELOG.md with bay's reader of it.
    const bay = package.dependencyLazy("bay", .{ .optimize = .safe }) catch return pending(b);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = package.path("src/checks.zig"),
        .target = target,
        .optimize = .debug,
        .imports = &.{ .{ .name = "gantry", .module = gantry }, .{ .name = "gantry.zig", .module = gantry_zig }, .{ .name = "glint", .module = glint }, .{ .name = "ensign", .module = ensign }, .{ .name = "shakedown", .module = shakedown }, .{ .name = "changelog", .module = bay.module("changelog") }, .{ .name = "aegis", .module = aegis } },
    }), .filters = test_filters });
    const options = b.addOptions();
    options.addOptionPathUntracked("root", package.path("."));
    options.addOptionPathUntracked("zig_std", b.graph.path(.zig_lib, "std"));
    options.addOptionPath("bay", bay.artifact("bay").getEmittedBin());
    // The gate's tests run the preflight program as its user does, and the facts' tests a
    // stand-in for a bay that cannot locate the development build.
    const executable = program(b, package, target) orelse return;
    options.addOptionPath("preflight", executable.getEmittedBin());
    const fake = b.addExecutable(.{ .name = "bay", .root_module = b.createModule(.{ .root_source_file = package.path("src/testing/bay.zig"), .target = target, .optimize = .debug }) });
    options.addOptionPath("fake_bay", fake.getEmittedBin());
    tests.root_module.addOptions("test_options", options);
    // The gate below gives every test here preflight's runner, as it does a
    // consumer's tests: the order module's and the watchdog's tests import
    // them as the runner does, so they run under it too.
    const suite = &b.addRunArtifact(tests).step;
    const order = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = package.path("src/order_test.zig"), .target = target, .optimize = .debug }), .filters = test_filters });
    const order_run = b.addRunArtifact(order);
    test_step.dependOn(suite);
    test_step.dependOn(&order_run.step);
    const watch = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = package.path("src/watchdog_test.zig"),
        .target = target,
        .optimize = .debug,
        .imports = &.{.{ .name = "shakedown", .module = shakedown }},
    }), .filters = test_filters });
    const watch_run = &b.addRunArtifact(watch).step;
    test_step.dependOn(watch_run);
    const profile = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = package.path("src/profile_test.zig"),
        .target = target,
        .optimize = .debug,
        .imports = &.{ .{ .name = "gantry", .module = gantry }, .{ .name = "shakedown", .module = shakedown }, .{ .name = "aegis", .module = aegis } },
    }) });
    b.step("profile-tests", "Native protocol fuzzer and concurrent tests").dependOn(&b.addRunArtifact(profile).step);
    // preflight gates its own sources with the checks it ships: the preflight
    // the gate finds among this build's dependencies is this package.
    ci.addCi(b, package, .{ .tests = test_step, .test_timeout = .{ .bound = .{ .limit = .fromSeconds(300), .reason = "an integration test may compile the checks a fixture's gate runs from cold, before the shared fixture cache is warm" } }, .hardened = .{ .fuzz_step = "profile-tests", .tsan_step = "profile-tests", .fuzz_iterations = 1000 }, .bench = .{
        .programs = &.{ .{ .name = "source", .source = "bench/source.zig" }, .{ .name = "workflow", .source = "bench/workflow.zig" }, .{ .name = "configuration", .source = "bench/configuration.zig" } },
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
    verify.dependOn(&b.addFmt(.{ .paths = package.pathList(&.{"."}), .check = true }).step);
    verify.dependOn(&executable.step);
}

/// The preflight program of `package`, built in `b` (`ci.programModule`). Null
/// while a lazy dependency is still to be fetched.
fn program(b: *std.Build, package: *std.Build, target: std.Build.ResolvedTarget) ?*std.Build.Step.Compile {
    return b.addExecutable(.{ .name = "preflight", .root_module = ci.programModule(b, package, target) orelse return pendingNull(b) });
}

/// Ends a configure pass that waits for a lazy dependency, with the CI options
/// declared, so the pass on an empty package cache accepts them.
fn pending(b: *std.Build) void {
    _ = ci.declareCiOptions(b, null);
}

fn pendingNull(b: *std.Build) ?*std.Build.Step.Compile {
    pending(b);
    return null;
}

/// The hosted runners the checks are built for.
const runners = [_]struct { name: []const u8, query: std.Target.Query }{
    .{ .name = "linux", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu, .cpu_model = .baseline } },
    .{ .name = "linux-arm", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu, .cpu_model = .baseline } },
    .{ .name = "macos", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos, .cpu_model = .baseline } },
    .{ .name = "windows", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu, .cpu_model = .baseline } },
    .{ .name = "windows-arm", .query = .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu, .cpu_model = .baseline } },
};

/// Adds `toolchain`, which builds the checks for every hosted runner under
/// `<prefix>/toolchain/<runner>/`, so that one job compiles them and the
/// others take the result. False while a lazy dependency is still to be fetched.
fn addToolchain(b: *std.Build) bool {
    const step = b.step("toolchain", "Build the checks and bay for the Linux, macOS and Windows runners, ARM ones included, under <prefix>/toolchain");
    for (runners) |runner| {
        const target = b.resolveTargetQuery(runner.query);
        const executable = b.addExecutable(.{ .name = "preflight", .root_module = ci.programModule(b, b, target) orelse {
            _ = ci.declareCiOptions(b, null);
            return false;
        } });
        step.dependOn(&b.addInstallArtifact(executable, .{ .dest_dir = .{ .override = .{ .custom = b.fmt("toolchain/{s}", .{runner.name}) } } }).step);
        // bay sits beside the checks: the runner runs a package developed with it through it.
        const bay = b.dependencyLazy("bay", .{ .target = target, .optimize = .safe }) catch {
            _ = ci.declareCiOptions(b, null);
            return false;
        };
        step.dependOn(&b.addInstallArtifact(bay.artifact("bay"), .{ .dest_dir = .{ .override = .{ .custom = b.fmt("toolchain/{s}", .{runner.name}) } } }).step);
    }
    return true;
}

/// The steps that run one of the installed command's subcommands in `root`.
fn addCommands(b: *std.Build, executable: *std.Build.Step.Compile, root: []const u8) void {
    for ([_][]const u8{ "plan", "setup", "prepare", "fetch", "run", "cache", "docs", "profile", "attest", "skip" }) |name| {
        if (b.top_level_steps.contains(name)) continue;
        const command = b.addRunArtifact(executable);
        command.addArg(name);
        command.setCwd(.{ .cwd_relative = root });
        command.addPassthruArgs();
        b.step(name, name).dependOn(&command.step);
    }
}

/// The benchmarks' imports, in `b`, the development build: the checks and the
/// facts reader of this package, with gantry and glint in the benchmark's mode.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const package = b.dependency("preflight", .{}).builder;
    const gantry_dep = package.dependencyLazy("gantry", .{ .target = target, .optimize = optimize, .zig = true }) catch unreachable; // unreachable: dev returns before addCi if gantry is not available
    const gantry = gantry_dep.module("gantry");
    const glint = (package.dependencyLazy("glint", .{ .target = target, .optimize = optimize }) catch unreachable).module("glint"); // unreachable: dev returns before addCi if glint is not available
    const changelog = (package.dependencyLazy("bay", .{ .target = target, .optimize = optimize }) catch unreachable).module("changelog"); // unreachable: dev returns before addCi if bay is not available
    const aegis = glint.import_table.get("aegis") orelse @panic("glint imports aegis");
    const imports: []const std.Build.Module.Import = &.{ .{ .name = "gantry", .module = gantry }, .{ .name = "gantry.zig", .module = gantry_dep.module("gantry.zig") }, .{ .name = "glint", .module = glint }, .{ .name = "changelog", .module = changelog }, .{ .name = "aegis", .module = aegis } };
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "checks", .module = b.createModule(.{ .root_source_file = package.path("src/checks.zig"), .target = target, .optimize = optimize, .imports = imports }) },
        .{ .name = "facts", .module = b.createModule(.{ .root_source_file = package.path("src/facts.zig"), .target = target, .optimize = optimize, .imports = imports }) },
    }) catch @panic("OOM");
}
