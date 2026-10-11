//! A stand-in for the GitHub CLI, and for bay's `tidy`, that the landing's tests run in
//! place of both. `<FAKE_GH_STATE>/calls` records each call, one line of arguments.
//!
//! - `gh workflow run <file> --ref <branch> ...` starts a run of the branch's commit on
//!   origin, finished at once with `FAKE_GH_OUTCOME` (`success` or `failure`). A
//!   successful run does what the caller's land job does: it fast-forwards origin's main
//!   to the commit and tags it `v<.version>` when that tag does not exist.
//! - `gh run list --branch <branch>` and `gh run view <id>` answer from the runs started.
//! - `tidy` replaces `FAKE_BAY_FROM` with `FAKE_BAY_TO` in `build.zig.zon`, as a re-pin.
const std = @import("std");

const Job = struct { name: []const u8, conclusion: []const u8 };
const Run = struct { databaseId: i64, headBranch: []const u8, headSha: []const u8, url: []const u8, status: []const u8 = "completed", conclusion: []const u8, jobs: []const Job };

const Fake = struct {
    a: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    state: std.Io.Dir,

    fn git(f: Fake, args: []const []const u8) !std.process.RunResult {
        const argv = try std.mem.concat(f.a, []const u8, &.{ &.{"git"}, args });
        return std.process.run(f.a, f.io, .{ .argv = argv, .environ_map = f.env });
    }

    /// `git <args>`'s output, trimmed; a failure stops the fake.
    fn must(f: Fake, args: []const []const u8) ![]const u8 {
        const result = try f.git(args);
        if (result.term != .exited or result.term.exited != 0) {
            std.log.err("git {s}: {s}", .{ try std.mem.join(f.a, " ", args), result.stderr });
            return error.GitFailed;
        }
        return std.mem.trim(u8, result.stdout, " \r\n");
    }

    fn runs(f: Fake) ![]const Run {
        const text = f.state.readFileAlloc(f.io, "runs.json", f.a, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => return &.{},
            else => return err,
        };
        return std.json.parseFromSliceLeaky([]const Run, f.a, text, .{});
    }

    fn print(f: Fake, value: anytype) !void {
        var buffer: [4096]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(f.io, &buffer);
        try out.interface.print("{s}\n", .{try std.json.Stringify.valueAlloc(f.a, value, .{})});
        try out.interface.flush();
    }

    /// The caller's land job: main fast-forwards to `sha` and the version is tagged.
    fn land(f: Fake, sha: []const u8) !bool {
        const origin = try f.must(&.{ "remote", "get-url", "origin" });
        const ahead = try f.git(&.{ "-C", origin, "merge-base", "--is-ancestor", "refs/heads/main", sha });
        if (ahead.term != .exited or ahead.term.exited != 0) return false;
        _ = try f.must(&.{ "-C", origin, "update-ref", "refs/heads/main", sha });
        const manifest = try f.must(&.{ "-C", origin, "show", try f.a.print("{s}:build.zig.zon", .{sha}) });
        const key = ".version = \"";
        const at = (std.mem.find(u8, manifest, key) orelse return error.NoVersion) + key.len;
        const tag = try f.a.print("v{s}", .{manifest[at..std.mem.findScalarPos(u8, manifest, at, '"').?]});
        const exists = try f.git(&.{ "-C", origin, "rev-parse", "-q", "--verify", try f.a.print("refs/tags/{s}", .{tag}) });
        if (exists.term != .exited or exists.term.exited != 0) _ = try f.must(&.{ "-C", origin, "tag", tag, sha });
        return true;
    }

    fn dispatch(f: Fake, branch: []const u8) !void {
        const listed = try f.must(&.{ "ls-remote", "origin", try f.a.print("refs/heads/{s}", .{branch}) });
        const sha = listed[0 .. std.mem.findAny(u8, listed, " \t") orelse return error.NoSuchBranch];
        const earlier = try f.runs();
        const id: i64 = @intCast(earlier.len + 1); // a count of runs, far below i64's range
        const green = std.mem.eql(u8, f.env.get("FAKE_GH_OUTCOME") orelse "success", "success") and try f.land(sha);
        const jobs: []const Job = if (green) &.{ .{ .name = "Linux Debug", .conclusion = "success" }, .{ .name = "land", .conclusion = "success" } } else &.{ .{ .name = "source checks", .conclusion = "success" }, .{ .name = "Linux Debug", .conclusion = "failure" }, .{ .name = "land", .conclusion = "skipped" } };
        const run: Run = .{ .databaseId = id, .headBranch = branch, .headSha = sha, .url = try f.a.print("https://github.invalid/runs/{d}", .{id}), .conclusion = if (green) "success" else "failure", .jobs = jobs };
        const all = try std.mem.concat(f.a, Run, &.{ earlier, &.{run} });
        try f.state.writeFile(f.io, .{ .sub_path = "runs.json", .data = try std.json.Stringify.valueAlloc(f.a, all, .{}) });
    }

    fn tidy(f: Fake) !void {
        const from = f.env.get("FAKE_BAY_FROM") orelse return;
        const to = f.env.get("FAKE_BAY_TO") orelse return;
        const text = try std.Io.Dir.cwd().readFileAlloc(f.io, "build.zig.zon", f.a, .limited(1 << 20));
        try std.Io.Dir.cwd().writeFile(f.io, .{ .sub_path = "build.zig.zon", .data = try std.mem.replaceOwned(u8, f.a, text, from, to) });
    }
};

fn option(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |arg, i| if (std.mem.eql(u8, arg, name) and i + 1 < args.len) return args[i + 1];
    return null;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = (try init.minimal.args.toSlice(a))[1..];
    var state = try std.Io.Dir.cwd().createDirPathOpen(init.io, init.environ_map.get("FAKE_GH_STATE") orelse return error.NoState, .{});
    defer state.close(init.io);
    const f: Fake = .{ .a = a, .io = init.io, .env = init.environ_map, .state = state };
    const calls = state.readFileAlloc(init.io, "calls", a, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    try state.writeFile(init.io, .{ .sub_path = "calls", .data = try a.print("{s}{s}\n", .{ calls, try std.mem.join(a, " ", args) }) });
    if (args.len == 0) return error.NoCommand;
    if (std.mem.eql(u8, args[0], "tidy")) return f.tidy();
    if (args.len < 2) return error.NoCommand;
    if (std.mem.eql(u8, args[0], "workflow") and std.mem.eql(u8, args[1], "run")) return f.dispatch(option(args, "--ref") orelse return error.NoRef);
    if (std.mem.eql(u8, args[0], "run") and std.mem.eql(u8, args[1], "list")) {
        const branch = option(args, "--branch") orelse return error.NoBranch;
        var matching: std.ArrayList(Run) = .empty;
        for (try f.runs()) |run| if (std.mem.eql(u8, run.headBranch, branch)) try matching.append(a, run);
        return f.print(matching.items);
    }
    if (std.mem.eql(u8, args[0], "run") and std.mem.eql(u8, args[1], "view") and args.len > 2) {
        const id = try std.fmt.parseInt(i64, args[2], 10);
        for (try f.runs()) |run| if (run.databaseId == id) return f.print(run);
        return error.NoSuchRun;
    }
    return error.UnknownCommand;
}
