const std = @import("std");
const src = @import("source.zig");

pub const hosts = [_][]const u8{ "ubuntu-latest", "macos-latest", "windows-latest" };
/// The `shards` keys of `ci/workflow.json`, in `hosts` order.
const host_names = [_][]const u8{ "linux", "macos", "windows" };
/// Named cases with weights gave way to per-test shards that the test runner
/// balances by `ci/durations.json`.
const obsolete = [_][]const u8{ "windows_shards", "fast_windows_shards", "shard_jobs", "fast_linux_shards", "fast_linux_jobs" };

pub const Job = struct {
    os: []const u8,
    name: []const u8,
    step: []const u8 = "ci",
    args: []const u8 = "",
    /// `i/n` when the job runs one shard of its tests.
    shard: []const u8 = "",
    setup: bool = false,
    job_timeout: usize = 20,
    cache_key: []const u8 = "",
    artifact: []const u8 = "",
    operation: enum { execute, objects, link, replay } = .execute,
    /// The cross targets a compile job covers, by name, space-separated.
    targets: []const u8 = "",
};

fn shardCount(value: src.Value) !usize {
    if (value == .null) return 1;
    if (value != .integer or value.integer < 1) return error.InvalidShardCount;
    return @intCast(value.integer);
}

fn shardName(a: std.mem.Allocator, index: usize, count: usize) ![]const u8 {
    return if (count > 1) a.print("{d}/{d}", .{ index + 1, count }) else "";
}

/// A job's cache scope: everything that changes what it builds and runs.
fn key(a: std.mem.Allocator, job: Job) ![]const u8 {
    var plain = job;
    plain.cache_key = "";
    plain.artifact = "";
    const text = try std.json.Stringify.valueAlloc(a, plain, .{});
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
    return a.print("{x}", .{hash[0..8]});
}

/// The optimize modes the gate runs, spelled as `-Doptimize` takes them.
const Mode = std.lang.Optimize;

/// The name a job shows for `mode`.
fn title(mode: Mode) []const u8 {
    return switch (mode) {
        .debug => "Debug",
        .safe => "ReleaseSafe",
        .fast => "ReleaseFast",
        .small => "ReleaseSmall",
    };
}

/// How much of the gate a run executes.
pub const Tier = enum {
    /// The source checks, Linux Debug and an object compile of every target; every other host compiles only.
    fast,
    /// The candidate for main: fast, the ReleaseFast benchmarks compiled for every target, and the Debug suite on macOS and Windows.
    merge,
    /// Before a release: every mode on every host, cross targets and TSan.
    release,
};

/// The sole planner also owns opt-in native safety execution jobs.
pub fn plan(a: std.mem.Allocator, config: src.Value, tier: Tier) ![]Job {
    const normal = try basePlan(a, config, tier);
    const hardened = src.get(config, "hardened");
    if (hardened != .null and hardened != .bool) return error.InvalidHardenedProfile;
    if (hardened == .null or !hardened.bool) return normal;
    var jobs: std.ArrayList(Job) = .empty;
    try jobs.appendSlice(a, normal);
    for ([_][]const u8{ "hardened", "hardened-fuzz", "hardened-tsan" }) |step| {
        var job: Job = .{ .os = hosts[0], .name = step, .step = step, .args = try a.print("-Dci-lint=false -Dci-bench-smoke=false{s}", .{try buildArgs(a, src.get(config, "build_args"))}), .setup = true };
        job.cache_key = try key(a, job);
        try jobs.append(a, job);
    }
    return jobs.toOwnedSlice(a);
}

fn basePlan(a: std.mem.Allocator, config: src.Value, tier: Tier) ![]Job {
    try validate(a, config);
    for (obsolete) |name| if (src.get(config, name) != .null) return error.ObsoleteShardConfig;
    // The watchdog bounds each test (`Config.test_timeout`).
    if (src.get(config, "test_timeout") != .null) return error.ObsoleteTestTimeout;
    switch (tier) {
        .fast => return fastPlan(a, config, .fast),
        .merge => return mergePlan(a, config),
        .release => {},
    }
    var jobs: std.ArrayList(Job) = .empty;
    for (hosts, host_names) |host, host_name| {
        const modes: []const Mode = if (std.mem.eql(u8, host, hosts[0])) &.{ .debug, .safe, .fast } else &.{ .debug, .safe };
        try hostJobs(a, config, &jobs, host, host_name, modes);
    }
    try jobs.append(a, try lintJob(a, config));
    try releaseJobs(a, config, &jobs);
    try sdkJobs(a, config, &jobs);
    for (jobs.items) |*job| job.cache_key = try key(a, job.*);
    return jobs.items;
}

/// The fast tier's jobs, recording durations, the ReleaseFast benchmarks
/// compiled for every target, and the Debug suite executed on macOS and Windows.
fn mergePlan(a: std.mem.Allocator, config: src.Value) ![]Job {
    var jobs: std.ArrayList(Job) = .empty;
    try jobs.appendSlice(a, try fastPlan(a, config, .merge));
    const start = jobs.items.len;
    for (hosts[1..], host_names[1..]) |host, host_name| try hostJobs(a, config, &jobs, host, host_name, &.{.debug});
    try sdkJobs(a, config, &jobs);
    for (jobs.items[start..]) |*job| job.cache_key = try key(a, job.*);
    return jobs.items;
}

/// The test jobs of one host: each mode in the host's shard count.
fn hostJobs(a: std.mem.Allocator, config: src.Value, jobs: *std.ArrayList(Job), host: []const u8, host_name: []const u8, modes: []const Mode) !void {
    const count = try shardCount(src.get(src.get(config, "shards"), host_name));
    for (modes) |mode| for (0..count) |i| {
        const shard = try shardName(a, i, count);
        try jobs.append(a, .{
            .os = host,
            .name = try a.print("test ({s}, {s}){s}{s}", .{ host, title(mode), if (count > 1) " shard " else "", shard }),
            .args = try a.print("-Doptimize={t} -Dci-lint=false -Dci-timings=true{s}", .{ mode, try buildArgs(a, src.get(config, "build_args")) }),
            .shard = shard,
            .setup = true,
            .job_timeout = src.number(src.get(config, if (std.mem.eql(u8, host, hosts[2])) "windows_job_timeout" else "test_job_timeout"), 20),
        });
    };
}

pub const Tiers = struct { native: []Job, compile: []Job, run: []Job };

/// Portable hosts link once on their SDK runner per host and mode; every shard of
/// that host and mode runs the same binaries.
pub fn split(a: std.mem.Allocator, config: src.Value, jobs: []const Job, tier: Tier) !Tiers {
    var native: std.ArrayList(Job) = .empty;
    var compile: std.ArrayList(Job) = .empty;
    var run: std.ArrayList(Job) = .empty;
    const enabled = src.get(config, "compile_once");
    for (jobs) |job| {
        const portable_hosts = src.get(config, "portable_hosts");
        var allowed = portable_hosts == .null;
        for (src.items(portable_hosts)) |host| if (std.mem.eql(u8, src.string(host, ""), job.os)) {
            allowed = true;
        };
        if (tier == .fast or enabled != .bool or !enabled.bool or !allowed or !std.mem.eql(u8, job.step, "ci") or std.mem.eql(u8, job.os, hosts[0])) {
            try native.append(a, job);
            continue;
        }
        var whole = job;
        whole.shard = "";
        whole.name = job.name[0 .. std.mem.find(u8, job.name, " shard ") orelse job.name.len];
        const whole_key = try key(a, whole);
        const artifact = try a.print("preflight-{s}", .{whole_key});
        var built = false;
        for (compile.items) |existing| if (std.mem.eql(u8, existing.artifact, artifact)) {
            built = true;
        };
        if (!built) {
            const target = if (std.mem.eql(u8, job.os, hosts[1])) "aarch64-macos" else "x86_64-windows-gnu";
            var builder = whole;
            builder.os = job.os;
            builder.step = "ci-build";
            builder.operation = .link;
            builder.setup = true;
            builder.args = try a.print("{s} -Dtarget={s} -Dcpu=baseline", .{ job.args, target });
            builder.name = try a.print("native link for {s}", .{whole.name});
            builder.cache_key = try a.print("compile-{s}", .{whole_key});
            builder.artifact = artifact;
            try compile.append(a, builder);
        }
        var executor = job;
        executor.step = "ci-run";
        executor.operation = .replay;
        executor.artifact = artifact;
        try run.append(a, executor);
    }
    return .{ .native = native.items, .compile = compile.items, .run = run.items };
}

/// Linux Debug in `fast_shards` jobs; the first also checks sources and
/// compiles the other targets. They record durations when `timing` is set
/// or they are shards.
fn fastPlan(a: std.mem.Allocator, config: src.Value, tier: Tier) ![]Job {
    const timing = tier != .fast;
    var jobs: std.ArrayList(Job) = .empty;
    try jobs.append(a, try lintJob(a, config));
    const count = try shardCount(src.get(config, "fast_shards"));
    for (0..count) |i| {
        const shard = try shardName(a, i, count);
        try jobs.append(a, .{
            .os = hosts[0],
            .name = try a.print("Linux Debug{s}{s}", .{ if (count > 1) " shard " else "", shard }),
            .args = try a.print("-Doptimize=debug -Dci-lint=false{s}{s}", .{ if (timing or count > 1) " -Dci-timings=true" else "", try buildArgs(a, src.get(config, "build_args")) }),
            .shard = shard,
            .setup = true,
            .job_timeout = src.number(src.get(config, "test_job_timeout"), 20),
            .cache_key = try a.print("fast-linux-debug-{d}", .{i}),
        });
    }
    try crossJobs(a, config, &jobs, try fastTargets(a, config), tier != .fast);
    return jobs.items;
}

/// The source checks: format, structure, the code rules, layout, snippets and
/// the package's own extra checks. Nothing in them runs a test, so they need
/// neither the external tools nor a test build.
fn lintJob(a: std.mem.Allocator, config: src.Value) !Job {
    return .{
        .os = hosts[0],
        .name = "source checks and documented snippets",
        .step = "lint",
        .args = std.mem.trimStart(u8, try buildArgs(a, src.get(config, "build_args")), " "),
        .job_timeout = src.number(src.get(config, "source_job_timeout"), 20),
        .cache_key = "lint",
    };
}

/// The target a `targets` entry names: a triple, or an object's `target`.
pub fn targetName(target: src.Value) []const u8 {
    return if (target == .string) target.string else src.string(src.get(target, "target"), "");
}

/// What compiling one target costs a job when no run has measured it, in seconds.
const unmeasured_target_seconds = 90;
/// The seconds of compiling one cross job is given, when `cross_seconds` does not say.
const default_cross_seconds = 200;

/// The seconds `name` takes to compile, as the last merge or release run
/// measured them (`ci/costs.json`, which the plan reads as `measured`), the
/// benchmarks too when `bench` is set; null when nothing was measured.
fn targetSeconds(a: std.mem.Allocator, config: src.Value, name: []const u8, bench: bool) !?f64 {
    const phases = src.get(src.get(config, "measured"), "phases");
    if (phases != .object) return null;
    const compiled = number(phases.object.get(try a.print("compile {s}", .{name})) orelse return null) orelse return null;
    if (!bench) return compiled;
    const benchmarks = number(phases.object.get(try a.print("benchmarks {s}", .{name})) orelse return null) orelse return null;
    return compiled + benchmarks;
}

fn number(value: src.Value) ?f64 {
    return switch (value) {
        .float => |seconds| seconds,
        .integer => |seconds| @floatFromInt(seconds),
        else => null,
    };
}

/// The object compile of `targets`, in as many jobs as `cross_jobs` asks for,
/// or as few as hold `cross_seconds` (200) of compiling each, by what the last
/// run measured of every target and 90 s for one it has not. The longest
/// target goes first onto the job with the least, so the jobs end together.
/// With `bench`, each job also compiles the ReleaseFast benchmarks.
fn crossJobs(a: std.mem.Allocator, config: src.Value, jobs: *std.ArrayList(Job), targets: []const src.Value, bench: bool) !void {
    if (targets.len == 0) return;
    const wanted = src.get(config, "cross_jobs");
    if (wanted != .null and (wanted != .integer or wanted.integer < 1)) return error.InvalidCrossJobs;
    const budget = src.get(config, "cross_seconds");
    if (budget != .null and !(number(budget) orelse 0 > 0)) return error.InvalidCrossSeconds;
    const cost = try a.alloc(f64, targets.len);
    var known: f64 = 0;
    var measured: usize = 0;
    for (targets, cost) |target, *seconds| {
        seconds.* = try targetSeconds(a, config, targetName(target), bench) orelse -1;
        if (seconds.* >= 0) {
            known += seconds.*;
            measured += 1;
        }
    }
    // A target nobody measured costs what the others do on average.
    for (cost) |*seconds| if (seconds.* < 0) {
        seconds.* = if (measured > 0) known / @as(f64, @floatFromInt(measured)) else unmeasured_target_seconds;
    };
    const order = try a.alloc(usize, targets.len);
    for (order, 0..) |*index, i| index.* = i;
    std.mem.sort(usize, order, cost, struct {
        fn longer(costs: []const f64, x: usize, y: usize) bool {
            return costs[x] > costs[y];
        }
    }.longer);
    // A job cannot be shorter than the longest target, so more jobs stop helping there.
    const limit = @max(number(budget) orelse default_cross_seconds, std.mem.max(f64, cost));
    const assignment = try a.alloc(usize, targets.len);
    const load = try a.alloc(f64, targets.len);
    var count: usize = if (wanted == .null) 1 else @min(@as(usize, @intCast(wanted.integer)), targets.len);
    while (true) : (count += 1) {
        @memset(load[0..count], 0);
        var longest: f64 = 0;
        for (order) |index| {
            var least: usize = 0;
            for (load[0..count], 0..) |seconds, group| if (seconds < load[least]) {
                least = group;
            };
            assignment[index] = least;
            load[least] += cost[index];
            longest = @max(longest, load[least]);
        }
        if (wanted != .null or count == targets.len or longest <= limit) break;
    }
    for (0..count) |group| {
        var names: std.ArrayList(u8) = .empty;
        for (targets, assignment) |target, owner| if (owner == group) {
            if (names.items.len > 0) try names.append(a, ' ');
            try names.appendSlice(a, targetName(target));
        };
        if (names.items.len == 0) continue;
        try jobs.append(a, .{
            .os = hosts[0],
            .name = try a.print("Cross compile{s}{s}", .{ if (count > 1) " " else "", try shardName(a, group, count) }),
            .step = if (bench) "preflight-cross-bench" else "preflight-cross",
            .operation = .objects,
            .job_timeout = src.number(src.get(config, "cross_job_timeout"), 20),
            .cache_key = try a.print("cross-{s}-{d}", .{ if (bench) "bench" else "objects", group }),
            .targets = names.items,
        });
    }
}

/// The targets the fast and merge tiers compile: the configured ones, and
/// the macOS and Windows targets those tiers do not run natively.
pub fn fastTargets(a: std.mem.Allocator, config: src.Value) ![]src.Value {
    try validate(a, config);
    var targets: std.ArrayList(src.Value) = .empty;
    try targets.appendSlice(a, src.items(src.get(config, "targets")));
    for ([_][]const u8{ "aarch64-macos", "x86_64-windows-gnu" }) |native| {
        var found = false;
        for (targets.items) |target| {
            if (std.mem.eql(u8, targetName(target), native)) found = true;
        }
        if (!found) try targets.append(a, .{ .string = native });
    }
    return targets.items;
}

fn releaseJobs(a: std.mem.Allocator, config: src.Value, jobs: *std.ArrayList(Job)) !void {
    const compile = src.string(src.get(config, "compile_step"), "check");
    try jobs.append(a, .{ .os = hosts[0], .name = "compile (ReleaseSmall)", .step = compile, .args = "-Doptimize=small" });
    try crossJobs(a, config, jobs, src.items(src.get(config, "targets")), true);
    const sanitizer = src.get(config, "sanitizer");
    if (sanitizer == .string) try jobs.append(a, .{
        .os = hosts[0],
        .name = "ThreadSanitizer (Linux)",
        .step = sanitizer.string,
        .args = "-Dthread-sanitizer -Doptimize=debug -Dci-lint=false",
        .setup = true,
        .job_timeout = src.number(src.get(config, "sanitizer_job_timeout"), 20),
    });
}

fn validate(a: std.mem.Allocator, config: src.Value) !void {
    if (config != .object) return error.InvalidWorkflowConfig;
    const targets = src.get(config, "targets");
    if (targets != .null and targets != .array) return error.InvalidCrossTargets;
    for (src.items(targets)) |target| _ = try crossOptions(a, config, target);
    _ = try validatedArgs(a, src.get(config, "build_args"));
    const shards = src.get(config, "shards");
    if (shards != .null and shards != .object) return error.InvalidShardCount;
    for (host_names) |host| _ = try shardCount(src.get(shards, host));
    for ([_][]const u8{ "compile_once", "windows_git_latest" }) |name| {
        const value = src.get(config, name);
        if (value != .null and value != .bool) return error.InvalidWorkflowBoolean;
    }
    const portable_hosts = src.get(config, "portable_hosts");
    if (portable_hosts != .null) {
        if (portable_hosts != .array) return error.InvalidPortableHosts;
        for (try src.strings(a, portable_hosts)) |host| {
            var found = false;
            for (hosts) |known| if (std.mem.eql(u8, host, known)) {
                found = true;
            };
            if (!found) return error.InvalidPortableHosts;
        }
    }
}

fn sdkJobs(a: std.mem.Allocator, config: src.Value, jobs: *std.ArrayList(Job)) !void {
    for (src.items(src.get(config, "targets"))) |target| {
        const options = try crossOptions(a, config, target);
        const name = options[1]["-Dtarget=".len..];
        const query = try std.Target.Query.parse(.{ .arch_os_abi = name });
        const host = switch (query.os_tag orelse return error.InvalidCrossTarget) {
            .macos => hosts[1],
            .windows => hosts[2],
            else => continue,
        };
        var text: std.Io.Writer.Allocating = .init(a);
        defer text.deinit();
        for (options) |arg| try text.writer.print("{s}{s}", .{ if (text.written().len == 0) "" else " ", arg });
        try jobs.append(a, .{ .os = host, .name = try a.print("SDK link ({s})", .{name}), .step = "ci-link", .args = try text.toOwnedSlice(), .setup = true, .operation = .link });
    }
}

fn validatedArgs(a: std.mem.Allocator, value: src.Value) ![]const []const u8 {
    if (value == .null) return &.{};
    if (value != .array) return error.InvalidBuildArgs;
    const args = try src.strings(a, value);
    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, "-D") or std.mem.startsWith(u8, arg, "-Dtarget=") or std.mem.startsWith(u8, arg, "-Dcpu=")) return error.InvalidBuildArgs;
        for (arg) |byte| if (std.ascii.isWhitespace(byte) or byte < 32) return error.InvalidBuildArgs;
    }
    return args;
}

fn buildArgs(a: std.mem.Allocator, value: src.Value) ![]const u8 {
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    for (try validatedArgs(a, value)) |arg| try text.writer.print(" {s}", .{arg});
    return text.toOwnedSlice();
}

/// The command that makes the objects of `target` in Debug: the build's `step`,
/// `ci-check`, or `ci-check-bench` for the ReleaseFast benchmarks.
pub fn crossArgs(a: std.mem.Allocator, config: src.Value, target: src.Value, step: []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "zig", "build", step });
    try args.appendSlice(a, try crossOptions(a, config, target));
    try args.append(a, "-Doptimize=debug");
    return args.toOwnedSlice(a);
}

/// The build options that make a build target `target`: lint off, the target
/// and CPU, and the caller's flags.
pub fn crossOptions(a: std.mem.Allocator, config: src.Value, target: src.Value) ![]const []const u8 {
    const name = targetName(target);
    if (name.len == 0) return error.InvalidCrossTarget;
    const cpu = src.get(target, "cpu");
    _ = std.Target.Query.parse(.{ .arch_os_abi = name, .cpu_features = if (cpu == .string) cpu.string else null }) catch return error.InvalidCrossTarget;
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(a, "-Dci-lint=false");
    try args.append(a, try a.print("-Dtarget={s}", .{name}));
    if (cpu != .null and cpu != .string) return error.InvalidCrossCpu;
    if (cpu == .string) {
        if (cpu.string.len == 0) return error.InvalidCrossCpu;
        for (cpu.string) |byte| if (std.ascii.isWhitespace(byte) or byte < 32) return error.InvalidCrossCpu;
        try args.append(a, try a.print("-Dcpu={s}", .{cpu.string}));
    }
    for ([_]src.Value{ src.get(config, "build_args"), src.get(target, "args") }) |values| {
        try args.appendSlice(a, try validatedArgs(a, values));
    }
    return args.toOwnedSlice(a);
}

test "the cross bundle retains every target, CPU and caller compile step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a,
        \\{"compile_step":"install","targets":["x86_64-windows-gnu",{"target":"aarch64-linux-gnu","cpu":"cortex_a72"}]}
    , .{})).value;
    const jobs = try plan(a, config, .release);
    var bundles: usize = 0;
    for (jobs) |job| if (std.mem.eql(u8, job.step, "preflight-cross-bench")) {
        bundles += 1;
        try std.testing.expectEqualStrings("x86_64-windows-gnu aarch64-linux-gnu", job.targets);
    };
    try std.testing.expectEqual(@as(usize, 1), bundles);
    const targets = src.items(src.get(config, "targets"));
    const first = try crossArgs(a, config, targets[0], "ci-check");
    const second = try crossArgs(a, config, targets[1], "ci-check-bench");
    try std.testing.expectEqualStrings("ci-check", first[2]);
    try std.testing.expectEqualStrings("-Dtarget=x86_64-windows-gnu", first[4]);
    try std.testing.expectEqualStrings("ci-check-bench", second[2]);
    try std.testing.expectEqualStrings("-Dtarget=aarch64-linux-gnu", second[4]);
    try std.testing.expectEqualStrings("-Dcpu=cortex_a72", second[5]);
    try std.testing.expectError(error.InvalidCrossTarget, crossArgs(a, config, .null, "ci-check"));
}

test "the fast tier checks sources, runs Linux Debug and compiles every target without the ReleaseFast benchmarks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a,
        \\{"compile_step":"install","compile_once":true,"cross_jobs":1,"targets":[{"target":"aarch64-linux-gnu","cpu":"cortex_a72"}]}
    , .{})).value;
    const jobs = try plan(a, config, .fast);
    try std.testing.expectEqual(@as(usize, 3), jobs.len);
    for (jobs) |job| try std.testing.expectEqualStrings(hosts[0], job.os);
    try std.testing.expectEqualStrings("lint", jobs[0].step);
    try std.testing.expect(!jobs[0].setup);
    try std.testing.expectEqualStrings("ci", jobs[1].step);
    try std.testing.expectEqualStrings("-Doptimize=debug -Dci-lint=false", jobs[1].args);
    try std.testing.expectEqualStrings("preflight-cross", jobs[2].step);
    try std.testing.expectEqualStrings("aarch64-linux-gnu aarch64-macos x86_64-windows-gnu", jobs[2].targets);
    const targets = try fastTargets(a, config);
    try std.testing.expectEqual(@as(usize, 3), targets.len);
    const args = try crossArgs(a, config, targets[0], "ci-check");
    try std.testing.expectEqualStrings("ci-check", args[2]);
    try std.testing.expectEqualStrings("-Dcpu=cortex_a72", args[5]);
    try std.testing.expectEqualStrings("-Doptimize=debug", args[6]);
    const bench = try crossArgs(a, config, targets[0], "ci-check-bench");
    try std.testing.expectEqualStrings("ci-check-bench", bench[2]);
    const tiers = try split(a, config, jobs, .fast);
    try std.testing.expectEqual(@as(usize, 3), tiers.native.len);
    try std.testing.expectEqual(@as(usize, 0), tiers.run.len);
}

fn allTargets(jobs: []const Job, a: std.mem.Allocator) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (jobs) |job| {
        var each = std.mem.tokenizeScalar(u8, job.targets, ' ');
        while (each.next()) |name| try names.append(a, name);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn before(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.before);
    return std.mem.join(a, " ", names.items);
}

test "cross targets no run has measured cost 90 s each, and get as many jobs as hold 200 s of them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const many = (try std.json.parseFromSlice(src.Value, a,
        \\{"targets":["a-linux-gnu","b","c","d","e","f","g"]}
    , .{})).value;
    var jobs: std.ArrayList(Job) = .empty;
    try crossJobs(a, many, &jobs, src.items(src.get(many, "targets")), false);
    try std.testing.expectEqual(@as(usize, 4), jobs.items.len);
    try std.testing.expectEqualStrings("a-linux-gnu b c d e f g", try allTargets(jobs.items, a));
    try std.testing.expectEqualStrings("Cross compile 4/4", jobs.items[3].name);
    const asked = (try std.json.parseFromSlice(src.Value, a,
        \\{"cross_jobs":3,"targets":["a","b"]}
    , .{})).value;
    jobs.clearRetainingCapacity();
    try crossJobs(a, asked, &jobs, src.items(src.get(asked, "targets")), true);
    try std.testing.expectEqual(@as(usize, 2), jobs.items.len);
    try std.testing.expectEqualStrings("preflight-cross-bench", jobs.items[0].step);
    try std.testing.expectEqualStrings("Cross compile 1/2", jobs.items[0].name);
    for ([_][]const u8{ "{\"cross_jobs\":0,\"targets\":[\"a\"]}", "{\"cross_seconds\":0,\"targets\":[\"a\"]}" }) |text| {
        const bad = (try std.json.parseFromSlice(src.Value, a, text, .{})).value;
        try std.testing.expect(std.meta.isError(crossJobs(a, bad, &jobs, src.items(src.get(bad, "targets")), false)));
    }
}

test "cross targets a run measured are balanced by their seconds, the benchmarks counted in the merge tier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a,
        \\{"targets":["a","b","c","d","e"],"measured":{"phases":{"compile a":150,"compile b":40.5,"compile c":40,"compile d":30,"benchmarks a":100,"benchmarks b":10,"benchmarks c":10,"benchmarks d":10}}}
    , .{})).value;
    const targets = src.items(src.get(config, "targets"));
    var fast: std.ArrayList(Job) = .empty;
    try crossJobs(a, config, &fast, targets, false);
    // e is unmeasured and costs the mean of the four others, 65 s: 325 s in all.
    try std.testing.expectEqual(@as(usize, 2), fast.items.len);
    try std.testing.expectEqualStrings("a", fast.items[0].targets);
    try std.testing.expectEqualStrings("b c d e", fast.items[1].targets);
    var merge: std.ArrayList(Job) = .empty;
    try crossJobs(a, config, &merge, targets, true);
    // The benchmarks lengthen a to 250 s, which no job of 200 s holds alone: it has one to itself.
    try std.testing.expectEqual(@as(usize, 2), merge.items.len);
    try std.testing.expectEqualStrings("a", merge.items[0].targets);
    try std.testing.expectEqualStrings("b c d e", merge.items[1].targets);
}

test "portable matrix links macOS and Windows binaries on their SDK runners without losing native coverage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"compile_once\":true,\"targets\":[\"aarch64-linux-gnu\"],\"sanitizer\":\"unit\"}", .{})).value;
    const jobs = try plan(a, config, .release);
    const tiers = try split(a, config, jobs, .release);
    try std.testing.expectEqual(@as(usize, 4), tiers.compile.len);
    try std.testing.expectEqual(@as(usize, 4), tiers.run.len);
    try std.testing.expectEqual(jobs.len, tiers.native.len + tiers.run.len);
    for (tiers.compile, tiers.run) |builder, executor| {
        try std.testing.expectEqualStrings(executor.os, builder.os);
        try std.testing.expectEqualStrings(builder.artifact, executor.artifact);
        try std.testing.expect(!std.mem.eql(u8, executor.os, hosts[0]));
    }
    try std.testing.expect(std.mem.find(u8, tiers.compile[0].args, "aarch64-macos") != null);
}

test "each host's shards run every mode, split by count, with the lint and compile jobs once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"shards\":{\"windows\":3,\"macos\":2},\"sanitizer\":\"test\"}", .{})).value;
    const jobs = try plan(a, config, .release);
    var windows: usize = 0;
    var macos: usize = 0;
    var linux: usize = 0;
    for (jobs) |job| {
        if (!std.mem.eql(u8, job.step, "ci")) continue;
        if (std.mem.eql(u8, job.os, hosts[2])) windows += 1;
        if (std.mem.eql(u8, job.os, hosts[1])) macos += 1;
        if (std.mem.eql(u8, job.os, hosts[0])) {
            linux += 1;
            try std.testing.expectEqualStrings("", job.shard);
        }
    }
    try std.testing.expectEqual(@as(usize, 6), windows);
    try std.testing.expectEqual(@as(usize, 4), macos);
    try std.testing.expectEqual(@as(usize, 3), linux);
    for (jobs) |job| if (std.mem.eql(u8, job.name, "test (windows-latest, ReleaseSafe) shard 3/3")) {
        try std.testing.expectEqualStrings("3/3", job.shard);
    };
    for (jobs, 0..) |x, i| for (jobs[i + 1 ..]) |y| try std.testing.expect(!std.mem.eql(u8, x.cache_key, y.cache_key));
    // The source checks job owns lint in the release tier; no test job repeats it.
    for (jobs) |job| if (!std.mem.eql(u8, job.step, "lint") and job.setup) try std.testing.expect(std.mem.find(u8, job.args, "-Dci-lint=false") != null);
    try std.testing.expectError(error.InvalidShardCount, plan(a, (try std.json.parseFromSlice(src.Value, a, "{\"shards\":{\"windows\":0}}", .{})).value, .release));
}

test "named weighted cases are refused, naming the per-test shards that replace them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "{\"windows_shards\":[{\"name\":\"core\",\"seconds\":3}]}", "{\"fast_linux_jobs\":2}", "{\"shard_jobs\":5}" }) |text| {
        const config = (try std.json.parseFromSlice(src.Value, a, text, .{})).value;
        try std.testing.expectError(error.ObsoleteShardConfig, plan(a, config, .release));
        try std.testing.expectError(error.ObsoleteShardConfig, plan(a, config, .fast));
    }
}

test "a workflow-level test timeout is refused; the watchdog bounds each test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"test_timeout\":\"--test-timeout 120s\"}", .{})).value;
    try std.testing.expectError(error.ObsoleteTestTimeout, plan(a, config, .release));
    try std.testing.expectError(error.ObsoleteTestTimeout, plan(a, config, .fast));
    for (try plan(a, (try std.json.parseFromSlice(src.Value, a, "{\"sanitizer\":\"test\"}", .{})).value, .release)) |job|
        try std.testing.expect(std.mem.find(u8, job.args, "test-timeout") == null);
}

test "fast shards split the Linux Debug tests, which no other job runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"fast_shards\":3}", .{})).value;
    const jobs = try plan(a, config, .fast);
    try std.testing.expectEqual(@as(usize, 5), jobs.len);
    try std.testing.expectEqualStrings("lint", jobs[0].step);
    try std.testing.expectEqualStrings("-Doptimize=debug -Dci-lint=false -Dci-timings=true", jobs[1].args);
    try std.testing.expectEqualStrings("1/3", jobs[1].shard);
    try std.testing.expectEqualStrings("Linux Debug shard 2/3", jobs[2].name);
    try std.testing.expectEqualStrings("3/3", jobs[3].shard);
    for (jobs[1..4]) |job| try std.testing.expectEqualStrings("ci", job.step);
    try std.testing.expectEqualStrings("preflight-cross", jobs[4].step);
}

test "portable shards share one compilation per host and mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"compile_once\":true,\"shards\":{\"windows\":3}}", .{})).value;
    const jobs = try plan(a, config, .release);
    const tiers = try split(a, config, jobs, .release);
    try std.testing.expectEqual(@as(usize, 4), tiers.compile.len);
    try std.testing.expectEqual(@as(usize, 2 + 6), tiers.run.len);
    for (tiers.compile) |builder| {
        try std.testing.expectEqualStrings("", builder.shard);
        try std.testing.expect(std.mem.find(u8, builder.name, "shard") == null);
    }
    var sharing: usize = 0;
    for (tiers.run) |executor| if (std.mem.eql(u8, executor.name, "test (windows-latest, Debug) shard 2/3")) {
        for (tiers.run) |other| if (std.mem.eql(u8, other.artifact, executor.artifact)) {
            sharing += 1;
        };
    };
    try std.testing.expectEqual(@as(usize, 3), sharing);
}

test "the merge tier adds the benchmarks and the Debug suite on macOS and Windows to the fast tier, and nothing more" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"cross_jobs\":1,\"shards\":{\"windows\":2},\"targets\":[\"aarch64-linux-gnu\"],\"sanitizer\":\"test\"}", .{})).value;
    const jobs = try plan(a, config, .merge);
    try std.testing.expectEqual(@as(usize, 6), jobs.len);
    try std.testing.expectEqualStrings("lint", jobs[0].step);
    try std.testing.expectEqualStrings("ci", jobs[1].step);
    try std.testing.expectEqualStrings("-Doptimize=debug -Dci-lint=false -Dci-timings=true", jobs[1].args);
    try std.testing.expectEqualStrings("preflight-cross-bench", jobs[2].step);
    try std.testing.expectEqualStrings("test (macos-latest, Debug)", jobs[3].name);
    try std.testing.expectEqualStrings("test (windows-latest, Debug) shard 2/2", jobs[5].name);
    for (jobs[3..]) |job| {
        try std.testing.expectEqualStrings("ci", job.step);
        try std.testing.expectEqualStrings("-Doptimize=debug -Dci-lint=false -Dci-timings=true", job.args);
        try std.testing.expect(!std.mem.eql(u8, job.os, hosts[0]));
    }
    for (jobs, 0..) |x, i| for (jobs[i + 1 ..]) |y| try std.testing.expect(!std.mem.eql(u8, x.cache_key, y.cache_key));
}

test "the merge tier links macOS and Windows Debug once on native runners and runs every shard of it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"compile_once\":true,\"shards\":{\"windows\":2}}", .{})).value;
    const tiers = try split(a, config, try plan(a, config, .merge), .merge);
    // The source checks, the Linux tests and the cross compile stay on Linux.
    try std.testing.expectEqual(@as(usize, 3), tiers.native.len);
    try std.testing.expectEqual(@as(usize, 2), tiers.compile.len);
    try std.testing.expectEqual(@as(usize, 3), tiers.run.len);
    for (tiers.compile) |builder| try std.testing.expect(std.mem.find(u8, builder.args, "-Doptimize=debug") != null);
}

test "the release tier is the full matrix: every mode on every host, ReleaseSmall, cross targets, TSan and the source checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"targets\":[\"aarch64-linux-gnu\"],\"sanitizer\":\"test\"}", .{})).value;
    const jobs = try plan(a, config, .release);
    const expected = [_][]const u8{
        "test (ubuntu-latest, Debug)",        "test (ubuntu-latest, ReleaseSafe)",     "test (ubuntu-latest, ReleaseFast)",
        "test (macos-latest, Debug)",         "test (macos-latest, ReleaseSafe)",      "test (windows-latest, Debug)",
        "test (windows-latest, ReleaseSafe)", "source checks and documented snippets", "compile (ReleaseSmall)",
        "Cross compile",                      "ThreadSanitizer (Linux)",
    };
    try std.testing.expectEqual(expected.len, jobs.len);
    for (expected) |name| {
        var found: usize = 0;
        for (jobs) |job| if (std.mem.eql(u8, job.name, name)) {
            found += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), found);
    }
    // Every host the tier executes records its durations; none of it is the fast job.
    for (jobs) |job| {
        if (std.mem.eql(u8, job.step, "ci")) try std.testing.expect(std.mem.find(u8, job.args, "-Dci-timings=true") != null);
    }
}

test "only the merge and release tiers execute macOS and Windows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"compile_once\":true,\"shards\":{\"macos\":2}}", .{})).value;
    for ([_]Tier{ .fast, .merge, .release }) |tier| {
        const tiers = try split(a, config, try plan(a, config, tier), tier);
        var executed: usize = 0;
        for ([_][]const Job{ tiers.native, tiers.run }) |group| for (group) |job| {
            if (!std.mem.eql(u8, job.os, hosts[0])) executed += 1;
        };
        try std.testing.expectEqual(@as(usize, switch (tier) {
            .fast => 0,
            .merge => 2 + 1,
            .release => 2 * 2 + 2,
        }), executed);
    }
}

test "owner SDK link jobs retain configured targets CPUs and feature arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a,
        \\{"compile_once":true,"build_args":["-Dfeature=true"],"targets":[{"target":"x86_64-macos","cpu":"baseline","args":["-Dtrust-store=true"]},"aarch64-macos","aarch64-windows-gnu","aarch64-linux-gnu"]}
    , .{})).value;
    const cross = try fastTargets(a, config);
    try std.testing.expectEqual(@as(usize, 5), cross.len);
    const argv = try crossArgs(a, config, cross[0], "ci-check");
    try std.testing.expectEqualStrings("ci-check", argv[2]);
    try std.testing.expectEqualStrings("-Dcpu=baseline", argv[5]);
    try std.testing.expectEqualStrings("-Dfeature=true", argv[6]);
    try std.testing.expectEqualStrings("-Dtrust-store=true", argv[7]);
    for ([_]Tier{ .merge, .release }) |tier| {
        const tiers = try split(a, config, try plan(a, config, tier), tier);
        var linked: usize = 0;
        for (tiers.native) |job| if (std.mem.eql(u8, job.step, "ci-link")) {
            linked += 1;
            try std.testing.expect(job.operation == .link);
            try std.testing.expect(!std.mem.eql(u8, job.os, hosts[0]));
            try std.testing.expect(std.mem.find(u8, job.args, "-Dfeature=true") != null);
            if (std.mem.find(u8, job.args, "x86_64-macos") != null) {
                try std.testing.expect(std.mem.find(u8, job.args, "-Dcpu=baseline") != null);
                try std.testing.expect(std.mem.find(u8, job.args, "-Dtrust-store=true") != null);
            }
        };
        try std.testing.expectEqual(@as(usize, 3), linked);
        for (tiers.compile) |job| {
            try std.testing.expect(job.operation == .link);
            try std.testing.expect(!std.mem.eql(u8, job.os, hosts[0]));
        }
        for (tiers.run) |job| try std.testing.expect(job.operation == .replay);
    }
    const bad = (try std.json.parseFromSlice(src.Value, a, "{\"build_args\":[\"-Dtarget=x86_64-macos\"]}", .{})).value;
    try std.testing.expectError(error.InvalidBuildArgs, plan(a, bad, .fast));
}

test "hardened planner schedules native execution with no portable sanitizer replay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"compile_once\":true,\"hardened\":true}", .{})).value;
    const tiers = try split(a, config, try plan(a, config, .merge), .merge);
    var executed: usize = 0;
    for (tiers.native) |job| if (std.mem.startsWith(u8, job.step, "hardened")) {
        executed += 1;
        try std.testing.expectEqualStrings(hosts[0], job.os);
        try std.testing.expectEqual(.execute, job.operation);
        try std.testing.expectEqualStrings("", job.artifact);
    };
    try std.testing.expectEqual(@as(usize, 3), executed);
}
