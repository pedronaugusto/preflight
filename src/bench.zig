//! Build and execution wiring. Measuring and comparison belong to shakedown.
const std = @import("std");
const configure = @import("configure.zig");

/// A repository's benchmark programs and their package modules.
pub const Bench = struct {
    programs: []const Program,
    imports: *const fn (*std.Build, std.Build.ResolvedTarget, std.lang.Optimize) []const std.Build.Module.Import = noImports,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    link_libc: ?bool = null,
    pub const Program = struct { name: []const u8, source: []const u8, timed: bool = true };
};
pub const smoke_flag = "--smoke";

pub fn add(b: *std.Build, pkg: *std.Build, tests: *std.Build.Step, bench: ?Bench, smoke: bool) void {
    const given = bench orelse {
        if (configure.exists(b, "bench")) tests.dependOn(&b.addFail("bench/: give addCi its .bench").step);
        return;
    };
    const dep = configure.dependency(b, pkg, "shakedown", .{ .target = b.graph.host, .optimize = .fast }) catch return;
    const comparison = dep.artifact("shakedown-bench-compare");
    const build = b.step("bench-build", "Build benchmarks and shakedown comparison in ReleaseFast; execute nothing");
    const step = b.step("bench", "Build and manually measure benchmark rows through shakedown");
    step.dependOn(build);
    build.dependOn(&b.addInstallArtifact(comparison, .{ .dest_dir = .{ .override = .{ .custom = "bench" } } }).step);
    var previous: ?*std.Build.Step = null;
    const commit = provenance(b);
    for (given.programs) |program| {
        const compile = executable(b, pkg, given, program, .fast, commit);
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
            const run = b.addRunArtifact(executable(b, pkg, given, program, given.optimize, commit));
            run.addArg(smoke_flag);
            run.setCwd(b.tmpPath());
            run.has_side_effects = true;
            run.expectExitCode(0);
            tests.dependOn(&run.step);
        }
    }
    const driver = b.addExecutable(.{ .name = "preflight-bench-ab", .root_module = b.createModule(.{
        .root_source_file = pkg.path("src/bench_driver.zig"),
        .target = b.graph.host,
        .optimize = .safe,
        .imports = &.{.{ .name = "shakedown", .module = dep.module("shakedown") }},
    }) });
    build.dependOn(&driver.step);
    const ab = b.addRunArtifact(driver);
    ab.addArgs(&.{ "--zig", b.graph.zig_exe, "--candidate" });
    ab.addDirectoryArg2(b.path("."), .{});
    ab.addArg("--comparison");
    ab.addArtifactArg2(comparison, .{});
    ab.addPassthruArgs();
    ab.setCwd(b.path("."));
    ab.has_side_effects = true;
    b.step("bench-ab", "Build an immutable base, interleave chosen ReleaseFast workloads, compare through shakedown").dependOn(&ab.step);
}

fn provenance(b: *std.Build) []const u8 {
    const cwd = b.root.toString(b.allocator) catch @panic("OOM");
    const git = std.process.run(b.allocator, b.graph.io, .{ .argv = &.{ "git", "rev-parse", "--absolute-git-dir" }, .cwd = .{ .path = cwd }, .stdout_limit = .limited(32768), .stderr_limit = .limited(32768) }) catch return "source-archive";
    if (git.term != .exited or git.term.exited != 0) return "source-archive";
    const directory = std.mem.trim(u8, git.stdout, "\r\n");
    const head_path = b.fmt("{s}/HEAD", .{directory});
    b.dependOnFileContents(.{ .cwd_relative = head_path });
    const head = std.Io.Dir.cwd().readFileAlloc(b.graph.io, head_path, b.allocator, .limited(32768)) catch return "source-archive";
    // A nested package still records its repository's real commit. Both loose
    // and packed refs are configuration inputs, rather than cached git guesses.
    if (std.mem.startsWith(u8, head, "ref: ")) {
        const ref = b.fmt("{s}/{s}", .{ directory, std.mem.trim(u8, head[5..], "\r\n") });
        b.dependOnDirectoryMetadata(.{ .cwd_relative = std.Io.Dir.path.dirname(ref).? });
        if (std.Io.Dir.cwd().access(b.graph.io, ref, .{})) |_| b.dependOnFileContents(.{ .cwd_relative = ref }) else |_| {}
    }
    b.dependOnDirectoryMetadata(.{ .cwd_relative = directory });
    const packed_path = b.fmt("{s}/packed-refs", .{directory});
    if (std.Io.Dir.cwd().access(b.graph.io, packed_path, .{})) |_| b.dependOnFileContents(.{ .cwd_relative = packed_path }) else |_| {}
    const result = std.process.run(b.allocator, b.graph.io, .{ .argv = &.{ "git", "rev-parse", "HEAD" }, .cwd = .{ .path = cwd }, .stdout_limit = .limited(1024), .stderr_limit = .limited(32768) }) catch return "source-archive";
    if (result.term != .exited or result.term.exited != 0) return "source-archive";
    return std.mem.trim(u8, result.stdout, "\r\n");
}

fn executable(b: *std.Build, pkg: *std.Build, bench: Bench, program: Bench.Program, optimize: std.lang.Optimize, commit: []const u8) *std.Build.Step.Compile {
    const dep = configure.dependency(b, pkg, "shakedown", .{ .target = bench.target, .optimize = optimize }) catch unreachable; // unreachable: lazy discovery restarts configuration
    const mod = b.createModule(.{ .root_source_file = b.path(program.source), .target = bench.target, .optimize = optimize, .link_libc = bench.link_libc, .imports = bench.imports(b, bench.target, optimize) });
    if (!mod.import_table.contains("shakedown")) mod.addImport("shakedown", dep.module("shakedown"));
    const metadata = b.addOptions();
    metadata.addOption([]const u8, "commit", commit);
    const root = std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, b.root.toString(b.allocator) catch @panic("OOM"), b.allocator) catch @panic("benchmark root unavailable");
    metadata.addOption([]const u8, "root", root);
    metadata.addOption([]const u8, "cpu", b.graph.host.result.cpu.model.name);
    metadata.addOption([]const u8, "os", @tagName(b.graph.host.result.os.tag));
    metadata.addOption([]const u8, "zig", b.graph.zig_exe);
    mod.addOptions("preflight_bench_options", metadata);
    return b.addExecutable(.{ .name = program.name, .root_module = mod });
}

fn noImports(_: *std.Build, _: std.Build.ResolvedTarget, _: std.lang.Optimize) []const std.Build.Module.Import {
    return &.{};
}
