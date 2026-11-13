//! The fuzz job (`ci-fuzz`): the package's properties under the fuzzer for a budget of
//! minutes. Zig's `--fuzz` takes a count of runs, never a time, so the budget is spent in
//! shakedown-fuzz sessions one after another, each asked for the runs the last one's pace
//! says fit what is left, until too little is left for another. The first finding ends it,
//! failed, with each finding's file printed: the test, the error, the tape the fuzzer found
//! and the shrunk one to add to the property's `.regressions`. The store keeps the
//! fuzzer's corpora (`<package>/cache/f`, and an input that crashed it, `f/crash`), which
//! the hosted job caches from run to run and keeps as an artifact with the findings.
const std = @import("std");
const aegis = @import("aegis");
const src = @import("source.zig");
const matrix = @import("matrix.zig");

/// The runs the first session asks for: few enough that a slow property still ends its
/// session well inside any budget, and the build it begins with is measured with it.
pub const first_limit: u64 = 100_000;
/// The fewest runs a session asks for.
const least_limit: u64 = 10_000;
/// The spans the budget is reckoned in.
pub const Span = aegis.units.Duration(.millisecond, u64);
/// How long a session is meant to take once the pace is known: long enough that its build
/// is a small part of it, short enough that the budget's end is met closely.
const session_goal: Span = .literal("5m");
/// What must be left of the budget for another session to start.
const least_left: Span = .literal("30s");
/// The shortest a session counts as having taken, so that a pace is never a division by zero.
const least_took: Span = .literal("1s");

/// The minutes the job fuzzes for: `given` (`--minutes`), else `PREFLIGHT_FUZZ_MINUTES` (a
/// dispatched run's `fuzz-minutes`) when set and not empty, else `fuzz_minutes` in the
/// configuration, 15 by default.
pub fn minutes(c: *src.Context, given: ?u32, config: src.Value) !usize {
    if (given) |value| return checked(c, value);
    if (c.environ_map) |env| if (env.get("PREFLIGHT_FUZZ_MINUTES")) |text| if (std.mem.trim(u8, text, " ").len != 0) {
        const value = std.fmt.parseUnsigned(u32, std.mem.trim(u8, text, " "), 10) catch {
            c.fail("ci-fuzz: PREFLIGHT_FUZZ_MINUTES is {s}, not a whole number of minutes", .{text});
            return error.CheckFailed;
        };
        return checked(c, value);
    };
    return matrix.fuzzMinutes(config) catch {
        c.fail("ci-fuzz: ci/workflow.json: {s}", .{matrix.problem});
        return error.CheckFailed;
    };
}

fn checked(c: *src.Context, value: u32) !usize {
    if (value > matrix.max_fuzz_minutes) {
        c.fail("ci-fuzz: {d} minutes is more than a hosted job holds; at most {d}", .{ value, matrix.max_fuzz_minutes });
        return error.CheckFailed;
    }
    return value;
}

/// The runs the next session asks for: as many as `limit` took `took` to run, scaled to the
/// session's goal or what is `left`, whichever is less, and never more than eight times the
/// last, since a first session's pace counts its build.
pub fn nextLimit(limit: u64, took: Span, left: Span) u64 {
    const goal = if (left.compare(session_goal) == .lt) left else session_goal;
    const spent = if (took.compare(least_took) == .lt) least_took else took;
    // The goal as a multiple of the time the last session took: a pure number.
    const ratio = goal.toSeconds(f64) / spent.toSeconds(f64);
    const runs: f64 = @floatFromInt(limit);
    return @intFromFloat(std.math.clamp(runs * ratio, @as(f64, @floatFromInt(least_limit)), runs * 8));
}

/// The time since `since` on the awake clock, as a span; a span too long for one is the longest.
fn elapsed(c: *src.Context, since: std.Io.Clock.Timestamp) Span {
    return Span.fromIoDuration(since.untilNow(c.io).raw, .down) catch .fromRaw(std.math.maxInt(u64));
}

/// Runs `fuzzer` (shakedown-fuzz and the package, build and step it fuzzes) in sessions for
/// `budget` minutes on the store `store`, and fails `c` on the first finding or on a session
/// that failed without one.
pub fn run(c: *src.Context, budget: usize, store: []const u8, fuzzer: []const []const u8) !void {
    if (budget == 0) {
        c.report("ci-fuzz: fuzz_minutes is 0: nothing to fuzz\n", .{});
        return;
    }
    try std.Io.Dir.cwd().createDirPath(c.io, store);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(c.io, store, c.a);
    // Findings an earlier run left here are not this run's.
    try clearFindings(c, root);
    const whole = Span.literal("1m").saturatingMul(budget);
    const start: std.Io.Clock.Timestamp = .now(c.io, .awake);
    var limit = first_limit;
    var sessions: usize = 0;
    var asked: u64 = 0;
    while (true) {
        const began: std.Io.Clock.Timestamp = .now(c.io, .awake);
        const argv = try std.mem.concat(c.a, []const u8, &.{ fuzzer, &.{ "--store", root, "--sessions", "1", "--limit", try c.a.print("{d}", .{limit}) } });
        var child = try std.process.spawn(c.io, .{ .argv = argv, .cwd = c.childCwd(), .environ_map = c.environ_map });
        const term = try child.wait(c.io);
        sessions += 1;
        asked += limit;
        if (term != .exited or term.exited != 0) {
            const found = try printFindings(c, root);
            if (found != 0) {
                c.fail("ci-fuzz: {d} finding(s) in session {d}; each file above is one, and its minimal tape is the regression to keep", .{ found, sessions });
            } else if (try crashed(c, root)) |input| {
                // A failure no property reported, as a std.testing.fuzz test's or a crash's.
                c.fail("ci-fuzz: session {d} failed on an input the fuzzer kept at {s}", .{ sessions, input });
            } else c.fail("ci-fuzz: session {d} failed with no finding written and no input kept; the store is {s}", .{ sessions, root });
            return;
        }
        const took = elapsed(c, began);
        const left = whole.saturatingSub(elapsed(c, start));
        if (left.compare(least_left) == .lt) break;
        limit = nextLimit(limit, took, left);
    }
    c.report("ci-fuzz: {d} minute(s), {d} session(s), {d} runs asked: no finding\n", .{ budget, sessions, asked });
}

/// Deletes `<package>/findings` under the store `root`, for each package the store holds.
fn clearFindings(c: *src.Context, root: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(c.io, root, .{ .iterate = true });
    defer dir.close(c.io);
    var entries = dir.iterate();
    while (try entries.next(c.io)) |entry| {
        if (entry.kind != .directory) continue;
        try dir.deleteTree(c.io, try std.Io.Dir.path.join(c.a, &.{ entry.name, "findings" }));
    }
}

/// Prints each finding under the store `root`, and to the job's summary when there is one;
/// returns how many there are.
fn printFindings(c: *src.Context, root: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(c.io, root, .{ .iterate = true });
    defer dir.close(c.io);
    var count: usize = 0;
    var packages = dir.iterate();
    while (try packages.next(c.io)) |package| {
        if (package.kind != .directory) continue;
        const folder = try std.Io.Dir.path.join(c.a, &.{ package.name, "findings" });
        var found = dir.openDir(c.io, folder, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer found.close(c.io);
        var files = found.iterate();
        while (try files.next(c.io)) |file| {
            if (file.kind != .file) continue;
            const path = try std.Io.Dir.path.join(c.a, &.{ root, folder, file.name });
            const bytes = try aegis.own.readFile(c.io, std.Io.Dir.cwd(), path, c.a, .fromRaw(1024 * 1024));
            count += 1;
            // shakedown-fuzz wrote it, from what the package's tests printed: input until read.
            const finding = aegis.input.Untrusted([]const u8).init(bytes).parse({}, Finding.read) catch {
                c.report("ci-fuzz: finding {s}: not a finding shakedown-fuzz writes; the file is kept with the artifact\n", .{path});
                continue;
            };
            const text = try c.a.print("test: {s}\nerror: {s}\nfound: {s}\nminimal: {s}\n", .{ finding.test_name, finding.err, finding.found, finding.minimal });
            c.report("ci-fuzz: finding {s}:\n{s}keep it: add \"{s}\" to the property's `.regressions`\n", .{ path, text, finding.minimal });
            if (c.summary_path) |summary| try append(c.*, summary, try c.a.print("<details open><summary>fuzz finding: {s}</summary>\n\n```\n{s}```\n</details>\n", .{ file.name, text }));
        }
    }
    return count;
}

/// A finding as shakedown-fuzz writes it: the test, the error, the tape the fuzzer found and the
/// shrunk one, a line each and in that order.
pub const Finding = struct {
    test_name: []const u8,
    err: []const u8,
    found: []const u8,
    minimal: []const u8,

    pub fn read(_: void, text: []const u8) error{InvalidFinding}!Finding {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var values: [4][]const u8 = undefined;
        for (&values, [_][]const u8{ "test: ", "error: ", "found: ", "minimal: " }) |*value, label| {
            const line = lines.next() orelse return error.InvalidFinding;
            if (!std.mem.startsWith(u8, line, label)) return error.InvalidFinding;
            value.* = line[label.len..];
            for (value.*) |byte| if (byte < 32 or byte == 127) return error.InvalidFinding;
        }
        return .{ .test_name = values[0], .err = values[1], .found = values[2], .minimal = values[3] };
    }
};

/// The input the fuzzer last crashed on, `<package>/cache/f/crash` under the store `root`.
fn crashed(c: *src.Context, root: []const u8) !?[]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(c.io, root, .{ .iterate = true });
    defer dir.close(c.io);
    var entries = dir.iterate();
    while (try entries.next(c.io)) |entry| {
        if (entry.kind != .directory) continue;
        const input = try std.Io.Dir.path.join(c.a, &.{ entry.name, "cache", "f", "crash" });
        if (dir.access(c.io, input, .{})) |_| return try std.Io.Dir.path.join(c.a, &.{ root, input }) else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }
    return null;
}

fn append(c: src.Context, path: []const u8, text: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(c.io, path, .{ .truncate = false, .read = true });
    defer file.close(c.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(c.io, &buffer);
    writer.pos = (try file.stat(c.io)).size;
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

test "a session asks for the runs that fit its goal or what is left, at most eight times the last" {
    // A session of a minute paces the next to five.
    try std.testing.expectEqual(@as(u64, 500_000), nextLimit(100_000, .literal("1m"), .literal("14m")));
    // Never more than eight times the last, though the pace says more.
    try std.testing.expectEqual(@as(u64, 800_000), nextLimit(100_000, .literal("2s"), .literal("14m")));
    // Two minutes left make a session of two.
    try std.testing.expectEqual(@as(u64, 200_000), nextLimit(100_000, .literal("1m"), .literal("2m")));
    // A slow session asks for fewer, and never fewer than the least.
    try std.testing.expectEqual(@as(u64, 50_000), nextLimit(100_000, .literal("10m"), .literal("14m")));
    try std.testing.expectEqual(least_limit, nextLimit(100_000, .literal("1h"), .literal("31s")));
    // A session that took no measurable time counts as one second.
    try std.testing.expectEqual(@as(u64, 800_000), nextLimit(100_000, .literal("0s"), .literal("14m")));
}

test "the budget is the flag, else the dispatched minutes, else the configuration's, else 15" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(a);
    var c: src.Context = .{ .a = a, .io = std.testing.io, .environ_map = &env, .held = null };
    var held: std.Io.Writer.Allocating = .init(a);
    c.held = &held;
    const empty: src.Value = .{ .object = .empty };
    const five = (try std.json.parseFromSlice(src.Value, a, "{\"fuzz_minutes\":5}", .{})).value;
    try std.testing.expectEqual(@as(usize, 15), try minutes(&c, null, empty));
    try std.testing.expectEqual(@as(usize, 5), try minutes(&c, null, five));
    // A dispatch that leaves the minutes empty takes the configuration's.
    try env.put("PREFLIGHT_FUZZ_MINUTES", "");
    try std.testing.expectEqual(@as(usize, 5), try minutes(&c, null, five));
    try env.put("PREFLIGHT_FUZZ_MINUTES", "60");
    try std.testing.expectEqual(@as(usize, 60), try minutes(&c, null, five));
    try std.testing.expectEqual(@as(usize, 2), try minutes(&c, 2, five));
    try std.testing.expectError(error.CheckFailed, minutes(&c, 331, five));
    try env.put("PREFLIGHT_FUZZ_MINUTES", "an hour");
    try std.testing.expectError(error.CheckFailed, minutes(&c, null, five));
    const wrong = (try std.json.parseFromSlice(src.Value, a, "{\"fuzz_minutes\":400}", .{})).value;
    _ = env.swapRemove("PREFLIGHT_FUZZ_MINUTES");
    try std.testing.expectError(error.CheckFailed, minutes(&c, null, wrong));
}

test "a failed session prints every finding the store holds; a new run clears the old ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var held: std.Io.Writer.Allocating = .init(a);
    var c: src.Context = .{ .a = a, .io = std.testing.io, .held = &held };
    try tmp.dir.createDirPath(c.io, "store/uplink/findings");
    try tmp.dir.createDirPath(c.io, "store/uplink/cache/f");
    try tmp.dir.writeFile(c.io, .{ .sub_path = "store/uplink/findings/wire-frame.txt", .data = "test: wire frame\nerror: Overflow\nfound: 0a0b\nminimal: 0a\n" });
    try tmp.dir.writeFile(c.io, .{ .sub_path = "store/uplink/cache/f/corpus", .data = "kept" });
    const root = try tmp.dir.realPathFileAlloc(c.io, "store", a);
    try std.testing.expectEqual(@as(usize, 1), try printFindings(&c, root));
    try std.testing.expect(std.mem.find(u8, held.written(), "minimal: 0a\nkeep it: add \"0a\"") != null);
    // A file that is not one is counted, named and not printed.
    try tmp.dir.writeFile(c.io, .{ .sub_path = "store/uplink/findings/odd.txt", .data = "test: x\n\x1b[2Jerror: y\n" });
    try std.testing.expectEqual(@as(usize, 2), try printFindings(&c, root));
    try std.testing.expect(std.mem.find(u8, held.written(), "odd.txt: not a finding shakedown-fuzz writes") != null);
    try std.testing.expect(std.mem.find(u8, held.written(), "\x1b") == null);
    try clearFindings(&c, root);
    try std.testing.expectEqual(@as(usize, 0), try printFindings(&c, root));
    // The corpora stay.
    try std.testing.expectEqualStrings("kept", try tmp.dir.readFileAlloc(c.io, "store/uplink/cache/f/corpus", a, .limited(16)));
}
