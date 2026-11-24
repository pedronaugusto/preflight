//! `<directory> <root> <bay> <cache>`: writes the package developed with bay that the
//! integration test of one runs ("a package developed with bay runs the gate from dev"), at
//! `directory`, and runs its development build's gate and benchmarks there through `bay dev`,
//! with the fixtures' cache `cache`, before the suite: the warm run of that package.
//!
//! A development build's root is a directory of its own under the package, where Zig runs its
//! compiles, so the packages Zig unpacks beside the package (`zig-pkg`) are keyed in the cache
//! by their full paths: a package made afresh in a test's temporary directory compiled
//! preflight's checks, its build runner and the benchmarks from cold, inside the test's bound
//! (200 to 290 s at rest, 2 min of it the checks; past 300 s under load). Written at one place
//! and built here, the test finds every compile of it done.
const std = @import("std");

/// The sample's files the package takes as they are: what its gate and its consumer check read.
const copied = [_][]const u8{ "src/sample.zig", "src/testing/cases.zig", "src/testing/hardened.zig", "ci/layers.zig", "ci/preflight.json", "ci/consumer.zig", "LICENSE", "README.md", "CHANGELOG.md", "bench/sum.zig" };

/// What the package ships is `build`'s, with nothing but std; preflight and shakedown are dev
/// dependencies, which `dev` wires and Zig never shows a consumer.
const build_zig =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\    _ = b.addModule("preflight_sample", .{ .root_source_file = b.path("src/sample.zig"), .target = target, .optimize = optimize });
    \\}
    \\
    \\pub fn dev(b: *std.Build, tools: type) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\    const package = b.dependency("preflight_sample", .{ .target = target, .optimize = optimize });
    \\    const step = b.step("test", "Run the sample tests");
    \\    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = package.module("preflight_sample") })).step);
    \\    // The hook comes from the dev dependency, which only `dev` is given (`tools`); the
    \\    // function it calls names nothing of preflight's, so it lives where the rest does.
    \\    tools.preflight.addCi(b, package.builder, .{ .tests = step, .bench = .{ .programs = &.{.{ .name = "sum", .source = "bench/sum.zig" }}, .imports = tools.preflight.Bench.importsFrom(benchImports), .target = target, .optimize = optimize } });
    \\    tools.preflight.addConsumerCheck(b, package.builder, .{ .package = "preflight_sample", .program = package.path("ci/consumer.zig") });
    \\}
    \\
    \\fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    \\    const package = b.dependency("preflight_sample", .{ .target = target, .optimize = optimize });
    \\    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "sample", .module = package.module("preflight_sample") }}) catch @panic("OOM");
    \\}
    \\
;

const Pin = struct { url: []const u8, hash: []const u8 };

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 5) return error.DevelopedArguments;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, args[1]);
    var dir = try cwd.openDir(io, args[1], .{});
    defer dir.close(io);
    const directory = try dir.realPathFileAlloc(io, ".", a);
    const root = try cwd.realPathFileAlloc(io, args[2], a);
    for (copied) |path| try put(io, a, dir, path, try cwd.readFileAlloc(io, try std.Io.Dir.path.join(a, &.{ root, "sample", path }), a, .limited(1 << 20)));
    try put(io, a, dir, "build.zig", build_zig);
    // The benchmarks take preflight's own shakedown: its pin, read from its manifest, so it never drifts.
    const shakedown = try shakedownPin(io, a, root);
    const relative = try std.Io.Dir.path.relativeAlloc(a, root, null, directory, root);
    try put(io, a, dir, "build.zig.zon", try a.print(".{{ .name = .preflight_sample, .version = \"0.0.0\", .minimum_zig_version = \"0.17.0\", .fingerprint = 0x5460136369dcf618, .paths = .{{ \"build.zig\", \"build.zig.zon\", \"src\", \"LICENSE\", \"README.md\", \"CHANGELOG.md\" }}, .dependencies = .{{}}, .dev_dependencies = .{{ .preflight = .{{ .path = \"{f}\" }}, .shakedown = .{{ .url = \"{f}\", .hash = \"{f}\" }} }} }}", .{ std.zig.fmtString(relative), std.zig.fmtString(shakedown.url), std.zig.fmtString(shakedown.hash) }));
    // One development build runs the gate and the benchmarks, as a runner would: with the
    // cache outside the package, where `ZIG_LOCAL_CACHE_DIR` names the workspace's.
    var env = try init.environ_map.clone(a);
    try env.put("ZIG_LOCAL_CACHE_DIR", try cwd.realPathFileAlloc(io, args[4], a));
    var child = try std.process.spawn(io, .{ .argv = &.{ try cwd.realPathFileAlloc(io, args[3], a), "dev", "ci-test", "bench-build", "-Dci-lint=false" }, .cwd = .{ .path = directory }, .environ_map = &env });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

/// Writes `data` at `path` unless it holds it already: an unchanged file keeps its time, and
/// Zig takes it as unchanged without reading it again.
fn put(io: std.Io, a: std.mem.Allocator, dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.Io.Dir.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    if (dir.readFileAlloc(io, path, a, .limited(1 << 20))) |held| {
        if (std.mem.eql(u8, held, data)) return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

/// The shakedown preflight's own manifest pins as a dev dependency.
fn shakedownPin(io: std.Io, a: std.mem.Allocator, root: []const u8) !Pin {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, try std.Io.Dir.path.join(a, &.{ root, "build.zig.zon" }), a, .limited(1 << 20));
    const Manifest = struct { dev_dependencies: struct { shakedown: Pin } };
    var diagnostics: std.zon.parse.Diagnostics = .{ .errors = &.{} };
    const manifest = try std.zon.parse.fromSlice(Manifest, .{ .gpa = a, .arena = a, .source = try a.dupeSentinel(u8, text, 0), .diagnostics = &diagnostics, .ignore_unknown_fields = true });
    return manifest.dev_dependencies.shakedown;
}
