//! Main reports green for a commit that passed the merge or release tier.
const std = @import("std");
const src = @import("source.zig");

/// The tiers whose successful run, with its proof artifact, stands for a commit.
const proof_tiers = [_][]const u8{ "merge", "release" };

/// A successful run other than this one.
fn passed(candidate: src.Value, current: []const u8) bool {
    return std.mem.eql(u8, src.string(src.get(candidate, "conclusion"), ""), "success") and
        src.get(candidate, "id") == .integer and
        src.get(candidate, "id").integer != (std.fmt.parseInt(i64, current, 10) catch return false);
}

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
    const prefix = try std.fmt.allocPrint(c.a, "https://api.github.com/repos/{s}/actions", .{repo});
    // PR metadata names the branch head; GITHUB_SHA and the proof name the
    // tested merge commit. Search the proof rather than filtering head_sha.
    var page: usize = 1;
    while (true) : (page += 1) {
        const runs = try get(c, &client, token, try std.fmt.allocPrint(c.a, "{s}/workflows/ci.yml/runs?status=success&per_page=100&page={d}", .{ prefix, page }));
        const candidates = src.items(src.get(runs, "workflow_runs"));
        for (candidates) |candidate| {
            if (!passed(candidate, current)) continue;
            const artifacts = try get(c, &client, token, try std.fmt.allocPrint(c.a, "{s}/runs/{d}/artifacts?per_page=100", .{ prefix, src.get(candidate, "id").integer }));
            for (src.items(src.get(artifacts, "artifacts"))) |artifact| {
                const name = src.string(src.get(artifact, "name"), "");
                if (!proves(name, sha)) continue;
                c.report("{s} passed for {s}: {s}\n", .{ name, sha, src.string(src.get(candidate, "html_url"), "") });
                return;
            }
        }
        if (candidates.len < 100) break;
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
        .privileged_headers = &.{.{ .name = "Authorization", .value = try std.fmt.allocPrint(c.a, "Bearer {s}", .{token}) }},
    });
    if (result.status != .ok) return error.GithubRequestFailed;
    return (try std.json.parseFromSlice(src.Value, c.a, output.written(), .{ .allocate = .alloc_always })).value;
}

test "main requires a merge or release proof of its exact commit from another successful run" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const value = (try std.json.parseFromSlice(src.Value, arena.allocator(),
        \\{"id":123,"head_sha":"abc","conclusion":"success"}
    , .{})).value;
    try std.testing.expect(passed(value, "456"));
    try std.testing.expect(!passed(value, "123"));
    var failed = value;
    try failed.object.put(arena.allocator(), "conclusion", .{ .string = "failure" });
    try std.testing.expect(!passed(failed, "456"));
    // The PR's branch head differs from the exact tested merge commit.
    try std.testing.expect(proves("preflight-merge-merge", "merge"));
    try std.testing.expect(proves("preflight-release-0f1e", "0f1e"));
    try std.testing.expect(!proves("preflight-fast-0f1e", "0f1e"));
    try std.testing.expect(!proves("preflight-full-0f1e", "0f1e"));
    try std.testing.expect(!proves("preflight-merge-0f1e", "other"));
    try std.testing.expect(!proves("preflight-merge0f1e", "0f1e"));
    try std.testing.expect(!proves("timings-merge-0f1e", "0f1e"));
}
