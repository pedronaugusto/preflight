//! Build-only CI checks. Consumers never acquire the checker's dependencies.
const std = @import("std");
const configure = @import("configure.zig");
const portable = @import("portable.zig");
const objects = @import("objects.zig");
const record = @import("record.zig");
pub const consumer = @import("consumer.zig");
pub const nested = @import("nested.zig");
const bench = @import("bench.zig");
const fuzz = @import("fuzz.zig");
const hardened = @import("hardened.zig");
const Tool = @import("tool.zig").Tool;

pub const Config = struct {
    tests: *std.Build.Step,
    layers: []const u8 = "ci/layers.zig",
    config: []const u8 = "ci/preflight.json",
    /// Recorded per-test durations that balance the hosted shards.
    durations: []const u8 = "ci/durations.json",
    portable_tests: bool = false,
    timings_enabled: ?bool = null,
    /// The watchdog: one test, its Io teardown included, fails by name,
    /// phase and seed once it runs this long, in local runs too.
    test_timeout: TestTimeout = .default,
    /// The `std.log` level a test prints at. Zig's runner prints `.warn`
    /// and above; a library that logs what it does can ask for `.info`.
    test_log_level: std.log.Level = .warn,
    /// The programs in `bench/`: `zig build bench` builds each in ReleaseFast
    /// under `zig-out/bench` and runs the timed ones one after another, and
    /// `zig build test` runs each once with `--smoke`. A repository with a `bench/`
    /// directory and none given fails its tests.
    bench: ?Bench = null,
    /// Opt-in native safety checks; release artifacts keep their chosen mode.
    hardened: ?Hardened = null,
    /// Continuous fuzzing: the step `zig build fuzz` fuzzes, one whose every
    /// test binary has a `check` property or a fuzz test, since the fuzzer
    /// refuses a binary with none. It runs the package's own shakedown, whose
    /// properties the tests are written with. Null fuzzes the step the hardened
    /// run fuzzes, else `test`, in a package that declares shakedown; one that
    /// declares none has no `fuzz` step. Naming a step requires shakedown.
    fuzz_step: ?[]const u8 = null,
};

pub const Bench = bench.Bench;
pub const Hardened = hardened.Profile;

pub const TestTimeout = record.TestTimeout;

/// A module of a dependency, or null while the dependency is still waiting for
/// one of its own lazy dependencies: its script ends before it adds modules, and
/// the script that asked for it ends too, so that Zig fetches what is missing
/// and configures again. gantry's Zig frontend waits for glint this way.
pub fn dependencyModule(dep: *std.Build.Dependency, name: []const u8) ?*std.Build.Module {
    return dep.builder.modules.get(name);
}

/// CI tools use a stable CPU target across hosted runner models.
pub fn ciTarget(b: *std.Build) std.Build.ResolvedTarget {
    const host = b.graph.host.result;
    return b.resolveTargetQuery(.{
        .cpu_arch = host.cpu.arch,
        .cpu_model = .baseline,
        .os_tag = host.os.tag,
        .abi = host.abi,
    });
}

/// Adds preflight's gate to `b`, over `package`. `b` is the build the steps and
/// their `-D` options belong to, and finds `preflight` and `shakedown` among its
/// dependencies; `package` is the package checked, whose sources, manifest,
/// installed artifacts and modules the gate reads. In a package developed with
/// bay, `dev` passes its development build and the package as a dependency of
/// it; without bay, `build` passes its own builder as both.
pub fn addCi(b: *std.Build, package: *std.Build, config: Config) void {
    if (b.pkg_hash.len != 0) return;
    const steps: Steps = .create(b, config);
    defer configure.refuseTaken(b, package, config.tests);
    // The gate reruns its tests with its own options, which only `b` declares.
    if (config.tests.owner != b) config.tests.dependOn(&b.addFail("addCi .tests: the tests the gate runs are a step of the build that calls addCi; with bay, define them in dev").step);
    const tools = b.dependencyLazy("preflight", .{}) catch return;
    steps.install(b, package, tools.builder, config);
}

/// Builds and runs a repository check program of `package` and its tests as one
/// step of `b`. The program runs from the repository root.
pub fn addCheck(b: *std.Build, package: *std.Build, name: []const u8, source: []const u8) *std.Build.Step.Compile {
    const module = b.createModule(.{ .root_source_file = package.path(source), .target = b.graph.host, .optimize = .debug });
    const executable = b.addExecutable(.{ .name = name, .root_module = module });
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(executable);
    run.setCwd(package.path("."));
    const step = b.step(name, "Run repository CI checks and their regressions");
    step.dependOn(&b.addRunArtifact(tests).step);
    step.dependOn(&run.step);
    return executable;
}

/// Declare the same CI controls when a root script must return early to
/// discover its own lazy dependencies, before it can construct test steps.
pub fn declareCiOptions(b: *std.Build, timing_override: ?bool) CiOptions {
    return .{
        .profile_options = hardened.declare(b),
        .smoke = b.option(bool, "ci-bench-smoke", "Smoke benchmark rows in local tests (hosted CI compiles only)") orelse true,
        .sdk = b.option([]const u8, "ci-sdk", "Native macOS SDK root, supplied by the hosted runner"),
        .lint_enabled = b.option(bool, "ci-lint", "Run source checks before CI tests") orelse true,
        .checks = b.option([]const u8, "ci-checks", "Path of a preflight built from this commit, which the hosted runner holds, in place of compiling the checks"),
        .timing = timing_override orelse (b.option(bool, "ci-timings", "Record per-test durations for the next shard balance") orelse false),
    };
}
/// Controls accepted during a root script's lazy-discovery pass.
pub const CiOptions = struct {
    profile_options: hardened.Options,
    smoke: bool,
    sdk: ?[]const u8,
    lint_enabled: bool,
    timing: bool,
    checks: ?[]const u8,
};

const Steps = struct {
    lint: *std.Build.Step,
    ci: *std.Build.Step,
    objects: *std.Build.Step,
    bench_objects: *std.Build.Step,
    links: *std.Build.Step,
    lint_enabled: bool,
    timing: bool,
    sdk: ?[]const u8,
    checks: ?[]const u8,
    smoke: bool,
    profile_options: hardened.Options,

    fn create(b: *std.Build, config: Config) Steps {
        const controls = declareCiOptions(b, config.timings_enabled);
        const lint = configure.claim(b, "lint", "Check format, structure, Zig policy, docs and test imports");
        const ci = configure.claim(b, "ci", "Run source checks, then the tests");
        ci.dependOn(config.tests);
        forceTests(config.tests);
        const objects_step = configure.claim(b, "ci-check", "Compile root, test, benchmark (Debug) and helper objects without linking or executing");
        const bench_objects_step = configure.claim(b, "ci-check-bench", "Compile the benchmarks as they are built to run (ReleaseFast) without linking or executing");
        const links_step = configure.claim(b, "ci-link", "Link tests, benchmarks and helpers on a runner with its native SDK");
        return .{ .lint = lint, .ci = ci, .objects = objects_step, .bench_objects = bench_objects_step, .links = links_step, .lint_enabled = controls.lint_enabled, .timing = controls.timing, .sdk = controls.sdk, .checks = controls.checks, .smoke = controls.smoke, .profile_options = controls.profile_options };
    }

    /// The program that runs the checks: the binary the runner holds, or the
    /// checks compiled here, in ReleaseSafe with glint as one module, so that
    /// gantry's Zig frontend and glint are built the same way. Null while a
    /// lazy dependency is still to be fetched.
    fn checksTool(steps: Steps, b: *std.Build, pkg: *std.Build, host: std.Build.ResolvedTarget) ?Tool {
        if (steps.checks) |path| return .{ .prebuilt = path };
        const gantry_dep = pkg.dependencyLazy("gantry", .{ .target = host, .optimize = .safe, .zig = true }) catch return null;
        const gantry = dependencyModule(gantry_dep, "gantry") orelse return null;
        const gantry_zig = dependencyModule(gantry_dep, "gantry.zig") orelse return null;
        const glint_dep = pkg.dependencyLazy("glint", .{ .target = host, .optimize = .safe }) catch return null;
        return .{ .compiled = b.addExecutable(.{
            .name = "preflight-checks",
            .root_module = b.createModule(.{
                .root_source_file = pkg.path("src/main.zig"),
                .target = host,
                .optimize = .safe,
                .imports = &.{ .{ .name = "gantry", .module = gantry }, .{ .name = "gantry.zig", .module = gantry_zig }, .{ .name = "glint", .module = glint_dep.module("glint") } },
            }),
        }) };
    }

    /// `package` is the package checked; `pkg` is the preflight whose sources and tools the gate runs.
    fn install(steps: Steps, b: *std.Build, package: *std.Build, pkg: *std.Build, config: Config) void {
        const host = ciTarget(b);
        const gantry_dep = pkg.dependencyLazy("gantry", .{ .target = host, .optimize = .debug, .zig = true }) catch return;
        const gantry = dependencyModule(gantry_dep, "gantry") orelse return;
        const gantry_zig = dependencyModule(gantry_dep, "gantry.zig") orelse return;
        const executable = steps.checksTool(b, pkg, host) orelse return;
        const timeout = config.test_timeout.duration() orelse fail: {
            config.tests.dependOn(&b.addFail("test_timeout: a bound needs its reason and must fit u64 nanoseconds; off needs its reason").step);
            break :fail std.Io.Duration.zero;
        };
        // ThreadSanitizer runs a test several times slower: the bound a test is held to
        // scales with it, so a heavy test under the sanitizer is not taken for a hang.
        const bounded: std.Io.Duration = if (steps.profile_options.tsan) .fromNanoseconds(timeout.toNanoseconds() *| hardened.tsan_slowdown) else timeout;
        record.add(b, config.tests, pkg, executable, .{ .timing = steps.timing, .test_timeout = bounded, .test_log_level = config.test_log_level, .durations = config.durations, .quarantine = steps.profile_options.active });
        const bench_build = bench.add(b, package, pkg, config.tests, config.bench, steps.smoke);
        // One way to fuzz, in every package: its properties, by the step it names, else
        // the one its hardened run fuzzes, else its tests.
        const fuzzed = config.fuzz_step orelse if (config.hardened) |profile| profile.fuzz_step else "test";
        fuzz.add(b, package, config.tests, fuzzed, config.fuzz_step != null);
        hardened.add(b, package, config.tests, config.hardened, steps.profile_options, executable);
        objects.add(b, package, config.tests, steps.sdk, .{ .objects = steps.objects, .bench_objects = steps.bench_objects, .links = steps.links, .bench = bench_build });
        if (config.portable_tests) portable.add(b, package, config.tests, executable);
        const plan = executable.run(b);
        plan.addArg("plan");
        plan.addArgs(&.{ "--zig-exe", b.graph.zig_exe });
        plan.addPassthruArgs();
        plan.setCwd(package.path("."));
        configure.claim(b, "plan", "Plan matrices or regenerate the pinned caller workflow").dependOn(&plan.step);
        const facts = executable.run(b);
        facts.addArgs(&.{ "facts", "--zig-exe", b.graph.zig_exe });
        configurationOptions(b, facts);
        facts.addPassthruArgs();
        facts.setCwd(package.path("."));
        facts.has_side_effects = true;
        configure.claim(b, "facts", "Read modules, steps and test roots from the Zig 0.17 configured build").dependOn(&facts.step);
        const release = executable.run(b);
        release.addArg("release");
        release.addPassthruArgs();
        release.setCwd(package.path("."));
        release.has_side_effects = true;
        configure.claim(b, "release", "Give a changed package its next version in build.zig.zon and CHANGELOG.md, or say it needs none").dependOn(&release.step);
        const land = executable.run(b);
        land.addArg("land");
        land.addArgs(&.{ "--zig-exe", b.graph.zig_exe });
        land.addPassthruArgs();
        land.setCwd(package.path("."));
        land.has_side_effects = true;
        configure.claim(b, "land", "Release the branch on a land branch, run the merge tier with land, and on green follow main").dependOn(&land.step);
        // A landing gated by hand on the machines at hand: ready, gate on each, publish.
        for ([_]struct { name: []const u8, description: []const u8 }{
            .{ .name = "ready", .description = "Make the landing commit on the branch: rebased on main, tidied, the caller refreshed, the release cut" },
            .{ .name = "gate", .description = "Run the release tier's jobs this machine runs, and name the ones it cannot" },
            .{ .name = "publish", .description = "Push the gated commit onto main, with its release's tag, never forced" },
        }) |command| {
            const run = executable.run(b);
            run.addArg(command.name);
            if (!std.mem.eql(u8, command.name, "publish")) run.addArgs(&.{ "--zig-exe", b.graph.zig_exe });
            run.addPassthruArgs();
            run.setCwd(package.path("."));
            run.has_side_effects = true;
            configure.claim(b, command.name, command.description).dependOn(&run.step);
        }
        const cache = executable.run(b);
        cache.addArgs(&.{ "cache", "--path", ".zig-cache" });
        cache.setCwd(package.path("."));
        configure.claim(b, "cache", "Prune compiled products while preserving packages and tools").dependOn(&cache.step);
        const docs = executable.run(b);
        docs.addArgs(&.{ "docs", "--config", config.config, "--zig-exe", b.graph.zig_exe });
        docs.addPassthruArgs();
        docs.setCwd(package.path("."));
        configure.claim(b, "docs", "Render a configured documentation region").dependOn(&docs.step);
        const deprecations = executable.run(b);
        deprecations.addArgs(&.{ "deprecations", "--std" });
        deprecations.addDirectoryArg2(b.graph.path(.zig_lib, "std"), .{});
        deprecations.addPassthruArgs();
        deprecations.setCwd(package.path("."));
        configure.claim(b, "deprecations", "List what this Zig release deprecated, rewritten; -- --write applies it").dependOn(&deprecations.step);
        steps.addLint(b, package, pkg, config, executable, gantry, gantry_zig);
    }

    fn addLint(steps: Steps, b: *std.Build, package: *std.Build, pkg: *std.Build, config: Config, executable: Tool, gantry: *std.Build.Module, gantry_zig: *std.Build.Module) void {
        const host = ciTarget(b);
        // A package that declares no structure is held to none.
        const layers = b.createModule(.{
            .root_source_file = if (configure.exists(package, config.layers)) package.path(config.layers) else pkg.path("src/layers_default.zig"),
            .target = host,
            .imports = &.{.{ .name = "gantry", .module = gantry }},
        });
        const checker = b.addExecutable(.{
            .name = "preflight-structure",
            .root_module = b.createModule(.{
                .root_source_file = pkg.path("src/structure.zig"),
                .target = host,
                .optimize = .debug,
                .imports = &.{ .{ .name = "gantry", .module = gantry }, .{ .name = "gantry.zig", .module = gantry_zig }, .{ .name = "layers", .module = layers } },
            }),
        });
        var format_paths: std.ArrayList([]const u8) = .empty;
        var format_excluded: std.ArrayList(std.Build.LazyPath) = .empty;
        for ([_][]const u8{ "build.zig", "build.zig.zon" }) |path| {
            if (configure.exists(package, path)) format_paths.append(b.allocator, path) catch @panic("OOM");
        }
        for ([_][]const u8{ "src", "examples", "ci", "conformance", "bench" }) |path| {
            if (!configure.exists(package, path)) continue;
            format_paths.append(b.allocator, path) catch @panic("OOM");
            // A build of its own in one of these keeps its packages and
            // outputs beside its manifest.
            format_excluded.appendSlice(b.allocator, configure.buildDirectoriesUnder(package, path)) catch @panic("OOM");
        }
        const format = b.addFmt(.{ .paths = package.pathList(format_paths.items), .exclude_paths = format_excluded.items, .check = true });
        const structure = b.addRunArtifact(checker);
        structure.addArgs(&.{ "--config", config.config });
        structure.setCwd(package.path("."));
        configure.claim(b, "check-imports", "Check declared source structure").dependOn(&structure.step);
        structure.addPassthruArgs();
        const lint_structure = b.addRunArtifact(checker);
        lint_structure.addArgs(&.{ "--config", config.config });
        lint_structure.setCwd(package.path("."));
        lint_structure.step.dependOn(&format.step);
        const checks = executable.run(b);
        checks.addArgs(&.{ "lint", "--config", config.config, "--zig-exe", b.graph.zig_exe, "--zig-std" });
        checks.addDirectoryArg2(b.graph.path(.zig_lib, "std"), .{});
        configurationOptions(b, checks);
        checks.setCwd(package.path("."));
        checks.step.dependOn(&lint_structure.step);
        steps.lint.dependOn(&checks.step);
        if (steps.lint_enabled) {
            orderTests(config.tests, steps.lint);
            steps.ci.dependOn(steps.lint);
        }
    }
};

fn forceTests(step: *std.Build.Step) void {
    if (step.cast(std.Build.Step.Run)) |run| {
        // Caches retain compiled products; a CI gate always executes its tests.
        run.has_side_effects = true;
        return;
    }
    for (step.dependencies.items) |dependency| forceTests(dependency);
}

// Only run steps acquire the lint prerequisite. Test compilation may overlap it.
fn orderTests(step: *std.Build.Step, lint: *std.Build.Step) void {
    if (step.tag == .run) {
        step.dependOn(lint);
        return;
    }
    for (step.dependencies.items) |dependency| orderTests(dependency, lint);
}

fn configurationOptions(b: *std.Build, run: *std.Build.Step.Run) void {
    for (b.user_input_options.keys(), b.user_input_options.values()) |name, value| switch (value) {
        .flag => run.addArgs(&.{ "--build-option", b.fmt("-D{s}", .{name}) }),
        .scalar => |text| run.addArgs(&.{ "--build-option", b.fmt("-D{s}={s}", .{ name, text }) }),
        .list => |list| for (list.items) |text| run.addArgs(&.{ "--build-option", b.fmt("-D{s}={s}", .{ name, text }) }),
        else => run.step.dependOn(&b.addFail("build facts: unsupported non-CLI configuration option; cannot reproduce configured graph").step),
    };
}
