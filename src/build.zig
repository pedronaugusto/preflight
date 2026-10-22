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
const vm = @import("vm.zig");
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
    /// The hardened profile, which every package runs (aegis's design §7): its tests with
    /// runtime safety on, a fuzz campaign and ThreadSanitizer. Null only in a configuration
    /// that runs no native tests (a freestanding target), and visibly so.
    hardened: ?Hardened = .{},
    /// Installed artifacts the build makes ReleaseFast or ReleaseSmall although the caller
    /// chose no mode, each with the measurement that says why: any other one fails the lint,
    /// since what the family ships is ReleaseSafe.
    release_fast: []const ReleaseFast = &.{},
    /// Continuous fuzzing: the step `zig build fuzz` fuzzes, one whose every
    /// test binary has a `check` property or a fuzz test, since the fuzzer
    /// refuses a binary with none. It runs the package's own shakedown, whose
    /// properties the tests are written with. Null fuzzes the step the hardened
    /// run fuzzes, else `test`, in a package that declares shakedown; one that
    /// declares none has no `fuzz` step. Naming a step requires shakedown.
    fuzz_step: ?[]const u8 = null,
    /// Alpine Linux packages the tests need on the riscv64 machine (`-Dci-vm`)
    /// beside its minimal system, by Alpine's names (`git`, `openssl`). Alpine's
    /// `apk` installs them on the machine when the build makes it, from the
    /// release's own repositories, verified by the release's own keys; a build
    /// that runs nothing on the machine fetches nothing.
    vm_packages: []const []const u8 = &.{},
};

pub const Bench = bench.Bench;
pub const Hardened = hardened.Profile;
pub const ReleaseFast = struct { artifact: []const u8, reason: []const u8 };

pub const TestTimeout = record.TestTimeout;

/// A module of a dependency, or null while the dependency is still waiting for
/// one of its own lazy dependencies: its script ends before it adds modules, and
/// the script that asked for it ends too, so that Zig fetches what is missing
/// and configures again. gantry's Zig frontend waits for glint this way.
pub fn dependencyModule(dep: *std.Build.Dependency, name: []const u8) ?*std.Build.Module {
    return dep.builder.modules.get(name);
}

/// The preflight program's root module from `pkg`'s sources, built in `b` for `target`:
/// ReleaseSafe with glint, which gantry's Zig frontend shares, so gantry is built the
/// same way, and ensign for its command line. Null while a lazy dependency is still to
/// be fetched.
pub fn programModule(b: *std.Build, pkg: *std.Build, target: std.Build.ResolvedTarget) ?*std.Build.Module {
    const gantry_dep = pkg.dependencyLazy("gantry", .{ .target = target, .optimize = .safe, .zig = true }) catch return null;
    const gantry = dependencyModule(gantry_dep, "gantry") orelse return null;
    const gantry_zig = dependencyModule(gantry_dep, "gantry.zig") orelse return null;
    const glint = pkg.dependencyLazy("glint", .{ .target = target, .optimize = .safe }) catch return null;
    const ensign = pkg.dependencyLazy("ensign", .{ .target = target, .optimize = .safe }) catch return null;
    return b.createModule(.{
        .root_source_file = pkg.path("src/main.zig"),
        .target = target,
        .optimize = .safe,
        .imports = &.{ .{ .name = "gantry", .module = gantry }, .{ .name = "gantry.zig", .module = gantry_zig }, .{ .name = "glint", .module = glint.module("glint") }, .{ .name = "ensign", .module = ensign.module("ensign") } },
    });
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

/// A program the tests run (a fixture server, a helper child), named to them as
/// `name` in `options`: installed under `zig-out/preflight/programs/` before
/// they compile, and named by its path from the package root, the working
/// directory of every test run, here and where portable tests replay. A path
/// from `addOptionPath` is the building runner's cache, which a runner
/// replaying the tests does not have: portable tests refuse one.
pub fn addTestProgram(b: *std.Build, options: *std.Build.Step.Options, name: []const u8, program: *std.Build.Step.Compile) void {
    portable.addProgram(b, options, name, program);
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
        .vm = b.option(bool, "ci-vm", "Run what is built for riscv64 Linux on its own kernel under QEMU's system emulation (qemu-system-riscv64 on PATH)") orelse false,
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
    vm: bool,
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
    vm: bool,
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
        return .{ .lint = lint, .ci = ci, .objects = objects_step, .bench_objects = bench_objects_step, .links = links_step, .lint_enabled = controls.lint_enabled, .timing = controls.timing, .sdk = controls.sdk, .checks = controls.checks, .smoke = controls.smoke, .vm = controls.vm, .profile_options = controls.profile_options };
    }

    /// The program that runs the checks: the binary the runner holds, or the
    /// checks compiled here (`programModule`). Null while a lazy dependency is
    /// still to be fetched.
    fn checksTool(steps: Steps, b: *std.Build, pkg: *std.Build, host: std.Build.ResolvedTarget) ?Tool {
        if (steps.checks) |path| return .{ .prebuilt = path };
        return .{ .compiled = b.addExecutable(.{ .name = "preflight-checks", .root_module = programModule(b, pkg, host) orelse return null }) };
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
        // ThreadSanitizer, and a machine QEMU emulates instruction by instruction, run a
        // test several times slower: the bound a test is held to scales with them, so a
        // heavy test there is not taken for a hang.
        var visited: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
        const sanitizer: i96 = if (steps.profile_options.tsan or hardened.sanitizesThreads(b, config.tests, &visited)) hardened.tsan_slowdown else 1;
        const emulation: i96 = if (steps.vm) vm.slowdown else 1;
        const slowdown = sanitizer * emulation;
        // aegis: design: std alone, as the test runner and build module every package compiles (aegis's own too) must be
        const bounded: std.Io.Duration = .fromNanoseconds(timeout.toNanoseconds() *| slowdown);
        // One way to fuzz, in every package: its properties, by the step it names, else
        // the one its hardened run fuzzes, else its tests. Its tests take the runner as
        // the tests do: a fuzzing build is the runner's to serve (`runner.zig`).
        const profile: Hardened = config.hardened orelse .{ .fuzz_step = null };
        const fuzzed = config.fuzz_step orelse profile.fuzz_step orelse "test";
        var roots_buffer: [2]*std.Build.Step = .{ config.tests, config.tests };
        if (b.top_level_steps.get(fuzzed)) |top| roots_buffer[1] = &top.step;
        const roots: []const *std.Build.Step = &roots_buffer;
        const counted = record.add(b, roots, pkg, executable, .{ .timing = steps.timing, .test_timeout = bounded, .test_log_level = config.test_log_level, .durations = config.durations, .quarantine = steps.profile_options.active });
        const bench_build = bench.add(b, package, pkg, config.tests, config.bench, steps.smoke);
        fuzz.add(b, package, config.tests, fuzzed, config.fuzz_step != null);
        hardened.add(b, package, config.tests, config.hardened, steps.profile_options, executable);
        objects.add(b, package, config.tests, steps.sdk, .{ .objects = steps.objects, .bench_objects = steps.bench_objects, .links = steps.links, .bench = bench_build });
        if (config.portable_tests) portable.add(b, package, config.tests, executable, counted.names);
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
        exported(b, package, release);
        release.addPassthruArgs();
        release.setCwd(package.path("."));
        release.has_side_effects = true;
        configure.claim(b, "release", "Give a changed package its next version in build.zig.zon and CHANGELOG.md, or say it needs none").dependOn(&release.step);
        const surface = executable.run(b);
        surface.addArg("surface");
        exported(b, package, surface);
        surface.addPassthruArgs();
        surface.setCwd(package.path("."));
        surface.has_side_effects = true;
        configure.claim(b, "surface", "List the public declarations of the modules the package exports; -- --since <tag> lists what changed").dependOn(&surface.step);
        const land = executable.run(b);
        land.addArg("land");
        land.addArgs(&.{ "--zig-exe", b.graph.zig_exe });
        exported(b, package, land);
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
            run.addArgs(&.{ "--zig-exe", b.graph.zig_exe });
            if (std.mem.eql(u8, command.name, "ready")) exported(b, package, run);
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
        // The steps CI runs tests under, whose runs make a file a test root: `ci` holds the
        // tests, and the fuzzer and the hardened profile run the steps they name.
        var test_steps: std.ArrayList([]const u8) = .empty;
        test_steps.append(b.allocator, "ci") catch @panic("OOM");
        const named: []const []const u8 = if (config.hardened) |given| &.{ fuzzed, given.fuzz_step orelse fuzzed, given.tsan_step } else &.{fuzzed};
        for (named) |name| if (b.top_level_steps.contains(name)) for (test_steps.items) |kept| {
            if (std.mem.eql(u8, kept, name)) break;
        } else test_steps.append(b.allocator, name) catch @panic("OOM");
        steps.addLint(b, package, pkg, config, executable, gantry, gantry_zig, test_steps.items);
        releaseModes(b, config);
        record.counts(b, config.tests, executable, counted);
        // Last, so that every run the gate added is in front of the machine too.
        if (steps.vm) vm.add(b, config.tests, pkg, host, config.vm_packages);
    }

    fn addLint(steps: Steps, b: *std.Build, package: *std.Build, pkg: *std.Build, config: Config, executable: Tool, gantry: *std.Build.Module, gantry_zig: *std.Build.Module, test_steps: []const []const u8) void {
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
        for (test_steps) |name| checks.addArgs(&.{ "--test-step", name });
        configurationOptions(b, checks);
        checks.setCwd(package.path("."));
        checks.step.dependOn(&lint_structure.step);
        steps.lint.dependOn(&checks.step);
        // `fix`: glint's deterministic fixes written into the sources, then the lint's report.
        const fixing = executable.run(b);
        fixing.addArgs(&.{ "lint", "--fix", "--config", config.config, "--zig-exe", b.graph.zig_exe, "--zig-std" });
        fixing.addDirectoryArg2(b.graph.path(.zig_lib, "std"), .{});
        for (test_steps) |name| fixing.addArgs(&.{ "--test-step", name });
        configurationOptions(b, fixing);
        fixing.setCwd(package.path("."));
        fixing.has_side_effects = true;
        configure.claim(b, "fix", "Apply glint's deterministic fixes to the sources (std's assert as aegis's, older written reasons as escapes, unused escapes gone), then report what is left").dependOn(&fixing.step);
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

/// `--module <name>=<root>` for each module `package` exports whose root is one of its files,
/// and its `build.zig`, which a build that depends on it imports: the public surface a release
/// that removes or changes a declaration of breaks.
fn exported(b: *std.Build, package: *std.Build, run: *std.Build.Step.Run) void {
    run.addArgs(&.{ "--module", "build.zig=build.zig" });
    for (package.modules.keys(), package.modules.values()) |name, module| {
        const root = module.root_source_file orelse continue;
        switch (root) {
            .src_path => |path| if (path.owner == package) run.addArgs(&.{ "--module", b.fmt("{s}={s}", .{ name, path.sub_path }) }),
            else => {},
        }
    }
}

/// Each installed artifact the build makes ReleaseFast or ReleaseSmall while the caller chose no
/// mode fails the lint, unless `Config.release_fast` names it with its measurement; a name that
/// matches no such artifact fails too, so an exception cannot outlive its artifact.
fn releaseModes(b: *std.Build, config: Config) void {
    if (b.user_input_options.contains("optimize") or b.user_input_options.contains("release")) return;
    const lint = b.top_level_steps.get("lint") orelse return;
    var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    var used: std.StringHashMapUnmanaged(void) = .empty;
    var stack: std.ArrayList(*std.Build.Step) = .empty;
    stack.append(b.allocator, b.getInstallStep()) catch @panic("OOM");
    while (stack.pop()) |step| {
        if ((seen.getOrPut(b.allocator, step) catch @panic("OOM")).found_existing) continue;
        for (step.dependencies.items) |next| stack.append(b.allocator, next) catch @panic("OOM");
        const artifact = step.cast(std.Build.Step.Compile) orelse continue;
        const mode = artifact.root_module.optimize orelse continue;
        if (mode != .fast and mode != .small) continue;
        const named = for (config.release_fast) |entry| {
            if (std.mem.eql(u8, entry.artifact, artifact.name)) break true;
        } else false;
        if (named) {
            used.put(b.allocator, artifact.name, {}) catch @panic("OOM");
        } else lint.step.dependOn(&b.addFail(b.fmt("release: {s} is installed {t} although no mode was chosen; the family ships ReleaseSafe, or Config.release_fast names it with its measurement", .{ artifact.name, mode })).step);
    }
    for (config.release_fast) |entry| {
        if (entry.reason.len == 0) lint.step.dependOn(&b.addFail(b.fmt("release: {s}: Config.release_fast needs the measurement that says why", .{entry.artifact})).step);
        if (!used.contains(entry.artifact)) lint.step.dependOn(&b.addFail(b.fmt("release: Config.release_fast names {s}, which no installed ReleaseFast or ReleaseSmall artifact is", .{entry.artifact})).step);
    }
}
