//! Seed, shard, bound and watch every CI test runner; record timing evidence only when requested.
//! A test run carries no environment of the build's: Zig bakes a run's
//! environment into the cached configuration, so the shard and seed would go
//! stale. The runner reads them when it runs, and its options module carries
//! the rest.
const std = @import("std");
const configure = @import("configure.zig");

pub const Options = struct {
    timing: bool,
    /// The watchdog's bound on one test; 0 turns it off.
    test_timeout: std.Io.Duration,
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

    /// The bound, zero for none, or null for a missing reason or overflow.
    /// aegis-raw: design: retain std's duration in the
    /// build helper, checking the generated runner's u64 schema before export.
    /// The published aegis build helper exports no scalar namespaces.
    pub fn duration(timeout: TestTimeout) ?std.Io.Duration {
        return switch (timeout) {
            .default => default_limit,
            .bound => |custom| bound: {
                if (std.mem.trim(u8, custom.reason, " ").len == 0) break :bound null;
                const ns = @max(custom.limit.toNanoseconds(), 1);
                if (ns > std.math.maxInt(u64)) break :bound null;
                break :bound .fromNanoseconds(ns);
            },
            .off => |reason| if (std.mem.trim(u8, reason, " ").len == 0) null else .zero,
        };
    }
};

/// `checker` is preflight's command program, which refuses a shard at run
/// time for a test runner that cannot honour one.
pub fn add(b: *std.Build, tests: *std.Build.Step, pkg: *std.Build, checker: *std.Build.Step.Compile, options: Options) void {
    var seen = std.AutoHashMap(*std.Build.Step, void).init(b.allocator);
    var names = std.StringHashMap(void).init(b.allocator);
    const durations = configure.read(b, options.durations, .limited(64 * 1024 * 1024)) orelse "";
    const context: Context = .{ .pkg = pkg, .checker = checker, .options = options, .durations = durations };
    visit(b, tests, context, &seen, &names);
}

const Context = struct {
    pkg: *std.Build,
    checker: *std.Build.Step.Compile,
    options: Options,
    /// The recorded durations' text, built into each runner.
    durations: []const u8,
};

fn visit(b: *std.Build, step: *std.Build.Step, context: Context, seen: *std.AutoHashMap(*std.Build.Step, void), names: *std.StringHashMap(void)) void {
    const entry = seen.getOrPut(step) catch @panic("OOM");
    if (entry.found_existing) return;
    if (step.cast(std.Build.Step.Run)) |run| {
        if (run.argv.items.len == 0 or run.argv.items[0] != .artifact) return;
        if (run.argv.items[0].artifact.artifact.kind != .@"test") return;
        instrument(b, run, context, names);
        return;
    }
    for (step.dependencies.items) |child| visit(b, child, context, seen, names);
}

/// Gives the test artifact `run` runs preflight's runner and its modules,
/// and the run its watchdog, durations and timing record. `names` holds the
/// timing record names already given out.
fn instrument(b: *std.Build, run: *std.Build.Step.Run, context: Context, names: *std.StringHashMap(void)) void {
    const options = context.options;
    const artifact = run.argv.items[0].artifact.artifact;
    // `setEnvironmentVariable` clones the whole environment into the run, and
    // Zig 0.17 keeps it in the cached configuration: a later shard, seed or
    // tool path would find it stale.
    if (run.environ_map != null) refuse("{s}: a test run carries no environment of the build's; Zig 0.17 keeps it in the cached configuration, where it goes stale. Read it when the tests run", b, run, .{artifact.name});
    // The runner's modules and options are the test module's imports, so
    // artifacts that share a root module share them, timing record included.
    if (artifact.root_module.import_table.get("preflight_runner_options") == null) {
        const module = b.createModule(.{ .root_source_file = context.pkg.path("src/timings.zig") });
        artifact.root_module.addImport("preflight_timings", module);
        const target = artifact.root_module.resolved_target.?;
        const optimize = artifact.root_module.optimize.?;
        const safety = context.pkg.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
        artifact.root_module.addImport("preflight_aegis", safety);
        artifact.root_module.addAnonymousImport("preflight_order", .{
            .root_source_file = context.pkg.path("src/order.zig"),
            .imports = &.{.{ .name = "preflight_aegis", .module = safety }},
        });
        const runner = b.addOptions();
        // aegis-raw: design: the generated options schema
        // is raw u64, validated by TestTimeout.duration and wrapped by the runner.
        runner.addOption(u64, "test_timeout_ns", @intCast(options.test_timeout.toNanoseconds())); // safe: validated export range
        runner.addOption(std.log.Level, "test_log_level", options.test_log_level);
        runner.addOption(?[]const u8, "timings", if (options.timing) timings(b, artifact, names) else null);
        runner.addOption([]const u8, "durations", context.durations);
        artifact.root_module.addOptions("preflight_runner_options", runner);
    }
    if (artifact.test_runner != null) {
        // That runner neither arms the watchdog nor reads the shard.
        if (options.test_timeout.toNanoseconds() != 0) refuse("{s}: a test runner of its own arms no watchdog; set .test_timeout = .{{ .off = reason }}", b, run, .{artifact.name});
        const unsharded = b.addRunArtifact(context.checker);
        unsharded.addArgs(&.{ "unsharded", artifact.name });
        unsharded.has_side_effects = true;
        run.step.dependOn(&unsharded.step);
    } else {
        const path = context.pkg.path("src/runner.zig");
        artifact.test_runner = .{ .path = path, .mode = .server };
        path.addStepDependencies(&artifact.step);
        artifact.root_module.addAnonymousImport("preflight_default_test_runner", .{
            .root_source_file = b.graph.path(.zig_lib, "compiler/test_runner.zig"),
        });
        // Not `enableProtocolMode`, though 0.17 deprecates this for it:
        // Zig 0.17's test runner reads its cache directory and seed from
        // argv, which only `.zig_test` passes, and a `.protocol` run cannot
        // fuzz. std's own `addRunArtifact` still sets `.zig_test`.
        if (run.stdio != .zig_test) run.enableTestRunnerMode();
    }
    if (options.test_timeout.toNanoseconds() != 0 and singleThreaded(artifact)) refuse("{s}: a single-threaded build has no watchdog; set .test_timeout = .{{ .off = reason }}", b, run, .{artifact.name});
}

/// The run's timing record, without its shard: the runner appends the shard
/// it runs, `-2of5.ndjson`, or `-all.ndjson`.
fn timings(b: *std.Build, artifact: *std.Build.Step.Compile, names: *std.StringHashMap(void)) []const u8 {
    const target = artifact.root_module.resolved_target.?.result;
    const stem = b.fmt("{s}-{s}-{s}", .{ artifact.name, @tagName(target.os.tag), @tagName(artifact.root_module.optimize.?) });
    // Two runs that share a name would truncate each other's records.
    var name = stem;
    // aegis-raw: no-danger: one build owns this name suffix; it is not an ID
    // or an externally supplied count and never meets another number domain.
    var count: usize = 2;
    while ((names.getOrPut(name) catch @panic("OOM")).found_existing) : (count += 1) name = b.fmt("{s}-{d}", .{ stem, count });
    return b.fmt(".zig-cache/preflight-timings/{s}", .{name});
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

test "the default test timeout needs no reason, any other one does" {
    try std.testing.expectEqual(@as(?std.Io.Duration, .fromSeconds(120)), TestTimeout.duration(.default));
    try std.testing.expectEqual(@as(?std.Io.Duration, .fromSeconds(30)), TestTimeout.duration(.{ .bound = .{ .limit = .fromSeconds(30), .reason = "spawns are slow" } }));
    try std.testing.expectEqual(@as(?std.Io.Duration, .zero), TestTimeout.duration(.{ .off = "its own runner" }));
    try std.testing.expectEqual(@as(?std.Io.Duration, null), TestTimeout.duration(.{ .bound = .{ .limit = .fromSeconds(30), .reason = "" } }));
    try std.testing.expectEqual(@as(?std.Io.Duration, null), TestTimeout.duration(.{ .off = " " }));
}

test "timeout rejects nanoseconds that cannot fit the runner option" {
    const too_large: std.Io.Duration = .fromNanoseconds(@as(i96, std.math.maxInt(u64)) + 1);
    try std.testing.expectEqual(@as(?std.Io.Duration, null), TestTimeout.duration(.{ .bound = .{ .limit = too_large, .reason = "explicit large bound" } }));
}

test "timeout boundary preserves representable bounds and rejects overflow" {
    const shake = @import("shakedown");
    try shake.check(std.testing.allocator, {}, struct {
        fn run(_: void, c: *shake.Case) !void {
            const ns = shake.gen.int(c.source, i96);
            const actual = TestTimeout.duration(.{ .bound = .{ .limit = .fromNanoseconds(ns), .reason = "boundary property" } });
            if (ns > std.math.maxInt(u64)) {
                try std.testing.expectEqual(@as(?std.Io.Duration, null), actual);
            } else {
                try std.testing.expectEqual(@max(ns, 1), actual.?.toNanoseconds());
            }
        }
    }.run, .{ .cases = 256 });
    const largest: std.Io.Duration = .fromNanoseconds(std.math.maxInt(u64));
    try std.testing.expectEqual(largest, TestTimeout.duration(.{ .bound = .{ .limit = largest, .reason = "maximum runner bound" } }).?);
}
