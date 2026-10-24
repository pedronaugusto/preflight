//! The tests counted per root after a run of the tests: one record per root module, which
//! preflight's runner writes when the build asks its binary which tests it holds
//! (`timings.zig`), read after the runs (`record.zig`).
const std = @import("std");
const aegis = @import("aegis");
const src = @import("source.zig");

/// The counts of the last run, beside the records, which the gate prints.
pub const summary_name = "summary.txt";

/// The runner's record, as `timings.Count` writes it.
const Record = struct { root: []const u8, artifact: []const u8, filtered: bool, tests: usize, selected: usize, shard: []const u8 = "" };

/// Reads the record of each of `names` in the directory `records`, of the shard `shard`
/// names (`2/5`, or empty for all of the tests). A missing record is a run that never
/// reached preflight's runner, and a binary that holds no test, unfiltered, has its tests in
/// modules it imports, which Zig never runs, or none: both fail by name. The counts go to
/// `summary_name` either way.
pub fn check(c: *src.Context, records: []const u8, names: []const []const u8, shard: []const u8) !void {
    const part = if (shard.len == 0) "all" else try std.mem.replaceOwned(u8, c.a, shard, "/", "of");
    try std.Io.Dir.cwd().createDirPath(c.io, records);
    var dir = try std.Io.Dir.cwd().openDir(c.io, records, .{});
    defer dir.close(c.io);
    var line: std.Io.Writer.Allocating = .init(c.a);
    try line.writer.writeAll("preflight: tests per root:");
    for (names, 0..) |name, i| {
        const text = aegis.own.readFile(c.io, dir, try c.a.print("{s}-{s}.json", .{ name, part }), c.a, .fromRaw(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => {
                c.fail("{s}: no count of its tests: its run never reached preflight's runner", .{name});
                continue;
            },
            else => return err,
        };
        const record = std.json.parseFromSliceLeaky(Record, c.a, text, .{}) catch {
            c.fail("{s}: its count of tests is not the runner's record", .{name});
            continue;
        };
        if (record.tests == 0 and !record.filtered)
            c.fail("{s} ({s}): the binary holds no test: its tests are in modules it imports, which Zig never runs, or it has none; give its root the tests, or drop the run", .{ record.root, record.artifact });
        try line.writer.print("{s} {s} {d}", .{ if (i == 0) "" else ",", record.root, record.selected });
        if (record.selected != record.tests) try line.writer.print(" of {d}", .{record.tests});
        try line.writer.print(" ({s})", .{record.artifact});
    }
    try line.writer.writeByte('\n');
    try dir.writeFile(c.io, .{ .sub_path = summary_name, .data = line.written() });
}

test "the counts name each root, and fail a missing record and a binary with no test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "tests-macos-Debug-all.json", .data = "{\"root\":\"src/root.zig\",\"artifact\":\"tests\",\"filtered\":false,\"tests\":3,\"selected\":3}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "empty-macos-Debug-all.json", .data = "{\"root\":\"src/empty.zig\",\"artifact\":\"empty\",\"filtered\":false,\"tests\":0,\"selected\":0}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "only-macos-Debug-all.json", .data = "{\"root\":\"src/only.zig\",\"artifact\":\"only\",\"filtered\":true,\"tests\":0,\"selected\":0}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tests-macos-Debug-2of2.json", .data = "{\"root\":\"src/root.zig\",\"artifact\":\"tests\",\"filtered\":false,\"tests\":3,\"selected\":1,\"shard\":\"2/2\"}" });
    const records = try tmp.dir.realPathFileAlloc(io, ".", a);
    var held: std.Io.Writer.Allocating = .init(a);
    var c: src.Context = .{ .a = a, .io = io, .held = &held };
    try check(&c, records, &.{ "tests-macos-Debug", "only-macos-Debug" }, "");
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    try std.testing.expectEqualStrings("preflight: tests per root: src/root.zig 3 (tests), src/only.zig 0 (only)\n", try tmp.dir.readFileAlloc(io, summary_name, a, .limited(1024)));
    try check(&c, records, &.{"tests-macos-Debug"}, "2/2");
    try std.testing.expectEqualStrings("preflight: tests per root: src/root.zig 1 of 3 (tests)\n", try tmp.dir.readFileAlloc(io, summary_name, a, .limited(1024)));
    try check(&c, records, &.{ "empty-macos-Debug", "gone-macos-Debug" }, "");
    try std.testing.expectEqual(@as(usize, 2), c.errors);
    try std.testing.expect(std.mem.find(u8, held.written(), "src/empty.zig (empty): the binary holds no test") != null);
    try std.testing.expect(std.mem.find(u8, held.written(), "gone-macos-Debug: no count of its tests") != null);
}
