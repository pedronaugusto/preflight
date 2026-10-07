//! Timing evidence is recorded by the test runner, never asserted by a test.
const std = @import("std");

pub const Recorder = struct {
    file: ?std.Io.File = null,
    /// The `ci/durations.json` column these records refresh.
    key: []const u8,
    /// The shard that ran the tests, `i/n`, or empty for all of them.
    shard: []const u8 = "",

    /// What `init` fails with: reading the environment, creating the
    /// records' directory or file, or memory.
    pub const InitError = std.process.Environ.CreateMapError || std.Io.Dir.CreateDirPathError || std.Io.File.OpenError || std.mem.Allocator.Error;
    /// What `record` fails with: encoding, sizing or writing the record.
    pub const RecordError = std.Io.File.StatError || std.Io.Writer.Error || std.mem.Allocator.Error;

    /// `stem` names the records without their shard, or is null for none:
    /// the file ends `-2of5.ndjson` for the shard `PREFLIGHT_SHARD` names,
    /// or `-all.ndjson`. Close it with `deinit(io)`.
    pub fn init(io: std.Io, environ: std.process.Environ, stem: ?[]const u8, key: []const u8) InitError!Recorder {
        const prefix = stem orelse return .{ .key = key };
        const a = std.heap.page_allocator;
        var env = try environ.createMap(a);
        defer env.deinit();
        const shard = env.get("PREFLIGHT_SHARD") orelse "";
        const part = if (shard.len == 0) "all" else try std.mem.replaceOwned(u8, a, shard, "/", "of");
        const path = try a.print("{s}-{s}.ndjson", .{ prefix, part });
        if (std.Io.Dir.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
        return .{
            .file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true }),
            .key = key,
            .shard = try a.dupe(u8, shard),
        };
    }

    pub fn deinit(recorder: Recorder, io: std.Io) void {
        if (recorder.file) |file| file.close(io);
    }

    /// Appends one test's record; nothing without a file.
    pub fn record(recorder: Recorder, io: std.Io, name: []const u8, nanoseconds: u64, status: []const u8) RecordError!void {
        const file = recorder.file orelse return;
        const json = try std.json.Stringify.valueAlloc(std.heap.page_allocator, .{
            .name = name,
            .seconds = @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_s,
            .status = status,
            .key = recorder.key,
            .shard = recorder.shard,
        }, .{});
        defer std.heap.page_allocator.free(json);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        writer.pos = (try file.stat(io)).size;
        try writer.interface.writeAll(json);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
    }
};
