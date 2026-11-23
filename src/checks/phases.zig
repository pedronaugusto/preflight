//! Where a hosted job's time goes. The gate times each command it runs and
//! each source check, prints the phase as it ends and adds it to the job's
//! summary. The job keeps its phases in a record too, which the profile job
//! folds into `ci/costs.json`, and the next plan balances its jobs by.
const std = @import("std");
const aegis = @import("aegis");
const src = @import("source.zig");

/// A phase's length, in nanoseconds as std's clock keeps them: every std duration fits exactly.
const Elapsed = aegis.units.Duration(.nanosecond, i96);

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

/// The most memory a phase's tree held, and any one process of it, in bytes, and the jobs its
/// build ran at once (`-j`).
pub const Memory = struct { bytes: u64, single: u64, jobs: u32 };

/// The CPUs a build runs a job on each of by default, as Zig's `-j` does; one where unknown.
pub fn cpus() u32 {
    const count = std.Thread.getCpuCount() catch return 1;
    return std.math.cast(u32, count) orelse std.math.maxInt(u32);
}

pub const Timer = struct {
    label: []const u8,
    start: std.Io.Clock.Timestamp,

    pub fn begin(c: src.Context, label: []const u8) Timer {
        return .{ .label = label, .start = .now(c.io, .awake) };
    }

    /// Seconds since `begin`.
    pub fn seconds(timer: Timer, c: src.Context) f64 {
        return Elapsed.fromIoDuration(timer.start.untilNow(c.io).raw, .exact).toSeconds(f64);
    }

    /// Prints the phase and adds it to the log. A log that cannot be written
    /// loses only its line, and says so.
    pub fn end(timer: Timer, c: src.Context, log: Log) void {
        timer.endWith(c, log, null);
    }

    /// `end`, with the most memory the phase's tree held where it was measured.
    pub fn endWith(timer: Timer, c: src.Context, log: Log, memory: ?Memory) void {
        const elapsed = timer.seconds(c);
        if (memory) |m| {
            c.report("preflight: phase {s}: {d:.1} s, at most {d:.2} GiB, {d:.2} GiB in one process, at -j{d}\n", .{ timer.label, elapsed, gib(m.bytes), gib(m.single), m.jobs });
        } else c.report("preflight: phase {s}: {d:.1} s\n", .{ timer.label, elapsed });
        timer.logged(c, log, elapsed, memory) catch |err| c.report("preflight: phase {s}: not logged ({s})\n", .{ timer.label, @errorName(err) });
    }

    /// Adds the phase, `elapsed` seconds long, to the summary and the record `log` names.
    fn logged(timer: Timer, c: src.Context, log: Log, elapsed: f64, memory: ?Memory) !void {
        if (log.summary) |path| {
            const held = if (memory) |m| try c.a.print(", at most {d:.2} GiB, {d:.2} GiB in one process, at -j{d}", .{ gib(m.bytes), gib(m.single), m.jobs }) else "";
            try append(c, path, try c.a.print("- phase `{s}`: {d:.1} s{s}\n", .{ timer.label, elapsed, held }));
        }
        if (log.record) |path| {
            var line: std.Io.Writer.Allocating = .init(c.a);
            try line.writer.writeAll("{\"phase\":");
            try std.json.Stringify.value(timer.label, .{}, &line.writer);
            try line.writer.print(",\"seconds\":{d:.2}", .{elapsed});
            if (memory) |m| try line.writer.print(",\"peak_bytes\":{d},\"single_bytes\":{d},\"jobs\":{d}", .{ m.bytes, m.single, m.jobs });
            try line.writer.writeAll("}\n");
            if (std.Io.Dir.path.dirname(path)) |parent| try c.directory().createDirPath(c.io, parent);
            try append(c, path, line.written());
        }
    }
};

fn gib(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024 * 1024 * 1024);
}

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
    const c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = .of(tmp.dir) };
    try tmp.dir.writeFile(c.io, .{ .sub_path = "summary.md", .data = "kept\n" });
    const log: Log = .{ .summary = "summary.md", .record = "cache/phases-job.ndjson" };
    Timer.begin(c, "lint").end(c, log);
    Timer.begin(c, "compile \"x\"").end(c, log);
    Timer.begin(c, "compile x86_64-macos").endWith(c, log, .{ .bytes = 16_106_127_360, .single = 9_234_179_072, .jobs = 4 });
    const text = try c.read("summary.md");
    try std.testing.expect(std.mem.startsWith(u8, text, "kept\n- phase `lint`: "));
    try std.testing.expect(std.mem.find(u8, text, "\n- phase `compile \"x\"`: ") != null);
    const record = try c.read("cache/phases-job.ndjson");
    try std.testing.expect(std.mem.startsWith(u8, record, "{\"phase\":\"lint\",\"seconds\":"));
    try std.testing.expect(std.mem.find(u8, record, "\n{\"phase\":\"compile \\\"x\\\"\",\"seconds\":") != null);
    try std.testing.expect(std.mem.find(u8, record, "\"peak_bytes\":16106127360,\"single_bytes\":9234179072,\"jobs\":4}\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "at most 15.00 GiB, 8.60 GiB in one process, at -j4\n") != null);
}

test "a job without a name keeps no record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    try std.testing.expectEqual(@as(?[]const u8, null), (try Log.init(arena.allocator(), &env)).record);
    try env.put("PREFLIGHT_JOB", "cross-objects-0");
    try std.testing.expectEqualStrings(".zig-cache/preflight-timings/phases-cross-objects-0.ndjson", (try Log.init(arena.allocator(), &env)).record.?);
}
