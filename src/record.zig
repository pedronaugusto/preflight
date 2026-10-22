//! Seed, shard, bound and watch every CI test runner; record timing evidence only when requested.
//! A test run carries no environment of the build's: Zig bakes a run's
//! environment into the cached configuration, so the shard and seed would go
//! stale. The runner reads them when it runs, and its options module carries
//! the rest.
const std = @import("std");
const configure = @import("configure.zig");
const Tool = @import("tool.zig").Tool;

pub const Options = struct {
    timing: bool,
    /// The watchdog's bound on one test; 0 turns it off.
    test_timeout: std.Io.Duration,
    test_log_level: std.log.Level,
    /// The package's recorded durations, repository-relative.
    durations: []const u8,
    /// The hardened run: `std.testing.allocator` is backed by the package's own
    /// shakedown's quarantine, which the runner imports as `preflight_quarantine`.
    quarantine: bool = false,
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
    /// The build helper keeps std's duration and checks the generated runner's u64 schema
    /// before export.
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

/// `roots`: the test step and the step the package fuzzes, whose test runs
/// all take the runner, one way. `checker` is preflight's command program,
/// which refuses a shard at run time for a test runner that cannot honour one,
/// and counts the tests step's tests per root after its runs (`counts`).
pub fn add(b: *std.Build, roots: []const *std.Build.Step, pkg: *std.Build, checker: Tool, options: Options) Counted {
    const durations = configure.read(b, options.durations, .limited(64 * 1024 * 1024)) orelse "";
    var state: State = .{ .context = .{ .pkg = pkg, .checker = checker, .options = options, .durations = durations } };
    for (roots, 0..) |root, index| visit(b, root, &state, index == 0);
    return .{ .names = state.counted.keys(), .runs = state.runs.items };
}

/// The runs of the tests step that take preflight's runner, and the names of the records of
/// their roots' tests the runner writes, one per root module: what `counts` reads.
pub const Counted = struct { names: []const []const u8, runs: []const *std.Build.Step };

const Context = struct {
    pkg: *std.Build,
    checker: Tool,
    options: Options,
    /// The recorded durations' text, built into each runner.
    durations: []const u8,
};

const State = struct {
    context: Context,
    seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty,
    /// The record names given out, timing and count alike.
    names: std.StringHashMapUnmanaged(void) = .empty,
    /// Each root module's record name: artifacts that share it share its options.
    records: std.AutoHashMapUnmanaged(*std.Build.Module, []const u8) = .empty,
    /// The artifacts given preflight's runner.
    ours: std.AutoHashMapUnmanaged(*std.Build.Step.Compile, void) = .empty,
    counted: std.array_hash_map.String(void) = .empty,
    runs: std.ArrayList(*std.Build.Step) = .empty,
};

fn visit(b: *std.Build, step: *std.Build.Step, state: *State, tests: bool) void {
    const entry = state.seen.getOrPut(b.allocator, step) catch @panic("OOM");
    if (entry.found_existing) return;
    if (step.cast(std.Build.Step.Run)) |run| {
        if (run.argv.items.len == 0 or run.argv.items[0] != .artifact) return;
        const artifact = run.argv.items[0].artifact.artifact;
        if (artifact.kind != .@"test") return;
        instrument(b, run, state);
        if (tests and state.ours.contains(artifact)) {
            state.counted.put(b.allocator, state.records.get(artifact.root_module).?, {}) catch @panic("OOM");
            state.runs.append(b.allocator, &run.step) catch @panic("OOM");
        }
        return;
    }
    for (step.dependencies.items) |child| visit(b, child, state, tests);
}

/// The tests counted per root after `counted`'s runs, a step `holder` waits for: a run whose
/// record is missing never reached preflight's runner, and a binary that holds no test,
/// unfiltered, has its tests in modules it imports, which Zig never runs, or none. The counts
/// go where the gate prints them. The count is preflight's program, no test: it joins the
/// tests step after every walk of that step (the compile checks, the hardened profile,
/// portable tests) has read it.
pub fn counts(b: *std.Build, holder: *std.Build.Step, checker: Tool, counted: Counted) void {
    if (counted.names.len == 0) return;
    const count = checker.run(b);
    count.addArg("counts");
    count.addDirectoryArg2(std.Build.LazyPath.cache_root.join(b.allocator, records_dir) catch @panic("OOM"), .{ .prefix = "--records=" });
    for (counted.names) |name| count.addArgs(&.{ "--expect", name });
    count.has_side_effects = true;
    for (counted.runs) |run| count.step.dependOn(run);
    holder.dependOn(&count.step);
}

/// Where the runner writes the count records, in the build's cache.
pub const records_dir = "preflight-counts";

/// Gives the test artifact `run` runs preflight's runner and its modules,
/// and the run its watchdog, durations, timing record and count record.
fn instrument(b: *std.Build, run: *std.Build.Step.Run, state: *State) void {
    const context = state.context;
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
        // The runner and its modules link std alone, so the artifact holds no
        // package it did not ask for.
        artifact.root_module.addAnonymousImport("preflight_order", .{ .root_source_file = context.pkg.path("src/order.zig") });
        artifact.root_module.addAnonymousImport("preflight_watchdog", .{ .root_source_file = context.pkg.path("src/watchdog.zig") });
        const runner = b.addOptions();
        // The generated options schema is raw u64, validated by TestTimeout.duration and
        // wrapped by the runner.
        runner.addOption(u64, "test_timeout_ns", @intCast(options.test_timeout.toNanoseconds())); // safe: validated export range
        runner.addOption(std.log.Level, "test_log_level", options.test_log_level);
        const name = recordName(b, artifact, &state.names);
        state.records.put(b.allocator, artifact.root_module, name) catch @panic("OOM");
        runner.addOption(?[]const u8, "timings", if (options.timing) b.fmt(".zig-cache/preflight-timings/{s}", .{name}) else null);
        runner.addOption([]const u8, "counts", b.fmt("{s}/{s}", .{ records_dir, name }));
        // The root as the package names it: its own file, or one a development build takes
        // from the package as a dependency (`package.path`); a generated one by its artifact.
        runner.addOption([]const u8, "root", switch (artifact.root_module.root_source_file.?) {
            .src_path => |path| path.sub_path,
            .dependency => |path| path.sub_path,
            else => artifact.name,
        });
        runner.addOption([]const u8, "artifact", artifact.name);
        runner.addOption(bool, "filtered", artifact.filters.len != 0);
        runner.addOption([]const u8, "durations", context.durations);
        runner.addOption(bool, "quarantine", options.quarantine);
        if (options.quarantine) quarantine(b, run, artifact);
        artifact.root_module.addOptions("preflight_runner_options", runner);
    }
    if (state.ours.contains(artifact)) {
        // Another run of an artifact given the runner already: it takes it as the first did.
    } else if (artifact.test_runner != null) {
        // That runner neither arms the watchdog nor reads the shard.
        if (options.test_timeout.toNanoseconds() != 0) refuse("{s}: a test runner of its own arms no watchdog; set .test_timeout = .{{ .off = reason }}", b, run, .{artifact.name});
        const unsharded = context.checker.run(b);
        unsharded.addArgs(&.{ "unsharded", artifact.name });
        unsharded.has_side_effects = true;
        run.step.dependOn(&unsharded.step);
    } else {
        state.ours.put(b.allocator, artifact, {}) catch @panic("OOM");
        const path = context.pkg.path("src/runner.zig");
        artifact.test_runner = .{ .path = path, .mode = .server };
        path.addStepDependencies(&artifact.step);
        artifact.root_module.addAnonymousImport("preflight_default_test_runner", .{
            .root_source_file = b.graph.path(.zig_lib, "compiler/test_runner.zig"),
        });
    }
    if (state.ours.contains(artifact)) {
        // Not `enableProtocolMode`, though 0.17 deprecates this for it:
        // Zig 0.17's test runner reads its cache directory and seed from
        // argv, which only `.zig_test` passes, and a `.protocol` run cannot
        // fuzz. std's own `addRunArtifact` still sets `.zig_test`.
        // glint-ignore: Z011 -- the deprecation names enableProtocolMode, which sets .protocol; this needs .zig_test
        if (run.stdio != .zig_test) run.enableTestRunnerMode();
    }
    if (options.test_timeout.toNanoseconds() != 0 and singleThreaded(artifact)) refuse("{s}: a single-threaded build has no watchdog; set .test_timeout = .{{ .off = reason }}", b, run, .{artifact.name});
}

/// The name of a root module's records, without their shard: the runner appends the shard
/// it runs, `-2of5`, or `-all`.
fn recordName(b: *std.Build, artifact: *std.Build.Step.Compile, names: *std.StringHashMapUnmanaged(void)) []const u8 {
    const target = artifact.root_module.resolved_target.?.result;
    const stem = b.fmt("{s}-{s}-{s}", .{ artifact.name, @tagName(target.os.tag), @tagName(artifact.root_module.optimize.?) });
    // Two runs that share a name would truncate each other's records.
    var name = stem;
    // One build owns this name suffix; it is not an ID or an externally supplied count and
    // never meets another number domain.
    var count: usize = 2;
    while ((names.getOrPut(b.allocator, name) catch @panic("OOM")).found_existing) : (count += 1) name = b.fmt("{s}-{d}", .{ stem, count });
    return name;
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

/// The hardened run's runner imports the package's shakedown, for its quarantine, as
/// `preflight_quarantine`: the shakedown the test module's graph holds already, so it is
/// the one copy, or else the one the package declares. A package that declares none is
/// refused by name.
fn quarantine(b: *std.Build, run: *std.Build.Step.Run, artifact: *std.Build.Step.Compile) void {
    const root = artifact.root_module;
    var graph: std.array_hash_map.Auto(*std.Build.Module, void) = .empty;
    graph.put(b.allocator, root, {}) catch @panic("OOM");
    var next: usize = 0;
    while (next < graph.count()) : (next += 1) {
        const module = graph.keys()[next];
        if (module.import_table.get("shakedown")) |found| {
            root.addImport("preflight_quarantine", found);
            return;
        }
        for (module.import_table.values()) |imported| graph.put(b.allocator, imported, {}) catch @panic("OOM");
    }
    const dep = (configure.declared(b, "shakedown", .{ .target = root.resolved_target.?, .optimize = root.optimize orelse .debug }) catch return) orelse
        return refuse("{s}: the hardened run backs std.testing.allocator with shakedown's quarantine; declare shakedown: a dev dependency with bay, else a lazy one", b, run, .{artifact.name});
    root.addImport("preflight_quarantine", dep.module("shakedown"));
}
