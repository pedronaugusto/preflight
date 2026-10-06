//! A merge or release run's per-test records refresh the durations the next shards balance by.
const std = @import("std");
const src = @import("source.zig");

/// Seconds per test name, per target column (`windows-Debug`).
pub const Durations = struct {
    tests: std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(f64)) = .empty,
    keys: std.StringArrayHashMapUnmanaged(void) = .empty,
    records: usize = 0,

    fn put(d: *Durations, a: std.mem.Allocator, name: []const u8, column: []const u8, seconds: f64) !void {
        try d.keys.put(a, column, {});
        const row = try d.tests.getOrPut(a, name);
        if (!row.found_existing) row.value_ptr.* = .empty;
        const cell = try row.value_ptr.getOrPut(a, column);
        cell.value_ptr.* = if (cell.found_existing) @max(cell.value_ptr.*, seconds) else seconds;
    }
};

pub fn reset(c: src.Context, root: []const u8) !void {
    try c.directory().deleteTree(c.io, root);
}

/// Reads every `.ndjson` record under `root`. A column this run measured
/// replaces the one in `previous`; columns it did not measure are kept. A
/// test that two shards of one column both ran fails: the split is broken.
pub fn summarize(c: src.Context, root: []const u8, previous: src.Value) !Durations {
    var result: Durations = .{};
    // The shard that recorded each test, by name and column.
    var shards: std.StringHashMapUnmanaged([]const u8) = .empty;
    var split = true;
    var dir = try c.directory().openDir(c.io, root, .{ .iterate = true });
    defer dir.close(c.io);
    var walker = try dir.walk(c.a);
    defer walker.deinit();
    while (try walker.next(c.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".ndjson")) continue;
        const text = try dir.readFileAlloc(c.io, entry.path, c.a, .limited(64 * 1024 * 1024));
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const value = (try std.json.parseFromSlice(src.Value, c.a, line, .{})).value;
            const seconds = try number(src.get(value, "seconds"));
            result.records += 1;
            const column = src.string(src.get(value, "key"), "");
            if (column.len == 0) continue;
            const name = src.string(src.get(value, "name"), "");
            const shard = src.string(src.get(value, "shard"), "");
            const seen = try shards.getOrPut(c.a, try std.fmt.allocPrint(c.a, "{s}\x00{s}", .{ name, column }));
            if (!seen.found_existing) {
                seen.value_ptr.* = try c.a.dupe(u8, shard);
            } else if (!std.mem.eql(u8, seen.value_ptr.*, shard)) {
                c.report("profile: {s} ran on shards {s} and {s} of {s}\n", .{ name, seen.value_ptr.*, shard, column });
                split = false;
            }
            try result.put(c.a, try c.a.dupe(u8, src.string(src.get(value, "name"), "")), try c.a.dupe(u8, column), seconds);
        }
    }
    if (!split) return error.TestOnTwoShards;
    const measured = try result.keys.clone(c.a);
    const keys = src.items(src.get(previous, "keys"));
    const tests = src.get(previous, "tests");
    if (tests == .object) {
        var rows = tests.object.iterator();
        while (rows.next()) |row| {
            const cells = src.items(row.value_ptr.*);
            if (cells.len != keys.len) return error.InvalidDurations;
            for (keys, cells) |column, cell| {
                if (column != .string or measured.contains(column.string) or cell == .null) continue;
                try result.put(c.a, row.key_ptr.*, column.string, try number(cell));
            }
        }
    }
    return result;
}

fn number(value: src.Value) !f64 {
    const seconds: f64 = switch (value) {
        .float => value.float,
        .integer => @floatFromInt(value.integer),
        else => return error.InvalidTestDuration,
    };
    if (!(seconds >= 0)) return error.InvalidTestDuration;
    return seconds;
}

/// One line per test, names and columns sorted, so a refresh diffs by test.
pub fn render(a: std.mem.Allocator, d: Durations) ![]const u8 {
    const columns = try a.dupe([]const u8, d.keys.keys());
    std.mem.sort([]const u8, columns, {}, lessThan);
    const names = try a.dupe([]const u8, d.tests.keys());
    std.mem.sort([]const u8, names, {}, lessThan);
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll("{\n  \"keys\": ");
    try std.json.Stringify.value(columns, .{}, w);
    try w.writeAll(",\n  \"tests\": {");
    for (names, 0..) |name, i| {
        try w.writeAll(if (i == 0) "\n    " else ",\n    ");
        try std.json.Stringify.value(name, .{}, w);
        try w.writeAll(": [");
        const row = d.tests.get(name).?;
        for (columns, 0..) |column, j| {
            if (j > 0) try w.writeAll(", ");
            if (row.get(column)) |seconds| try w.print("{d:.2}", .{seconds}) else try w.writeAll("null");
        }
        try w.writeByte(']');
    }
    try w.writeAll("\n  }\n}\n");
    return out.written();
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

test "a refresh replaces the columns it measured, keeps the rest, and takes the longest record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const c: src.Context = .{ .a = a, .io = std.testing.io, .dir = tmp.dir };
    // Fixed fixture weights exercise arithmetic, not a machine's timing.
    try tmp.dir.writeFile(c.io, .{ .sub_path = "tests-windows-Debug-1of2.ndjson", .data = "{\"name\":\"first\",\"seconds\":3,\"status\":\"pass\",\"key\":\"windows-Debug\"}\n{\"name\":\"first\",\"seconds\":4.5,\"status\":\"pass\",\"key\":\"windows-Debug\"}\n" });
    try tmp.dir.writeFile(c.io, .{ .sub_path = "tests-linux-Debug-all.ndjson", .data = "{\"name\":\"second\",\"seconds\":0.25,\"status\":\"skip\",\"key\":\"linux-Debug\"}\n{\"name\":\"untargeted\",\"seconds\":1,\"status\":\"pass\"}\n" });
    const previous = (try std.json.parseFromSlice(src.Value, a,
        \\{"keys":["macos-Debug","windows-Debug"],"tests":{"first":[2,9],"gone":[1,1],"kept":[3,null]}}
    , .{})).value;
    const durations = try summarize(c, ".", previous);
    try std.testing.expectEqual(@as(usize, 4), durations.records);
    try std.testing.expectEqualStrings(
        \\{
        \\  "keys": ["linux-Debug","macos-Debug","windows-Debug"],
        \\  "tests": {
        \\    "first": [null, 2.00, 4.50],
        \\    "gone": [null, 1.00, null],
        \\    "kept": [null, 3.00, null],
        \\    "second": [0.25, null, null]
        \\  }
        \\}
        \\
    , try render(a, durations));
    try tmp.dir.writeFile(c.io, .{ .sub_path = "bad.ndjson", .data = "{\"name\":\"x\",\"seconds\":-1,\"key\":\"k\"}\n" });
    try std.testing.expectError(error.InvalidTestDuration, summarize(c, ".", .null));
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

test "a test recorded on two shards of one column fails the refresh" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const c: src.Context = .{ .a = a, .io = std.testing.io, .dir = tmp.dir };
    try tmp.dir.writeFile(c.io, .{ .sub_path = "tests-windows-Debug-1of2.ndjson", .data = "{\"name\":\"first\",\"seconds\":3,\"status\":\"pass\",\"key\":\"windows-Debug\",\"shard\":\"1/2\"}\n" });
    try tmp.dir.writeFile(c.io, .{ .sub_path = "tests-macos-Debug-2of2.ndjson", .data = "{\"name\":\"first\",\"seconds\":3,\"status\":\"pass\",\"key\":\"macos-Debug\",\"shard\":\"2/2\"}\n" });
    _ = try summarize(c, ".", .null);
    try tmp.dir.writeFile(c.io, .{ .sub_path = "tests-windows-Debug-2of2.ndjson", .data = "{\"name\":\"first\",\"seconds\":2,\"status\":\"pass\",\"key\":\"windows-Debug\",\"shard\":\"2/2\"}\n" });
    try std.testing.expectError(error.TestOnTwoShards, summarize(c, ".", .null));
}
