//! `preflight gate` end to end, before its jobs: a package in a git repository of its own,
//! the preflight program run as `bay gate` runs it, refusing what a release must not carry
//! (a caller other than `generate` makes, a manifest and a CHANGELOG at different releases,
//! a public declaration changed with no breaking entry) before any job runs. The program
//! gets PATH (on Windows, PATHEXT and SystemRoot beside it) and what the test sets, nothing
//! else of the user's.
const std = @import("std");
const test_options = @import("test_options");
const workflow = @import("workflow.zig");

const pin = "0000000000000000000000000000000000000000";

const Package = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,

    fn init() !*Package {
        const p = try std.testing.allocator.create(Package);
        p.arena = .init(std.testing.allocator);
        p.tmp = std.testing.tmpDir(.{});
        const a = p.arena.allocator();
        const inherited = try std.testing.environ.createMap(a);
        p.env = .init(a);
        // A Windows program finds `git` on PATH by the extensions its own PATHEXT names.
        const kept: []const []const u8 = if (@import("builtin").target.os.tag == .windows) &.{ "PATH", "PATHEXT", "SystemRoot" } else &.{"PATH"};
        for (kept) |name| if (inherited.get(name)) |value| try p.env.put(name, value);
        try p.env.put("HOME", try p.tmp.dir.realPathFileAlloc(std.testing.io, ".", a));
        try p.env.put("GIT_CONFIG_NOSYSTEM", "1");
        try p.env.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try p.git(&.{ "init", "-q", "-b", "main" });
        for ([_][2][]const u8{ .{ "user.name", "Preflight" }, .{ "user.email", "preflight@example.invalid" }, .{ "commit.gpgsign", "false" }, .{ "tag.gpgsign", "false" } }) |setting|
            try p.git(&.{ "config", setting[0], setting[1] });
        try p.write("build.zig.zon", ".{\n    .name = .pkg,\n    .version = \"0.1.0\",\n    .paths = .{\"\"},\n    .dev_dependencies = .{\n        .preflight = .{ .url = \"git+https://github.com/pedronaugusto/preflight#" ++ pin ++ "\", .hash = \"preflight-0.1.0-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC\" },\n    },\n}\n");
        try p.write("build.zig", "pub fn build(b: *@import(\"std\").Build) void {\n    _ = b.addModule(\"pkg\", .{ .root_source_file = b.path(\"src/a.zig\") });\n}\n");
        try p.write("src/a.zig", "pub fn run(size: usize) void {\n    _ = size;\n}\n");
        try p.write("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-01-01\n\n### Added\n\n- First.\n");
        const config = "{}\n";
        try p.write("ci/workflow.json", config);
        const parsed = (try std.json.parseFromSlice(std.json.Value, a, config, .{})).value;
        try p.write(".github/workflows/ci.yml", try workflow.render(a, parsed, pin, ".", false, "ci/workflow.json: bay generate"));
        try p.git(&.{ "add", "-A" });
        try p.git(&.{ "commit", "-q", "-m", "First" });
        try p.git(&.{ "tag", "v0.1.0" });
        return p;
    }

    fn deinit(p: *Package) void {
        p.tmp.cleanup();
        p.arena.deinit();
        std.testing.allocator.destroy(p);
    }

    fn write(p: *Package, path: []const u8, data: []const u8) !void {
        if (std.Io.Dir.path.dirname(path)) |dir| try p.tmp.dir.createDirPath(std.testing.io, dir);
        try p.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }

    fn git(p: *Package, args: []const []const u8) !void {
        const result = try std.process.run(p.arena.allocator(), std.testing.io, .{ .argv = try std.mem.concat(p.arena.allocator(), []const u8, &.{ &.{"git"}, args }), .cwd = .{ .dir = p.tmp.dir }, .environ_map = &p.env });
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("git {s}: {s}\n", .{ args[0], result.stderr });
            return error.FixtureCommandFailed;
        }
    }

    /// `preflight gate` as the package's build runs it, with the module it exports.
    fn gate(p: *Package) !std.process.RunResult {
        const program = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, test_options.preflight, p.arena.allocator());
        return std.process.run(p.arena.allocator(), std.testing.io, .{ .argv = &.{ program, "gate", "--module", "build.zig=build.zig", "--module", "pkg=src/a.zig" }, .cwd = .{ .dir = p.tmp.dir }, .environ_map = &p.env });
    }
};

/// The gate refused, saying `said`, and ran no job.
fn refusedBeforeJobs(result: std.process.RunResult, said: []const u8) !void {
    if (result.term != .exited or result.term.exited != 1 or std.mem.find(u8, result.stderr, said) == null) {
        std.debug.print("expected a refusal saying:\n{s}\nstdout:\n{s}\nstderr:\n{s}\n", .{ said, result.stdout, result.stderr });
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(std.mem.find(u8, result.stdout, "gate: ") == null);
}

test "the gate refuses a public declaration changed with no breaking entry, before any job" {
    const p = try Package.init();
    defer p.deinit();
    try p.write("src/a.zig", "pub fn run(size: u32) void {\n    _ = size;\n}\n");
    try p.write("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n### Changed\n\n- A smaller size.\n\n## [0.1.0] - 2026-01-01\n\n### Added\n\n- First.\n");
    try p.git(&.{ "commit", "-q", "-am", "Smaller" });
    try refusedBeforeJobs(try p.gate(), "removed or changed these public declarations");
}

test "the gate refuses a manifest and a CHANGELOG at different releases, before any job" {
    const p = try Package.init();
    defer p.deinit();
    try p.write("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n## [0.1.1] - 2026-01-02\n\n### Fixed\n\n- A fix.\n\n## [0.1.0] - 2026-01-01\n\n### Added\n\n- First.\n");
    try p.git(&.{ "commit", "-q", "-am", "Half a release" });
    try refusedBeforeJobs(try p.gate(), ".version is 0.1.0 and CHANGELOG.md's newest release is 0.1.1");
}

test "the gate refuses a caller that is not what generate makes for the package's configuration, before any job" {
    const p = try Package.init();
    defer p.deinit();
    try p.write("ci/workflow.json", "{\"targets\":[\"x86_64-linux-gnu\"]}\n");
    try p.git(&.{ "commit", "-q", "-am", "A target, the caller left as it was" });
    try refusedBeforeJobs(try p.gate(), ".github/workflows/ci.yml is not what generate makes for this package's pins and ci/workflow.json: run `bay generate`");
}
