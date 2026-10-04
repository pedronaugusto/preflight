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
    for (groups, out) |group, *result| result.* = group.items;
    return out;
}

pub fn plan(a: std.mem.Allocator, config: src.Value, full: bool) ![]Job {
    var jobs: std.ArrayList(Job) = .empty;
    for (hosts) |host| {
        const modes: []const []const u8 = if (!full) &.{"Debug"} else if (std.mem.eql(u8, host, hosts[0])) &.{ "Debug", "ReleaseSafe", "ReleaseFast" } else &.{ "Debug", "ReleaseSafe" };
        for (modes) |mode| {
            const shard_values = src.items(src.get(config, "windows_shards"));
            const groups: []const []const []const u8 = if (std.mem.eql(u8, host, hosts[2]) and shard_values.len > 0)
                try balance(a, shard_values, src.number(src.get(config, "shard_jobs"), 5))
            else
                &.{&.{}};
            for (groups, 0..) |group, i| {
                const suffix = if (group.len > 0) try std.fmt.allocPrint(a, " shard {d}", .{i + 1}) else "";
                try jobs.append(a, .{
                    .os = host,
                    .name = try std.fmt.allocPrint(a, "test ({s}, {s}){s}", .{ host, mode, suffix }),
                    .args = try std.fmt.allocPrint(a, "-Doptimize={s} -Dci-lint=false", .{mode}),
                    .cases = try std.mem.join(a, " ", group),
                    .timeout = src.string(src.get(config, "test_timeout"), ""),
                    .setup = true,
                    .job_timeout = src.number(src.get(config, if (std.mem.eql(u8, host, hosts[2])) "windows_job_timeout" else "test_job_timeout"), 20),
                });
            }
        }
    }
    try jobs.append(a, .{ .os = hosts[0], .name = "source checks and documented snippets", .step = "lint", .job_timeout = src.number(src.get(config, "source_job_timeout"), 20) });
    if (full) try fullJobs(a, config, &jobs);
    for (jobs.items) |*job| {
        const text = try std.json.Stringify.valueAlloc(a, job.*, .{});
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
        job.cache_key = try std.fmt.allocPrint(a, "{x}", .{hash[0..8]});
    }
    return jobs.items;
}

fn fullJobs(a: std.mem.Allocator, config: src.Value, jobs: *std.ArrayList(Job)) !void {
    const compile = src.string(src.get(config, "compile_step"), "check");
    try jobs.append(a, .{ .os = hosts[0], .name = "compile (ReleaseSmall)", .step = compile, .args = "-Doptimize=ReleaseSmall" });
    for (src.items(src.get(config, "targets"))) |target| {
        const name = if (target == .string) target.string else src.string(src.get(target, "target"), "");
        const cpu = src.get(target, "cpu");
        const args = if (cpu == .string) try std.fmt.allocPrint(a, "-Dtarget={s} -Dcpu={s}", .{ name, cpu.string }) else try std.fmt.allocPrint(a, "-Dtarget={s}", .{name});
        try jobs.append(a, .{ .os = hosts[0], .name = try std.fmt.allocPrint(a, "cross ({s})", .{args}), .step = compile, .args = args });
    }
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

test "fast gate contains three Debug hosts and source checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const jobs = try plan(arena.allocator(), .null, false);
    try std.testing.expectEqual(@as(usize, 4), jobs.len);
    for (jobs) |job| {
        try std.testing.expect(std.mem.indexOf(u8, job.args, "Release") == null);
        try std.testing.expectEqual(@as(usize, 16), job.cache_key.len);
    }
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
