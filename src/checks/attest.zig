//! A tag requires a commit that passed the release tier: `bay release` asks this before it tags.
const std = @import("std");
const src = @import("source.zig");

/// The tier whose successful run, with its proof artifact, stands for a commit a tag may name.
const proof_tiers = [_][]const u8{"release"};

/// Whether `artifact` is the release tier's proof for commit `sha`: `preflight-release-<sha>`.
fn proves(artifact: []const u8, sha: []const u8) bool {
    const rest = std.mem.cutPrefix(u8, artifact, "preflight-") orelse return false;
    const tier = std.mem.cutSuffix(u8, rest, sha) orelse return false;
    for (proof_tiers) |name| {
        if (tier.len == name.len + 1 and std.mem.startsWith(u8, tier, name) and tier[name.len] == '-') return true;
    }
    return false;
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
    for (proof_tiers) |tier| {
        const name = try c.a.print("preflight-{s}-{s}", .{ tier, sha });
        const found = try get(c, &client, token, try c.a.print("https://api.github.com/repos/{s}/actions/artifacts?name={s}&per_page=100", .{ repo, name }));
        for (try src.items(src.get(found, "artifacts"))) |artifact| {
            if (src.get(artifact, "expired") == .bool and src.get(artifact, "expired").bool) continue;
            const run_of = src.get(artifact, "workflow_run");
            const id = src.get(run_of, "id");
            if (id != .integer or (current != null and id.integer == current.?)) continue;
            if (!proves(try src.string(src.get(artifact, "name"), ""), sha)) continue;
            c.report("{s} passed for {s}: run {d}\n", .{ name, sha, id.integer });
            return;
        }
    }
    c.report("No successful release tier recorded for exact commit {s}; dispatch the release tier for this commit, and tag once it is green.\n", .{sha});
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

test "a tag requires the release tier's proof named for its exact commit" {
    try std.testing.expect(proves("preflight-release-0f1e", "0f1e"));
    try std.testing.expect(!proves("preflight-ci-0f1e", "0f1e"));
    try std.testing.expect(!proves("preflight-merge-0f1e", "0f1e"));
    try std.testing.expect(!proves("preflight-fast-0f1e", "0f1e"));
    try std.testing.expect(!proves("preflight-full-0f1e", "0f1e"));
    try std.testing.expect(!proves("preflight-release-0f1e", "other"));
    try std.testing.expect(!proves("preflight-release0f1e", "0f1e"));
    try std.testing.expect(!proves("timings-release-0f1e", "0f1e"));
}
