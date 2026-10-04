//! The last successful full run supplies measured weights to the next plan.
const std = @import("std");
const src = @import("source.zig");

pub const Weight = struct { name: []const u8, seconds: f64 };
pub const Summary = struct { windows_shards: []Weight, test_records: usize };

pub fn reset(c: src.Context, root: []const u8) !void {
    try c.directory().deleteTree(c.io, root);
}

pub fn summarize(c: src.Context, config: src.Value, root: []const u8) !Summary {
    var dir = try c.directory().openDir(c.io, root, .{ .iterate = true });
    defer dir.close(c.io);
    var walker = try dir.walk(c.a);
    defer walker.deinit();
    const shards = src.items(src.get(config, "windows_shards"));
    const weights = try c.a.alloc(Weight, shards.len);
    for (shards, weights) |shard, *weight| weight.* = .{ .name = src.string(src.get(shard, "name"), ""), .seconds = 0 };
    var records: usize = 0;
    while (try walker.next(c.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".ndjson")) continue;
        const text = try dir.readFileAlloc(c.io, entry.path, c.a, .limited(64 * 1024 * 1024));
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        var seconds: f64 = 0;
        while (lines.next()) |line| {
            const value = (try std.json.parseFromSlice(src.Value, c.a, line, .{})).value;
            const duration = src.get(value, "seconds");
            seconds += switch (duration) {
                .float => duration.float,
                .integer => @floatFromInt(duration.integer),
                else => return error.InvalidTestDuration,
            };
            records += 1;
        }
        if (std.mem.indexOf(u8, entry.path, "-windows-") == null) continue;
        for (weights) |*weight| {
            const suffix = try std.fmt.allocPrint(c.a, "-{s}.ndjson", .{weight.name});
            if (std.mem.endsWith(u8, entry.path, suffix)) weight.seconds = @max(weight.seconds, seconds);
        }
    }
    return .{ .windows_shards = weights, .test_records = records };
}

pub fn apply(a: std.mem.Allocator, config: src.Value, summary: src.Value) !src.Value {
    var result = config;
    if (result != .object) return result;
    var shards: std.array_list.Managed(src.Value) = .init(a);
    for (src.items(src.get(config, "windows_shards"))) |original| {
        var shard = original;
        const name = src.string(src.get(original, "name"), "");
        for (src.items(src.get(summary, "windows_shards"))) |measured| {
            if (!std.mem.eql(u8, name, src.string(src.get(measured, "name"), ""))) continue;
            const duration = src.get(measured, "seconds");
            if ((duration == .float and duration.float > 0) or (duration == .integer and duration.integer > 0))
                try shard.object.put(a, "seconds", duration);
        }
        try shards.append(shard);
    }
    if (shards.items.len > 0) try result.object.put(a, "windows_shards", .{ .array = shards });
    return result;
}

test "profiles use complete recorded durations, keep new cases and ignore unrelated hosts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const c: src.Context = .{ .a = a, .io = std.testing.io, .dir = tmp.dir };
    try tmp.dir.writeFile(c.io, .{ .sub_path = "tests-windows-Debug-history-0.ndjson", .data = "{\"name\":\"first\",\"seconds\":3,\"status\":\"pass\"}\n{\"name\":\"second\",\"seconds\":4,\"status\":\"pass\"}\n" });
    try tmp.dir.writeFile(c.io, .{ .sub_path = "tests-linux-Debug-history-0.ndjson", .data = "{\"name\":\"first\",\"seconds\":100,\"status\":\"pass\"}\n" });
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"windows_shards\":[{\"name\":\"history-0\",\"seconds\":1},{\"name\":\"new-case\",\"seconds\":2}]}", .{})).value;
    const summary = try summarize(c, config, ".");
    try std.testing.expectEqual(@as(usize, 3), summary.test_records);
    // Fixed fixture weights exercise arithmetic, not a machine's timing.
    try std.testing.expectEqual(@as(f64, 7), summary.windows_shards[0].seconds);
    const json = try std.json.Stringify.valueAlloc(a, summary, .{});
    const updated = try apply(a, config, (try std.json.parseFromSlice(src.Value, a, json, .{})).value);
    try std.testing.expectEqual(@as(i64, 2), src.get(src.items(src.get(updated, "windows_shards"))[1], "seconds").integer);
}

test "restored timings are discarded before a gate records this run" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const c: src.Context = .{ .a = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    try tmp.dir.createDirPath(c.io, "cache/preflight-timings");
    try tmp.dir.writeFile(c.io, .{ .sub_path = "cache/preflight-timings/previous.ndjson", .data = "old run" });
    try tmp.dir.writeFile(c.io, .{ .sub_path = "cache/compiled", .data = "keep" });
    try reset(c, "cache/preflight-timings");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(c.io, "cache/preflight-timings", .{}));
    try tmp.dir.access(c.io, "cache/compiled", .{});
    try reset(c, "cache/preflight-timings");
}
