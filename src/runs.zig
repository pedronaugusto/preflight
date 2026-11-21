//! The bound on each run the tests step makes that is no test: an example, a generator, a
//! benchmark's smoke run. Zig bounds unit tests alone (`--test-timeout`), and preflight's runner
//! bounds each test it runs; any other run had no bound but the hosted job's, and none at all
//! locally (blackbox's example ran 45 hours). Each such run runs under preflight's bound program
//! (`bound.zig`): past its bound, or when the hosted job's deadline comes sooner, it is ended,
//! and fails naming its step and its command.
const std = @import("std");
const Tool = @import("tool.zig").Tool;

/// A run's own bound, where the default is too short for it, and why. `step` is the run's
/// step's name, as the build names it (`run exe example`).
pub const RunBound = struct { step: []const u8, limit: std.Io.Duration, reason: []const u8 };

/// The bound of a run the build names no bound for.
pub const default_limit: std.Io.Duration = .fromSeconds(300);

/// Puts each run under `tests` that is no test under its bound, `slowdown` times longer, as the
/// tests' bound is under a sanitizer or an emulated machine. Left to their own bounds: test
/// runs, which preflight's runner bounds; runs of `checker`, preflight's own; and a program the
/// host runs only through an emulator (`-fqemu`, `-fwine`), which Zig starts itself and only
/// as a run's first argument: the hosted job's bound holds it. `bounds` names a run's own
/// bound, each with its reason; one naming no such run is refused.
pub fn add(b: *std.Build, pkg: *std.Build, tests: *std.Build.Step, bounds: []const RunBound, slowdown: i96, checker: Tool) void {
    const used = b.allocator.alloc(bool, bounds.len) catch @panic("OOM");
    @memset(used, false);
    for (bounds) |given| {
        if (std.mem.trim(u8, given.reason, " ").len == 0 or given.limit.nanoseconds <= 0 or given.limit.nanoseconds *| slowdown > std.math.maxInt(u64))
            tests.dependOn(&b.addFail(b.fmt("run_bounds: `{s}`: a bound is above zero, fits u64 nanoseconds, and says why the run needs it", .{given.step})).step);
    }
    var walk: Walk = .{ .b = b, .pkg = pkg, .bounds = bounds, .used = used, .slowdown = slowdown, .checker = checker };
    walk.visit(tests);
    for (bounds, used) |given, named| if (!named) tests.dependOn(&b.addFail(b.fmt("run_bounds: `{s}` names no run of the tests step that is no test: remove it, or name the run by its step's name", .{given.step})).step);
}

const Walk = struct {
    b: *std.Build,
    pkg: *std.Build,
    bounds: []const RunBound,
    used: []bool,
    slowdown: i96,
    checker: Tool,
    seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty,
    /// The bound program, built once for the host.
    program: ?*std.Build.Step.Compile = null,

    fn visit(walk: *Walk, step: *std.Build.Step) void {
        const entry = walk.seen.getOrPut(walk.b.allocator, step) catch @panic("OOM");
        if (entry.found_existing) return;
        // A generator's run, which a test's compile waits for, is a run of the tests step too.
        for (step.dependencies.items) |child| walk.visit(child);
        const run = step.cast(std.Build.Step.Run) orelse return;
        if (run.argv.items.len == 0) return;
        switch (run.stdio) {
            // A test binary's run, which preflight's runner bounds test by test.
            .zig_test, .protocol => return,
            else => {},
        }
        var libraries: []const *std.Build.Step.Compile = &.{};
        switch (run.argv.items[0]) {
            .artifact => |first| {
                const artifact = first.artifact;
                if (artifact.kind == .@"test") return;
                if (walk.checker == .compiled and walk.checker.compiled == artifact) return;
                if (!native(walk.b, artifact)) return;
                if (artifact.rootModuleTarget().os.tag == .windows) libraries = artifact.getCompileDependencies(true);
            },
            .bytes => |first| if (walk.checker == .prebuilt and std.mem.eql(u8, walk.checker.prebuilt, first)) return,
            else => {},
        }
        walk.bound(run, libraries);
    }

    /// Puts the bound program before `run`'s command: its first argument the program, then
    /// the bound, the step's name, the directories of the build's DLLs `libraries` holds
    /// (Windows looks for them on `PATH`), and `--`.
    fn bound(walk: *Walk, run: *std.Build.Step.Run, libraries: []const *std.Build.Step.Compile) void {
        const b = walk.b;
        const program = walk.program orelse made: {
            const made = b.addExecutable(.{ .name = "preflight-bound", .root_module = b.createModule(.{
                .root_source_file = walk.pkg.path("src/bound.zig"),
                .target = b.graph.host,
                .optimize = .debug,
            }) });
            walk.program = made;
            break :made made;
        };
        var limit = default_limit;
        for (walk.bounds, walk.used) |given, *used| if (std.mem.eql(u8, given.step, run.step.name)) {
            limit = given.limit;
            used.* = true;
        };
        const nanoseconds: u64 = @intCast(@min(limit.nanoseconds *| walk.slowdown, std.math.maxInt(u64)));
        const command = run.argv.items.len;
        run.addArtifactArg(program);
        run.addArg(b.fmt("{d}", .{nanoseconds}));
        run.addArg(run.step.name);
        for (libraries) |library| if (library.isDynamicLibrary() and library.rootModuleTarget().os.tag == .windows)
            run.addDirectoryArg2(library.getEmittedBinDirectory(), .{ .prefix = "--path=" });
        run.addArg("--");
        // The bound's arguments, appended, go before the command.
        std.mem.rotate(std.Build.Step.Run.Arg, run.argv.items, command);
    }
};

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
