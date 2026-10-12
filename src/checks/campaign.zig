//! A bounded native fuzz campaign, judged. Under `--fuzz=<limit>` Zig 0.17's
//! build runner prints a failure the fuzzer finds and still exits 0, so the
//! campaign is judged on what the fuzzer leaves in the cache it ran on: an
//! input saved to `f/crash` during the run, and the runs its coverage files
//! (`v/<id>`, each headed by `std.Build.abi.fuzz.SeenPcsHeader`) count.
const std = @import("std");
const src = @import("source.zig");

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
        var file = try coverage.openFile(io, entry.name, .{});
        defer file.close(io);
        var buffer: [@sizeOf(std.Build.abi.fuzz.SeenPcsHeader)]u8 = undefined;
        var reader = file.reader(io, &buffer);
        var header: std.Build.abi.fuzz.SeenPcsHeader = undefined;
        // A file the fuzzer is still creating holds no header yet, and counts no runs.
        reader.interface.readSliceAll(std.mem.asBytes(&header)) catch continue;
        found.runs += header.n_runs;
    }
    return found;
}

/// A crash saved during the campaign fails it, and so does a campaign that
/// ran no input: a fuzz test that never started is not a passing one.
pub fn judge(before: State, after: State) Verdict {
    if (after.crash) |saved| {
        const earlier = before.crash orelse return .crashed;
        if (saved.nanoseconds != earlier.nanoseconds) return .crashed;
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
    var child = try std.process.spawn(c.io, .{
        .argv = try std.mem.concat(c.a, []const u8, &.{ argv, &.{ "--cache-dir", absolute } }),
        .cwd = .{ .path = cwd },
        .environ_map = c.environ_map,
    });
    const term = try child.wait(c.io);
    if (term != .exited or term.exited != 0) return c.fail("fuzz campaign: the build failed", .{});
    switch (judge(before, try state(c.io, cache))) {
        .ran => {},
        .crashed => c.fail("fuzz campaign: the fuzzer found a failing input, saved to {s}/f/crash", .{absolute}),
        .idle => c.fail("fuzz campaign: the fuzzer ran no input; a fuzz test that never starts fails as one that crashes", .{}),
    }
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
