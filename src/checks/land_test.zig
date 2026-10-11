//! `preflight land` end to end: a package in a clone of a bare repository standing in for
//! GitHub, the preflight program run as its user runs it, and a stand-in for the GitHub CLI
//! and for bay's tidy on PATH (src/testing/gh.zig), with no git configuration of the user's.
const std = @import("std");
const test_options = @import("test_options");
const workflow = @import("workflow.zig");

const old_hash = "dep-0.1.0-" ++ "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const new_hash = "dep-0.2.0-" ++ "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
const date = "2026-10-11";

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
        s.env = try std.testing.environ.createMap(a);
        try s.env.put("HOME", root);
        try s.env.put("GIT_CONFIG_NOSYSTEM", "1");
        try s.env.put("GIT_CONFIG_GLOBAL", "/dev/null");
        const fake = try std.Io.Dir.cwd().realPathFileAlloc(io, test_options.gh, a);
        const path = s.env.get("PATH") orelse "";
        try s.env.put("PATH", try a.print("{s}{c}{s}", .{ std.Io.Dir.path.dirname(fake).?, std.Io.Dir.path.delimiter, path }));
        // The manifest declares dev dependencies, so the landing tidies with this bay.
        try s.env.put("BAY", fake);
        try s.env.put("FAKE_GH_STATE", s.state);
        try s.env.put("FAKE_BAY_FROM", old_hash);
        try s.env.put("FAKE_BAY_TO", new_hash);
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
            \\    .dev_dependencies = .{},
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
        try s.write(".github/workflows/ci.yml", try workflow.render(a, parsed, "0000000000000000000000000000000000000000", ".", false, ".github/workflows/ci.yml"));
        try s.commit("First");
        try s.git(&.{ "tag", "v0.1.0" });
        try s.git(&.{ "remote", "add", "origin", s.origin });
        try s.git(&.{ "push", "-q", "--tags", "origin", "main" });
        return s;
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

    /// The stand-in's calls so far, one per line.
    fn calls(s: *Scene) ![]const u8 {
        return s.tmp.dir.readFileAlloc(std.testing.io, "gh/calls", s.arena.allocator(), .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => |e| return e,
        };
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
    // The branch, its checkout and main are as they were; the land branch stays for a look.
    try std.testing.expectEqualStrings(before, try s.gitOut(&.{ "rev-parse", "HEAD" }));
    try std.testing.expectEqualStrings("work", try s.gitOut(&.{ "symbolic-ref", "--short", "HEAD" }));
    try std.testing.expectEqualStrings("", try s.gitOut(&.{ "status", "--porcelain" }));
    try std.testing.expectEqualStrings(main, try s.remote("refs/heads/main"));
    try std.testing.expect((try s.remote("refs/heads/land/v0.1.1")).len != 0);
    try std.testing.expectEqualStrings("", try s.remote("refs/tags/v0.1.1"));
    const dispatched = try s.calls();
    try contains(dispatched, "tidy\n");
    try contains(dispatched, "workflow run ci.yml --ref land/v0.1.1 -f tier=merge -f land=true\n");

    const green = try s.land("success");
    try expectExit(green, 0);
    try contains(green.stdout, "pushed land/v0.1.1 at ");
    try contains(green.stdout, "run https://github.invalid/runs/2\n");
    try contains(green.stdout, "landed v0.1.1: main is at ");
    // Main and the tag are on the release commit, which is the rebased fix with the release on it.
    const landed = try s.remote("refs/heads/main");
    try std.testing.expectEqualStrings(landed, try s.remote("refs/tags/v0.1.1^{commit}"));
    try std.testing.expectEqualStrings(landed, try s.gitOut(&.{ "rev-parse", "HEAD" }));
    try std.testing.expectEqualStrings("work", try s.gitOut(&.{ "symbolic-ref", "--short", "HEAD" }));
    try std.testing.expectEqualStrings("Release v0.1.1\nFix\nSay more\nFirst", try s.gitOut(&.{ "log", "--format=%s" }));
    try std.testing.expectEqualStrings("", try s.remote("refs/heads/land/v0.1.1"));
    const changelog = try s.gitOut(&.{ "show", "HEAD:CHANGELOG.md" });
    try contains(changelog, "## [Unreleased]\n\n## [0.1.1] - " ++ date ++ "\n\n### Fixed\n\n- A fix.\n\n### Changed\n\n- Pins dep 0.2.0.\n\n## [0.1.0]");
    try contains(changelog, "[0.1.1]: https://example.invalid/pkg/compare/v0.1.0...v0.1.1\n");
    const manifest = try s.gitOut(&.{ "show", "HEAD:build.zig.zon" });
    try contains(manifest, ".version = \"0.1.1\"");
    try contains(manifest, new_hash);

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
