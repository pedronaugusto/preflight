//! The run's last job (`runners`): the jobs GitHub never gave a runner, named. GitHub
//! cancels a job it queued and no runner took ("The job was not acquired by Runner of type
//! hosted even after multiple attempts"), and the job ends cancelled, with no runner and no
//! step; its gate result is then `cancelled`, which no later job reads as red, so a release
//! run could end with a platform's tests never run and nothing failing by name (hull's run
//! 43891655054, cairn's 43896073872, strand's 43877949215: macOS jobs queued 78 to 111
//! minutes). The job reads the run's jobs as the Actions API lists them (the token's
//! `actions: read`) and fails on each such job, with the minutes it was queued. Nothing is
//! retried: a run is dispatched again by a person, who sees why.
const std = @import("std");
const src = @import("source.zig");

/// A job GitHub cancelled before any runner took it.
pub const Unserved = struct {
    name: []const u8,
    /// From the job's creation to its cancellation, in whole minutes.
    minutes: i64,
    /// Whether its result is the run's: a job named non-blocking (Zig master's) is not.
    blocking: bool,
};

/// The jobs of `pages` (the Actions API's job listings of one run attempt, as
/// `gh api --paginate --slurp` writes them: an array of pages, each with its `jobs`)
/// that ended cancelled with no runner and no step.
pub fn unserved(a: std.mem.Allocator, pages: src.Value) ![]const Unserved {
    var found: std.ArrayList(Unserved) = .empty;
    for (try src.items(pages)) |page| for (try src.items(src.get(page, "jobs"))) |job| {
        if (!std.mem.eql(u8, try src.string(src.get(job, "conclusion"), ""), "cancelled")) continue;
        // A runner that took the job is named, and its id is never 0.
        if (try src.number(src.get(job, "runner_id"), 0) != 0) continue;
        if ((try src.items(src.get(job, "steps"))).len != 0) continue;
        const created = try seconds(try src.string(src.get(job, "created_at"), ""));
        const completed = try seconds(try src.string(src.get(job, "completed_at"), ""));
        const name = try src.string(src.get(job, "name"), "(unnamed)");
        try found.append(a, .{ .name = name, .minutes = @divFloor(completed - created, 60), .blocking = std.mem.find(u8, name, "non-blocking") == null });
    };
    return found.items;
}

/// `runners`: fails on each job of the listing at `path` that GitHub never gave a runner.
pub fn check(c: *src.Context, path: []const u8) !void {
    const listed = try unserved(c.a, try c.json(path));
    for (listed) |job| if (job.blocking) {
        c.fail("runners: {s}: queued {d} min and cancelled before any runner took it; its tests never ran. Dispatch the run again", .{ job.name, job.minutes });
    } else c.report("runners: {s}: queued {d} min and cancelled before any runner took it; it blocks nothing\n", .{ job.name, job.minutes });
    if (listed.len == 0) c.report("runners: every job of the run that was queued had a runner\n", .{});
}

/// Seconds since the epoch of a UTC timestamp as the API writes one, `2026-11-16T15:25:14Z`.
pub fn seconds(text: []const u8) error{InvalidTimestamp}!i64 {
    if (text.len != 20 or text[4] != '-' or text[7] != '-' or text[10] != 'T' or text[13] != ':' or text[16] != ':' or text[19] != 'Z') return error.InvalidTimestamp;
    const year = try field(text[0..4]);
    const month = try field(text[5..7]);
    const day = try field(text[8..10]);
    const hour = try field(text[11..13]);
    const minute = try field(text[14..16]);
    const second = try field(text[17..19]);
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60) return error.InvalidTimestamp;
    return days(year, month, day) * 86400 + hour * 3600 + minute * 60 + second;
}

fn field(digits: []const u8) error{InvalidTimestamp}!i64 {
    return std.fmt.parseInt(u16, digits, 10) catch error.InvalidTimestamp;
}

/// Days from 1970-01-01 to the civil date, proleptic Gregorian (Howard Hinnant's days_from_civil).
fn days(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (if (month > 2) month - 3 else month + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test "a timestamp the API writes reads as seconds since the epoch" {
    try std.testing.expectEqual(@as(i64, 0), try seconds("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 951782400), try seconds("2000-02-29T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, 1794842714), try seconds("2026-11-16T15:25:14Z"));
    for ([_][]const u8{ "", "2026-11-16 15:25:14Z", "2026-13-01T00:00:00Z", "2026-11-16T15:25:14+00:00", "2026-1x-16T15:25:14Z" }) |bad| {
        try std.testing.expectError(error.InvalidTimestamp, seconds(bad));
    }
}

test "the jobs GitHub never gave a runner are named with their minutes queued, and no other" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // hull's run 43891655054, attempt 1, as the API listed it, in two pages; a job a runner
    // took and then cancelled, a skipped job and a green one beside them.
    const listing =
        \\[{"total_count":6,"jobs":[
        \\ {"name":"gate / test (macos-latest, Debug)","conclusion":"cancelled","runner_id":0,"runner_name":"","steps":[],"created_at":"2026-11-16T15:25:14Z","completed_at":"2026-11-16T16:43:56Z"},
        \\ {"name":"gate / test (ubuntu-latest, Debug)","conclusion":"success","runner_id":1000123,"runner_name":"GitHub Actions 1000123","steps":[{"name":"Set up job"}],"created_at":"2026-11-16T15:25:14Z","completed_at":"2026-11-16T15:40:02Z"},
        \\ {"name":"gate / test (windows-latest, Debug)","conclusion":"cancelled","runner_id":1000456,"runner_name":"GitHub Actions 1000456","steps":[{"name":"Set up job"}],"created_at":"2026-11-16T15:25:14Z","completed_at":"2026-11-16T15:50:00Z"}
        \\]},{"total_count":6,"jobs":[
        \\ {"name":"gate / compile (macos-latest, ReleaseSmall)","conclusion":"cancelled","runner_id":null,"runner_name":null,"steps":[],"created_at":"2026-11-16T15:25:15Z","completed_at":"2026-11-16T16:45:37Z"},
        \\ {"name":"gate / Zig master (Linux Debug, non-blocking)","conclusion":"cancelled","runner_id":0,"runner_name":"","steps":[],"created_at":"2026-11-16T15:25:15Z","completed_at":"2026-11-16T15:31:15Z"},
        \\ {"name":"gate / execute","conclusion":"skipped","runner_id":0,"runner_name":"","steps":[],"created_at":"2026-11-16T16:45:38Z","completed_at":"2026-11-16T16:45:38Z"}
        \\]}]
    ;
    const pages = try std.json.parseFromSliceLeaky(src.Value, a, listing, .{});
    const found = try unserved(a, pages);
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqualStrings("gate / test (macos-latest, Debug)", found[0].name);
    try std.testing.expectEqual(@as(i64, 78), found[0].minutes);
    try std.testing.expectEqualStrings("gate / compile (macos-latest, ReleaseSmall)", found[1].name);
    try std.testing.expectEqual(@as(i64, 80), found[1].minutes);
    try std.testing.expect(found[0].blocking and found[1].blocking);
    try std.testing.expectEqualStrings("gate / Zig master (Linux Debug, non-blocking)", found[2].name);
    try std.testing.expectEqual(@as(i64, 6), found[2].minutes);
    try std.testing.expect(!found[2].blocking);
    try std.testing.expectEqual(@as(usize, 0), (try unserved(a, try std.json.parseFromSliceLeaky(src.Value, a, "[{\"jobs\":[]}]", .{}))).len);
}
