//! Seed every CI test runner; record timing evidence only when requested.
const std = @import("std");

pub fn add(b: *std.Build, tests: *std.Build.Step, dep: *std.Build.Dependency, timing: bool) void {
    var seen = std.AutoHashMap(*std.Build.Step, void).init(b.allocator);
    visit(b, tests, dep, timing, &seen);
}

fn visit(b: *std.Build, step: *std.Build.Step, dep: *std.Build.Dependency, timing: bool, seen: *std.AutoHashMap(*std.Build.Step, void)) void {
    const entry = seen.getOrPut(step) catch @panic("OOM");
    if (entry.found_existing) return;
    if (step.cast(std.Build.Step.Run)) |run| {
        if (run.argv.items.len == 0 or run.argv.items[0] != .artifact) return;
        const artifact = run.argv.items[0].artifact.artifact;
        if (artifact.kind != .@"test") return;
        const module = b.createModule(.{ .root_source_file = dep.path("src/timings.zig") });
        artifact.root_module.addImport("preflight_timings", module);
        artifact.root_module.addAnonymousImport("preflight_order", .{ .root_source_file = dep.path("src/shuffle.zig") });
        if (artifact.test_runner == null) {
            const path = dep.path("src/test_runner.zig");
            artifact.test_runner = .{ .path = path, .mode = .server };
            path.addStepDependencies(&artifact.step);
            artifact.root_module.addAnonymousImport("preflight_default_test_runner", .{
                .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ b.graph.zig_lib_directory.path.?, "compiler", "test_runner.zig" }) },
            });
            if (run.stdio != .zig_test) run.enableTestRunnerMode();
        }
        if (!timing) return;
        const target = artifact.root_module.resolved_target.?.result;
        const mode = artifact.root_module.optimize.?;
        const shard = b.graph.environ_map.get("PREFLIGHT_SHARD") orelse "all";
        run.setEnvironmentVariable("PREFLIGHT_TIMINGS", b.fmt(".zig-cache/preflight-timings/{s}-{s}-{s}-{s}.ndjson", .{
            artifact.name, @tagName(target.os.tag), @tagName(mode), shard,
        }));
        return;
    }
    for (step.dependencies.items) |child| visit(b, child, dep, timing, seen);
}
