//! Main reports green for a commit that passed the merge or release tier.
const std = @import("std");
const src = @import("source.zig");

/// The tiers whose successful run, with its proof artifact, stands for a commit.
const proof_tiers = [_][]const u8{ "merge", "release" };

/// Whether `artifact` is a merge or release tier's proof for commit `sha`:
/// `preflight-merge-<sha>` or `preflight-release-<sha>`.
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
    const current = env.get("GITHUB_RUN_ID") orelse return error.MissingRun;
    var client: std.http.Client = .{ .allocator = c.a, .io = c.io };
    defer client.deinit();
    // The proof is named for the commit a tier tested, in whichever workflow file
    // the caller lives: one query per tier, by name.
    for (proof_tiers) |tier| {
        const name = try c.a.print("preflight-{s}-{s}", .{ tier, sha });
        const found = try get(c, &client, token, try c.a.print("https://api.github.com/repos/{s}/actions/artifacts?name={s}&per_page=100", .{ repo, name }));
        for (src.items(src.get(found, "artifacts"))) |artifact| {
            if (src.get(artifact, "expired") == .bool and src.get(artifact, "expired").bool) continue;
            const run_of = src.get(artifact, "workflow_run");
            const id = src.get(run_of, "id");
            if (id != .integer or id.integer == (std.fmt.parseInt(i64, current, 10) catch return error.MissingRun)) continue;
            if (!proves(src.string(src.get(artifact, "name"), ""), sha)) continue;
            c.report("{s} passed for {s}: run {d}\n", .{ name, sha, id.integer });
            return;
        }
    }
    c.report("No successful merge or release tier recorded for exact commit {s}; dispatch the merge tier for this commit.\n", .{sha});
    return error.NoSuccessfulMergeGate;
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

test "main requires a merge or release proof named for its exact commit" {
    // The PR's branch head differs from the exact tested merge commit.
    try std.testing.expect(proves("preflight-merge-merge", "merge"));
    try std.testing.expect(proves("preflight-release-0f1e", "0f1e"));
    try std.testing.expect(!proves("preflight-fast-0f1e", "0f1e"));
    try std.testing.expect(!proves("preflight-full-0f1e", "0f1e"));
    try std.testing.expect(!proves("preflight-merge-0f1e", "other"));
    try std.testing.expect(!proves("preflight-merge0f1e", "0f1e"));
    try std.testing.expect(!proves("timings-merge-0f1e", "0f1e"));
}
