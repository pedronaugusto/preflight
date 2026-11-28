//! The keys `ci/preflight.json` and `ci/workflow.json` hold. Any other key is refused by name,
//! with the file and the nearest known key: a misplaced or misspelt setting would otherwise
//! change nothing, silently (`"hardened"` in ci/preflight.json, where only ci/workflow.json
//! reads it).
const std = @import("std");
const src = @import("source.zig");

/// The source checks' configuration, `ci/preflight.json`.
pub const preflight = [_][]const u8{
    "policy",              "sources",           "test_roots",     "test_dependencies",
    "test_support",        "glint",             "glint_paths",    "extra_checks",
    "docs",                "layout_exceptions", "function_limit", "function_limits",
    "function_exceptions", "shipped",           "fuzz",           "vendored",
    "binary",
};

/// The options of `ci/workflow.json`, and keys the planner adds to it as it reads it (from the
/// build, and the policy from the `ci/preflight.json` beside it).
pub const workflow = written ++ planned;

/// The options a package writes in `ci/workflow.json`.
const written = [_][]const u8{
    "jobs",              "targets",  "build_args",   "shards",
    "cross_jobs",        "hardened", "compile_step", "setup_step",
    "before_tests_step", "git",      "fuzz_minutes", "configurations",
};

/// Added as the planner reads the file, never written in it.
const planned = [_][]const u8{ "sdk_targets", "policy", "fuzzed" };

/// What replaced the job limits 0.20.0 removed.
const tier_limits = ": preflight 0.20.0 removed it (CHANGELOG): a job's limit is its tier's, 10 minutes in ci and 15 in release and nightly";

/// The options 0.20.0 removed from `ci/workflow.json`, each refused by name with what replaced
/// it.
const removed = [_]struct { []const u8, []const u8 }{
    .{ "test_job_timeout", tier_limits },
    .{ "windows_job_timeout", tier_limits },
    .{ "source_job_timeout", tier_limits },
    .{ "cross_job_timeout", tier_limits },
    .{ "riscv64_seconds", tier_limits },
    .{ "portable_hosts", ": preflight 0.20.0 removed it (CHANGELOG): each runner builds the tests it runs" },
    .{ "cross_seconds", ": preflight 0.20.0 removed it (CHANGELOG): the targets compile in one job, or in the `cross_jobs` asked for" },
};

pub const File = enum { preflight, workflow };

/// What to say of `key`, unknown to `file`: the file it belongs in, or the nearest key of
/// this one, or nothing.
pub fn hint(a: std.mem.Allocator, file: File, key: []const u8) ![]const u8 {
    if (file == .workflow) for (removed) |entry| if (std.mem.eql(u8, entry[0], key)) return entry[1];
    const other: []const []const u8 = switch (file) {
        .preflight => &workflow,
        .workflow => &preflight,
    };
    const other_name = switch (file) {
        .preflight => "ci/workflow.json",
        .workflow => "ci/preflight.json",
    };
    // `policy` is read into the workflow's configuration, written only in ci/preflight.json.
    for (other) |name| if (std.mem.eql(u8, name, key) and !(file == .preflight and std.mem.eql(u8, key, "policy"))) return a.print(": `{s}` belongs in {s}", .{ key, other_name });
    const own: []const []const u8 = switch (file) {
        .preflight => &preflight,
        .workflow => &workflow,
    };
    if (nearest(key, own)) |near| return a.print("; the nearest key is `{s}`", .{near});
    return "";
}

/// Refuses each key of the configuration at `path` (`file`'s) that the file does not hold,
/// by name. `config` is the file as written.
pub fn refuseUnknown(c: *src.Context, path: []const u8, config: src.Value, file: File) !void {
    if (config != .object) return;
    for (config.object.keys()) |key| {
        if (known(file, key)) continue;
        c.fail("{s}: `{s}` is not a key of this file{s}", .{ path, key, try hint(c.a, file, key) });
    }
}

fn known(file: File, key: []const u8) bool {
    const lists: []const []const []const u8 = switch (file) {
        .preflight => &.{&preflight},
        .workflow => &.{&workflow},
    };
    for (lists) |list| for (list) |name| if (std.mem.eql(u8, name, key)) return true;
    return false;
}

/// The key of `list` fewest single-character edits from `key`, when it is close enough to be
/// a misspelling (at most a third of the longer, and at least two edits allowed).
fn nearest(key: []const u8, list: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = std.math.maxInt(usize);
    for (list) |name| {
        const d = distance(key, name);
        if (d < best_distance) {
            best = name;
            best_distance = d;
        }
    }
    const longer = if (best) |name| @max(name.len, key.len) else return null;
    return if (best_distance <= @max(2, longer / 3)) best else null;
}

/// Levenshtein distance of two short keys; a key past 64 bytes is no misspelling of one.
fn distance(a: []const u8, b: []const u8) usize {
    if (a.len > 64 or b.len > 64) return std.math.maxInt(usize);
    var row: [65]usize = undefined;
    for (0..b.len + 1) |j| row[j] = j;
    for (a, 1..) |ca, i| {
        var diagonal = row[0];
        row[0] = i;
        for (b, 1..) |cb, j| {
            const above = row[j];
            row[j] = @min(@min(row[j] + 1, row[j - 1] + 1), diagonal + @intFromBool(ca != cb));
            diagonal = above;
        }
    }
    return row[b.len];
}

test "a key of the other file is told where it belongs; a misspelt one its nearest key; any other only that it is unknown" {
    const a = std.testing.allocator;
    const cases = [_]struct { file: File, key: []const u8, said: []const u8 }{
        .{ .file = .preflight, .key = "hardened", .said = ": `hardened` belongs in ci/workflow.json" },
        .{ .file = .workflow, .key = "test_roots", .said = ": `test_roots` belongs in ci/preflight.json" },
        .{ .file = .preflight, .key = "test_root", .said = "; the nearest key is `test_roots`" },
        .{ .file = .workflow, .key = "targetz", .said = "; the nearest key is `targets`" },
        .{ .file = .preflight, .key = "zzzzzzzz", .said = "" },
    };
    for (cases) |case| {
        const said = try hint(a, case.file, case.key);
        defer if (said.len != 0) a.free(said);
        try std.testing.expectEqualStrings(case.said, said);
    }
    for (preflight) |key| try std.testing.expect(known(.preflight, key));
    for (workflow) |key| try std.testing.expect(known(.workflow, key));
    try std.testing.expect(!known(.preflight, "hardened"));
    try std.testing.expectEqual(@as(usize, 3), distance("kitten", "sitting"));
    // A key 0.20.0 removed says what replaced it; the hint is the table's own text.
    try std.testing.expectEqualStrings(": preflight 0.20.0 removed it (CHANGELOG): the targets compile in one job, or in the `cross_jobs` asked for", try hint(a, .workflow, "cross_seconds"));
}
