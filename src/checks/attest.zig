//! Main reports the successful full gate for its exact commit.
const std = @import("std");
const src = @import("source.zig");

fn successful(candidate: src.Value, sha: []const u8, current: []const u8) bool {
    return std.mem.eql(u8, src.string(src.get(candidate, "head_sha"), ""), sha) and
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
    const runs = try get(c, &client, token, try std.fmt.allocPrint(c.a, "{s}/workflows/ci.yml/runs?head_sha={s}&status=success&per_page=100", .{ prefix, sha }));
    const proof = try std.fmt.allocPrint(c.a, "preflight-full-{s}", .{sha});
    for (src.items(src.get(runs, "workflow_runs"))) |candidate| {
        if (!successful(candidate, sha, current)) continue;
        const artifacts = try get(c, &client, token, try std.fmt.allocPrint(c.a, "{s}/runs/{d}/artifacts?per_page=100", .{ prefix, src.get(candidate, "id").integer }));
        for (src.items(src.get(artifacts, "artifacts"))) |artifact| {
            if (!std.mem.eql(u8, src.string(src.get(artifact, "name"), ""), proof)) continue;
            std.debug.print("Full gate passed for {s}: {s}\n", .{ sha, src.string(src.get(candidate, "html_url"), "") });
            return;
        }
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
    try std.testing.expect(successful(value, "abc", "456"));
    try std.testing.expect(!successful(value, "def", "456"));
    try std.testing.expect(!successful(value, "abc", "123"));
}
