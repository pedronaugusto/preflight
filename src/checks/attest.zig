//! Main reports the successful full gate for its exact commit.
const std = @import("std");
const src = @import("source.zig");

fn verified(candidate: src.Value, artifact: []const u8, proof: []const u8, current: []const u8) bool {
    return std.mem.eql(u8, artifact, proof) and
        std.mem.eql(u8, src.string(src.get(candidate, "conclusion"), ""), "success") and
        src.get(candidate, "id") == .integer and
        src.get(candidate, "id").integer != (std.fmt.parseInt(i64, current, 10) catch return false);
}

pub fn run(c: src.Context, env: *const std.process.Environ.Map) !void {
    const repo = env.get("GITHUB_REPOSITORY") orelse return error.MissingRepository;
    const sha = env.get("GITHUB_SHA") orelse return error.MissingCommit;
    const token = env.get("GITHUB_TOKEN") orelse return error.MissingToken;
    const current = env.get("GITHUB_RUN_ID") orelse return error.MissingRun;
    var client: std.http.Client = .{ .allocator = c.a, .io = c.io };
    defer client.deinit();
    const prefix = try std.fmt.allocPrint(c.a, "https://api.github.com/repos/{s}/actions", .{repo});
    const proof = try std.fmt.allocPrint(c.a, "preflight-full-{s}", .{sha});
    // PR metadata names the branch head; GITHUB_SHA and the proof name the
    // tested merge commit. Search the proof rather than filtering head_sha.
    var page: usize = 1;
    while (true) : (page += 1) {
        const runs = try get(c, &client, token, try std.fmt.allocPrint(c.a, "{s}/workflows/ci.yml/runs?status=success&per_page=100&page={d}", .{ prefix, page }));
        const candidates = src.items(src.get(runs, "workflow_runs"));
        for (candidates) |candidate| {
            if (!verified(candidate, proof, proof, current)) continue;
            const artifacts = try get(c, &client, token, try std.fmt.allocPrint(c.a, "{s}/runs/{d}/artifacts?per_page=100", .{ prefix, src.get(candidate, "id").integer }));
            for (src.items(src.get(artifacts, "artifacts"))) |artifact| {
                if (!verified(candidate, src.string(src.get(artifact, "name"), ""), proof, current)) continue;
                std.debug.print("Full gate passed for {s}: {s}\n", .{ sha, src.string(src.get(candidate, "html_url"), "") });
                return;
            }
        }
        if (candidates.len < 100) break;
    }
    std.debug.print("No successful full gate recorded for exact commit {s}; dispatch the full gate for this commit.\n", .{sha});
    return error.NoSuccessfulFullGate;
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

test "main requires a successful exact SHA and excludes itself" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const value = (try std.json.parseFromSlice(src.Value, arena.allocator(),
        \\{"id":123,"head_sha":"abc","conclusion":"success"}
    , .{})).value;
    // The PR's branch head differs from the exact tested merge commit.
    try std.testing.expect(verified(value, "preflight-full-merge", "preflight-full-merge", "456"));
    try std.testing.expect(!verified(value, "preflight-full-other", "preflight-full-merge", "456"));
    try std.testing.expect(!verified(value, "preflight-full-merge", "preflight-full-merge", "123"));
    var failed = value;
    try failed.object.put(arena.allocator(), "conclusion", .{ .string = "failure" });
    try std.testing.expect(!verified(failed, "preflight-full-merge", "preflight-full-merge", "456"));
}
