//! A stand-in for the GitHub CLI, and for bay's `tidy` and `locate`, that the landing's tests
//! run in place of both. `<FAKE_GH_STATE>/calls` records each call, one line of arguments.
//!
//! The repository is `FAKE_GH_REPO` (`owner/name`), a bare repository at `FAKE_GH_ORIGIN`
//! standing in for it; a gh call that does not name it with `--repo` fails, as gh does in a
//! directory whose remote it does not know.
//!
//! - `gh workflow run <file> --ref <branch> ...` starts a run of `<file>` on the branch's commit
//!   on origin, a `workflow_dispatch`, and prints its URL as gh 2.100 does, which ends in `FAKE_GH_OUTCOME` (`success` or `failure`)
//!   after `FAKE_GH_POLLS` looks at it (none by default). A run that ends green does what the
//!   caller's land job does: it fast-forwards origin's default branch to the commit and tags it
//!   `v<.version>` when that tag does not exist. Each dispatch adds a line to
//!   `<FAKE_GH_STATE>/land-refs`: the `land/` branches origin holds then.
//! - `gh run list` answers from the runs started, those of `--branch`, `--workflow` and
//!   `--event` when given; `gh run view <id>` with one of them.
//! - `<FAKE_GH_STATE>/flaky-view` holds how many of the next `run view` calls fail as a dropped
//!   connection does, and `flaky-list` how many of the next `run list` calls of a branch with a
//!   run.
//! - `FAKE_GH_MEANWHILE`, on the first look at a run in progress: `commit` commits on the branch
//!   checked out where gh runs, `edit` changes CHANGELOG.md, which a release changes, there
//!   without committing it.
//! - `FAKE_GH_AFTER_LAND`, once the land job moved the default branch: `advance` lands another
//!   commit on it, `unreachable` moves origin away to `<FAKE_GH_ORIGIN>.away`.
//! - `locate --dev` names `FAKE_BAY_ROOT`, or, without it, fails as a bay from before
//!   `locate` does.
//! - `tidy` replaces each of `FAKE_BAY_FROM` with the one of `FAKE_BAY_TO` in the same place
//!   (both separated by spaces) in `build.zig.zon`, as re-pins.
const std = @import("std");

const Job = struct { name: []const u8, conclusion: []const u8 };
const Run = struct {
    databaseId: i64,
    workflowName: []const u8,
    event: []const u8,
    headBranch: []const u8,
    headSha: []const u8,
    url: []const u8,
    status: []const u8,
    conclusion: []const u8,
    jobs: []const Job,
    /// Looks left before it ends, and how it ends.
    polls: u64,
    outcome: []const u8,
};

const Fake = struct {
    a: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    state: std.Io.Dir,
    origin: []const u8,

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

    fn read(f: Fake, name: []const u8) !?[]const u8 {
        return f.state.readFileAlloc(f.io, name, f.a, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    fn runs(f: Fake) ![]Run {
        const text = try f.read("runs.json") orelse return &.{};
        return std.json.parseFromSliceLeaky([]Run, f.a, text, .{});
    }

    fn save(f: Fake, all: []const Run) !void {
        try f.state.writeFile(f.io, .{ .sub_path = "runs.json", .data = try std.json.Stringify.valueAlloc(f.a, all, .{}) });
    }

    fn print(f: Fake, value: anytype) !void {
        var buffer: [4096]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(f.io, &buffer);
        try out.interface.print("{s}\n", .{try std.json.Stringify.valueAlloc(f.a, value, .{})});
        try out.interface.flush();
    }

    /// Fails as gh does when it cannot reach GitHub, while the count in `file` says so.
    fn flaky(f: Fake, file: []const u8) !void {
        const left = std.fmt.parseInt(u64, std.mem.trim(u8, try f.read(file) orelse return, " \r\n"), 10) catch return;
        if (left == 0) return;
        try f.state.writeFile(f.io, .{ .sub_path = file, .data = try f.a.print("{d}\n", .{left - 1}) });
        fail(f.io, "error connecting to api.github.com");
    }

    /// The caller's land job: the default branch fast-forwards to `sha` and the version is tagged.
    fn land(f: Fake, sha: []const u8) !bool {
        const default = try f.must(&.{ "-C", f.origin, "symbolic-ref", "HEAD" });
        const ahead = try f.git(&.{ "-C", f.origin, "merge-base", "--is-ancestor", default, sha });
        if (ahead.term != .exited or ahead.term.exited != 0) return false;
        _ = try f.must(&.{ "-C", f.origin, "update-ref", default, sha });
        const manifest = try f.must(&.{ "-C", f.origin, "show", try f.a.print("{s}:build.zig.zon", .{sha}) });
        const key = ".version = \"";
        const at = (std.mem.find(u8, manifest, key) orelse return error.NoVersion) + key.len;
        const tag = try f.a.print("v{s}", .{manifest[at..std.mem.findScalarPos(u8, manifest, at, '"').?]});
        const exists = try f.git(&.{ "-C", f.origin, "rev-parse", "-q", "--verify", try f.a.print("refs/tags/{s}", .{tag}) });
        if (exists.term != .exited or exists.term.exited != 0) _ = try f.must(&.{ "-C", f.origin, "tag", tag, sha });
        try f.afterLand(default);
        return true;
    }

    fn afterLand(f: Fake, default: []const u8) !void {
        const what = f.env.get("FAKE_GH_AFTER_LAND") orelse return;
        if (std.mem.eql(u8, what, "advance")) {
            const tree = try f.must(&.{ "-C", f.origin, "rev-parse", try f.a.print("{s}^{{tree}}", .{default}) });
            const next = try f.must(&.{ "-C", f.origin, "-c", "user.name=Other", "-c", "user.email=other@example.invalid", "commit-tree", tree, "-p", default, "-m", "Another landing" });
            _ = try f.must(&.{ "-C", f.origin, "update-ref", default, next });
        } else if (std.mem.eql(u8, what, "unreachable")) {
            try std.Io.Dir.renameAbsolute(f.origin, try f.a.print("{s}.away", .{f.origin}), f.io);
        } else return error.UnknownAfterLand;
    }

    /// What the user does in the checkout while the run runs.
    fn meanwhile(f: Fake) !void {
        const what = f.env.get("FAKE_GH_MEANWHILE") orelse return;
        if (std.mem.eql(u8, what, "commit")) {
            _ = try f.must(&.{ "commit", "-q", "--allow-empty", "-m", "Meanwhile" });
        } else if (std.mem.eql(u8, what, "edit")) {
            const changelog = try std.Io.Dir.cwd().readFileAlloc(f.io, "CHANGELOG.md", f.a, .limited(1 << 20));
            try std.Io.Dir.cwd().writeFile(f.io, .{ .sub_path = "CHANGELOG.md", .data = try f.a.print("{s}\nAn edit.\n", .{changelog}) });
        } else return error.UnknownMeanwhile;
    }

    /// Adds the `land/` branches origin holds to `land-refs`, one line per dispatch.
    fn landRefs(f: Fake) !void {
        var names: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.tokenizeScalar(u8, try f.must(&.{ "-C", f.origin, "for-each-ref", "--format=%(refname:short)", "refs/heads/land" }), '\n');
        while (lines.next()) |line| try names.append(f.a, line);
        const before = try f.read("land-refs") orelse "";
        try f.state.writeFile(f.io, .{ .sub_path = "land-refs", .data = try f.a.print("{s}{s}\n", .{ before, try std.mem.join(f.a, " ", names.items) }) });
    }

    fn dispatch(f: Fake, file: []const u8, branch: []const u8) !void {
        const sha = try f.must(&.{ "-C", f.origin, "rev-parse", "--verify", try f.a.print("refs/heads/{s}", .{branch}) });
        try f.landRefs();
        const earlier = try f.runs();
        const id: i64 = @intCast(earlier.len + 1); // safe: one more than the runs one test starts, far below i64's range
        const polls = std.fmt.parseInt(u64, f.env.get("FAKE_GH_POLLS") orelse "0", 10) catch return error.BadPolls;
        var run: Run = .{ .databaseId = id, .workflowName = file, .event = "workflow_dispatch", .headBranch = branch, .headSha = sha, .url = try f.a.print("https://github.invalid/runs/{d}", .{id}), .status = "queued", .conclusion = "", .jobs = &.{}, .polls = polls, .outcome = f.env.get("FAKE_GH_OUTCOME") orelse "success" };
        if (polls == 0) try f.end(&run);
        try f.save(try std.mem.concat(f.a, Run, &.{ earlier, &.{run} }));
        // gh 2.100 answers a dispatch with the run's URL, no JSON.
        var buffer: [256]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(f.io, &buffer);
        try out.interface.print("{s}\n", .{run.url});
        try out.interface.flush();
    }

    /// The run's jobs end: green lands, as the caller's land job does.
    fn end(f: Fake, run: *Run) !void {
        const green = std.mem.eql(u8, run.outcome, "success") and try f.land(run.headSha);
        run.status = "completed";
        run.conclusion = if (green) "success" else "failure";
        run.jobs = if (green) &.{ .{ .name = "Linux Debug", .conclusion = "success" }, .{ .name = "land", .conclusion = "success" } } else &.{ .{ .name = "source checks", .conclusion = "success" }, .{ .name = "Linux Debug", .conclusion = "failure" }, .{ .name = "land", .conclusion = "skipped" } };
    }

    fn view(f: Fake, id: i64) !void {
        try f.flaky("flaky-view");
        const all = try f.runs();
        for (all) |*run| {
            if (run.databaseId != id) continue;
            if (!std.mem.eql(u8, run.status, "completed")) {
                if (run.polls == 0) try f.end(run) else {
                    if (std.mem.eql(u8, run.status, "queued")) try f.meanwhile();
                    run.status = "in_progress";
                    run.polls -= 1;
                }
                try f.save(all);
            }
            return f.print(run.*);
        }
        return error.NoSuchRun;
    }

    fn list(f: Fake, args: []const []const u8) !void {
        var matching: std.ArrayList(Run) = .empty;
        for (try f.runs()) |run| {
            if (!matches(args, "--branch", run.headBranch) or !matches(args, "--workflow", run.workflowName) or !matches(args, "--event", run.event)) continue;
            try matching.append(f.a, run);
        }
        if (option(args, "--branch") != null and matching.items.len != 0) try f.flaky("flaky-list");
        return f.print(matching.items);
    }

    /// `FAKE_BAY_ROOT`, the development build's root; without it, a bay from before `locate`.
    fn locate(f: Fake) !void {
        const root = f.env.get("FAKE_BAY_ROOT") orelse fail(f.io, "bay: no command or step named locate");
        var buffer: [1024]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(f.io, &buffer);
        try out.interface.print("{s}\n", .{root});
        try out.interface.flush();
    }

    fn tidy(f: Fake) !void {
        var froms = std.mem.tokenizeScalar(u8, f.env.get("FAKE_BAY_FROM") orelse return, ' ');
        var tos = std.mem.tokenizeScalar(u8, f.env.get("FAKE_BAY_TO") orelse return, ' ');
        var text = try std.Io.Dir.cwd().readFileAlloc(f.io, "build.zig.zon", f.a, .limited(1 << 20));
        while (froms.next()) |from| text = try std.mem.replaceOwned(u8, f.a, text, from, tos.next() orelse return error.UnpairedPin);
        try std.Io.Dir.cwd().writeFile(f.io, .{ .sub_path = "build.zig.zon", .data = text });
    }
};

/// Writes `message` to stderr and exits 1, as a failing gh or bay does.
fn fail(io: std.Io, message: []const u8) noreturn {
    var buffer: [256]u8 = undefined;
    var err = std.Io.File.stderr().writerStreaming(io, &buffer);
    // glint-ignore: Z026 -- the fake exits 1 next whatever happens; its exit status is the failure the test reads
    err.interface.print("{s}\n", .{message}) catch {};
    // glint-ignore: Z026 -- as above: a message that cannot be written still ends in exit 1
    err.interface.flush() catch {};
    std.process.exit(1);
}

fn option(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |arg, i| if (std.mem.eql(u8, arg, name) and i + 1 < args.len) return args[i + 1];
    return null;
}

/// Whether `value` is what the option `name` asks for, or the option is not given.
fn matches(args: []const []const u8, name: []const u8, value: []const u8) bool {
    return std.mem.eql(u8, option(args, name) orelse return true, value);
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = (try init.minimal.args.toSlice(a))[1..];
    var state = try std.Io.Dir.cwd().createDirPathOpen(init.io, init.environ_map.get("FAKE_GH_STATE") orelse return error.NoState, .{});
    defer state.close(init.io);
    const f: Fake = .{ .a = a, .io = init.io, .env = init.environ_map, .state = state, .origin = init.environ_map.get("FAKE_GH_ORIGIN") orelse "" };
    const calls = try f.read("calls") orelse "";
    try state.writeFile(init.io, .{ .sub_path = "calls", .data = try a.print("{s}{s}\n", .{ calls, try std.mem.join(a, " ", args) }) });
    if (args.len == 0) return error.NoCommand;
    if (std.mem.eql(u8, args[0], "tidy")) return f.tidy();
    if (std.mem.eql(u8, args[0], "locate")) return f.locate();
    const repo = init.environ_map.get("FAKE_GH_REPO") orelse return error.NoRepo;
    if (!std.mem.eql(u8, option(args, "--repo") orelse "", repo)) fail(init.io, "none of the git remotes configured for this repository point to a known GitHub host; name one with --repo");
    if (args.len < 2) return error.NoCommand;
    if (std.mem.eql(u8, args[0], "workflow") and std.mem.eql(u8, args[1], "run") and args.len > 2) return f.dispatch(args[2], option(args, "--ref") orelse return error.NoRef);
    if (std.mem.eql(u8, args[0], "run") and std.mem.eql(u8, args[1], "list")) return f.list(args);
    if (std.mem.eql(u8, args[0], "run") and std.mem.eql(u8, args[1], "view") and args.len > 2) return f.view(try std.fmt.parseInt(i64, args[2], 10));
    return error.UnknownCommand;
}
