//! Build-only CI checks. Consumers never acquire the checker's dependencies.
const std = @import("std");
const configure = @import("configure.zig");
const portable = @import("portable.zig");
const record = @import("record.zig");
pub const consumer = @import("consumer.zig");
const bench = @import("bench.zig");

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
};

pub const Bench = bench.Bench;

pub const TestTimeout = record.TestTimeout;

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

pub fn addCi(b: *std.Build, config: Config) void {
    if (b.pkg_hash.len != 0) return;
    const steps: Steps = .create(b, config);
    const dep = b.dependencyLazy("preflight", .{}) catch return;
    steps.install(b, dep.builder, config);
}

/// preflight's own gate, built from this checkout rather than a dependency.
pub fn addOwnCi(b: *std.Build, config: Config) void {
    const steps: Steps = .create(b, config);
    steps.install(b, b, config);
}

/// Builds and runs a repository check program and its tests as one step.
/// The program runs from the repository root.
pub fn addCheck(b: *std.Build, name: []const u8, source: []const u8) *std.Build.Step.Compile {
    const module = b.createModule(.{ .root_source_file = b.path(source), .target = b.graph.host, .optimize = .debug });
    const executable = b.addExecutable(.{ .name = name, .root_module = module });
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(executable);
    run.setCwd(b.path("."));
    const step = b.step(name, "Run repository CI checks and their regressions");
    step.dependOn(&b.addRunArtifact(tests).step);
    step.dependOn(&run.step);
    return executable;
}

const Steps = struct {
    lint: *std.Build.Step,
    ci: *std.Build.Step,
    lint_enabled: bool,
    timing: bool,

    fn create(b: *std.Build, config: Config) Steps {
        const lint = b.step("lint", "Check format, structure, Zig policy, docs and test imports");
        bench.add(b, config.tests, config.bench);
        const ci = b.step("ci", "Run source checks, then the tests");
        ci.dependOn(config.tests);
        forceTests(config.tests);
        const compile = b.step("ci-check", "Compile every test and its helpers without executing tests");
        compileTests(config.tests, compile);
        // Options are declared before any lazy dependency can end the
        // build script: Zig 0.17 rejects a -D option the first pass never
        // declared, even while it only discovers what to fetch.
        const enabled = b.option(bool, "ci-lint", "Run source checks before CI tests") orelse true;
        const timing = config.timings_enabled orelse (b.option(bool, "ci-timings", "Record per-test durations for the next shard balance") orelse false);
        return .{ .lint = lint, .ci = ci, .lint_enabled = enabled, .timing = timing };
    }

    /// `pkg` is the preflight package whose sources and tools the gate runs.
    fn install(steps: Steps, b: *std.Build, pkg: *std.Build, config: Config) void {
        const host = ciTarget(b);
        const gantry_dep = pkg.dependencyLazy("gantry", .{ .target = host, .optimize = .debug }) catch return;
        const gantry = gantry_dep.module("gantry");
        const executable = b.addExecutable(.{
            .name = "preflight-checks",
            .root_module = b.createModule(.{
                .root_source_file = pkg.path("src/main.zig"),
                .target = host,
                .optimize = .safe,
                .imports = &.{.{ .name = "gantry", .module = gantry }},
            }),
        });
        const timeout = config.test_timeout.nanoseconds() orelse fail: {
            config.tests.dependOn(&b.addFail("test_timeout: a bound other than the default, or none, needs its reason").step);
            break :fail 0;
        };
        record.add(b, config.tests, pkg, executable, .{ .timing = steps.timing, .test_timeout_ns = timeout, .test_log_level = config.test_log_level, .durations = config.durations });
        if (config.portable_tests) portable.add(b, config.tests, executable);
        const cache = b.addRunArtifact(executable);
        cache.addArgs(&.{ "cache", "--path", ".zig-cache" });
        cache.setCwd(b.path("."));
        b.step("cache", "Prune compiled products while preserving packages and tools").dependOn(&cache.step);
        const docs = b.addRunArtifact(executable);
        docs.addArgs(&.{ "docs", "--config", config.config });
        docs.addPassthruArgs();
        docs.setCwd(b.path("."));
        b.step("docs", "Render a configured documentation region").dependOn(&docs.step);
        const deprecations = b.addRunArtifact(executable);
        deprecations.addArgs(&.{ "deprecations", "--std" });
        deprecations.addDirectoryArg2(b.graph.path(.zig_lib, "std"), .{});
        deprecations.addPassthruArgs();
        deprecations.setCwd(b.path("."));
        b.step("deprecations", "List what this Zig release deprecated, rewritten; -- --write applies it").dependOn(&deprecations.step);
        steps.addLint(b, pkg, config, executable, gantry);
    }

    fn addLint(steps: Steps, b: *std.Build, pkg: *std.Build, config: Config, executable: *std.Build.Step.Compile, gantry: *std.Build.Module) void {
        const host = ciTarget(b);
        const layers = b.createModule(.{
            .root_source_file = b.path(config.layers),
            .target = host,
            .imports = &.{ .{ .name = "gantry", .module = gantry }, .{ .name = "preflight_rules", .module = b.createModule(.{ .root_source_file = pkg.path("src/rules.zig"), .target = host, .imports = &.{.{ .name = "gantry", .module = gantry }} }) } },
        });
        const checker = b.addExecutable(.{
            .name = "preflight-structure",
            .root_module = b.createModule(.{
                .root_source_file = pkg.path("src/structure.zig"),
                .target = host,
                .optimize = .debug,
                .imports = &.{ .{ .name = "gantry", .module = gantry }, .{ .name = "layers", .module = layers } },
            }),
        });
        var format_paths: std.ArrayList([]const u8) = .empty;
        var format_excluded: std.ArrayList(std.Build.LazyPath) = .empty;
        for ([_][]const u8{ "build.zig", "build.zig.zon" }) |path| {
            if (configure.exists(b, path)) format_paths.append(b.allocator, path) catch @panic("OOM");
        }
        for ([_][]const u8{ "src", "examples", "ci", "conformance", "bench" }) |path| {
            if (!configure.exists(b, path)) continue;
            format_paths.append(b.allocator, path) catch @panic("OOM");
            // A build of its own in one of these keeps its packages and
            // outputs beside its manifest.
            format_excluded.appendSlice(b.allocator, configure.buildDirectoriesUnder(b, path)) catch @panic("OOM");
        }
        const format = b.addFmt(.{ .paths = b.pathList(format_paths.items), .exclude_paths = format_excluded.items, .check = true });
        const structure = b.addRunArtifact(checker);
        structure.addArgs(&.{ "--config", config.config });
        structure.setCwd(b.path("."));
        b.step("check-imports", "Check declared source structure").dependOn(&structure.step);
        structure.addPassthruArgs();
        const lint_structure = b.addRunArtifact(checker);
        lint_structure.addArgs(&.{ "--config", config.config });
        lint_structure.setCwd(b.path("."));
        lint_structure.step.dependOn(&format.step);
        const ziglint_dep = pkg.dependencyLazy("ziglint", .{ .target = host, .optimize = .safe }) catch return;
        const checks = b.addRunArtifact(executable);
        checks.addArgs(&.{ "lint", "--config", config.config, "--ziglint" });
        checks.addArtifactArg2(ziglint_dep.artifact("ziglint"), .{});
        checks.setCwd(b.path("."));
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

fn compileTests(step: *std.Build.Step, compile: *std.Build.Step) void {
    if (step.tag == .compile) {
        compile.dependOn(step);
        return;
    }
    for (step.dependencies.items) |dependency| compileTests(dependency, compile);
}
