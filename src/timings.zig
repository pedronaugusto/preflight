//! Evidence the test runner records, never asserted by a test: each test's timing, and the
//! count of the tests a run's binary holds.
const std = @import("std");

pub const Recorder = struct {
    // aegis: design: std alone, as the test runner and build module every package compiles (aegis's own too) must be
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
        const shard = try Shard.read(a, environ);
        const path = try a.print("{s}-{s}.ndjson", .{ prefix, shard.part });
        if (std.Io.Dir.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
        return .{
            .file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true }),
            .key = key,
            .shard = shard.name,
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
            // aegis: design: std alone, as the test runner and build module every package compiles (aegis's own too) must be
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

/// The shard a run's tests are, `PREFLIGHT_SHARD`: its name, `2/5` or empty for all of the
/// tests, and the part of a record's name it gives, `2of5` or `all`.
pub const Shard = struct {
    name: []const u8,
    part: []const u8,

    pub fn read(a: std.mem.Allocator, environ: std.process.Environ) (std.process.Environ.CreateMapError || std.mem.Allocator.Error)!Shard {
        var env = try environ.createMap(a);
        defer env.deinit();
        return of(a, env.get("PREFLIGHT_SHARD") orelse "");
    }

    pub fn of(a: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!Shard {
        return .{ .name = try a.dupe(u8, name), .part = if (name.len == 0) "all" else try std.mem.replaceOwned(u8, a, name, "/", "of") };
    }
};

/// What a run's binary holds, as the runner tells it to the build: its root, the artifact
/// that compiles it, whether the compiler kept only the tests a filter names, how many tests
/// the binary holds, and how many of them the run's shard selects.
pub const Count = struct {
    root: []const u8,
    artifact: []const u8,
    filtered: bool,
    tests: usize,
    selected: usize,
    shard: []const u8 = "",
};

/// What `count` fails with: reading the environment, the records' directory or file, or memory.
pub const CountError = std.process.Environ.CreateMapError || std.Io.Dir.CreateDirPathError || std.Io.Dir.WriteFileError || std.Io.Writer.Error || std.mem.Allocator.Error;

/// Writes `record` to `<stem>-<shard part>.json`, in place of an earlier run's: the build's
/// count of the run's tests reads it after the run.
pub fn count(io: std.Io, environ: std.process.Environ, stem: []const u8, record: Count) CountError!void {
    const a = std.heap.page_allocator;
    const shard = try Shard.read(a, environ);
    const path = try a.print("{s}-{s}.json", .{ stem, shard.part });
    if (std.Io.Dir.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    var with_shard = record;
    with_shard.shard = shard.name;
    const json = try std.json.Stringify.valueAlloc(a, with_shard, .{});
    defer a.free(json);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
}
