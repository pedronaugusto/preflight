const std = @import("std");
const src = @import("source.zig");

pub const hosts = [_][]const u8{ "ubuntu-latest", "macos-latest", "windows-latest" };
pub const Job = struct {
    os: []const u8,
    name: []const u8,
    step: []const u8 = "ci",
    args: []const u8 = "",
    cases: []const u8 = "",
    timeout: []const u8 = "",
    setup: bool = false,
    job_timeout: usize = 20,
    cache_key: []const u8 = "",
    artifact: []const u8 = "",
};

const Shard = struct { name: []const u8, seconds: f64 };

pub fn balance(a: std.mem.Allocator, values: []const src.Value, count: usize) ![][]const []const u8 {
    if (count == 0) return error.InvalidShardCount;
    const shards = try a.alloc(Shard, values.len);
    for (values, shards) |value, *shard| {
        const weight = src.get(value, "seconds");
        shard.* = .{ .name = src.string(src.get(value, "name"), ""), .seconds = switch (weight) {
            .float => weight.float,
            .integer => @floatFromInt(weight.integer),
            else => 1,
        } };
        if (shard.name.len == 0 or shard.seconds <= 0) return error.InvalidShard;
    }
    std.mem.sort(Shard, shards, {}, struct {
        fn less(_: void, x: Shard, y: Shard) bool {
            return x.seconds > y.seconds or (x.seconds == y.seconds and std.mem.lessThan(u8, x.name, y.name));
        }
    }.less);
    const groups = try a.alloc(std.ArrayList([]const u8), @min(count, shards.len));
    const weights = try a.alloc(f64, groups.len);
    @memset(weights, 0);
    for (groups) |*group| group.* = .empty;
    for (shards) |shard| {
        var index: usize = 0;
        for (weights, 0..) |weight, i| if (weight < weights[index]) {
            index = i;
        };
        try groups[index].append(a, shard.name);
        weights[index] += shard.seconds;
    }
    const out = try a.alloc([]const []const u8, groups.len);
    for (groups, out) |group, *result| {
        std.sort.insertion([]const u8, group.items, values, struct {
            fn priority(items: []const src.Value, name: []const u8) usize {
                for (items) |item| if (std.mem.eql(u8, src.string(src.get(item, "name"), ""), name)) return src.number(src.get(item, "priority"), 0);
                return 0;
            }
            fn less(items: []const src.Value, x: []const u8, y: []const u8) bool {
                return priority(items, x) > priority(items, y);
            }
        }.less);
        result.* = group.items;
    }
    return out;
}

pub fn plan(a: std.mem.Allocator, config: src.Value, full: bool) ![]Job {
    var jobs: std.ArrayList(Job) = .empty;
    if (!full) return fastPlan(a, config);
    for (hosts) |host| {
        const modes: []const []const u8 = if (!full) &.{"Debug"} else if (std.mem.eql(u8, host, hosts[0])) &.{ "Debug", "ReleaseSafe", "ReleaseFast" } else &.{ "Debug", "ReleaseSafe" };
        for (modes) |mode| {
            const fast_shards = src.get(config, "fast_windows_shards");
            const shard_values = src.items(if (!full and fast_shards != .null) fast_shards else src.get(config, "windows_shards"));
            const groups: []const []const []const u8 = if (full and std.mem.eql(u8, host, hosts[2]) and shard_values.len > 0)
                try balance(a, shard_values, src.number(src.get(config, "shard_jobs"), 5))
            else
                &.{&.{}};
            for (groups, 0..) |group, i| {
                const suffix = if (group.len > 0) try std.fmt.allocPrint(a, " shard {d}", .{i + 1}) else "";
                try jobs.append(a, .{
                    .os = host,
                    .name = try std.fmt.allocPrint(a, "test ({s}, {s}){s}", .{ host, mode, suffix }),
                    .args = try std.fmt.allocPrint(a, "-Doptimize={s}{s}{s}", .{ mode, if (full or !std.mem.eql(u8, host, hosts[0])) " -Dci-lint=false" else "", if (full) " -Dci-timings=true" else "" }),
                    .cases = if (!full and std.mem.eql(u8, host, hosts[2])) "" else try std.mem.join(a, " ", group),
                    .timeout = src.string(src.get(config, "test_timeout"), ""),
                    .setup = true,
                    .job_timeout = src.number(src.get(config, if (std.mem.eql(u8, host, hosts[2])) "windows_job_timeout" else "test_job_timeout"), 20),
                });
            }
        }
    }
    if (full) {
        try jobs.append(a, .{ .os = hosts[0], .name = "source checks and documented snippets", .step = "lint", .job_timeout = src.number(src.get(config, "source_job_timeout"), 20) });
        try fullJobs(a, config, &jobs);
    }
    for (jobs.items) |*job| {
        const text = try std.json.Stringify.valueAlloc(a, job.*, .{});
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
        job.cache_key = try std.fmt.allocPrint(a, "{x}", .{hash[0..8]});
    }
    return jobs.items;
}

pub const Tiers = struct { native: []Job, compile: []Job, run: []Job };

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
        if (job.cases.len != 0) return error.ShardedPortableTestsUnsupported;
        const target = if (std.mem.eql(u8, job.os, hosts[1])) "aarch64-macos" else "x86_64-windows-gnu";
        var builder = job;
        builder.os = hosts[0];
        builder.step = "ci-build";
        builder.setup = false;
        builder.args = try std.fmt.allocPrint(a, "{s} -Dtarget={s}", .{ job.args, target });
        builder.name = try std.fmt.allocPrint(a, "compile for {s}", .{job.name});
        builder.cache_key = try std.fmt.allocPrint(a, "compile-{s}", .{job.cache_key});
        builder.artifact = try std.fmt.allocPrint(a, "preflight-{s}", .{job.cache_key});
        try compile.append(a, builder);
        var executor = job;
        executor.step = "ci-run";
        executor.artifact = builder.artifact;
        try run.append(a, executor);
    }
    return .{ .native = native.items, .compile = compile.items, .run = run.items };
}

fn fastPlan(a: std.mem.Allocator, config: src.Value) ![]Job {
    const values = src.items(src.get(config, "fast_linux_shards"));
    const groups: []const []const []const u8 = if (values.len > 0)
        try balance(a, values, src.number(src.get(config, "fast_linux_jobs"), 1))
    else
        &.{&.{}};
    const jobs = try a.alloc(Job, groups.len);
    for (groups, jobs, 0..) |group, *job, i| {
        job.* = .{
            .os = hosts[0],
            .name = try std.fmt.allocPrint(a, "Linux Debug{s}", .{if (groups.len > 1) try std.fmt.allocPrint(a, " shard {d}", .{i + 1}) else ""}),
            .step = "preflight-fast",
            .args = try std.fmt.allocPrint(a, "-Doptimize=Debug{s}{s}", .{ if (i == 0) "" else " -Dci-lint=false", if (values.len > 0) " -Dci-timings=true" else "" }),
            .cases = try std.mem.join(a, " ", group),
            .timeout = src.string(src.get(config, "test_timeout"), ""),
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
        .args = "-Dthread-sanitizer -Doptimize=Debug",
        .timeout = "--test-timeout 120s",
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
        \\{"compile_step":"install","compile_once":true,"targets":[{"target":"aarch64-linux-gnu","cpu":"cortex_a72"}],"test_timeout":"--test-timeout 60s"}
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

test "Linux fast shards cover every measured family exactly once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a,
        \\{"fast_linux_jobs":2,"fast_linux_shards":[{"name":"a","seconds":3},{"name":"b","seconds":2},{"name":"c","seconds":1}]}
    , .{})).value;
    const jobs = try plan(a, config, false);
    try std.testing.expectEqual(@as(usize, 2), jobs.len);
    try std.testing.expectEqualStrings("a", jobs[0].cases);
    try std.testing.expectEqualStrings("b c", jobs[1].cases);
    try std.testing.expectEqualStrings("-Doptimize=Debug -Dci-lint=false -Dci-timings=true", jobs[1].args);
}

test "duration balancing assigns each case once and equalizes measured weights" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "[{\"name\":\"1\",\"seconds\":1},{\"name\":\"2\",\"seconds\":2},{\"name\":\"3\",\"seconds\":3},{\"name\":\"4\",\"seconds\":4},{\"name\":\"5\",\"seconds\":5},{\"name\":\"6\",\"seconds\":6}]", .{})).value;
    for (try balance(a, src.items(config), 3)) |group| {
        var sum: usize = 0;
        for (group) |name| sum += try std.fmt.parseInt(usize, name, 10);
        try std.testing.expectEqual(@as(usize, 7), sum);
    }
    try std.testing.expectError(error.InvalidShardCount, balance(a, src.items(config), 0));
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

test "priority cases start independently of their bundled comparisons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const values = (try std.json.parseFromSlice(src.Value, a, "[{\"name\":\"comparison\",\"seconds\":10},{\"name\":\"core\",\"seconds\":3,\"priority\":1},{\"name\":\"tiny\",\"seconds\":2}]", .{})).value;
    const groups = try balance(a, src.items(values), 1);
    for ([_][]const u8{ "core", "comparison", "tiny" }, groups[0]) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
}
