//! Continuous fuzzing, off the landing path: the `fuzz` step runs
//! shakedown's runner over the package's `check` properties. The fuzzing,
//! the corpora kept outside the package and the shrinking of what it finds
//! are shakedown's; this wires the step, as `bench` wires measuring.
const std = @import("std");
const configure = @import("configure.zig");

pub fn add(b: *std.Build, package: *std.Build, tests: *std.Build.Step, step: []const u8) void {
    const dep = (configure.declared(b, "shakedown", .{ .target = b.graph.host, .optimize = .safe }) catch return) orelse {
        tests.dependOn(&b.addFail("addCi .fuzz_step: the fuzzer is shakedown's, as are the properties it fuzzes; declare shakedown: a dev dependency with bay, else a lazy one").step);
        return;
    };
    const run = b.addRunArtifact(dep.artifact("shakedown-fuzz"));
    run.addArg("--package");
    run.addDirectoryArg2(package.path("."), .{});
    // The runner builds the step itself, as this same build: `bay dev` under bay, else zig build.
    if (configure.bay(b, package)) |bay| run.addArgs(&.{ "--bay", bay }) else run.addArgs(&.{ "--zig", b.graph.zig_exe });
    run.addArgs(&.{ "--step", step });
    run.addPassthruArgs();
    run.has_side_effects = true;
    configure.claim(b, "fuzz", "Fuzz the check properties off the landing path, corpora and findings outside the package: -- --limit 10M --sessions 1 --store ~/shakedown-fuzz --filter <test>").dependOn(&run.step);
}
