//! The bound on every run preflight's steps make that is no test, under preflight's bound program
//! (`bound.zig`, `bounded.zig`): once it makes no progress for its bound (its tree uses no CPU
//! time), or when the hosted job's deadline comes, the run and every process it started are ended, and it fails naming its step, its command and
//! the last line it printed. Zig bounds unit tests alone (`--test-timeout`), and preflight's runner
//! bounds each test it runs; any other run had no bound but the host's, which keeps no log of it
//! (blackbox's example ran 45 hours locally; strand's cross-compile jobs and a consumer build hung
//! to GitHub's 40 minutes). The package's runs of the tests step (an example, a generator, a
//! benchmark's smoke run) have a bound of their own, `default_limit` or the one `run_bounds`
//! names; every other run (preflight's checks, the hardened rerun, the consumer builds, the
//! machine's) has the job's deadline. The fuzz steps are left out: a fuzz session's end is its
//! budget's (`checks/budget.zig`), a planned end with its grace.
//!
//! Lint's reading of the configured graph (`facts.read`) configures with `-Dci-bound=false`, so it
//! reads each run as the build wrote it: the bound program is never in it.
const std = @import("std");
const Tool = @import("tool.zig").Tool;

/// A run's own bound, how long it may make no progress, where the default is too short for it,
/// and why. `step` is the run's
/// step's name, as the build names it (`run exe example`).
pub const RunBound = struct { step: []const u8, limit: std.Io.Duration, reason: []const u8 };

/// The bound of a package's run of the tests step the build names no bound for.
pub const default_limit: std.Io.Duration = .fromSeconds(300);

/// The option that leaves every run unbounded, which only the graph's reading passes.
pub const option = "ci-bound";

/// The bound program, built once for the host, while `addCi` bounds runs: null where it does not
/// (`-Dci-bound=false`), or before `addCi`.
threadlocal var program: ?*std.Build.Step.Compile = null;

/// Builds the bound program from `pkg`'s sources, unless `-Dci-bound=false` (`enabled`, which
/// `declareCiOptions` declares) leaves every run unbounded.
pub fn declare(b: *std.Build, pkg: *std.Build, enabled: bool) void {
    program = null;
    if (!enabled) return;
    program = b.addExecutable(.{ .name = "preflight-bound", .root_module = b.createModule(.{
        .root_source_file = pkg.path("src/bound.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    }) });
}

/// Bounds the runs of `tests` and of `others` (preflight's steps), `slowdown` times longer, as the
/// tests' bound is under a sanitizer or an emulated machine. A package's run of `tests` has its
/// own bound; a run of `checker` (preflight's), a run only `others` reach, and a run whose bound
/// the job's deadline is, have the job's. Left out: test runs, which preflight's runner bounds;
/// a program the host runs only through an emulator (`-fqemu`, `-fwine`), which Zig starts
/// itself and only as a run's first argument. `bounds` names a run's own bound, each with its
/// reason; one naming no package run of `tests` is refused.
pub fn add(b: *std.Build, tests: *std.Build.Step, others: []const *std.Build.Step, bounds: []const RunBound, slowdown: i96, checker: Tool) void {
    const used = b.allocator.alloc(bool, bounds.len) catch @panic("OOM");
    @memset(used, false);
    for (bounds) |given| {
        if (std.mem.trim(u8, given.reason, " ").len == 0 or given.limit.nanoseconds <= 0 or given.limit.nanoseconds *| slowdown > std.math.maxInt(u64))
            tests.dependOn(&b.addFail(b.fmt("run_bounds: `{s}`: a bound is above zero, fits u64 nanoseconds, and says why the run needs it", .{given.step})).step);
    }
    var walk: Walk = .{ .b = b, .bounds = bounds, .used = used, .slowdown = slowdown, .checker = checker, .own = true };
    walk.visit(tests);
    walk.own = false;
    for (others) |step| walk.visit(step);
    for (bounds, used) |given, named| if (!named) tests.dependOn(&b.addFail(b.fmt("run_bounds: `{s}` names no run of the tests step that is no test: remove it, or name the run by its step's name", .{given.step})).step);
}

/// Bounds `run`, one of preflight's own, by the job's deadline.
pub fn job(b: *std.Build, run: *std.Build.Step.Run) void {
    const bound = program orelse return;
    wrap(b, bound, run, 0, &.{});
}

const Walk = struct {
    b: *std.Build,
    bounds: []const RunBound,
    used: []bool,
    slowdown: i96,
    checker: Tool,
    /// Whether the steps walked are the tests', whose package runs have their own bound.
    own: bool,
    seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty,

    fn visit(walk: *Walk, step: *std.Build.Step) void {
        const entry = walk.seen.getOrPut(walk.b.allocator, step) catch @panic("OOM");
        if (entry.found_existing) return;
        // A generator's run, which a test's compile waits for, is a run of the step too.
        for (step.dependencies.items) |child| walk.visit(child);
        const run = step.cast(std.Build.Step.Run) orelse return;
        const bound = program orelse return;
        if (run.argv.items.len == 0) return;
        switch (run.stdio) {
            // A test binary's run, which preflight's runner bounds test by test.
            .zig_test, .protocol => return,
            else => {},
        }
        var libraries: []const *std.Build.Step.Compile = &.{};
        var own = walk.own;
        switch (run.argv.items[0]) {
            .artifact => |first| {
                const artifact = first.artifact;
                if (artifact == bound) return;
                if (artifact.kind == .@"test") return;
                if (walk.checker == .compiled and walk.checker.compiled == artifact) own = false;
                if (!native(walk.b, artifact)) return;
                if (artifact.rootModuleTarget().os.tag == .windows) libraries = artifact.getCompileDependencies(true);
            },
            .bytes => |first| if (walk.checker == .prebuilt and std.mem.eql(u8, walk.checker.prebuilt, first)) {
                own = false;
            },
            else => {},
        }
        var nanoseconds: u64 = 0;
        if (own) {
            var limit = default_limit;
            for (walk.bounds, walk.used) |given, *used| if (std.mem.eql(u8, given.step, run.step.name)) {
                limit = given.limit;
                used.* = true;
            };
            nanoseconds = @intCast(@min(limit.nanoseconds *| walk.slowdown, std.math.maxInt(u64)));
        }
        wrap(walk.b, bound, run, nanoseconds, libraries);
    }
};

/// Puts the bound program before `run`'s command: its first argument the program, then the
/// bound (0 for the job's deadline alone), the step's name, the directories of the build's DLLs
/// `libraries` holds (Windows looks for them on `PATH`), and `--`.
fn wrap(b: *std.Build, bound: *std.Build.Step.Compile, run: *std.Build.Step.Run, nanoseconds: u64, libraries: []const *std.Build.Step.Compile) void {
    const command = run.argv.items.len;
    run.addArtifactArg2(bound, .{});
    run.addArg(b.fmt("{d}", .{nanoseconds}));
    run.addArg(run.step.name);
    for (libraries) |library| if (library.isDynamicLibrary() and library.rootModuleTarget().os.tag == .windows)
        run.addDirectoryArg2(library.getEmittedBinDirectory(), .{ .prefix = "--path=" });
    run.addArg("--");
    // The bound's arguments, appended, go before the command.
    std.mem.rotate(std.Build.Step.Run.Arg, run.argv.items, command);
}

/// Whether the host runs `artifact` itself, not through an emulator Zig starts.
fn native(b: *std.Build, artifact: *std.Build.Step.Compile) bool {
    const host = b.graph.host.result;
    const target = artifact.rootModuleTarget();
    return switch (std.zig.system.getExternalExecutor(b.graph.io, &target, .{
        .host_cpu_arch = host.cpu.arch,
        .host_os_tag = host.os.tag,
        .link_mode = artifact.linkage orelse .static,
        .link_libc = artifact.root_module.link_libc orelse false,
    })) {
        .native, .rosetta => true,
        else => false,
    };
}
