//! Build-only CI checks. Consumers never acquire the checker's dependencies.
const std = @import("std");

pub const Config = struct {
    tests: *std.Build.Step,
    layers: []const u8 = "ci/layers.zig",
    config: []const u8 = "ci/preflight.json",
};

pub fn addCi(b: *std.Build, config: Config) void {
    if (b.pkg_hash.len != 0) return;
    const lint = b.step("lint", "Check format, structure, Zig policy, docs and test imports");
    const ci = b.step("ci", "Run source checks, then the tests");
    ci.dependOn(config.tests);
    const enabled = b.option(bool, "ci-lint", "Run source checks before CI tests") orelse true;
    const dep = b.lazyDependency("preflight", .{}) orelse return;
    const gantry_dep = dep.builder.lazyDependency("gantry", .{ .target = b.graph.host, .optimize = .Debug }) orelse return;
    const gantry = gantry_dep.module("gantry");
    const layers = b.createModule(.{
        .root_source_file = b.path(config.layers),
        .target = b.graph.host,
        .imports = &.{.{ .name = "gantry", .module = gantry }},
    });
    const checker = b.addExecutable(.{
        .name = "preflight-structure",
        .root_module = b.createModule(.{
            .root_source_file = dep.path("src/structure.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{ .{ .name = "gantry", .module = gantry }, .{ .name = "layers", .module = layers } },
        }),
    });
    const format = b.addSystemCommand(&.{ "zig", "fmt", "--check", "." });
    format.setCwd(b.path("."));
    const structure = b.addRunArtifact(checker);
    structure.setCwd(b.path("."));
    const imports = b.step("check-imports", "Check declared source structure");
    imports.dependOn(&structure.step);
    if (b.args) |args| structure.addArgs(args);
    const lint_structure = b.addRunArtifact(checker);
    lint_structure.setCwd(b.path("."));
    lint_structure.step.dependOn(&format.step);
    const checks = b.addSystemCommand(&.{"python3"});
    checks.addFileArg(dep.path("checks/run.py"));
    checks.addArgs(&.{ "--config", config.config });
    checks.setCwd(b.path("."));
    checks.step.dependOn(&lint_structure.step);
    lint.dependOn(&checks.step);
    if (enabled) {
        orderTests(config.tests, lint);
        ci.dependOn(lint);
    }
}

// Only run steps acquire the lint prerequisite. Test compilation may overlap it.
fn orderTests(step: *std.Build.Step, lint: *std.Build.Step) void {
    if (step.id == .run) {
        step.dependOn(lint);
        return;
    }
    for (step.dependencies.items) |dependency| orderTests(dependency, lint);
}
