//! The fuzz job (`ci-fuzz`): the package's properties under the fuzzer for a budget of
//! minutes. Zig's `--fuzz` takes a count of runs, never a time, so the budget is spent in
//! shakedown-fuzz sessions one after another: the first small, each next asked for the runs
//! the last one's measured rate says fit what is left, until too little is left for another.
//! A run's cost is no constant (a package's properties differ, and so do their inputs), so the
//! pace is no guarantee: the deadline is. A session still running when the budget is spent is
//! ended there, its whole process group, and the job passes on what it fuzzed; the fuzzer has
//! written its corpus as it grew. A finding written before the end still fails it. The first finding ends it,
//! failed, with each finding's file printed: the test, the error, the tape the fuzzer found
//! and the shrunk one to add to the property's `.regressions`. The store keeps the
//! fuzzer's corpora (`<package>/cache/f`, and an input that crashed it, `f/crash`), which
//! the hosted job caches from run to run and keeps as an artifact with the findings.
const std = @import("std");
const builtin = @import("builtin");
const aegis = @import("aegis");
const src = @import("source.zig");
const matrix = @import("matrix.zig");

/// The runs the first session asks for: few, so that its build and a slow property's pace are
/// measured before any session is asked for many.
pub const first_limit: u64 = 1_000;
/// The fewest runs a session asks for.
const least_limit: u64 = 1_000;
/// The spans the budget is reckoned in.
pub const Span = aegis.units.Duration(.millisecond, u64);
/// How long a session is meant to take once the pace is known: long enough that its build
/// is a small part of it, short enough that the budget's end is met closely.
const session_goal: Span = .literal("5m");
/// What must be left of the budget for another session to start.
const least_left: Span = .literal("30s");
/// The shortest a session counts as having taken, so that a pace is never a division by zero.
const least_took: Span = .literal("1s");
/// How long a session asked to end at the deadline has before it is ended outright.
const ending_grace: Span = .literal("10s");
/// How often the watch on a session looks at the clock.
const watch_step: Span = .literal("200ms");

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

/// How a session ended: of itself, passing or failing, or at the deadline.
const Ended = enum { passed, failed, expired };

/// The watch on a session: at `until` it asks the session's process group to end, and ends it
/// outright `ending_grace` later, unless the session ended first (`done`).
const Watch = struct {
    io: std.Io,
    group: std.posix.pid_t,
    until: std.Io.Clock.Timestamp,
    /// Whether the session has ended of itself, which the session's thread says.
    session: aegis.Atomic(enum(u8) { running, ended }) = .init(.running),
    /// Whether the watch ended it, which the watch says.
    deadline: aegis.Atomic(enum(u8) { ahead, passed }) = .init(.ahead),

    fn run(w: *Watch) void {
        while (w.session.load(.acquire) != .ended) {
            if (std.Io.Clock.Timestamp.compare(.now(w.io, .awake), .gte, w.until)) {
                w.deadline.store(.passed, .release);
                end(w.group, .TERM);
                const grace: std.Io.Clock.Timestamp = .fromNow(w.io, .{ .raw = ending_grace.toIoDuration(), .clock = .awake });
                while (w.session.load(.acquire) != .ended) {
                    if (std.Io.Clock.Timestamp.compare(.now(w.io, .awake), .gte, grace)) return end(w.group, .KILL);
                    // A cancel ends this program: the group ends with it.
                    std.Io.sleep(w.io, watch_step.toIoDuration(), .awake) catch |err| switch (err) {
                        error.Canceled => return end(w.group, .KILL),
                    };
                }
                return;
            }
            // A cancel ends this program: the session's group ends with it.
            std.Io.sleep(w.io, watch_step.toIoDuration(), .awake) catch |err| switch (err) {
                error.Canceled => return end(w.group, .KILL),
            };
        }
    }

    /// Sends `signal` to every process of the group: the session, its build, the build's fuzzers.
    fn end(group: std.posix.pid_t, signal: std.posix.SIG) void {
        // glint-ignore: Z026 -- a group already gone has nothing left to end, and the session's own wait says how it ended
        std.posix.kill(-group, signal) catch {};
    }
};

/// Runs one session, `argv`, in a process group of its own, ended when `left` is spent.
fn session(c: *src.Context, argv: []const []const u8, left: Span) !Ended {
    if (builtin.target.os.tag == .windows) {
        // Zig's fuzzer runs on no Windows host (`hardened-fuzz` says so), and the job runs on Linux.
        c.fail("ci-fuzz: the fuzzer runs on Linux and macOS, not Windows", .{});
        return .failed;
    }
    var child = try std.process.spawn(c.io, .{ .argv = argv, .cwd = c.childCwd(), .environ_map = c.environ_map, .pgid = 0 });
    var watch: Watch = .{ .io = c.io, .group = child.id.?, .until = .fromNow(c.io, .{ .raw = left.toIoDuration(), .clock = .awake }) };
    const watcher = try std.Thread.spawn(.{}, Watch.run, .{&watch});
    const term = child.wait(c.io);
    watch.session.store(.ended, .release);
    watcher.join();
    const ended = try term;
    if (watch.deadline.load(.acquire) == .passed) return .expired;
    return if (ended == .exited and ended.exited == 0) .passed else .failed;
}

/// Runs `fuzzer` (shakedown-fuzz and the package, build and step it fuzzes) in sessions for
/// `budget` on the store `store`, and fails `c` on the first finding or on a session that
/// failed without one. A session the budget's end interrupts passes, unless it had written a
/// finding.
pub fn run(c: *src.Context, budget: Span, store: []const u8, fuzzer: []const []const u8) !void {
    if (budget.eql(.literal("0s"))) {
        c.report("ci-fuzz: fuzz_minutes is 0: nothing to fuzz\n", .{});
        return;
    }
    try std.Io.Dir.cwd().createDirPath(c.io, store);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(c.io, store, c.a);
    // Findings an earlier run left here are not this run's.
    try clearFindings(c, root);
    const whole = budget;
    const start: std.Io.Clock.Timestamp = .now(c.io, .awake);
    var limit = first_limit;
    var sessions: usize = 0;
    var asked: u64 = 0;
    while (true) {
        const began: std.Io.Clock.Timestamp = .now(c.io, .awake);
        const argv = try std.mem.concat(c.a, []const u8, &.{ fuzzer, &.{ "--store", root, "--sessions", "1", "--limit", try c.a.print("{d}", .{limit}) } });
        const ended = try session(c, argv, whole.saturatingSub(elapsed(c, start)));
        sessions += 1;
        asked += limit;
        if (ended == .expired) {
            // A finding written before the end is one all the same.
            const found = try printFindings(c, root);
            if (found != 0) {
                c.fail("ci-fuzz: {d} finding(s) in session {d}, which the budget's end interrupted; each file above is one, and its minimal tape is the regression to keep", .{ found, sessions });
                return;
            }
            c.report("ci-fuzz: {f} spent during session {d}, which was ended there; {d} session(s): no finding\n", .{ whole, sessions, sessions });
            return;
        }
        if (ended == .failed) {
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
    c.report("ci-fuzz: {f}, {d} session(s), {d} runs asked: no finding\n", .{ whole, sessions, asked });
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

/// A stand-in for shakedown-fuzz: a shell script that finds the store among its arguments, writes
/// a finding there when `finds`, and runs past any budget, in a process of its own (`sleep`) as a
/// session's build does.
fn standIn(a: std.mem.Allocator, dir: std.Io.Dir, finds: bool) ![]const []const u8 {
    const script =
        \\while [ $# -gt 0 ]; do if [ "$1" = --store ]; then store=$2; fi; shift; done
        \\
    ;
    const finding =
        \\mkdir -p "$store/pkg/findings"
        \\printf 'test: decode\nerror: Overflow\nfound: 0a0b\nminimal: 0a\n' > "$store/pkg/findings/decode.txt"
        \\
    ;
    try dir.writeFile(std.testing.io, .{ .sub_path = "fuzzer.sh", .data = try std.mem.concat(a, u8, &.{ script, if (finds) finding else "", "sleep 600\n" }) });
    return a.dupe([]const u8, &.{ "/bin/sh", try dir.realPathFileAlloc(std.testing.io, "fuzzer.sh", a) });
}

test "a session the budget's end interrupts is ended, its processes with it, and passes" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var held: std.Io.Writer.Allocating = .init(a);
    var c: src.Context = .{ .a = a, .io = std.testing.io, .held = &held };
    const began: std.Io.Clock.Timestamp = .now(c.io, .awake);
    try run(&c, .literal("1s"), try std.Io.Dir.path.join(a, &.{ try tmp.dir.realPathFileAlloc(c.io, ".", a), "store" }), try standIn(a, tmp.dir, false));
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    try std.testing.expect(std.mem.find(u8, held.written(), "spent during session 1, which was ended there") != null);
    // Ended at the deadline, not at the stand-in's ten minutes.
    try std.testing.expect(elapsed(&c, began).compare(.literal("30s")) == .lt);
}

test "a finding written before the budget's end fails the job, printed with its shrunk tape" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var held: std.Io.Writer.Allocating = .init(a);
    var c: src.Context = .{ .a = a, .io = std.testing.io, .held = &held };
    try run(&c, .literal("1s"), try std.Io.Dir.path.join(a, &.{ try tmp.dir.realPathFileAlloc(c.io, ".", a), "store" }), try standIn(a, tmp.dir, true));
    try std.testing.expectEqual(@as(usize, 1), c.errors);
    try std.testing.expect(std.mem.find(u8, held.written(), "minimal: 0a\nkeep it: add \"0a\"") != null);
    try std.testing.expect(std.mem.find(u8, held.written(), "which the budget's end interrupted") != null);
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
