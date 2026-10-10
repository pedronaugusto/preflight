//! Where a hosted job's time goes. The gate times each command it runs and
//! each source check, prints the phase as it ends and adds it to the job's
//! summary. The job keeps its phases in a record too, which the profile job
//! folds into `ci/costs.json`, and the next plan balances its jobs by.
const std = @import("std");
const src = @import("source.zig");

/// Where a phase is reported once it ends.
pub const Log = struct {
    /// The job's step summary.
    summary: ?[]const u8 = null,
    /// The job's record of phases, one JSON line each.
    record: ?[]const u8 = null,

    pub const directory = ".zig-cache/preflight-timings";

    /// The summary the runner gives the job, and a record named for it by
    /// `PREFLIGHT_JOB`; a run outside a hosted job keeps none.
    pub fn init(a: std.mem.Allocator, env: *const std.process.Environ.Map) !Log {
        const job = env.get("PREFLIGHT_JOB") orelse "";
        return .{
            .summary = env.get("GITHUB_STEP_SUMMARY"),
            .record = if (job.len == 0) null else try a.print("{s}/phases-{s}.ndjson", .{ directory, job }),
        };
    }
};

pub const Timer = struct {
    label: []const u8,
    start: std.Io.Clock.Timestamp,

    pub fn begin(c: src.Context, label: []const u8) Timer {
        return .{ .label = label, .start = .now(c.io, .awake) };
    }

    /// Seconds since `begin`.
    pub fn seconds(timer: Timer, c: src.Context) f64 {
        return @as(f64, @floatFromInt(timer.start.untilNow(c.io).raw.nanoseconds)) / std.time.ns_per_s;
    }

    /// Prints the phase and adds it to the log. A log that cannot be written
    /// loses only its line.
    pub fn end(timer: Timer, c: src.Context, log: Log) void {
        const elapsed = timer.seconds(c);
        c.report("preflight: phase {s}: {d:.1} s\n", .{ timer.label, elapsed });
        if (log.summary) |path| {
            const line = c.a.print("- phase `{s}`: {d:.1} s\n", .{ timer.label, elapsed }) catch return;
            append(c, path, line) catch return;
        }
        if (log.record) |path| {
            var line: std.Io.Writer.Allocating = .init(c.a);
            line.writer.writeAll("{\"phase\":") catch return;
            std.json.Stringify.value(timer.label, .{}, &line.writer) catch return;
            line.writer.print(",\"seconds\":{d:.2}}}\n", .{elapsed}) catch return;
            if (std.Io.Dir.path.dirname(path)) |parent| c.directory().createDirPath(c.io, parent) catch return;
            append(c, path, line.written()) catch return;
        }
    }
};

fn append(c: src.Context, path: []const u8, text: []const u8) !void {
    const file = try c.directory().createFile(c.io, path, .{ .truncate = false, .read = true });
    defer file.close(c.io);
    var buffer: [1024]u8 = undefined;
    var writer = file.writer(c.io, &buffer);
    writer.pos = (try file.stat(c.io)).size;
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

test "a phase is added to the summary and the record, after what the files hold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    try tmp.dir.writeFile(c.io, .{ .sub_path = "summary.md", .data = "kept\n" });
    const log: Log = .{ .summary = "summary.md", .record = "cache/phases-job.ndjson" };
    Timer.begin(c, "lint").end(c, log);
    Timer.begin(c, "compile \"x\"").end(c, log);
    const text = try c.read("summary.md");
    try std.testing.expect(std.mem.startsWith(u8, text, "kept\n- phase `lint`: "));
    try std.testing.expect(std.mem.find(u8, text, "\n- phase `compile \"x\"`: ") != null);
    const record = try c.read("cache/phases-job.ndjson");
    try std.testing.expect(std.mem.startsWith(u8, record, "{\"phase\":\"lint\",\"seconds\":"));
    try std.testing.expect(std.mem.find(u8, record, "\n{\"phase\":\"compile \\\"x\\\"\",\"seconds\":") != null);
}

test "a job without a name keeps no record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    try std.testing.expectEqual(@as(?[]const u8, null), (try Log.init(arena.allocator(), &env)).record);
    try env.put("PREFLIGHT_JOB", "cross-objects-0");
    try std.testing.expectEqualStrings(".zig-cache/preflight-timings/phases-cross-objects-0.ndjson", (try Log.init(arena.allocator(), &env)).record.?);
}
