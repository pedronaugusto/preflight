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
    /// The stand-in, which a test runs by its path: a child's PATH is not where this process
    /// looks for the program it starts.
    fake: []const u8,

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
        s.fake = fake;
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
        try s.write(".github/workflows/ci.yml", try workflow.render(a, parsed, old_pin, ".", false, "ci/workflow.json: zig build plan -- --workflow .github/workflows/ci.yml"));
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
        const kept: []const []const u8 = if (@import("builtin").target.os.tag == .windows) &.{ "PATH", "SystemRoot" } else &.{"PATH"};
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
        return s.landWith(outcome, &.{});
    }

    /// `land` with `extra` options after its own.
    fn landWith(s: *Scene, outcome: []const u8, extra: []const []const u8) !std.process.RunResult {
        try s.env.put("FAKE_GH_OUTCOME", outcome);
        var work = try s.tmp.dir.openDir(std.testing.io, "work", .{});
        defer work.close(std.testing.io);
        const program = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, test_options.preflight, s.arena.allocator());
        const argv = try std.mem.concat(s.arena.allocator(), []const u8, &.{ &.{ program, "land", "--date", date, "--poll", "0" }, extra });
        return std.process.run(s.arena.allocator(), std.testing.io, .{ .argv = argv, .cwd = .{ .dir = work }, .environ_map = &s.env });
    }

    /// A commit that sets `a` in src/a.zig and says so under `[Unreleased]`.
    fn change(s: *Scene, value: u8) !void {
        const a = s.arena.allocator();
        try s.write("src/a.zig", try a.print("pub const a = {d};\n", .{value}));
        const changelog = try s.tmp.dir.readFileAlloc(std.testing.io, "work/CHANGELOG.md", a, .limited(1 << 20));
        try s.write("CHANGELOG.md", try std.mem.replaceOwned(u8, a, changelog, "## [Unreleased]\n", try a.print("## [Unreleased]\n\n### Fixed\n\n- a is {d}.\n", .{value})));
        try s.commit(try a.print("Set a to {d}", .{value}));
    }

    /// The stand-in's next `count` calls of `command` (`list` or `view`) fail.
    fn flaky(s: *Scene, command: []const u8, count: usize) !void {
        const a = s.arena.allocator();
        try s.tmp.dir.createDirPath(std.testing.io, "gh");
        try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = try a.print("gh/flaky-{s}", .{command}), .data = try a.print("{d}\n", .{count}) });
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
    try contains(green.stdout, "landed v0.1.1 on main at ");
    // Main and the tag are on the release commit, which is the rebased fix with the release on it.
    const landed = try s.remote("refs/heads/main");
    try std.testing.expectEqualStrings(landed, try s.remote("refs/tags/v0.1.1^{commit}"));
    try std.testing.expectEqualStrings(landed, try s.gitOut(&.{ "rev-parse", "HEAD" }));
    try std.testing.expectEqualStrings("work", try s.gitOut(&.{ "symbolic-ref", "--short", "HEAD" }));
    try std.testing.expectEqualStrings("Release v0.1.1\nFix again\nFix\nSay more\nFirst", try s.gitOut(&.{ "log", "--format=%s" }));
    // Every attempt's ref of the version goes.
    try std.testing.expectEqualStrings("", try s.landRefs());
    const changelog = try s.gitOut(&.{ "show", "HEAD:CHANGELOG.md" });
    try contains(changelog, "## [Unreleased]\n\n## [0.1.1] - " ++ date ++ "\n\n### Fixed\n\n- A fix.\n\n### Changed\n\n- Pins dep 0.2.0.\n\n## [0.1.0]");
    try contains(changelog, "[0.1.1]: https://example.invalid/pkg/compare/v0.1.0...v0.1.1\n");
    const manifest = try s.gitOut(&.{ "show", "HEAD:build.zig.zon" });
    try contains(manifest, ".version = \"0.1.1\"");
    try contains(manifest, new_hash);
    // The caller names the preflight tidy pinned, generated as plan generates it.
    const parsed = (try std.json.parseFromSlice(std.json.Value, s.arena.allocator(), "{\"land\":true,\"release\":true}", .{})).value;
    const regenerated = try workflow.render(s.arena.allocator(), parsed, new_pin, ".", false, "ci/workflow.json: zig build plan -- --workflow .github/workflows/ci.yml");
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

test "a package whose gate is configured and run in another directory lands as its caller's first line says it was planned" {
    const s = try Scene.init();
    defer s.deinit();
    const a = s.arena.allocator();
    // As preflight's own: the configuration in its sample, which the gate runs in.
    const config = "{\"land\":true,\"release\":true}\n";
    try s.git(&.{ "rm", "-q", "ci/workflow.json" });
    try s.write("sample/ci/workflow.json", config);
    const parsed = (try std.json.parseFromSlice(std.json.Value, a, config, .{})).value;
    const heading = try workflow.heading(a, "sample/ci/workflow.json", ".github/workflows/ci.yml", "sample", true);
    try s.write(".github/workflows/ci.yml", try workflow.render(a, parsed, "${{ github.sha }}", "sample", true, heading));
    try s.commit("The gate in the sample");
    try s.git(&.{ "push", "-q", "origin", "main" });
    try s.branch();
    // No flags to remember: the caller says where the gate is configured and runs.
    try expectExit(try s.land("success"), 0);
    try std.testing.expectEqualStrings(try s.remote("refs/heads/main"), try s.remote("refs/tags/v0.1.1"));
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

test "a landing whose only move is a development pin releases nothing and notes nothing" {
    const s = try Scene.init();
    defer s.deinit();
    // tidy moves preflight, which the package develops with, and nothing a consumer fetches.
    try s.env.put("FAKE_BAY_FROM", old_pin ++ " " ++ old_preflight);
    try s.env.put("FAKE_BAY_TO", new_pin ++ " " ++ new_preflight);
    try s.git(&.{ "checkout", "-q", "-b", "tools" });
    const result = try s.land("success");
    try expectExit(result, 0);
    try contains(result.stdout, "pushed land/tools-");
    try std.testing.expectEqualStrings("", try s.remote("refs/tags/v0.1.1"));
    try contains(try s.gitOut(&.{ "show", "origin/main:build.zig.zon" }), new_preflight);
    try contains(try s.gitOut(&.{ "show", "origin/main:CHANGELOG.md" }), "## [Unreleased]\n\n## [0.1.0]");
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
    try contains(result.stdout, "landed docs on main at ");
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
    try contains(green.stdout, "landed v0.1.1 on trunk at ");
    const landed = try s.remote("refs/heads/trunk");
    try std.testing.expectEqualStrings(landed, try s.remote("refs/tags/v0.1.1^{commit}"));
    try std.testing.expectEqualStrings(landed, try s.gitOut(&.{ "rev-parse", "HEAD" }));
    try std.testing.expectEqualStrings("", try s.remote("refs/heads/main"));
}

test "a first landing on a default branch without the caller puts the caller there alone, then lands" {
    const s = try Scene.init();
    defer s.deinit();
    // main was made before its caller, as a new repository's is.
    try s.git(&.{ "rm", "-q", ".github/workflows/ci.yml" });
    try s.commit("Before the caller");
    try s.git(&.{ "push", "-q", "origin", "main" });
    const before = try s.remote("refs/heads/main");
    try s.git(&.{ "checkout", "-q", "-b", "work" });
    try s.git(&.{ "checkout", "HEAD~1", "--", ".github/workflows/ci.yml" });
    try s.commit("Add the caller");
    try s.change(2);
    const green = try s.land("success");
    try expectExit(green, 0);
    try contains(green.stdout, "origin's main had no .github/workflows/ci.yml");
    try contains(green.stdout, "landed v0.1.1 on main at ");
    // The commit after the old main holds the caller and nothing else.
    const added = try s.output(".", &.{ "git", "-C", s.origin, "rev-list", "--reverse", try s.arena.allocator().print("{s}..main", .{before}) });
    const first = added[0 .. std.mem.findScalar(u8, added, '\n') orelse added.len];
    try std.testing.expectEqualStrings(".github/workflows/ci.yml", try s.output(".", &.{ "git", "-C", s.origin, "diff-tree", "--no-commit-id", "--name-only", "-r", first }));
    try std.testing.expectEqualStrings(try s.remote("refs/heads/main"), try s.remote("refs/tags/v0.1.1^{commit}"));
}

test "once landed, a nested build pins a shared package as the package does, and one that takes the package by path follows its graph" {
    const s = try Scene.init();
    defer s.deinit();
    const pinned = ".{ .name = .x, .version = \"0.0.0\", .dependencies = .{ .pkg = .{ .path = \"PATH\" }, .dep = .{ .url = \"git+https://example.invalid/dep#1111111111111111111111111111111111111111\", .hash = \"" ++ old_hash ++ "\" } } }\n";
    const a = s.arena.allocator();
    try s.write("sample/bay/build.zig.zon", try std.mem.replaceOwned(u8, a, pinned, "PATH", "../.."));
    // The fixture also pins a package the package does not, which stays as it is.
    const fixture = try std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, pinned, "PATH", "../elsewhere"), "} } }", "}, .other = .{ .url = \"git+https://example.invalid/other#2222222222222222222222222222222222222222\", .hash = \"other-0.1.0-EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE\" } } }");
    try s.write("fixture/build.zig.zon", fixture);
    try s.commit("A sample and a fixture");
    try s.git(&.{ "push", "-q", "origin", "main" });
    try s.git(&.{ "checkout", "-q", "-b", "work" });
    try s.change(2);
    const green = try s.land("success");
    try expectExit(green, 0);
    try contains(try s.gitOut(&.{ "show", "HEAD:sample/bay/build.zig.zon" }), new_hash);
    const landed_fixture = try s.gitOut(&.{ "show", "HEAD:fixture/build.zig.zon" });
    try contains(landed_fixture, ".dep = .{ .url = \"git+https://example.invalid/dep#1111111111111111111111111111111111111111\", .hash = \"" ++ new_hash ++ "\" }");
    try contains(landed_fixture, ".other = .{ .url = \"git+https://example.invalid/other#2222222222222222222222222222222222222222\", .hash = \"other-0.1.0-EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE\" }");
}

test "a job GitHub found no runner for runs again, and the landing lands" {
    const s = try Scene.init();
    defer s.deinit();
    try s.git(&.{ "checkout", "-q", "-b", "work" });
    try s.change(2);
    const green = try s.land("unstarted");
    try expectExit(green, 0);
    try contains(green.stderr, "land: GitHub ran no runner for a job of https://github.invalid/runs/1; running the jobs that did not pass again (1/3)");
    try contains(green.stdout, "landed v0.1.1 on main at ");
    try contains(try s.calls(), "run rerun 1 --failed --repo owner/pkg");
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

test "a landing that another lands on top of while it finishes still landed" {
    const s = try Scene.init();
    defer s.deinit();
    try s.branch();
    try s.env.put("FAKE_GH_AFTER_LAND", "advance");
    const green = try s.land("success");
    try expectExit(green, 0);
    const tagged = try s.remote("refs/tags/v0.1.1^{commit}");
    try contains(green.stdout, try std.mem.concat(s.arena.allocator(), u8, &.{ "landed v0.1.1 on main at ", tagged[0..12], "\n" }));
    // main went on past the landing, which the branch follows.
    try std.testing.expectEqualStrings(tagged, try s.remote("refs/heads/main^"));
    try std.testing.expectEqualStrings(tagged, try s.gitOut(&.{ "rev-parse", "HEAD" }));
    try std.testing.expectEqualStrings("", try s.landRefs());
}

test "a landing deletes the attempts no landing needs, and leaves another's in flight and the clone's refs" {
    const s = try Scene.init();
    defer s.deinit();
    try s.branch();
    // Another clone's landing of the same version runs, and a third has just pushed its branch.
    try s.git(&.{ "push", "-q", "origin", "HEAD:refs/heads/land/v0.1.1-aaaaaaaaaaaa", "HEAD:refs/heads/land/v0.1.1-bbbbbbbbbbbb" });
    try s.env.put("FAKE_GH_POLLS", "100");
    try s.run("work", &.{ s.fake, "workflow", "run", "ci.yml", "--ref", "land/v0.1.1-aaaaaaaaaaaa", "--repo", "owner/pkg" });
    try s.env.put("FAKE_GH_POLLS", "0");
    // A branch origin no longer has, which the clone still tracks.
    try s.git(&.{ "push", "-q", "origin", "HEAD:refs/heads/gone" });
    try s.git(&.{ "fetch", "-q", "origin" });
    try s.run(".", &.{ "git", "-C", "origin.git", "branch", "-q", "-D", "gone" });
    const red = try s.land("failure");
    try expectExit(red, 1);
    try s.write("src/a.zig", "pub const a = 3;\n");
    try s.commit("Fix again");
    const green = try s.land("success");
    try expectExit(green, 0);
    // The red attempt went; the others stay.
    try std.testing.expectEqualStrings("land/v0.1.1-aaaaaaaaaaaa\nland/v0.1.1-bbbbbbbbbbbb", try s.landRefs());
    try std.testing.expect((try s.gitOut(&.{ "rev-parse", "-q", "--verify", "refs/remotes/origin/gone" })).len != 0);
}

test "a gh that fails for a while is asked again, and the run is named as soon as it is found" {
    const s = try Scene.init();
    defer s.deinit();
    try s.branch();
    try s.env.put("FAKE_GH_POLLS", "2");
    try s.flaky("list", 3);
    try s.flaky("view", 3);
    const green = try s.land("success");
    try expectExit(green, 0);
    try contains(green.stderr, "land: gh run list failed, looking again: error connecting to api.github.com");
    try contains(green.stderr, "land: gh run view failed, looking again");
    try contains(green.stdout, "landed v0.1.1 on main at ");

    // A run GitHub stops answering for is named, and said to go on without the landing.
    try s.change(5);
    try s.flaky("view", 1000);
    const lost = try s.land("success");
    try expectExit(lost, 1);
    try contains(lost.stdout, "run https://github.invalid/runs/2\n");
    try contains(lost.stderr, "gh run view failed 10 times in a row");
    try contains(lost.stderr, "may still land");
}

test "a branch that moves while the run runs stays, and so does one whose tree git would not carry" {
    const s = try Scene.init();
    defer s.deinit();
    try s.branch();
    const head = try s.gitOut(&.{ "rev-parse", "HEAD" });
    try s.env.put("FAKE_GH_POLLS", "1");
    try s.env.put("FAKE_GH_MEANWHILE", "commit");
    const moved = try s.land("success");
    try expectExit(moved, 0);
    try contains(moved.stdout, "landed v0.1.1 on main at ");
    try contains(moved.stdout, "and the branch stays where it was");
    try contains(moved.stderr, "work is no longer checked out at the commit it landed from");
    try std.testing.expectEqualStrings(head, try s.gitOut(&.{ "rev-parse", "HEAD^" }));
    try std.testing.expectEqualStrings("Meanwhile", try s.gitOut(&.{ "log", "-1", "--format=%s" }));

    // An edit of a file the landing changed, made while the run runs, stays in the tree.
    try s.git(&.{ "reset", "-q", "--hard", "origin/main" });
    try s.change(6);
    const six = try s.gitOut(&.{ "rev-parse", "HEAD" });
    try s.env.put("FAKE_GH_MEANWHILE", "edit");
    const edited = try s.land("success");
    try expectExit(edited, 0);
    try contains(edited.stdout, "landed v0.1.2 on main at ");
    try contains(edited.stderr, "work stays where it is, since git would not carry the tree's edits");
    try std.testing.expectEqualStrings(six, try s.gitOut(&.{ "rev-parse", "HEAD" }));
    try contains(try s.gitOut(&.{ "status", "--porcelain" }), "CHANGELOG.md");
    try s.alone();
}

test "a landing whose end the clone did not see stands, and landing again finishes it" {
    const s = try Scene.init();
    defer s.deinit();
    try s.branch();
    const head = try s.gitOut(&.{ "rev-parse", "HEAD" });
    try s.env.put("FAKE_GH_AFTER_LAND", "unreachable");
    const green = try s.land("success");
    try expectExit(green, 0);
    try contains(green.stdout, "landed v0.1.1 on main at ");
    try contains(green.stderr, "origin could not be fetched to see it, so work stays where it is");
    try std.testing.expectEqualStrings(head, try s.gitOut(&.{ "rev-parse", "HEAD" }));

    // Origin is back: there is nothing left to land, its attempt goes and the branch follows.
    const a = s.arena.allocator();
    try std.Io.Dir.renameAbsolute(try a.print("{s}.away", .{s.origin}), s.origin, std.testing.io);
    _ = s.env.swapRemove("FAKE_GH_AFTER_LAND");
    try std.testing.expect(std.mem.startsWith(u8, try s.landRefs(), "land/v0.1.1-"));
    const again = try s.land("success");
    try expectExit(again, 0);
    try contains(again.stdout, "nothing to land: main holds work, which follows it now");
    try std.testing.expectEqualStrings("", try s.landRefs());
    const landed = try s.remote("refs/heads/main");
    try std.testing.expectEqualStrings(landed, try s.remote("refs/tags/v0.1.1^{commit}"));
    try std.testing.expectEqualStrings(landed, try s.gitOut(&.{ "rev-parse", "HEAD" }));
    try s.alone();
}

test "an empty [Unreleased] beside other changes is refused, though tidy re-pins; re-pins alone are the entry" {
    const s = try Scene.init();
    defer s.deinit();
    try s.git(&.{ "checkout", "-q", "-b", "work" });
    try s.write("src/a.zig", "pub const a = 2;\n");
    try s.commit("Two, unsaid");
    const head = try s.gitOut(&.{ "rev-parse", "HEAD" });
    const refused = try s.land("success");
    try expectExit(refused, 1);
    try contains(refused.stderr, "[Unreleased] lists nothing");
    try s.untouched("work", head);
    try std.testing.expectEqualStrings("", try s.landRefs());

    try s.git(&.{ "reset", "-q", "--hard", "main" });
    const green = try s.land("success");
    try expectExit(green, 0);
    try contains(try s.gitOut(&.{ "show", "HEAD:CHANGELOG.md" }), "## [0.1.1] - " ++ date ++ "\n\n### Changed\n\n- Pins dep 0.2.0.\n");
}

/// `preflight <command>` in the clone, with `extra` options after it.
fn hand(s: *Scene, command: []const []const u8) !std.process.RunResult {
    var work = try s.tmp.dir.openDir(std.testing.io, "work", .{});
    defer work.close(std.testing.io);
    const program = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, test_options.preflight, s.arena.allocator());
    return std.process.run(s.arena.allocator(), std.testing.io, .{ .argv = try std.mem.concat(s.arena.allocator(), []const u8, &.{ &.{program}, command }), .cwd = .{ .dir = work }, .environ_map = &s.env });
}

test "a hand landing: ready makes the release on the branch, publish puts it and its tag on origin, and nothing goes to GitHub" {
    const s = try Scene.init();
    defer s.deinit();
    try s.branch();
    const ready = try hand(s, &.{ "ready", "--date", date });
    try expectExit(ready, 0);
    try contains(ready.stdout, "ready: v0.1.1 at ");
    // Rebased on main, re-pinned, released, all on the branch itself.
    try std.testing.expectEqualStrings("Release v0.1.1", try s.gitOut(&.{ "log", "-1", "--format=%s" }));
    try s.git(&.{ "merge-base", "--is-ancestor", "origin/main", "HEAD" });
    const changelog = try s.tmp.dir.readFileAlloc(std.testing.io, "work/CHANGELOG.md", s.arena.allocator(), .limited(1 << 20));
    try contains(changelog, "## [0.1.1] - " ++ date);
    try std.testing.expectEqualStrings("", try s.remote("refs/tags/v0.1.1"));
    const head = try s.gitOut(&.{ "rev-parse", "HEAD" });
    const published = try hand(s, &.{"publish"});
    try expectExit(published, 0);
    try contains(published.stdout, "as v0.1.1");
    try std.testing.expectEqualStrings(head, try s.remote("refs/heads/main"));
    try std.testing.expectEqualStrings(head, try s.remote("refs/tags/v0.1.1^{commit}"));
    // The stand-in saw bay's tidy and no call of GitHub's.
    var calls = std.mem.tokenizeScalar(u8, try s.calls(), '\n');
    while (calls.next()) |call| try std.testing.expectEqualStrings("tidy", call);
    try std.testing.expectEqualStrings("", try s.landRefs());
}

test "ready and gate refuse a caller that is not what plan generates for the package's pins and configuration" {
    const s = try Scene.init();
    defer s.deinit();
    try s.branch();
    // preflight's pin stays, so ready leaves the caller as it is; the configuration moved
    // without it.
    _ = s.env.swapRemove("FAKE_BAY_FROM");
    try s.write("ci/workflow.json", "{\"land\":true,\"release\":true,\"targets\":[\"x86_64-linux-gnu\"]}\n");
    try s.commit("A target, the caller left as it was");
    const readied = try hand(s, &.{ "ready", "--date", date });
    try expectExit(readied, 1);
    try contains(readied.stderr, ".github/workflows/ci.yml is not what plan generates for this package's pins and ci/workflow.json");
    try std.testing.expect(!std.mem.startsWith(u8, try s.gitOut(&.{ "log", "-1", "--format=%s" }), "Release"));
    const gated = try hand(s, &.{"gate"});
    try expectExit(gated, 1);
    try contains(gated.stderr, ".github/workflows/ci.yml is not what plan generates");
}

test "publish refuses a commit that does not hold origin's main, a tree with changes, and a tag that names another commit" {
    const s = try Scene.init();
    defer s.deinit();
    try s.branch();
    // The branch is behind main: publishing it would rewrite main.
    try expectExit(try hand(s, &.{"publish"}), 1);
    try expectExit(try hand(s, &.{ "ready", "--date", date }), 0);
    try s.write("src/a.zig", "pub const a = 3;\n");
    try expectExit(try hand(s, &.{"publish"}), 1);
    try s.git(&.{ "checkout", "-q", "--", "src/a.zig" });
    // Another commit took the version's tag on origin.
    const other = try s.gitOut(&.{ "commit-tree", "origin/main^{tree}", "-p", "origin/main", "-m", "Another" });
    try s.git(&.{ "tag", "v0.1.1", other });
    try s.git(&.{ "push", "-q", "origin", "v0.1.1" });
    const refused = try hand(s, &.{"publish"});
    try expectExit(refused, 1);
    try contains(refused.stderr, "a tag is never moved");
    try std.testing.expect(!std.mem.eql(u8, try s.gitOut(&.{ "rev-parse", "HEAD" }), try s.remote("refs/heads/main")));
}
