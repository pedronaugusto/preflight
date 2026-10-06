//! Seed, shard, bound and watch every CI test runner; record timing evidence only when requested.
const std = @import("std");

pub const Options = struct {
    timing: bool,
    /// The watchdog's bound on one test; 0 turns it off.
    test_timeout_ns: u64,
    test_log_level: std.log.Level,
    /// The package's recorded durations, repository-relative.
    durations: []const u8,
};

/// A package keeps the default bound unless it says why not.
pub const TestTimeout = union(enum) {
    /// `default_limit`.
    default,
    /// Another bound, and why the package needs it.
    bound: struct { limit: std.Io.Duration, reason: []const u8 },
    /// No watchdog, and why: a test runner of its own, a single-threaded build.
    off: []const u8,

    pub const default_limit: std.Io.Duration = .fromSeconds(120);

    /// The bound in nanoseconds, 0 for none, or null when a reason is missing.
    pub fn nanoseconds(timeout: TestTimeout) ?u64 {
        return switch (timeout) {
            .default => @intCast(default_limit.toNanoseconds()),
            .bound => |custom| if (std.mem.trim(u8, custom.reason, " ").len == 0) null else @intCast(@max(custom.limit.toNanoseconds(), 1)),
            .off => |reason| if (std.mem.trim(u8, reason, " ").len == 0) null else 0,
        };
    }
};

pub fn add(b: *std.Build, tests: *std.Build.Step, pkg: *std.Build, options: Options) void {
    var seen = std.AutoHashMap(*std.Build.Step, void).init(b.allocator);
    var names = std.StringHashMap(void).init(b.allocator);
    visit(b, tests, pkg, options, &seen, &names);
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

/// The build runner's bound on one test: the watchdog's and a margin, a
/// quarter of it and at least 15 s, so the watchdog, which names the test,
/// its phase and its seed, always fires first. Null without a watchdog.
pub fn outerTimeout(test_timeout_ns: u64) ?u64 {
    if (test_timeout_ns == 0) return null;
    return test_timeout_ns +| @max(test_timeout_ns / 4, 15 * std.time.ns_per_s);
}

/// Has the build runner bound each test `run` runs by `outer_ns`, in place
/// of `--test-timeout`. Call it before anything else wraps the step.
pub fn bound(run: *std.Build.Step.Run, outer_ns: ?u64) void {
    const ns = outer_ns orelse return;
    if (Bounded.original) |original| std.debug.assert(original == run.step.makeFn) else Bounded.original = run.step.makeFn;
    Bounded.ns = ns;
    run.step.makeFn = Bounded.make;
}

const Bounded = struct {
    /// Every run step's own make, the same function for all of them.
    var original: ?std.Build.Step.MakeFn = null;
    /// One package's gate per build, so one bound.
    var ns: u64 = 0;

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        var bounded = options;
        bounded.unit_test_timeout_ns = ns;
        return original.?(step, bounded);
    }
};

fn visit(b: *std.Build, step: *std.Build.Step, pkg: *std.Build, options: Options, seen: *std.AutoHashMap(*std.Build.Step, void), names: *std.StringHashMap(void)) void {
    const entry = seen.getOrPut(step) catch @panic("OOM");
    if (entry.found_existing) return;
    if (step.cast(std.Build.Step.Run)) |run| {
        if (run.argv.items.len == 0 or run.argv.items[0] != .artifact) return;
        if (run.argv.items[0].artifact.artifact.kind != .@"test") return;
        instrument(b, run, pkg, options, names);
        return;
    }
    for (step.dependencies.items) |child| visit(b, child, pkg, options, seen, names);
}

/// Gives the test artifact `run` runs preflight's runner and its modules,
/// and the run its bound, shard and timing record. `names` holds the timing
/// record names already given out.
fn instrument(b: *std.Build, run: *std.Build.Step.Run, pkg: *std.Build, options: Options, names: *std.StringHashMap(void)) void {
    const artifact = run.argv.items[0].artifact.artifact;
    const module = b.createModule(.{ .root_source_file = pkg.path("src/timings.zig") });
    artifact.root_module.addImport("preflight_timings", module);
    artifact.root_module.addAnonymousImport("preflight_order", .{ .root_source_file = pkg.path("src/order.zig") });
    if (artifact.test_runner != null) {
        // That runner neither arms the watchdog nor reads the shard.
        if (options.test_timeout_ns != 0) refuse("{s}: a test runner of its own arms no watchdog; set .test_timeout = .{{ .off = reason }}", b, run, .{artifact.name});
        if (shard(b) != null) refuse("{s}: a test runner of its own runs every shard's tests; drop the shards or the runner", b, run, .{artifact.name});
    } else {
        const path = pkg.path("src/runner.zig");
        artifact.test_runner = .{ .path = path, .mode = .server };
        path.addStepDependencies(&artifact.step);
        artifact.root_module.addAnonymousImport("preflight_default_test_runner", .{
            .root_source_file = .{ .cwd_relative = b.pathJoin(&.{ b.graph.zig_lib_directory.path.?, "compiler", "test_runner.zig" }) },
        });
        const runner = b.addOptions();
        runner.addOption(u64, "test_timeout_ns", options.test_timeout_ns);
        runner.addOption(std.log.Level, "test_log_level", options.test_log_level);
        artifact.root_module.addOptions("preflight_runner_options", runner);
        if (run.stdio != .zig_test) run.enableTestRunnerMode();
    }
    if (options.test_timeout_ns != 0 and singleThreaded(artifact)) refuse("{s}: a single-threaded build has no watchdog; set .test_timeout = .{{ .off = reason }}", b, run, .{artifact.name});
    bound(run, outerTimeout(options.test_timeout_ns));
    if (shard(b) != null) run.setEnvironmentVariable("PREFLIGHT_DURATIONS", b.pathFromRoot(options.durations));
    if (!options.timing) return;
    const target = artifact.root_module.resolved_target.?.result;
    const stem = b.fmt("{s}-{s}-{s}", .{ artifact.name, @tagName(target.os.tag), @tagName(artifact.root_module.optimize.?) });
    // Two runs that share a name would truncate each other's records.
    var name = stem;
    var count: usize = 2;
    while ((names.getOrPut(name) catch @panic("OOM")).found_existing) : (count += 1) name = b.fmt("{s}-{d}", .{ stem, count });
    run.setEnvironmentVariable("PREFLIGHT_TIMINGS", b.fmt(".zig-cache/preflight-timings/{s}-{s}.ndjson", .{ name, part(b) }));
}

/// Fails `run`, when the build gets to it, with a message naming why.
fn refuse(comptime format: []const u8, b: *std.Build, run: *std.Build.Step.Run, args: anytype) void {
    run.step.dependOn(&b.addFail(b.fmt(format, args)).step);
}

fn singleThreaded(artifact: *std.Build.Step.Compile) bool {
    if (artifact.root_module.single_threaded) |single| return single;
    const target = artifact.root_module.resolved_target.?.result;
    return target.cpu.arch.isWasm() and !target.cpu.has(.wasm, .atomics);
}

test "the build runner's bound outlasts the watchdog's by a quarter, at least 15 s" {
    try std.testing.expectEqual(@as(?u64, null), outerTimeout(0));
    try std.testing.expectEqual(@as(?u64, 45 * std.time.ns_per_s), outerTimeout(30 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(?u64, 150 * std.time.ns_per_s), outerTimeout(120 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(?u64, 15 * std.time.ns_per_s + 300 * std.time.ns_per_ms), outerTimeout(300 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), outerTimeout(std.math.maxInt(u64)));
}

test "the default test timeout needs no reason, any other one does" {
    try std.testing.expectEqual(@as(?u64, 120 * std.time.ns_per_s), TestTimeout.nanoseconds(.default));
    try std.testing.expectEqual(@as(?u64, 30 * std.time.ns_per_s), TestTimeout.nanoseconds(.{ .bound = .{ .limit = .fromSeconds(30), .reason = "spawns are slow" } }));
    try std.testing.expectEqual(@as(?u64, 0), TestTimeout.nanoseconds(.{ .off = "its own runner" }));
    try std.testing.expectEqual(@as(?u64, null), TestTimeout.nanoseconds(.{ .bound = .{ .limit = .fromSeconds(30), .reason = "" } }));
    try std.testing.expectEqual(@as(?u64, null), TestTimeout.nanoseconds(.{ .off = " " }));
}
