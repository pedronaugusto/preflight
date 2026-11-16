//! A bounded native fuzz campaign, judged. Under `--fuzz=<limit>` Zig 0.17's
//! build runner prints a failure the fuzzer finds and still exits 0, so the
//! campaign is judged on what the fuzzer leaves in the cache it ran on: an
//! input saved to `f/crash` during the run, and the runs its coverage files
//! (`v/<id>`, each headed by `std.Build.abi.fuzz.SeenPcsHeader`) count.
const std = @import("std");
const builtin = @import("builtin");
const aegis = @import("aegis");
const src = @import("source.zig");
const seam = @import("input.zig");
const budget = @import("budget.zig");

/// When a file was last written: an instant of the real clock, in nanoseconds as std keeps it.
const Saved = aegis.units.Instant(std.Io.Clock.real, .nanosecond, i96);

/// A hosted job's deadline, `PREFLIGHT_DEADLINE`: whole seconds of the real clock.
const Deadline = aegis.units.Instant(std.Io.Clock.real, .second, i64);

/// What the fuzzer has left in a cache.
pub const State = struct {
    /// The runs every coverage file counts, accumulated across campaigns.
    runs: u64 = 0,
    /// When the fuzzer last saved a crashing input.
    crash: ?std.Io.Timestamp = null,
};

pub const Verdict = enum { ran, crashed, idle };

pub fn state(io: std.Io, cache: std.Io.Dir) !State {
    var found: State = .{};
    if (cache.statFile(io, "f/crash", .{})) |stat| {
        found.crash = stat.mtime;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    var coverage = cache.openDir(io, "v", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return found,
        else => return err,
    };
    defer coverage.close(io);
    var entries = coverage.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .file) continue;
        // A file the fuzzer is still creating holds no header yet, and counts no runs.
        const header = try seam.header(std.Build.abi.fuzz.SeenPcsHeader, io, coverage, entry.name) orelse continue;
        found.runs += header.n_runs;
    }
    return found;
}

/// A crash saved during the campaign fails it, and so does a campaign that
/// ran no input: a fuzz test that never started is not a passing one.
pub fn judge(before: State, after: State) Verdict {
    if (after.crash) |saved| {
        const earlier = before.crash orelse return .crashed;
        if (!Saved.fromTimestamp(saved, .exact).eql(.fromTimestamp(earlier, .exact))) return .crashed;
    }
    return if (after.runs > before.runs) .ran else .idle;
}

/// Runs `argv`, a build of a step with `--fuzz=<limit>`, in `cwd` on the local
/// cache `cache`, and fails `c` unless the build passed, the fuzzer ran inputs
/// and saved no crash.
pub fn run(c: *src.Context, cache_path: []const u8, cwd: []const u8, argv: []const []const u8) !void {
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(c.io, cache_path, c.a);
    var cache = try std.Io.Dir.cwd().openDir(c.io, absolute, .{});
    defer cache.close(c.io);
    const before = try state(c.io, cache);
    // Where the test binaries claim their fuzz tests' names (the runner's
    // `FuzzNames`): a directory of this campaign's own.
    var id: [8]u8 = undefined;
    c.io.random(&id);
    var names_buffer: [64]u8 = undefined;
    const names = try std.mem.print(&names_buffer, "tmp/preflight-fuzz-names-{x}", .{&id});
    try cache.createDirPath(c.io, names);
    // A directory left in the cache's tmp holds only names: the campaign's verdict stands, and the
    // run says what it left.
    defer cache.deleteTree(c.io, names) catch |err| c.report("fuzz campaign: {s}/{s} is left in the cache ({s})\n", .{ absolute, names, @errorName(err) });
    var env = try (c.environ_map orelse return error.EnvironmentUnknown).clone(c.a);
    try env.put("PREFLIGHT_FUZZ_NAMES", try std.Io.Dir.path.join(c.a, &.{ absolute, names }));
    const build = try std.mem.concat(c.a, []const u8, &.{ argv, &.{ "--cache-dir", absolute } });
    // `--fuzz` counts runs, never time: a hosted job's campaign ends at the job's deadline
    // (`PREFLIGHT_DEADLINE`, the job's limit less its report), whatever its runs cost, and is
    // judged on what the fuzzer ran by then (warp's, chronicle's and strand's campaigns were
    // cancelled at their 20 minutes, 43783174223, 43783866546).
    const left = try untilDeadline(c, env.get("PREFLIGHT_DEADLINE"));
    var expired = false;
    if (left != null and builtin.target.os.tag != .windows) {
        if (left.?.compare(.literal("0s")) != .gt) return c.fail("fuzz campaign: the job's deadline (PREFLIGHT_DEADLINE) passed before the campaign began", .{});
        switch (try budget.bounded(c, .{ .argv = build, .cwd = .{ .path = cwd }, .environ_map = &env }, left.?)) {
            .passed => {},
            .failed => return c.fail("fuzz campaign: the build failed", .{}),
            .expired => expired = true,
        }
    } else {
        var child = try std.process.spawn(c.io, .{ .argv = build, .cwd = .{ .path = cwd }, .environ_map = &env });
        const term = try child.wait(c.io);
        if (term != .exited or term.exited != 0) return c.fail("fuzz campaign: the build failed", .{});
    }
    const after = try state(c.io, cache);
    switch (judge(before, after)) {
        .ran => if (expired) c.report("fuzz campaign: ended at the job's deadline after {d} runs with no crash saved: it passes on what it fuzzed\n", .{after.runs - before.runs}),
        .crashed => c.fail("fuzz campaign: the fuzzer found a failing input, saved to {s}/f/crash", .{absolute}),
        .idle => if (expired)
            c.fail("fuzz campaign: the job's deadline came before the fuzzer ran an input, its build having taken the job's time: raise test_job_timeout", .{})
        else
            c.fail("fuzz campaign: the fuzzer ran no input; a fuzz test that never starts fails as one that crashes", .{}),
    }
}

/// What is left until `deadline`, whole seconds since the epoch as `PREFLIGHT_DEADLINE` holds
/// them; null where it is unset (a campaign outside a hosted job runs to its count of runs), and
/// none left once it has passed.
fn untilDeadline(c: *src.Context, deadline: ?[]const u8) !?budget.Span {
    const text = deadline orelse return null;
    const seconds = std.fmt.parseInt(i64, text, 10) catch {
        c.fail("fuzz campaign: PREFLIGHT_DEADLINE is {s}, not whole seconds since the epoch", .{text});
        return error.CheckFailed;
    };
    const end = Deadline.fromRaw(seconds).convert(.nanosecond, i96, .exact);
    const now = try Saved.fromIoTimestamp(.now(c.io, .real), .exact);
    const left = now.saturatingDurationTo(end);
    if (left.compare(.fromRaw(0)) != .gt) return .fromRaw(0);
    return budget.Span.fromIoDuration(left.toIoDuration(), .down) catch .fromRaw(std.math.maxInt(u64));
}

test "a crash saved during the campaign fails it, one from before does not" {
    const old: std.Io.Timestamp = .{ .nanoseconds = 1 };
    const new: std.Io.Timestamp = .{ .nanoseconds = 2 };
    try std.testing.expectEqual(Verdict.crashed, judge(.{}, .{ .runs = 10, .crash = new }));
    try std.testing.expectEqual(Verdict.crashed, judge(.{ .crash = old }, .{ .runs = 10, .crash = new }));
    try std.testing.expectEqual(Verdict.ran, judge(.{ .runs = 4, .crash = old }, .{ .runs = 10, .crash = old }));
}

test "a campaign whose coverage counts no new run ran nothing" {
    try std.testing.expectEqual(Verdict.idle, judge(.{}, .{}));
    try std.testing.expectEqual(Verdict.idle, judge(.{ .runs = 3224 }, .{ .runs = 3224 }));
    try std.testing.expectEqual(Verdict.ran, judge(.{ .runs = 3224 }, .{ .runs = 6225 }));
}

test "the state is the coverage files' runs and the saved crash" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(State{}, try state(io, tmp.dir));
    try tmp.dir.createDirPath(io, "v");
    for ([_]usize{ 7, 35 }, [_][]const u8{ "v/1a", "v/2b" }) |runs, name| {
        const header: std.Build.abi.fuzz.SeenPcsHeader = .{ .n_runs = runs, .unique_runs = 1, .pcs_len = 1 };
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = std.mem.asBytes(&header) });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "v/partial", .data = "x" });
    try tmp.dir.createDirPath(io, "f");
    try tmp.dir.writeFile(io, .{ .sub_path = "f/crash", .data = "input" });
    const found = try state(io, tmp.dir);
    try std.testing.expectEqual(@as(u64, 42), found.runs);
    try std.testing.expect(found.crash != null);
}
