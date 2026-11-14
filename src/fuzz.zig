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
/// gives it no fuzz job. `tool` is preflight's program, which spends the fuzz job's budget.
pub fn add(b: *std.Build, package: *std.Build, tests: *std.Build.Step, step: []const u8, named: bool, tool: Tool) void {
    const dep = (configure.declared(b, "shakedown", .{ .target = b.graph.host, .optimize = .safe }) catch return) orelse {
        if (!named) return;
        tests.dependOn(&b.addFail("addCi .fuzz_step: the fuzzer is shakedown's, as are the properties it fuzzes; declare shakedown: a dev dependency with bay, else a lazy one").step);
        return;
    };
    const fuzzer = dep.artifact("shakedown-fuzz");
    const run = b.addRunArtifact(fuzzer);
    run.addArg("--package");
    run.addDirectoryArg2(package.path("."), .{});
    // The runner builds the step itself, as this same build: `bay dev` under bay, else zig build.
    if (configure.bay(b, package)) |bay| run.addArgs(&.{ "--bay", bay }) else run.addArgs(&.{ "--zig", b.graph.zig_exe });
    run.addArgs(&.{ "--step", step });
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
    job.addArgs(&.{ "--step", hardened.testsAlone(b, tests, step), "--build-arg", "-Dci-fuzzing=true" });
    job.setCwd(package.path("."));
    job.has_side_effects = true;
    configure.claim(b, "ci-fuzz", "The fuzz job: the check properties fuzzed for ci/workflow.json's fuzz_minutes (PREFLIGHT_FUZZ_MINUTES), failing on the first finding with its shrunk tape; corpora and findings in .zig-cache/preflight-fuzz").dependOn(&job.step);
}
