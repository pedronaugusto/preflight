//! The family's contract for `zig build bench`: every program in `bench/`
//! built in ReleaseFast under `zig-out/bench`, the timed ones run with no
//! arguments one after another, and each run once with `--smoke` by `zig
//! build test`, so it keeps working with the API. A program's own arguments
//! are for running it from `zig-out/bench` by hand. Each run has a fresh, empty
//! working directory of its own, where a program writes the fixtures it needs.
const std = @import("std");
const configure = @import("configure.zig");

/// A repository's benchmark programs and what they import.
pub const Bench = struct {
    /// Every program in `bench/`.
    programs: []const Program,
    /// The modules a program imports, built in `optimize`: an imported module
    /// keeps its own mode, so a ReleaseFast program over the package's Debug
    /// module would time the Debug module.
    imports: *const fn (b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import,
    target: std.Build.ResolvedTarget,
    /// The mode the runs of `zig build test` build in: the build's own.
    optimize: std.lang.Optimize,
    link_libc: ?bool = null,

    pub const Program = struct {
        name: []const u8,
        /// The root source, under `bench/`.
        source: []const u8,
        /// Whether `zig build bench` runs it, with no arguments: false for a
        /// tool the benchmarks need, such as a fixture writer, which is
        /// still built there and run once by `zig build test`.
        timed: bool = true,
    };
};

/// The argument a program gets in `zig build test`: run every point once,
/// at its smallest size, so the run checks the program still works and
/// times nothing worth reading.
pub const smoke_flag = "--smoke";

/// Adds `bench` and runs every program once with `--smoke` before `tests`
/// passes. A repository with a `bench/` directory and no benchmarks given
/// fails `tests` by name.
pub fn add(b: *std.Build, tests: *std.Build.Step, bench: ?Bench) void {
    const given = bench orelse {
        if (configure.exists(b, "bench")) tests.dependOn(&b.addFail("bench/: give addCi its .bench, so zig build bench builds the programs and zig build test runs each once").step);
        return;
    };
    const step = b.step("bench", "Build the benchmarks in ReleaseFast under zig-out/bench and run the timed ones, one after another");
    // One after another: a measurement taken beside another is of both.
    var previous: ?*std.Build.Step = null;
    for (given.programs) |program| {
        const compile = executable(b, given, program, .fast);
        step.dependOn(&b.addInstallArtifact(compile, .{ .dest_dir = .{ .override = .{ .custom = "bench" } } }).step);
        if (!program.timed) continue;
        const run = b.addRunArtifact(compile);
        run.setCwd(b.tmpPath());
        run.has_side_effects = true;
        if (previous) |before| run.step.dependOn(before);
        previous = &run.step;
        step.dependOn(&run.step);
    }
    for (given.programs) |program| {
        const run = b.addRunArtifact(executable(b, given, program, given.optimize));
        run.addArg(smoke_flag);
        run.setCwd(b.tmpPath());
        // Captured, not printed: numbers from a smoke run mean nothing.
        run.expectExitCode(0);
        tests.dependOn(&run.step);
    }
}

fn executable(b: *std.Build, bench: Bench, program: Bench.Program, optimize: std.lang.Optimize) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = program.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(program.source),
            .target = bench.target,
            .optimize = optimize,
            .link_libc = bench.link_libc,
            .imports = bench.imports(b, bench.target, optimize),
        }),
    });
}
