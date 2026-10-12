//! `preflight land` end to end: a package in a clone of a bare repository standing in for
//! GitHub, the preflight program run as its user runs it, and a stand-in for the GitHub CLI
//! and for bay's tidy on PATH (src/testing/gh.zig). The programs get PATH and what the test
//! sets, nothing else: no git, gh or ssh configuration or variable of the user's.
const std = @import("std");
const test_options = @import("test_options");
const workflow = @import("workflow.zig");

const old_hash = "dep-0.1.0-" ++ "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const new_hash = "dep-0.2.0-" ++ "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
const old_pin = "0000000000000000000000000000000000000000";
const new_pin = "1111111111111111111111111111111111111111";
const old_preflight = "preflight-0.1.0-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC";
const new_preflight = "preflight-0.1.1-DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD";
const date = "2026-10-11";
/// The repository origin's URL names, which `url.<origin>.insteadOf` sends to the bare one.
const url = "https://github.com/owner/pkg.git";

const Scene = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    /// The bare repository the clone pushes to.
    origin: []const u8,
    /// Where the stand-in records its calls and runs.
    state: []const u8,

    fn init() !*Scene {
        const s = try std.testing.allocator.create(Scene);
        s.arena = .init(std.testing.allocator);
        s.tmp = std.testing.tmpDir(.{});
        const a = s.arena.allocator();
        const io = std.testing.io;
        const root = try s.tmp.dir.realPathFileAlloc(io, ".", a);
        s.origin = try std.Io.Dir.path.join(a, &.{ root, "origin.git" });
        s.state = try std.Io.Dir.path.join(a, &.{ root, "gh" });
        s.env = try environment(a);
        try s.env.put("HOME", root);
        try s.env.put("GIT_CONFIG_NOSYSTEM", "1");
        try s.env.put("GIT_CONFIG_GLOBAL", "/dev/null");
        const fake = try std.Io.Dir.cwd().realPathFileAlloc(io, test_options.gh, a);
        const path = s.env.get("PATH") orelse "";
        try s.env.put("PATH", try a.print("{s}{c}{s}", .{ std.Io.Dir.path.dirname(fake).?, std.Io.Dir.path.delimiter, path }));
        try s.env.put("FAKE_GH_REPO", "owner/pkg");
        try s.env.put("FAKE_GH_ORIGIN", s.origin);
        // The manifest declares dev dependencies, so the landing tidies with this bay.
        try s.env.put("BAY", fake);
        try s.env.put("FAKE_GH_STATE", s.state);
        // tidy re-pins dep, and preflight, which the caller names.
        try s.env.put("FAKE_BAY_FROM", old_hash ++ " " ++ old_pin ++ " " ++ old_preflight);
        try s.env.put("FAKE_BAY_TO", new_hash ++ " " ++ new_pin ++ " " ++ new_preflight);
        try s.run(".", &.{ "git", "init", "-q", "--bare", "-b", "main", "origin.git" });
        try s.run(".", &.{ "git", "init", "-q", "-b", "main", "work" });
        for ([_][2][]const u8{ .{ "user.name", "Preflight" }, .{ "user.email", "preflight@example.invalid" }, .{ "commit.gpgsign", "false" }, .{ "tag.gpgsign", "false" } }) |setting|
            try s.git(&.{ "config", setting[0], setting[1] });
        try s.write("build.zig.zon",
            \\.{
            \\    .name = .pkg,
            \\    .version = "0.1.0",
            \\    .paths = .{ "build.zig", "build.zig.zon", "src", "CHANGELOG.md" },
            \\    .dependencies = .{
            \\        .dep = .{
            \\            .url = "git+https://example.invalid/dep#1111111111111111111111111111111111111111",
            \\            .hash = "
        ++ old_hash ++
            \\",
            \\        },
            \\    },
            \\    .dev_dependencies = .{
            \\        .preflight = .{
            \\            .url = "git+https://github.com/pedronaugusto/preflight#
        ++ old_pin ++
            \\",
            \\            .hash = "
        ++ old_preflight ++
            \\",
            \\        },
            \\    },
            \\}
            \\
        );
        try s.write("build.zig", "pub fn build(_: *@import(\"std\").Build) void {}\n");
        try s.write("src/a.zig", "pub const a = 1;\n");
        try s.write("README.md", "# pkg\n");
        try s.write("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-01-01\n\n- First.\n\n[Unreleased]: https://example.invalid/pkg/compare/v0.1.0...HEAD\n[0.1.0]: https://example.invalid/pkg/releases/tag/v0.1.0\n");
        const config = "{\"land\":true,\"release\":true}\n";
        try s.write("ci/workflow.json", config);
        const parsed = (try std.json.parseFromSlice(std.json.Value, a, config, .{})).value;
        try s.write(".github/workflows/ci.yml", try workflow.render(a, parsed, old_pin, ".", false, ".github/workflows/ci.yml"));
        try s.commit("First");
        try s.git(&.{ "tag", "v0.1.0" });
        try s.git(&.{ "remote", "add", "origin", url });
        try s.git(&.{ "config", try a.print("url.{s}.insteadOf", .{s.origin}), url });
        try s.git(&.{ "push", "-q", "--tags", "origin", "main" });
        return s;
    }

    /// PATH, and SystemRoot where Windows needs it to start a program; nothing else of this
    /// process's environment.
    fn environment(a: std.mem.Allocator) !std.process.Environ.Map {
        const inherited = try std.testing.environ.createMap(a);
        var env: std.process.Environ.Map = .init(a);
        const kept: []const []const u8 = if (@import("builtin").os.tag == .windows) &.{ "PATH", "SystemRoot" } else &.{"PATH"};
        for (kept) |name| if (inherited.get(name)) |value| try env.put(name, value);
        return env;
    }

    fn deinit(s: *Scene) void {
        s.tmp.cleanup();
        s.arena.deinit();
        std.testing.allocator.destroy(s);
    }

    fn run(s: *Scene, cwd: []const u8, argv: []const []const u8) !void {
        _ = try s.output(cwd, argv);
    }

    fn output(s: *Scene, cwd: []const u8, argv: []const []const u8) ![]const u8 {
        var dir = try s.tmp.dir.openDir(std.testing.io, cwd, .{});
        defer dir.close(std.testing.io);
        const result = try std.process.run(s.arena.allocator(), std.testing.io, .{ .argv = argv, .cwd = .{ .dir = dir }, .environ_map = &s.env });
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("{s}: {s}\n", .{ try std.mem.join(s.arena.allocator(), " ", argv), result.stderr });
            return error.FixtureCommandFailed;
        }
        return std.mem.trim(u8, result.stdout, " \r\n");
    }

    fn git(s: *Scene, args: []const []const u8) !void {
        _ = try s.gitOut(args);
    }

    fn gitOut(s: *Scene, args: []const []const u8) ![]const u8 {
        return s.output("work", try std.mem.concat(s.arena.allocator(), []const u8, &.{ &.{"git"}, args }));
    }

    /// What `rev` names in origin, or "" when nothing.
    fn remote(s: *Scene, rev: []const u8) ![]const u8 {
        const result = try std.process.run(s.arena.allocator(), std.testing.io, .{ .argv = &.{ "git", "-C", s.origin, "rev-parse", "-q", "--verify", rev }, .environ_map = &s.env });
        return std.mem.trim(u8, result.stdout, " \r\n");
    }

    fn write(s: *Scene, path: []const u8, data: []const u8) !void {
        const full = try std.Io.Dir.path.join(s.arena.allocator(), &.{ "work", path });
        if (std.Io.Dir.path.dirname(full)) |dir| try s.tmp.dir.createDirPath(std.testing.io, dir);
        try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = full, .data = data });
    }

    fn commit(s: *Scene, message: []const u8) !void {
        try s.git(&.{ "add", "-A" });
        try s.git(&.{ "commit", "-q", "-m", message });
    }

    /// `preflight land` in the clone, the run the stand-in starts ending in `outcome`.
    fn land(s: *Scene, outcome: []const u8) !std.process.RunResult {
        try s.env.put("FAKE_GH_OUTCOME", outcome);
        var work = try s.tmp.dir.openDir(std.testing.io, "work", .{});
        defer work.close(std.testing.io);
        const program = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, test_options.preflight, s.arena.allocator());
        return std.process.run(s.arena.allocator(), std.testing.io, .{ .argv = &.{ program, "land", "--date", date }, .cwd = .{ .dir = work }, .environ_map = &s.env });
    }

    /// The `land/` branches origin holds, one per line.
    fn landRefs(s: *Scene) ![]const u8 {
        const result = try std.process.run(s.arena.allocator(), std.testing.io, .{ .argv = &.{ "git", "-C", s.origin, "for-each-ref", "--format=%(refname:short)", "refs/heads/land" }, .environ_map = &s.env });
        return std.mem.trim(u8, result.stdout, " \r\n");
    }

    /// The stand-in's calls so far, one per line.
    fn calls(s: *Scene) ![]const u8 {
        return s.tmp.dir.readFileAlloc(std.testing.io, "gh/calls", s.arena.allocator(), .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => |e| return e,
        };
    }

    /// The branch, its checkout and the user's tree are as they were before a landing, and
    /// the landing left no worktree of its own behind.
    fn untouched(s: *Scene, name: []const u8, head: []const u8) !void {
        try std.testing.expectEqualStrings(head, try s.gitOut(&.{ "rev-parse", "HEAD" }));
        try std.testing.expectEqualStrings(head, try s.gitOut(&.{ "rev-parse", name }));
        try std.testing.expectEqualStrings(name, try s.gitOut(&.{ "symbolic-ref", "--short", "HEAD" }));
        try std.testing.expectEqualStrings("", try s.gitOut(&.{ "status", "--porcelain" }));
        try s.alone();
    }

    /// The checkout is the repository's one worktree.
    fn alone(s: *Scene) !void {
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, try s.gitOut(&.{ "worktree", "list", "--porcelain" }), "worktree "));
    }

    /// A work branch with a fix, while main moved on with a change of its own.
    fn branch(s: *Scene) !void {
        try s.git(&.{ "checkout", "-q", "-b", "work" });
        try s.write("src/a.zig", "pub const a = 2;\n");
        const changelog = try s.tmp.dir.readFileAlloc(std.testing.io, "work/CHANGELOG.md", s.arena.allocator(), .limited(1 << 20));
        try s.write("CHANGELOG.md", try std.mem.replaceOwned(u8, s.arena.allocator(), changelog, "## [Unreleased]\n", "## [Unreleased]\n\n### Fixed\n\n- A fix.\n"));
        try s.commit("Fix");
        try s.git(&.{ "checkout", "-q", "main" });
        try s.write("README.md", "# pkg\n\nMore.\n");
        try s.commit("Say more");
        try s.git(&.{ "push", "-q", "origin", "main" });
        try s.git(&.{ "checkout", "-q", "work" });
    }
};

fn expectExit(result: std.process.RunResult, code: u8) !void {
    if (result.term != .exited or result.term.exited != code) {
        std.debug.print("stdout:\n{s}\nstderr:\n{s}\n", .{ result.stdout, result.stderr });
        return error.TestUnexpectedExit;
    }
}

fn contains(text: []const u8, part: []const u8) !void {
    if (std.mem.find(u8, text, part) == null) {
        std.debug.print("expected to find:\n{s}\nin:\n{s}\n", .{ part, text });
        return error.TestExpectedText;
    }
}

test "a red landing leaves the branch as it was; landing again lands the same release, and the branch follows main" {
    const s = try Scene.init();
    defer s.deinit();
    try s.branch();
    const before = try s.gitOut(&.{ "rev-parse", "HEAD" });
    const main = try s.remote("refs/heads/main");

    const red = try s.land("failure");
    try expectExit(red, 1);
    try contains(red.stderr, "Linux Debug (failure)");
    try contains(red.stderr, "https://github.invalid/runs/1");
    try std.testing.expect(std.mem.find(u8, red.stderr, "source checks") == null);
    // The branch, its checkout and main are as they were; the attempt's ref stays for a look.
    try std.testing.expectEqualStrings(before, try s.gitOut(&.{ "rev-parse", "HEAD" }));
    try std.testing.expectEqualStrings("work", try s.gitOut(&.{ "symbolic-ref", "--short", "HEAD" }));
    try std.testing.expectEqualStrings("", try s.gitOut(&.{ "status", "--porcelain" }));
    try std.testing.expectEqualStrings(main, try s.remote("refs/heads/main"));
    const attempt = try s.landRefs();
    try std.testing.expect(std.mem.startsWith(u8, attempt, "land/v0.1.1-") and std.mem.findScalar(u8, attempt, '\n') == null);
    const tested = try s.remote(try std.mem.concat(s.arena.allocator(), u8, &.{ "refs/heads/", attempt }));
    try std.testing.expectEqualStrings(try std.mem.concat(s.arena.allocator(), u8, &.{ "land/v0.1.1-", tested[0..12] }), attempt);
    try std.testing.expectEqualStrings("", try s.remote("refs/tags/v0.1.1"));
    const dispatched = try s.calls();
    try contains(dispatched, "tidy\n");
    try contains(dispatched, try std.mem.concat(s.arena.allocator(), u8, &.{ "workflow run ci.yml --ref ", attempt, " -f tier=merge -f land=true --repo owner/pkg\n" }));

    // A fix after the red run is a new attempt with a ref of its own; both are there while it runs.
    try s.write("src/a.zig", "pub const a = 3;\n");
    try s.commit("Fix again");

    const green = try s.land("success");
    try expectExit(green, 0);
    try contains(green.stdout, "pushed land/v0.1.1-");
    const seen = try s.tmp.dir.readFileAlloc(std.testing.io, "gh/land-refs", s.arena.allocator(), .limited(1 << 20));
    var dispatches = std.mem.splitScalar(u8, seen, '\n');
    try std.testing.expectEqualStrings(attempt, dispatches.next().?);
    const during = dispatches.next().?;
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, during, "land/v0.1.1-"));
    try contains(during, attempt);
    try contains(green.stdout, "run https://github.invalid/runs/2\n");
    try contains(green.stdout, "landed v0.1.1: main is at ");
    // Main and the tag are on the release commit, which is the rebased fix with the release on it.
    const landed = try s.remote("refs/heads/main");
    try std.testing.expectEqualStrings(landed, try s.remote("refs/tags/v0.1.1^{commit}"));
    try std.testing.expectEqualStrings(landed, try s.gitOut(&.{ "rev-parse", "HEAD" }));
    try std.testing.expectEqualStrings("work", try s.gitOut(&.{ "symbolic-ref", "--short", "HEAD" }));
    try std.testing.expectEqualStrings("Release v0.1.1\nFix again\nFix\nSay more\nFirst", try s.gitOut(&.{ "log", "--format=%s" }));
    // Every attempt's ref of the version goes.
    try std.testing.expectEqualStrings("", try s.landRefs());
    const changelog = try s.gitOut(&.{ "show", "HEAD:CHANGELOG.md" });
    try contains(changelog, "## [Unreleased]\n\n## [0.1.1] - " ++ date ++ "\n\n### Fixed\n\n- A fix.\n\n### Changed\n\n- Pins dep 0.2.0 and preflight 0.1.1.\n\n## [0.1.0]");
    try contains(changelog, "[0.1.1]: https://example.invalid/pkg/compare/v0.1.0...v0.1.1\n");
    const manifest = try s.gitOut(&.{ "show", "HEAD:build.zig.zon" });
    try contains(manifest, ".version = \"0.1.1\"");
    try contains(manifest, new_hash);
    // The caller names the preflight tidy pinned, generated as plan generates it.
    const parsed = (try std.json.parseFromSlice(std.json.Value, s.arena.allocator(), "{\"land\":true,\"release\":true}", .{})).value;
    const regenerated = try workflow.render(s.arena.allocator(), parsed, new_pin, ".", false, ".github/workflows/ci.yml");
    try std.testing.expectEqualStrings(std.mem.trim(u8, regenerated, " \r\n"), try s.gitOut(&.{ "show", "HEAD:.github/workflows/ci.yml" }));
    try contains(regenerated, "preflight-ref: " ++ new_pin ++ "\n");

    // Main holds everything now: nothing is pushed or dispatched.
    const calls = (try s.calls()).len;
    const again = try s.land("success");
    try expectExit(again, 0);
    try contains(again.stdout, "nothing to land");
    try std.testing.expect(std.mem.find(u8, (try s.calls())[calls..], "workflow run") == null);
    try std.testing.expectEqualStrings(landed, try s.remote("refs/heads/main"));
}

test "a branch that conflicts with main is not landed, and names the files" {
    const s = try Scene.init();
    defer s.deinit();
    try s.git(&.{ "checkout", "-q", "-b", "work" });
    try s.write("src/a.zig", "pub const a = 2;\n");
    try s.commit("Two");
    try s.git(&.{ "checkout", "-q", "main" });
    try s.write("src/a.zig", "pub const a = 3;\n");
    try s.commit("Three");
    try s.git(&.{ "push", "-q", "origin", "main" });
    try s.git(&.{ "checkout", "-q", "work" });
    const before = try s.gitOut(&.{ "rev-parse", "HEAD" });
    const result = try s.land("success");
    try expectExit(result, 1);
    try contains(result.stderr, "work conflicts with origin/main in src/a.zig");
    try std.testing.expectEqualStrings(before, try s.gitOut(&.{ "rev-parse", "HEAD" }));
    try std.testing.expectEqualStrings("work", try s.gitOut(&.{ "symbolic-ref", "--short", "HEAD" }));
    try std.testing.expectEqualStrings("", try s.gitOut(&.{ "status", "--porcelain" }));
    try std.testing.expectEqualStrings("", try s.calls());
}

test "a landing is refused without land and release, or with changes in the tree" {
    const s = try Scene.init();
    defer s.deinit();
    try s.branch();
    try s.write("ci/workflow.json", "{\"land\":true}\n");
    try s.commit("No release");
    const unreleased = try s.land("success");
    try expectExit(unreleased, 1);
    try contains(unreleased.stderr, "does not set `release`");
    try s.write("ci/workflow.json", "{\"land\":true,\"release\":true}\n");
    try s.commit("Release");
    try s.write("src/a.zig", "pub const a = 4;\n");
    const dirty = try s.land("success");
    try expectExit(dirty, 1);
    try contains(dirty.stderr, "the tree has changes");
    try std.testing.expectEqualStrings("", try s.calls());
}

test "a version whose tag exists is not landed, and nothing moves" {
    const s = try Scene.init();
    defer s.deinit();
    try s.branch();
    // Someone made v0.1.1 by hand, on main.
    try s.git(&.{ "tag", "v0.1.1", "main" });
    try s.git(&.{ "push", "-q", "origin", "v0.1.1" });
    const head = try s.gitOut(&.{ "rev-parse", "HEAD" });
    const main = try s.remote("refs/heads/main");
    const result = try s.land("success");
    try expectExit(result, 1);
    try contains(result.stderr, "tag v0.1.1 exists");
    try s.untouched("work", head);
    try std.testing.expectEqualStrings(main, try s.remote("refs/heads/main"));
    try std.testing.expectEqualStrings("", try s.landRefs());
    try std.testing.expect(std.mem.find(u8, try s.calls(), "workflow run") == null);
}

test "a branch that changes nothing the package ships lands on land/<branch>- and tags nothing" {
    const s = try Scene.init();
    defer s.deinit();
    // No re-pins: README.md is not among the manifest's paths.
    _ = s.env.swapRemove("FAKE_BAY_FROM");
    try s.git(&.{ "checkout", "-q", "-b", "docs" });
    try s.write("README.md", "# pkg\n\nA word.\n");
    try s.commit("A word");
    const result = try s.land("success");
    try expectExit(result, 0);
    try contains(result.stdout, "pushed land/docs-");
    try contains(result.stdout, "landed docs: main is at ");
    try contains(try s.calls(), "workflow run ci.yml --ref land/docs-");
    const landed = try s.remote("refs/heads/main");
    try std.testing.expectEqualStrings(landed, try s.gitOut(&.{ "rev-parse", "HEAD" }));
    try std.testing.expectEqualStrings("A word\nFirst", try s.gitOut(&.{ "log", "--format=%s" }));
    try std.testing.expectEqualStrings("", try s.remote("refs/tags/v0.1.1"));
    try std.testing.expectEqualStrings("", try s.landRefs());
    try s.alone();
}

test "a landing goes onto origin's default branch, whatever its name, and says so when there is none" {
    const s = try Scene.init();
    defer s.deinit();
    // origin's HEAD names a branch it does not have.
    try s.run(".", &.{ "git", "-C", "origin.git", "symbolic-ref", "HEAD", "refs/heads/nothing" });
    try s.git(&.{ "checkout", "-q", "-b", "work" });
    try s.write("src/a.zig", "pub const a = 2;\n");
    const changelog = try s.tmp.dir.readFileAlloc(std.testing.io, "work/CHANGELOG.md", s.arena.allocator(), .limited(1 << 20));
    try s.write("CHANGELOG.md", try std.mem.replaceOwned(u8, s.arena.allocator(), changelog, "## [Unreleased]\n", "## [Unreleased]\n\n### Fixed\n\n- A fix.\n"));
    try s.commit("Fix");
    const head = try s.gitOut(&.{ "rev-parse", "HEAD" });
    const lost = try s.land("success");
    try expectExit(lost, 1);
    try contains(lost.stderr, "origin's default branch is not known");
    try s.untouched("work", head);
    try std.testing.expectEqualStrings("", try s.calls());

    // The default branch is trunk, and origin has no main.
    try s.run(".", &.{ "git", "-C", "origin.git", "branch", "-m", "main", "trunk" });
    try s.run(".", &.{ "git", "-C", "origin.git", "symbolic-ref", "HEAD", "refs/heads/trunk" });
    const green = try s.land("success");
    try expectExit(green, 0);
    try contains(green.stdout, "landed v0.1.1: trunk is at ");
    const landed = try s.remote("refs/heads/trunk");
    try std.testing.expectEqualStrings(landed, try s.remote("refs/tags/v0.1.1^{commit}"));
    try std.testing.expectEqualStrings(landed, try s.gitOut(&.{ "rev-parse", "HEAD" }));
    try std.testing.expectEqualStrings("", try s.remote("refs/heads/main"));
}

test "a landing rewrites no branch, whatever rebase.updateRefs says" {
    const s = try Scene.init();
    defer s.deinit();
    try s.branch();
    try s.git(&.{ "config", "rebase.updateRefs", "true" });
    try s.git(&.{ "branch", "keep" });
    const head = try s.gitOut(&.{ "rev-parse", "HEAD" });
    const red = try s.land("failure");
    try expectExit(red, 1);
    try s.untouched("work", head);
    try std.testing.expectEqualStrings(head, try s.gitOut(&.{ "rev-parse", "keep" }));
    const green = try s.land("success");
    try expectExit(green, 0);
    // The branch landing follows main; another branch at its commit stays.
    try std.testing.expectEqualStrings(try s.remote("refs/heads/main"), try s.gitOut(&.{ "rev-parse", "work" }));
    try std.testing.expectEqualStrings(head, try s.gitOut(&.{ "rev-parse", "keep" }));
    try s.alone();
}
