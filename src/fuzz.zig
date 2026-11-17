//! Continuous fuzzing, off the landing path: the `fuzz` step runs
//! shakedown's runner over the package's `check` properties, and `ci-fuzz`,
//! the release tier's fuzz job, runs it for a budget of minutes (`budget.zig`).
//! The fuzzing, the corpora kept outside the package and the shrinking of what
//! it finds are shakedown's; this wires the steps, as `bench` wires measuring.
const std = @import("std");
const configure = @import("configure.zig");
const hardened = @import("hardened.zig");
const Tool = @import("tool.zig").Tool;

/// `named`: the package named the step, and so must declare shakedown; else a package that
/// declares none has no `fuzz` step, as it has no properties, and no `ci-fuzz`, so the planner
/// gives it no fuzz job; and where `step` is the package's tests, the steps fuzz its own
/// property tests alone (`properties`). `tool` is preflight's program, which spends the fuzz
/// job's budget.
pub fn add(b: *std.Build, package: *std.Build, tests: *std.Build.Step, step: []const u8, named: bool, tool: Tool) void {
    if (!configure.declares(b, "shakedown")) {
        if (!named) return;
        tests.dependOn(&b.addFail("addCi .fuzz_step: the fuzzer is shakedown's, as are the properties it fuzzes; declare shakedown: a dev dependency with bay, else a lazy one").step);
        return;
    }
    const dep = configure.lazy(b, "shakedown", .{ .target = b.graph.host, .optimize = .safe }) orelse return;
    // The package's own property tests, where it names no step and the hardened run fuzzes its tests.
    const fuzzed = if (named) step else properties(b, package, tests, step);
    const fuzzer = dep.artifact("shakedown-fuzz");
    const run = b.addRunArtifact(fuzzer);
    run.addArg("--package");
    run.addDirectoryArg2(package.path("."), .{});
    // The runner builds the step itself, as this same build: `bay dev` under bay, else zig build.
    if (configure.bay(b, package)) |bay| run.addArgs(&.{ "--bay", bay }) else run.addArgs(&.{ "--zig", b.graph.zig_exe });
    run.addArgs(&.{ "--step", fuzzed });
    // A fuzzing build, asked for by name: its tests are built as the fuzzer reads them.
    run.addArgs(&.{ "--build-arg", "-Dci-fuzzing=true" });
    run.addPassthruArgs();
    run.has_side_effects = true;
    configure.claim(b, "fuzz", "Fuzz the check properties off the landing path, corpora and findings outside the package: -- --limit 10M --sessions 1 --store ~/shakedown-fuzz --filter <test>").dependOn(&run.step);
    // The fuzz job: the same properties for the job's minutes, in the package's store, the
    // tests alone where the step is the package's tests (the source checks are their own job's).
    const job = tool.run(b);
    job.addArgs(&.{ "fuzz-budget", "--" });
    job.addArtifactArg2(fuzzer, .{});
    job.addArg("--package");
    job.addDirectoryArg2(package.path("."), .{});
    if (configure.bay(b, package)) |bay| job.addArgs(&.{ "--bay", bay }) else job.addArgs(&.{ "--zig", b.graph.zig_exe });
    job.addArgs(&.{ "--step", hardened.testsAlone(b, tests, fuzzed), "--build-arg", "-Dci-fuzzing=true" });
    job.setCwd(package.path("."));
    job.has_side_effects = true;
    configure.claim(b, "ci-fuzz", "The fuzz job: the check properties fuzzed for ci/workflow.json's fuzz_minutes (PREFLIGHT_FUZZ_MINUTES), failing on the first finding with its shrunk tape; corpora and findings in .zig-cache/preflight-fuzz").dependOn(&job.step);
}

/// The step the fuzz steps fuzz when the package names none and `name` is its tests: its own
/// property tests, the runs of the test binaries `tests` reaches that the package builds and
/// whose modules import shakedown, in whose `check` the properties are written, and no other
/// run. A session of Zig's fuzzer runs again every Run step its step reaches, a generator's
/// or a fixture's as much as a test's: fuzzing the tests' whole graph had each session run
/// all of it, and two of hull's table generators wrote one output path (hull 7623e71, which
/// named a step of its own until this). None found fails by name. Any other step, as named.
pub fn properties(b: *std.Build, package: *std.Build, tests: *std.Build.Step, name: []const u8) []const u8 {
    const top = b.top_level_steps.get(name) orelse return name;
    if (&top.step != tests) return name;
    const step = configure.claim(b, properties_step, "The package's own property tests alone, which the fuzz steps fuzz: the runs of the tests' binaries that import shakedown, and no other run");
    var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    if (!collect(b, package, tests, step, &seen)) step.dependOn(&b.addFail("ci-fuzz: no test binary the tests run imports shakedown, in whose check the properties the fuzz job fuzzes are written; write them with shakedown, or name the step to fuzz (addCi .fuzz_step)").step);
    return properties_step;
}

/// The step of the package's own property tests (`properties`).
pub const properties_step = "ci-properties";

/// Sets `into` on each run of a property test that `step` reaches; whether any was found.
fn collect(b: *std.Build, package: *std.Build, step: *std.Build.Step, into: *std.Build.Step, seen: *std.AutoHashMapUnmanaged(*std.Build.Step, void)) bool {
    if ((seen.getOrPut(b.allocator, step) catch @panic("OOM")).found_existing) return false;
    if (step.cast(std.Build.Step.Run)) |run| if (run.argv.items.len != 0 and run.argv.items[0] == .artifact) {
        const artifact = run.argv.items[0].artifact.artifact;
        const own = artifact.root_module.owner == b or artifact.root_module.owner == package;
        if (artifact.kind.isTest() and own and importsShakedown(b, artifact.root_module)) {
            into.dependOn(step);
            return true;
        }
    };
    var found = false;
    for (step.dependencies.items) |dependency| found = collect(b, package, dependency, into, seen) or found;
    return found;
}

/// Whether `root`'s module graph imports shakedown, by the name a package imports it with.
fn importsShakedown(b: *std.Build, root: *std.Build.Module) bool {
    var graph: std.array_hash_map.Auto(*std.Build.Module, void) = .empty;
    graph.put(b.allocator, root, {}) catch @panic("OOM");
    var next: usize = 0;
    while (next < graph.count()) : (next += 1) {
        const module = graph.keys()[next];
        if (module.import_table.contains("shakedown")) return true;
        for (module.import_table.values()) |imported| graph.put(b.allocator, imported, {}) catch @panic("OOM");
    }
    return false;
}
