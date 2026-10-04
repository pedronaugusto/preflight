//! Build-only CI checks. Consumers never acquire the checker's dependencies.
const std = @import("std");
const portable = @import("portable.zig");
const record = @import("record.zig");

pub const Config = struct {
    tests: *std.Build.Step,
    layers: []const u8 = "ci/layers.zig",
    config: []const u8 = "ci/preflight.json",
    portable_tests: bool = false,
    timings_enabled: ?bool = null,
};

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
    const lint = b.step("lint", "Check format, structure, Zig policy, docs and test imports");
    const ci = b.step("ci", "Run source checks, then the tests");
    ci.dependOn(config.tests);
    forceTests(config.tests);
    const enabled = b.option(bool, "ci-lint", "Run source checks before CI tests") orelse true;
    const dep = b.lazyDependency("preflight", .{}) orelse return;
    const host = ciTarget(b);
    const executable = b.addExecutable(.{
        .name = "preflight-checks",
        .root_module = b.createModule(.{
            .root_source_file = dep.path("src/main.zig"),
            .target = host,
            .optimize = .ReleaseSafe,
        }),
    });
    const timing = config.timings_enabled orelse (b.option(bool, "ci-timings", "Record per-test durations for the next full-tier shard plan") orelse false);
    if (timing) record.add(b, config.tests, dep);
    if (config.portable_tests) portable.add(b, config.tests);
    const cache = b.addRunArtifact(executable);
    cache.addArgs(&.{ "cache", "--path", ".zig-cache" });
    cache.setCwd(b.path("."));
    b.step("cache", "Prune compiled products while preserving packages and tools").dependOn(&cache.step);
    const linux = b.addRunArtifact(executable);
    linux.addArg("container");
    if (b.args) |args| linux.addArgs(args);
    linux.setCwd(b.path("."));
    b.step("ci-linux", "Run the explicit Linux container gate").dependOn(&linux.step);
    const docs = b.addRunArtifact(executable);
    docs.addArgs(&.{ "docs", "--config", config.config, "--region" });
    docs.addArgs(b.args orelse &.{"usage"});
    docs.setCwd(b.path("."));
    b.step("docs", "Render a configured documentation region").dependOn(&docs.step);
    const gantry_dep = dep.builder.lazyDependency("gantry", .{ .target = host, .optimize = .Debug }) orelse return;
    const gantry = gantry_dep.module("gantry");
    const layers = b.createModule(.{
        .root_source_file = b.path(config.layers),
        .target = host,
        .imports = &.{.{ .name = "gantry", .module = gantry }},
    });
    const checker = b.addExecutable(.{
        .name = "preflight-structure",
        .root_module = b.createModule(.{
            .root_source_file = dep.path("src/structure.zig"),
            .target = host,
            .optimize = .Debug,
            .imports = &.{ .{ .name = "gantry", .module = gantry }, .{ .name = "layers", .module = layers } },
        }),
    });
    var format_paths: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "build.zig", "build.zig.zon", "src", "examples", "ci", "conformance", "bench" }) |path| {
        b.build_root.handle.access(b.graph.io, path, .{}) catch continue;
        format_paths.append(b.allocator, path) catch @panic("OOM");
    }
    const format = b.addFmt(.{ .paths = format_paths.items, .check = true });
    const structure = b.addRunArtifact(checker);
    structure.setCwd(b.path("."));
    b.step("check-imports", "Check declared source structure").dependOn(&structure.step);
    if (b.args) |args| structure.addArgs(args);
    const lint_structure = b.addRunArtifact(checker);
    lint_structure.setCwd(b.path("."));
    lint_structure.step.dependOn(&format.step);
    const ziglint_dep = dep.builder.lazyDependency("ziglint", .{ .target = host, .optimize = .ReleaseSafe }) orelse return;
    const checks = b.addRunArtifact(executable);
    checks.addArgs(&.{ "lint", "--config", config.config, "--ziglint" });
    checks.addArtifactArg(ziglint_dep.artifact("ziglint"));
    checks.setCwd(b.path("."));
    checks.step.dependOn(&lint_structure.step);
    lint.dependOn(&checks.step);
    if (enabled) {
        orderTests(config.tests, lint);
        ci.dependOn(lint);
    }
}

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
    if (step.id == .run) {
        step.dependOn(lint);
        return;
    }
    for (step.dependencies.items) |dependency| orderTests(dependency, lint);
}
