const std = @import("std");
const ci = @import("src/build.zig");
/// Adds the package's local gate and the steps the hosted gate runs.
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
/// Adds `check-consumer`: a project that depends on the package with nothing fetched.
pub const addConsumerCheck = ci.consumer.add;
/// What `addConsumerCheck` builds.
pub const ConsumerOptions = ci.consumer.Options;

pub fn build(b: *std.Build) void {
    // Declared before the lazy gantry can end the script, so the first
    // pass on an empty package cache accepts it.
    const repo_root = b.option([]const u8, "repo-root", "Repository checked by the hosted runner");
    const test_filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this") orelse &.{};
    // A package that depends on preflight builds nothing of it here: its gate
    // installs the tools through addCi, and our suite belongs to this checkout.
    if (b.pkg_hash.len != 0) return;
    const target = ci.ciTarget(b);
    // Zig is read through gantry's frontend module, which takes glint's token tier.
    const gantry_dep = b.dependencyLazy("gantry", .{ .target = target, .optimize = .debug, .zig = true }) catch {
        _ = ci.declareCiOptions(b, null);
        return;
    };
    const gantry = ci.dependencyModule(gantry_dep, "gantry") orelse {
        _ = ci.declareCiOptions(b, null);
        return;
    };
    const gantry_zig = ci.dependencyModule(gantry_dep, "gantry.zig") orelse {
        _ = ci.declareCiOptions(b, null);
        return;
    };
    // Code rules are glint's; the checks import it as a library. A module that
    // sets no optimize mode takes its importer's, so the tests, which build
    // aegis in Debug for themselves, take glint in Debug and share it.
    const glint = (b.dependencyLazy("glint", .{ .target = target, .optimize = .debug }) catch {
        _ = ci.declareCiOptions(b, null);
        return;
    }).module("glint");
    const glint_safe = (b.dependencyLazy("glint", .{ .target = target, .optimize = .safe }) catch {
        _ = ci.declareCiOptions(b, null);
        return;
    }).module("glint");
    // The test doubles are shakedown's, which only preflight's own suite
    // imports: a build that runs preflight for another repository never
    // fetches it.
    const shakedown = if (repo_root == null) (b.dependencyLazy("shakedown", .{ .target = target, .optimize = .debug }) catch {
        _ = ci.declareCiOptions(b, null);
        return;
    }).module("shakedown") else null;
    const test_step = b.step("test", "Run the shared check regression suite");
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/checks.zig"),
        .target = target,
        .optimize = .debug,
        .imports = &.{ .{ .name = "gantry", .module = gantry }, .{ .name = "gantry.zig", .module = gantry_zig }, .{ .name = "glint", .module = glint } },
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
    // The executable runs in ReleaseSafe with glint, which gantry's Zig frontend shares, so it takes
    // gantry built the same way.
    const gantry_safe_dep = b.dependencyLazy("gantry", .{ .target = target, .optimize = .safe, .zig = true }) catch {
        _ = ci.declareCiOptions(b, null);
        return;
    };
    const executable = b.addExecutable(.{ .name = "preflight", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .safe,
        .imports = &.{ .{ .name = "gantry", .module = gantry_safe_dep.module("gantry") }, .{ .name = "gantry.zig", .module = gantry_safe_dep.module("gantry.zig") }, .{ .name = "glint", .module = glint_safe } },
    }) });
    b.installArtifact(executable);
    if (!addToolchain(b)) return;
    if (repo_root == null) {
        // preflight gates its own sources with the checks it ships.
        const profile = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/profile_test.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{ .{ .name = "gantry", .module = gantry }, .{ .name = "shakedown", .module = shakedown.? } },
        }) });
        b.step("profile-tests", "Native protocol fuzzer and concurrent tests").dependOn(&b.addRunArtifact(profile).step);
        ci.addOwnCi(b, .{ .tests = suite, .hardened = .{ .fuzz_step = "profile-tests", .tsan_step = "profile-tests", .fuzz_iterations = 1000 }, .bench = .{
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
        verify.dependOn(&order_run.step);
        if (watch_run) |run| verify.dependOn(run);
        verify.dependOn(&b.addFmt(.{ .paths = b.pathList(&.{"."}), .check = true }).step);
        verify.dependOn(&executable.step);
    }
    addCommands(b, executable, repo_root orelse ".");
}

/// The hosted runners the checks are built for.
const runners = [_]struct { name: []const u8, query: std.Target.Query }{
    .{ .name = "linux", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu, .cpu_model = .baseline } },
    .{ .name = "macos", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos, .cpu_model = .baseline } },
    .{ .name = "windows", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu, .cpu_model = .baseline } },
};

/// Adds `toolchain`, which builds the checks for every hosted runner under
/// `<prefix>/toolchain/<runner>/`, so that one job compiles them and the
/// others take the result. False while a lazy dependency is still to be fetched.
fn addToolchain(b: *std.Build) bool {
    const step = b.step("toolchain", "Build the checks for the Linux, macOS and Windows runners under <prefix>/toolchain");
    for (runners) |runner| {
        const target = b.resolveTargetQuery(runner.query);
        const gantry_dep = b.dependencyLazy("gantry", .{ .target = target, .optimize = .safe, .zig = true }) catch {
            _ = ci.declareCiOptions(b, null);
            return false;
        };
        const glint_dep = b.dependencyLazy("glint", .{ .target = target, .optimize = .safe }) catch {
            _ = ci.declareCiOptions(b, null);
            return false;
        };
        const executable = b.addExecutable(.{ .name = "preflight", .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .safe,
            .imports = &.{ .{ .name = "gantry", .module = gantry_dep.module("gantry") }, .{ .name = "gantry.zig", .module = gantry_dep.module("gantry.zig") }, .{ .name = "glint", .module = glint_dep.module("glint") } },
        }) });
        step.dependOn(&b.addInstallArtifact(executable, .{ .dest_dir = .{ .override = .{ .custom = b.fmt("toolchain/{s}", .{runner.name}) } } }).step);
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

fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const gantry_dep = b.dependencyLazy("gantry", .{ .target = target, .optimize = optimize, .zig = true }) catch unreachable; // unreachable: build returns before addOwnCi if gantry is not available
    const gantry = gantry_dep.module("gantry");
    const glint = (b.dependencyLazy("glint", .{ .target = target, .optimize = optimize }) catch unreachable).module("glint"); // unreachable: build returns before addOwnCi if glint is not available
    const imports: []const std.Build.Module.Import = &.{ .{ .name = "gantry", .module = gantry }, .{ .name = "gantry.zig", .module = gantry_dep.module("gantry.zig") }, .{ .name = "glint", .module = glint } };
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "checks", .module = b.createModule(.{ .root_source_file = b.path("src/checks.zig"), .target = target, .optimize = optimize, .imports = imports }) },
        .{ .name = "facts", .module = b.createModule(.{ .root_source_file = b.path("src/facts.zig"), .target = target, .optimize = optimize, .imports = imports }) },
    }) catch @panic("OOM");
}
