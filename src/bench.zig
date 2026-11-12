//! Build and execution wiring. Measuring and comparison belong to shakedown.
const std = @import("std");
const aegis = @import("aegis");
const configure = @import("configure.zig");
const family = @import("family.zig");

/// A repository's benchmark programs and their package modules.
pub const Bench = struct {
    programs: []const Program,
    /// The package's own modules the programs import, made where they are built (`Imports`).
    imports: ?*const Imports = null,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    link_libc: ?bool = null,
    pub const Program = struct { name: []const u8, source: []const u8, timed: bool = true };
    /// What the benchmarks import beside shakedown, made for each mode they are built in. A package
    /// embeds it in its own state and gets that state back with `@fieldParentPtr`, so what the
    /// modules need is held there, never in a container-level variable.
    pub const Imports = struct {
        make: *const fn (*const Imports, *std.Build, std.Build.ResolvedTarget, std.lang.Optimize) []const std.Build.Module.Import,
    };

    /// What makes a package's modules for one mode, from what it is built for and nothing else.
    pub const MakeImports = fn (*std.Build, std.Build.ResolvedTarget, std.lang.Optimize) []const std.Build.Module.Import;

    /// The hook for imports that need no state: `.imports = tools.preflight.Bench.importsFrom(benchImports)`.
    /// Each function given has one hook of its own, made at compile time, which calls it.
    pub fn importsFrom(comptime make: MakeImports) *const Imports {
        return &struct {
            const hook: Imports = .{ .make = call };
            fn call(_: *const Imports, b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
                return make(b, target, optimize);
            }
        }.hook;
    }
};
pub const smoke_flag = "--smoke";

/// The step that builds the benchmarks, or null when there are none. With shakedown the programs
/// measure through `shakedown.bench` and `bench-ab` compares two revisions; without it they are
/// built, smoke-run and run, and nothing is compared. The family's policy requires shakedown.
pub fn add(b: *std.Build, package: *std.Build, pkg: *std.Build, tests: *std.Build.Step, bench: ?Bench, smoke: bool, policy: family.Policy) ?*std.Build.Step {
    const given = bench orelse {
        if (configure.exists(package, "bench")) tests.dependOn(&b.addFail("bench/: give addCi its .bench").step);
        return null;
    };
    // With shakedown, the programs measure through shakedown.bench and the comparison reads what they
    // write: both are the package's own shakedown, never a copy of preflight's.
    const shakedown = configure.declared(b, "shakedown", .{ .target = b.graph.host, .optimize = .fast }) catch return null;
    if (shakedown == null and policy == .family) {
        tests.dependOn(&b.addFail("addCi .bench: under the family's policy benchmarks measure through shakedown.bench; declare shakedown: a dev dependency with bay, else a lazy one").step);
        return null;
    }
    const build = configure.claim(b, "bench-build", "Build the benchmarks in ReleaseFast, and shakedown's comparison when shakedown is declared; execute nothing");
    const step = configure.claim(b, "bench", "Build and run the timed benchmark programs; with shakedown, measure their rows");
    step.dependOn(build);
    if (shakedown) |dep| build.dependOn(&b.addInstallArtifact(dep.artifact("shakedown-bench-compare"), .{ .dest_dir = .{ .override = .{ .custom = "bench" } } }).step);
    var previous: ?*std.Build.Step = null;
    const commit = provenance(package);
    for (given.programs) |program| {
        const compile = executable(b, package, given, program, .fast, commit, shakedown != null);
        build.dependOn(&b.addInstallArtifact(compile, .{ .dest_dir = .{ .override = .{ .custom = "bench" } } }).step);
        if (program.timed) {
            const run = b.addRunArtifact(compile);
            run.setCwd(b.tmpPath());
            run.has_side_effects = true;
            if (previous) |before| run.step.dependOn(before);
            previous = &run.step;
            step.dependOn(&run.step);
        }
        if (smoke) {
            const run = b.addRunArtifact(executable(b, package, given, program, given.optimize, commit, shakedown != null));
            run.addArg(smoke_flag);
            run.setCwd(b.tmpPath());
            run.has_side_effects = true;
            run.expectExitCode(0);
            tests.dependOn(&run.step);
        }
    }
    // Two revisions compared is shakedown's measurement: without it there is no `bench-ab`.
    const dep = shakedown orelse return build;
    const comparison = dep.artifact("shakedown-bench-compare");
    // The caller types the driver's arguments after `--`; ensign reads them, as preflight's own.
    // Configured as shakedown is, so the two share one aegis.
    const ensign = pkg.dependencyLazy("ensign", .{ .target = b.graph.host, .optimize = .fast }) catch return null;
    const driver = b.addExecutable(.{ .name = "preflight-bench-ab", .root_module = b.createModule(.{
        .root_source_file = pkg.path("src/bench_driver.zig"),
        .target = b.graph.host,
        .optimize = .safe,
        .imports = &.{ .{ .name = "shakedown", .module = dep.module("shakedown") }, .{ .name = "ensign", .module = ensign.module("ensign") } },
    }) });
    build.dependOn(&driver.step);
    const ab = b.addRunArtifact(driver);
    ab.addArgs(&.{ "--zig", b.graph.zig_exe });
    if (configure.bay(b, package)) |bay| ab.addArgs(&.{ "--bay", bay });
    ab.addArg("--candidate");
    ab.addDirectoryArg2(package.path("."), .{});
    ab.addArg("--comparison");
    ab.addArtifactArg2(comparison, .{});
    ab.addPassthruArgs();
    ab.setCwd(package.path("."));
    ab.has_side_effects = true;
    configure.claim(b, "bench-ab", "Build an immutable base, interleave chosen ReleaseFast workloads, compare through shakedown").dependOn(&ab.step);
    return build;
}

fn provenance(b: *std.Build) []const u8 {
    const cwd = b.root.toString(b.allocator) catch @panic("OOM");
    // A linked worktree keeps its HEAD in its own git directory and the branches in the
    // repository's common one.
    const git = std.process.run(b.allocator, b.graph.io, .{ .argv = &.{ "git", "rev-parse", "--path-format=absolute", "--absolute-git-dir", "--git-common-dir" }, .cwd = .{ .path = cwd }, .stdout_limit = .limited(32768), .stderr_limit = .limited(32768) }) catch return "source-archive";
    if (git.term != .exited or git.term.exited != 0) return "source-archive";
    var lines = std.mem.tokenizeAny(u8, git.stdout, "\r\n");
    const directory = lines.next() orelse return "source-archive";
    const common = lines.next() orelse return "source-archive";
    const head_path = b.fmt("{s}/HEAD", .{directory});
    b.dependOnFileContents(.{ .cwd_relative = head_path });
    const head = aegis.own.readFile(b.graph.io, std.Io.Dir.cwd(), head_path, b.allocator, .fromRaw(32768)) catch return "source-archive";
    // A nested package still records its repository's real commit. Both loose
    // and packed refs are configuration inputs, rather than cached git guesses.
    if (std.mem.startsWith(u8, head, "ref: ")) {
        const ref = b.fmt("{s}/{s}", .{ common, std.mem.trim(u8, head[5..], "\r\n") });
        b.dependOnDirectoryMetadata(.{ .cwd_relative = std.Io.Dir.path.dirname(ref).? });
        if (std.Io.Dir.cwd().access(b.graph.io, ref, .{})) |_| b.dependOnFileContents(.{ .cwd_relative = ref }) else |_| {}
    }
    b.dependOnDirectoryMetadata(.{ .cwd_relative = directory });
    const packed_path = b.fmt("{s}/packed-refs", .{common});
    if (std.Io.Dir.cwd().access(b.graph.io, packed_path, .{})) |_| b.dependOnFileContents(.{ .cwd_relative = packed_path }) else |_| {}
    const result = std.process.run(b.allocator, b.graph.io, .{ .argv = &.{ "git", "rev-parse", "HEAD" }, .cwd = .{ .path = cwd }, .stdout_limit = .limited(1024), .stderr_limit = .limited(32768) }) catch return "source-archive";
    if (result.term != .exited or result.term.exited != 0) return "source-archive";
    return std.mem.trim(u8, result.stdout, "\r\n");
}

fn executable(b: *std.Build, package: *std.Build, bench: Bench, program: Bench.Program, optimize: std.lang.Optimize, commit: []const u8, measured: bool) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .root_source_file = package.path(program.source), .target = bench.target, .optimize = optimize, .link_libc = bench.link_libc, .imports = if (bench.imports) |hook| hook.make(hook, b, bench.target, optimize) else &.{} });
    // A benchmark measures through the shakedown the package declares, the one its tests
    // link; `imports` gives the package's own modules, and one way is the only way.
    if (mod.import_table.contains("shakedown")) std.debug.panic("bench.imports gives `shakedown`: preflight adds the one the package declares; leave it out of the list", .{});
    if (measured) {
        const found = configure.declared(b, "shakedown", .{ .target = bench.target, .optimize = optimize });
        // unreachable: `add` fetched it first, and says `measured` only for a package that declares it
        const dep = (found catch unreachable).?;
        mod.addImport("shakedown", dep.module("shakedown"));
    }
    const metadata = b.addOptions();
    metadata.addOption([]const u8, "commit", commit);
    const root = std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, package.root.toString(b.allocator) catch @panic("OOM"), b.allocator) catch @panic("benchmark root unavailable");
    metadata.addOption([]const u8, "root", root);
    metadata.addOption([]const u8, "cpu", b.graph.host.result.cpu.model.name);
    metadata.addOption([]const u8, "os", @tagName(b.graph.host.result.os.tag));
    metadata.addOption([]const u8, "zig", b.graph.zig_exe);
    mod.addOptions("preflight_bench_options", metadata);
    return b.addExecutable(.{ .name = program.name, .root_module = mod });
}
