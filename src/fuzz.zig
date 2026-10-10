//! Continuous fuzzing, off the landing path: the `fuzz` step runs
//! shakedown's runner over the package's `check` properties. The fuzzing,
//! the corpora kept outside the package and the shrinking of what it finds
//! are shakedown's; this wires the step, as `bench` wires measuring.
const std = @import("std");

pub fn add(b: *std.Build, pkg: *std.Build) void {
    const dep = pkg.dependencyLazy("shakedown", .{ .target = b.graph.host, .optimize = .safe }) catch return;
    const run = b.addRunArtifact(dep.artifact("shakedown-fuzz"));
    run.addArg("--package");
    run.addDirectoryArg2(b.path("."), .{});
    run.addArgs(&.{ "--zig", b.graph.zig_exe });
    run.addPassthruArgs();
    run.has_side_effects = true;
    b.step("fuzz", "Fuzz the check properties off the landing path, corpora and findings outside the package: -- --limit 10M --sessions 1 --store ~/shakedown-fuzz --filter <test>").dependOn(&run.step);
}
