//! A tag requires a commit that passed the release and the nightly tiers: `bay release` asks this
//! before it tags.
const std = @import("std");
const src = @import("source.zig");

/// The tiers whose successful runs, each with its proof artifact, stand together for a commit a
/// tag may name: the release tier and the heavy legs.
const proof_tiers = [_][]const u8{ "release", "nightly" };

/// Whether `artifact` is `tier`'s proof for commit `sha`: `preflight-<tier>-<sha>`.
fn proves(artifact: []const u8, tier: []const u8, sha: []const u8) bool {
    const rest = std.mem.cutPrefix(u8, artifact, "preflight-") orelse return false;
    const named = std.mem.cutSuffix(u8, rest, sha) orelse return false;
    return named.len == tier.len + 1 and std.mem.startsWith(u8, named, tier) and named[tier.len] == '-';
}

pub fn run(c: src.Context, env: *const std.process.Environ.Map) !void {
    const repo = env.get("GITHUB_REPOSITORY") orelse return error.MissingRepository;
    const sha = env.get("GITHUB_SHA") orelse return error.MissingCommit;
    const token = env.get("GITHUB_TOKEN") orelse return error.MissingToken;
    // Inside a run, that run's own artifact is no proof; at a tag there is no run.
    const current: ?i64 = if (env.get("GITHUB_RUN_ID")) |id| std.fmt.parseInt(i64, id, 10) catch return error.MissingRun else null;
    var client: std.http.Client = .{ .allocator = c.a, .io = c.io };
    defer client.deinit();
    // The proof is named for the commit a tier tested, in whichever workflow file
    // the caller lives: one query per tier, by name.
    var missing: std.ArrayList([]const u8) = .empty;
    for (proof_tiers) |tier| {
        const name = try c.a.print("preflight-{s}-{s}", .{ tier, sha });
        const found = try get(c, &client, token, try c.a.print("https://api.github.com/repos/{s}/actions/artifacts?name={s}&per_page=100", .{ repo, name }));
        const passed = for (try src.items(src.get(found, "artifacts"))) |artifact| {
            if (src.get(artifact, "expired") == .bool and src.get(artifact, "expired").bool) continue;
            const run_of = src.get(artifact, "workflow_run");
            const id = src.get(run_of, "id");
            if (id != .integer or (current != null and id.integer == current.?)) continue;
            if (!proves(try src.string(src.get(artifact, "name"), ""), tier, sha)) continue;
            c.report("{s} passed for {s}: run {d}\n", .{ name, sha, id.integer });
            break true;
        } else false;
        if (!passed) try missing.append(c.a, tier);
    }
    if (missing.items.len == 0) return;
    c.report("No successful {s} run recorded for exact commit {s}; dispatch it for this commit, and tag once the release and nightly runs are green.\n", .{ try std.mem.join(c.a, " or ", missing.items), sha });
    return error.NoSuccessfulReleaseRun;
}

fn get(c: src.Context, client: *std.http.Client, token: []const u8, url: []const u8) !src.Value {
    var output: std.Io.Writer.Allocating = .init(c.a);
    defer output.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &output.writer,
        .extra_headers = &.{ .{ .name = "Accept", .value = "application/vnd.github+json" }, .{ .name = "User-Agent", .value = "preflight" } },
        .privileged_headers = &.{.{ .name = "Authorization", .value = try c.a.print("Bearer {s}", .{token}) }},
    });
    if (result.status != .ok) return error.GithubRequestFailed;
    return (try std.json.parseFromSlice(src.Value, c.a, output.written(), .{ .allocate = .alloc_always })).value;
}

test "a tag requires the release and nightly tiers' proofs, each named for its exact commit" {
    try std.testing.expect(proves("preflight-release-0f1e", "release", "0f1e"));
    try std.testing.expect(proves("preflight-nightly-0f1e", "nightly", "0f1e"));
    try std.testing.expect(!proves("preflight-nightly-0f1e", "release", "0f1e"));
    try std.testing.expect(!proves("preflight-ci-0f1e", "release", "0f1e"));
    try std.testing.expect(!proves("preflight-full-0f1e", "release", "0f1e"));
    try std.testing.expect(!proves("preflight-release-0f1e", "release", "other"));
    try std.testing.expect(!proves("preflight-release0f1e", "release", "0f1e"));
    try std.testing.expect(!proves("records-release-0f1e", "release", "0f1e"));
}
