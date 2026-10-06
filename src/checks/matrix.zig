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
};

fn shardCount(value: src.Value) !usize {
    if (value == .null) return 1;
    if (value != .integer or value.integer < 1) return error.InvalidShardCount;
    return @intCast(value.integer);
}

fn shardName(a: std.mem.Allocator, index: usize, count: usize) ![]const u8 {
    return if (count > 1) std.fmt.allocPrint(a, "{d}/{d}", .{ index + 1, count }) else "";
}

/// A job's cache scope: everything that changes what it builds and runs.
fn key(a: std.mem.Allocator, job: Job) ![]const u8 {
    var plain = job;
    plain.cache_key = "";
    plain.artifact = "";
    const text = try std.json.Stringify.valueAlloc(a, plain, .{});
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
    return std.fmt.allocPrint(a, "{x}", .{hash[0..8]});
}

pub fn plan(a: std.mem.Allocator, config: src.Value, full: bool) ![]Job {
    for (obsolete) |name| if (src.get(config, name) != .null) return error.ObsoleteShardConfig;
    // The build bounds each test past its watchdog (`Config.test_timeout`).
    if (src.get(config, "test_timeout") != .null) return error.ObsoleteTestTimeout;
    if (!full) return fastPlan(a, config);
    var jobs: std.ArrayList(Job) = .empty;
    for (hosts, host_names) |host, host_name| {
        const modes: []const []const u8 = if (std.mem.eql(u8, host, hosts[0])) &.{ "Debug", "ReleaseSafe", "ReleaseFast" } else &.{ "Debug", "ReleaseSafe" };
        const count = try shardCount(src.get(src.get(config, "shards"), host_name));
        for (modes) |mode| for (0..count) |i| {
            const shard = try shardName(a, i, count);
            try jobs.append(a, .{
                .os = host,
                .name = try std.fmt.allocPrint(a, "test ({s}, {s}){s}{s}", .{ host, mode, if (count > 1) " shard " else "", shard }),
                .args = try std.fmt.allocPrint(a, "-Doptimize={s} -Dci-lint=false -Dci-timings=true", .{mode}),
                .shard = shard,
                .setup = true,
                .job_timeout = src.number(src.get(config, if (std.mem.eql(u8, host, hosts[2])) "windows_job_timeout" else "test_job_timeout"), 20),
            });
        };
    }
    try jobs.append(a, .{ .os = hosts[0], .name = "source checks and documented snippets", .step = "lint", .job_timeout = src.number(src.get(config, "source_job_timeout"), 20) });
    try fullJobs(a, config, &jobs);
    for (jobs.items) |*job| job.cache_key = try key(a, job.*);
    return jobs.items;
}

pub const Tiers = struct { native: []Job, compile: []Job, run: []Job };

/// Portable hosts compile once on Linux per host and mode; every shard of
/// that host and mode runs the same binaries.
pub fn split(a: std.mem.Allocator, config: src.Value, jobs: []const Job, full: bool) !Tiers {
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
        if (!full or enabled != .bool or !enabled.bool or !allowed or !std.mem.eql(u8, job.step, "ci") or std.mem.eql(u8, job.os, hosts[0])) {
            try native.append(a, job);
            continue;
        }
        var whole = job;
        whole.shard = "";
        whole.name = job.name[0 .. std.mem.indexOf(u8, job.name, " shard ") orelse job.name.len];
        const whole_key = try key(a, whole);
        const artifact = try std.fmt.allocPrint(a, "preflight-{s}", .{whole_key});
        var built = false;
        for (compile.items) |existing| if (std.mem.eql(u8, existing.artifact, artifact)) {
            built = true;
        };
        if (!built) {
            const target = if (std.mem.eql(u8, job.os, hosts[1])) "aarch64-macos" else "x86_64-windows-gnu";
            var builder = whole;
            builder.os = hosts[0];
            builder.step = "ci-build";
            builder.setup = false;
            builder.args = try std.fmt.allocPrint(a, "{s} -Dtarget={s}", .{ job.args, target });
            builder.name = try std.fmt.allocPrint(a, "compile for {s}", .{whole.name});
            builder.cache_key = try std.fmt.allocPrint(a, "compile-{s}", .{whole_key});
            builder.artifact = artifact;
            try compile.append(a, builder);
        }
        var executor = job;
        executor.step = "ci-run";
        executor.artifact = artifact;
        try run.append(a, executor);
    }
    return .{ .native = native.items, .compile = compile.items, .run = run.items };
}

/// Linux Debug in `fast_shards` jobs; the first also checks sources and
/// compiles the other targets.
fn fastPlan(a: std.mem.Allocator, config: src.Value) ![]Job {
    const count = try shardCount(src.get(config, "fast_shards"));
    const jobs = try a.alloc(Job, count);
    for (jobs, 0..) |*job, i| {
        const shard = try shardName(a, i, count);
        job.* = .{
            .os = hosts[0],
            .name = try std.fmt.allocPrint(a, "Linux Debug{s}{s}", .{ if (count > 1) " shard " else "", shard }),
            .step = "preflight-fast",
            .args = try std.fmt.allocPrint(a, "-Doptimize=Debug{s}{s}", .{ if (i == 0) "" else " -Dci-lint=false", if (count > 1) " -Dci-timings=true" else "" }),
            .shard = shard,
            .setup = true,
            .job_timeout = src.number(src.get(config, "test_job_timeout"), 20),
            .cache_key = try std.fmt.allocPrint(a, "fast-linux-debug-{d}", .{i}),
        };
    }
    return jobs;
}

pub fn fastTargets(a: std.mem.Allocator, config: src.Value) ![]src.Value {
    var targets: std.ArrayList(src.Value) = .empty;
    try targets.appendSlice(a, src.items(src.get(config, "targets")));
    for ([_][]const u8{ "aarch64-macos", "x86_64-windows-gnu" }) |native| {
        var found = false;
        for (targets.items) |target| {
            const name = if (target == .string) target.string else src.string(src.get(target, "target"), "");
            if (std.mem.eql(u8, name, native)) found = true;
        }
        if (!found) try targets.append(a, .{ .string = native });
    }
    return targets.items;
}

pub fn fastCrossArgs(a: std.mem.Allocator, config: src.Value, target: src.Value) ![]const []const u8 {
    const args = try crossArgs(a, config, target);
    const result = try a.alloc([]const u8, args.len + 1);
    @memcpy(result[0..args.len], args);
    result[2] = "ci-check";
    result[args.len] = "-Doptimize=Debug";
    return result;
}

fn fullJobs(a: std.mem.Allocator, config: src.Value, jobs: *std.ArrayList(Job)) !void {
    const compile = src.string(src.get(config, "compile_step"), "check");
    try jobs.append(a, .{ .os = hosts[0], .name = "compile (ReleaseSmall)", .step = compile, .args = "-Doptimize=ReleaseSmall" });
    if (src.items(src.get(config, "targets")).len > 0)
        try jobs.append(a, .{ .os = hosts[0], .name = "cross (all configured targets)", .step = "preflight-cross", .job_timeout = src.number(src.get(config, "cross_job_timeout"), 20) });
    const sanitizer = src.get(config, "sanitizer");
    if (sanitizer == .string) try jobs.append(a, .{
        .os = hosts[0],
        .name = "ThreadSanitizer (Linux)",
        .step = sanitizer.string,
        .args = "-Dthread-sanitizer -Doptimize=Debug -Dci-lint=false",
        .setup = true,
        .job_timeout = src.number(src.get(config, "sanitizer_job_timeout"), 20),
    });
}

pub fn crossArgs(a: std.mem.Allocator, config: src.Value, target: src.Value) ![]const []const u8 {
    const name = if (target == .string) target.string else src.string(src.get(target, "target"), "");
    if (name.len == 0) return error.InvalidCrossTarget;
    const cpu = src.get(target, "cpu");
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, &.{ "zig", "build", src.string(src.get(config, "compile_step"), "check"), "-Dci-lint=false" });
    try args.append(a, try std.fmt.allocPrint(a, "-Dtarget={s}", .{name}));
    if (cpu == .string) try args.append(a, try std.fmt.allocPrint(a, "-Dcpu={s}", .{cpu.string}));
    return args.toOwnedSlice(a);
}

test "the cross bundle retains every target, CPU and caller compile step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a,
        \\{"compile_step":"install","targets":["x86_64-windows-gnu",{"target":"aarch64-linux-gnu","cpu":"cortex_a72"}]}
    , .{})).value;
    const jobs = try plan(a, config, true);
    var bundles: usize = 0;
    for (jobs) |job| if (std.mem.eql(u8, job.step, "preflight-cross")) {
        bundles += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), bundles);
    const targets = src.items(src.get(config, "targets"));
    const first = try crossArgs(a, config, targets[0]);
    const second = try crossArgs(a, config, targets[1]);
    try std.testing.expectEqualStrings("install", first[2]);
    try std.testing.expectEqualStrings("-Dtarget=x86_64-windows-gnu", first[4]);
    try std.testing.expectEqualStrings("-Dtarget=aarch64-linux-gnu", second[4]);
    try std.testing.expectEqualStrings("-Dcpu=cortex_a72", second[5]);
    try std.testing.expectError(error.InvalidCrossTarget, crossArgs(a, config, .null));
}

test "fast gate executes only Linux Debug and compiles all other test targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a,
        \\{"compile_step":"install","compile_once":true,"targets":[{"target":"aarch64-linux-gnu","cpu":"cortex_a72"}]}
    , .{})).value;
    const jobs = try plan(a, config, false);
    try std.testing.expectEqual(@as(usize, 1), jobs.len);
    try std.testing.expectEqualStrings(hosts[0], jobs[0].os);
    try std.testing.expectEqualStrings("-Doptimize=Debug", jobs[0].args);
    const targets = try fastTargets(a, config);
    try std.testing.expectEqual(@as(usize, 3), targets.len);
    const args = try fastCrossArgs(a, config, targets[0]);
    try std.testing.expectEqualStrings("ci-check", args[2]);
    try std.testing.expectEqualStrings("-Dcpu=cortex_a72", args[5]);
    try std.testing.expectEqualStrings("-Doptimize=Debug", args[6]);
    const tiers = try split(a, config, jobs, false);
    try std.testing.expectEqual(@as(usize, 1), tiers.native.len);
    try std.testing.expectEqual(@as(usize, 0), tiers.run.len);
}

test "portable matrix builds macOS and Windows binaries on Linux without losing native coverage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"compile_once\":true,\"targets\":[\"aarch64-linux-gnu\"],\"sanitizer\":\"unit\"}", .{})).value;
    const jobs = try plan(a, config, true);
    const tiers = try split(a, config, jobs, true);
    try std.testing.expectEqual(@as(usize, 4), tiers.compile.len);
    try std.testing.expectEqual(@as(usize, 4), tiers.run.len);
    try std.testing.expectEqual(jobs.len, tiers.native.len + tiers.run.len);
    for (tiers.compile, tiers.run) |builder, executor| {
        try std.testing.expectEqualStrings(hosts[0], builder.os);
        try std.testing.expectEqualStrings(builder.artifact, executor.artifact);
        try std.testing.expect(!std.mem.eql(u8, executor.os, hosts[0]));
    }
    try std.testing.expect(std.mem.indexOf(u8, tiers.compile[0].args, "aarch64-macos") != null);
}

test "each host's shards run every mode, split by count, with the lint and compile jobs once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"shards\":{\"windows\":3,\"macos\":2},\"sanitizer\":\"test\"}", .{})).value;
    const jobs = try plan(a, config, true);
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
    // The source checks job owns lint in the full tier; no test job repeats it.
    for (jobs) |job| if (!std.mem.eql(u8, job.step, "lint") and job.setup) try std.testing.expect(std.mem.indexOf(u8, job.args, "-Dci-lint=false") != null);
    try std.testing.expectError(error.InvalidShardCount, plan(a, (try std.json.parseFromSlice(src.Value, a, "{\"shards\":{\"windows\":0}}", .{})).value, true));
}

test "named weighted cases are refused, naming the per-test shards that replace them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "{\"windows_shards\":[{\"name\":\"core\",\"seconds\":3}]}", "{\"fast_linux_jobs\":2}", "{\"shard_jobs\":5}" }) |text| {
        const config = (try std.json.parseFromSlice(src.Value, a, text, .{})).value;
        try std.testing.expectError(error.ObsoleteShardConfig, plan(a, config, true));
        try std.testing.expectError(error.ObsoleteShardConfig, plan(a, config, false));
    }
}

test "a workflow-level test timeout is refused; the build bounds each test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"test_timeout\":\"--test-timeout 120s\"}", .{})).value;
    try std.testing.expectError(error.ObsoleteTestTimeout, plan(a, config, true));
    try std.testing.expectError(error.ObsoleteTestTimeout, plan(a, config, false));
    for (try plan(a, (try std.json.parseFromSlice(src.Value, a, "{\"sanitizer\":\"test\"}", .{})).value, true)) |job|
        try std.testing.expect(std.mem.indexOf(u8, job.args, "test-timeout") == null);
}

test "fast shards split Linux Debug, and only the first checks sources and compiles other targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"fast_shards\":3}", .{})).value;
    const jobs = try plan(a, config, false);
    try std.testing.expectEqual(@as(usize, 3), jobs.len);
    try std.testing.expectEqualStrings("-Doptimize=Debug -Dci-timings=true", jobs[0].args);
    try std.testing.expectEqualStrings("1/3", jobs[0].shard);
    try std.testing.expectEqualStrings("Linux Debug shard 2/3", jobs[1].name);
    try std.testing.expectEqualStrings("-Doptimize=Debug -Dci-lint=false -Dci-timings=true", jobs[1].args);
    try std.testing.expectEqualStrings("3/3", jobs[2].shard);
}

test "portable shards share one compilation per host and mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"compile_once\":true,\"shards\":{\"windows\":3}}", .{})).value;
    const jobs = try plan(a, config, true);
    const tiers = try split(a, config, jobs, true);
    try std.testing.expectEqual(@as(usize, 4), tiers.compile.len);
    try std.testing.expectEqual(@as(usize, 2 + 6), tiers.run.len);
    for (tiers.compile) |builder| {
        try std.testing.expectEqualStrings("", builder.shard);
        try std.testing.expect(std.mem.indexOf(u8, builder.name, "shard") == null);
    }
    var sharing: usize = 0;
    for (tiers.run) |executor| if (std.mem.eql(u8, executor.name, "test (windows-latest, Debug) shard 2/3")) {
        for (tiers.run) |other| if (std.mem.eql(u8, other.artifact, executor.artifact)) {
            sharing += 1;
        };
    };
    try std.testing.expectEqual(@as(usize, 3), sharing);
}
