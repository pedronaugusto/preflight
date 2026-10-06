//! Seed, shard and watch every CI test runner; record timing evidence only when requested.
const std = @import("std");

pub const Options = struct {
    timing: bool,
    /// 0 turns the watchdog off.
    test_timeout_ns: u64,
    /// The package's recorded durations, repository-relative.
    durations: []const u8,
};

pub fn add(b: *std.Build, tests: *std.Build.Step, pkg: *std.Build, options: Options) void {
    var seen = std.AutoHashMap(*std.Build.Step, void).init(b.allocator);
    visit(b, tests, pkg, options, &seen);
}

/// The shard this build runs, `i/n`, or null for every test.
pub fn shard(b: *std.Build) ?[]const u8 {
    const value = b.graph.environ_map.get("PREFLIGHT_SHARD") orelse return null;
    return if (value.len > 0) value else null;
}

/// The shard in a timing file's name: `2of5`, or `all`.
pub fn part(b: *std.Build) []const u8 {
    const value = shard(b) orelse return "all";
    return std.mem.replaceOwned(u8, b.allocator, value, "/", "of") catch @panic("OOM");
}

fn visit(b: *std.Build, step: *std.Build.Step, pkg: *std.Build, options: Options, seen: *std.AutoHashMap(*std.Build.Step, void)) void {
    const entry = seen.getOrPut(step) catch @panic("OOM");
    if (entry.found_existing) return;
    if (step.cast(std.Build.Step.Run)) |run| {
        if (run.argv.items.len == 0 or run.argv.items[0] != .artifact) return;
        const artifact = run.argv.items[0].artifact.artifact;
        if (artifact.kind != .@"test") return;
        const module = b.createModule(.{ .root_source_file = pkg.path("src/timings.zig") });
        artifact.root_module.addImport("preflight_timings", module);
        artifact.root_module.addAnonymousImport("preflight_order", .{ .root_source_file = pkg.path("src/order.zig") });
        if (artifact.test_runner == null) {
            const path = pkg.path("src/test_runner.zig");
            artifact.test_runner = .{ .path = path, .mode = .server };
            path.addStepDependencies(&artifact.step);
            artifact.root_module.addAnonymousImport("preflight_default_test_runner", .{
                .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ b.graph.zig_lib_directory.path.?, "compiler", "test_runner.zig" }) },
            });
            const runner = b.addOptions();
            runner.addOption(u64, "test_timeout_ns", options.test_timeout_ns);
            artifact.root_module.addOptions("preflight_runner_options", runner);
            if (run.stdio != .zig_test) run.enableTestRunnerMode();
        }
        if (shard(b) != null) run.setEnvironmentVariable("PREFLIGHT_DURATIONS", b.pathFromRoot(options.durations));
        if (!options.timing) return;
        const target = artifact.root_module.resolved_target.?.result;
        const mode = artifact.root_module.optimize.?;
        run.setEnvironmentVariable("PREFLIGHT_TIMINGS", b.fmt(".zig-cache/preflight-timings/{s}-{s}-{s}-{s}.ndjson", .{
            artifact.name, @tagName(target.os.tag), @tagName(mode), part(b),
        }));
        return;
    }
    for (step.dependencies.items) |child| visit(b, child, pkg, options, seen);
}
