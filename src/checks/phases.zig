//! Where a hosted job's time goes. The gate times each command it runs and
//! each source check, prints the phase as it ends and adds it to the job's
//! summary.
const std = @import("std");
const aegis = @import("aegis");
const src = @import("source.zig");

/// A phase's length, in nanoseconds as std's clock keeps them: every std duration fits exactly.
const Elapsed = aegis.units.Duration(.nanosecond, i96);

/// Where a phase is reported once it ends.
pub const Log = struct {
    /// The job's step summary.
    summary: ?[]const u8 = null,

    /// The summary the runner gives the job; a run outside a hosted job has none.
    pub fn init(env: *const std.process.Environ.Map) Log {
        return .{ .summary = env.get("GITHUB_STEP_SUMMARY") };
    }
};

/// The most memory a phase's tree held, and any one process of it, in bytes, and the jobs its
/// build ran at once (`-j`). The tree's is never less than the one process's.
pub const Memory = struct {
    bytes: u64,
    single: u64,
    jobs: u32,

    /// A phase's memory from its bound's reading (`bounded.zig`). Linux's tree is the most a
    /// sample saw of the group's resident sum, its one process the kernel's own high-water mark
    /// (`VmHWM`), which a compile peaking between samples leaves above any sample of the sum;
    /// the tree held that process, so it held at least as much.
    pub fn sampled(tree: u64, single: u64, jobs: u32) Memory {
        return .{ .bytes = @max(tree, single), .single = single, .jobs = jobs };
    }
};

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
            c.report("preflight: phase {s}: {f}, at most {f}, {f} in one process, at -j{d}\n", .{ timer.label, shown(elapsed), mebibytes(m.bytes), mebibytes(m.single), m.jobs });
        } else c.report("preflight: phase {s}: {f}\n", .{ timer.label, shown(elapsed) });
        timer.logged(c, log, elapsed, memory) catch |err| c.report("preflight: phase {s}: not logged ({s})\n", .{ timer.label, @errorName(err) });
    }

    /// Adds the phase, `elapsed` seconds long, to the summary `log` names.
    fn logged(timer: Timer, c: src.Context, log: Log, elapsed: f64, memory: ?Memory) !void {
        if (log.summary) |path| {
            const held = if (memory) |m| try c.a.print(", at most {f}, {f} in one process, at -j{d}", .{ mebibytes(m.bytes), mebibytes(m.single), m.jobs }) else "";
            try append(c, path, try c.a.print("- phase `{s}`: {f}{s}\n", .{ timer.label, shown(elapsed), held }));
        }
    }
};

/// A phase's length as it prints: to the millisecond.
fn shown(seconds: f64) aegis.units.Duration(.millisecond, i64) {
    return .fromRaw(std.math.lossyCast(i64, @round(seconds * 1000)));
}

/// Memory as it prints: whole mebibytes, rounded down.
fn mebibytes(bytes: u64) aegis.units.Bytes(u64) {
    return .fromRaw((bytes >> 20) << 20);
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

test "a phase is added to the summary, after what it holds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = .of(tmp.dir) };
    try tmp.dir.writeFile(c.io, .{ .sub_path = "summary.md", .data = "kept\n" });
    const log: Log = .{ .summary = "summary.md" };
    Timer.begin(c, "lint").end(c, log);
    Timer.begin(c, "compile \"x\"").end(c, log);
    Timer.begin(c, "compile x86_64-macos").endWith(c, log, .{ .bytes = 16_106_127_360, .single = 9_234_179_072, .jobs = 4 });
    const text = try c.read("summary.md");
    try std.testing.expect(std.mem.startsWith(u8, text, "kept\n- phase `lint`: "));
    try std.testing.expect(std.mem.find(u8, text, "\n- phase `compile \"x\"`: ") != null);
    try std.testing.expect(std.mem.find(u8, text, "at most 15GiB, 8806MiB in one process, at -j4\n") != null);
}

test "a peak one process held between the tree's samples is the tree's too" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = .of(tmp.dir) };
    const log: Log = .{ .summary = "summary.md" };
    // Linux: the samples saw 1 GiB resident across the group, the kernel 3 GiB in one process.
    const memory: Memory = .sampled(1 << 30, 3 << 30, 2);
    try std.testing.expectEqual(@as(u64, 3 << 30), memory.bytes);
    Timer.begin(c, "compile x86_64-linux").endWith(c, log, memory);
    try std.testing.expect(std.mem.find(u8, try c.read("summary.md"), "at most 3GiB, 3GiB in one process, at -j2\n") != null);
}

test "the log is the hosted job's summary, and none outside one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = std.process.Environ.Map.init(arena.allocator());
    try std.testing.expectEqual(@as(?[]const u8, null), Log.init(&env).summary);
    try env.put("GITHUB_STEP_SUMMARY", "/s");
    try std.testing.expectEqualStrings("/s", Log.init(&env).summary.?);
}
