//! `preflight gate` end to end (and lint's look at the caller, the same check before a push): a package in a git repository of its own, the preflight
//! program run as `bay gate` runs it, refusing what a release must not carry (a caller
//! other than `generate` makes, a manifest and a CHANGELOG at different releases, a public
//! declaration changed with no breaking entry). The program
//! gets PATH (on Windows, PATHEXT and SystemRoot beside it) and what the test sets, nothing
//! else of the user's.
const std = @import("std");
const test_options = @import("test_options");
const workflow = @import("workflow.zig");
const attributes = @import("attributes.zig");

const pin = "0000000000000000000000000000000000000000";

const Package = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,

    fn init() !*Package {
        return start(.bay);
    }

    /// A package developed with bay, its tools dev dependencies, or one built with zig build alone.
    fn start(developed: enum { bay, zig }) !*Package {
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
        // The run's global cache, not one under that `HOME`: there each build the package's
        // lint configures compiled what Zig keeps there (its build runner's) from nothing, inside
        // the test's bound.
        try p.env.put("ZIG_GLOBAL_CACHE_DIR", try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, test_options.zig_global_cache, a));
        try p.env.put("GIT_CONFIG_NOSYSTEM", "1");
        try p.env.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try p.git(&.{ "init", "-q", "-b", "main" });
        for ([_][2][]const u8{ .{ "user.name", "Preflight" }, .{ "user.email", "preflight@example.invalid" }, .{ "commit.gpgsign", "false" }, .{ "tag.gpgsign", "false" } }) |setting|
            try p.git(&.{ "config", setting[0], setting[1] });
        try p.write("build.zig.zon", if (developed == .bay) ".{\n    .name = .pkg,\n    .version = \"0.1.0\",\n    .paths = .{\"\"},\n    .dev_dependencies = .{\n        .preflight = .{ .url = \"git+https://github.com/pedronaugusto/preflight#" ++ pin ++ "\", .hash = \"preflight-0.1.0-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC\" },\n    },\n}\n" else ".{\n    .name = .pkg,\n    .version = \"0.1.0\",\n    .paths = .{\"\"},\n    .dependencies = .{\n        .preflight = .{ .url = \"git+https://github.com/pedronaugusto/preflight#" ++ pin ++ "\", .hash = \"preflight-0.1.0-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC\", .lazy = true },\n    },\n}\n");
        try p.write("build.zig", "pub fn build(b: *@import(\"std\").Build) void {\n    _ = b.addModule(\"pkg\", .{ .root_source_file = b.path(\"src/a.zig\") });\n}\n");
        try p.write("src/a.zig", "pub fn run(size: usize) void {\n    _ = size;\n}\n");
        try p.write("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-01-01\n\n### Added\n\n- First.\n");
        const config = "{}\n";
        try p.write("ci/workflow.json", config);
        const parsed = (try std.json.parseFromSlice(std.json.Value, a, config, .{})).value;
        try p.write(".github/workflows/ci.yml", try workflow.render(a, parsed, pin, ".", false, if (developed == .bay) "ci/workflow.json: bay generate" else "ci/workflow.json: zig build generate", 0));
        var problem: []const u8 = "";
        try p.write(attributes.path, try attributes.render(a, &.{}, ".", &problem));
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
        return p.preflight(&.{ "gate", "--module", "build.zig=build.zig", "--module", "pkg=src/a.zig" });
    }

    /// The preflight program run in the package with `args`.
    fn preflight(p: *Package, args: []const []const u8) !std.process.RunResult {
        const program = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, test_options.preflight, p.arena.allocator());
        return std.process.run(p.arena.allocator(), std.testing.io, .{ .argv = try std.mem.concat(p.arena.allocator(), []const u8, &.{ &.{program}, args }), .cwd = .{ .dir = p.tmp.dir }, .environ_map = &p.env });
    }
};

/// The gate refused, saying `said`, and passed nothing.
fn refused(result: std.process.RunResult, said: []const u8) !void {
    if (result.term != .exited or result.term.exited != 1 or std.mem.find(u8, result.stderr, said) == null) {
        std.debug.print("expected a refusal saying:\n{s}\nstdout:\n{s}\nstderr:\n{s}\n", .{ said, result.stdout, result.stderr });
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(std.mem.find(u8, result.stdout, "gate: ") == null);
}

test "the gate refuses a public declaration changed with no breaking entry" {
    const p = try Package.init();
    defer p.deinit();
    try p.write("src/a.zig", "pub fn run(size: u32) void {\n    _ = size;\n}\n");
    try p.write("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n### Changed\n\n- A smaller size.\n\n## [0.1.0] - 2026-01-01\n\n### Added\n\n- First.\n");
    try p.git(&.{ "commit", "-q", "-am", "Smaller" });
    try refused(try p.gate(), "removed or changed these public declarations");
}

test "the gate refuses a repository whose .gitattributes is missing or not what generate makes" {
    const p = try Package.init();
    defer p.deinit();
    // datapad's first ci run: no file, and a Windows checkout wrote its spec texts with CRLF.
    try p.git(&.{ "rm", "-q", attributes.path });
    try p.git(&.{ "commit", "-q", "-m", "No attributes" });
    try refused(try p.gate(), ".gitattributes is missing: what generate makes");
    // A binary path declared and the file not made again.
    try p.write(attributes.path, "* text=auto eol=lf\n");
    try p.write("ci/preflight.json", "{\"binary\":[\"testdata/**\"]}\n");
    try p.git(&.{ "add", "-A" });
    try p.git(&.{ "commit", "-q", "-m", "Bytes declared" });
    try refused(try p.gate(), ".gitattributes is not what generate makes for this package's ci/preflight.json");
}

test "the gate refuses a manifest and a CHANGELOG at different releases" {
    const p = try Package.init();
    defer p.deinit();
    try p.write("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n## [0.1.1] - 2026-01-02\n\n### Fixed\n\n- A fix.\n\n## [0.1.0] - 2026-01-01\n\n### Added\n\n- First.\n");
    try p.git(&.{ "commit", "-q", "-am", "Half a release" });
    try refused(try p.gate(), ".version is 0.1.0 and CHANGELOG.md's newest release is 0.1.1");
}

test "the gate refuses a caller that is not what generate makes for the package's configuration" {
    const p = try Package.init();
    defer p.deinit();
    try p.write("ci/workflow.json", "{\"targets\":[\"x86_64-linux-gnu\"]}\n");
    try p.git(&.{ "commit", "-q", "-am", "A target, the caller left as it was" });
    try refused(try p.gate(), ".github/workflows/ci.yml is not what generate makes for this package's pins and ci/workflow.json: run `bay generate`");
}

test "lint refuses a stale caller before a push, not first at a release's gate, and passes it once generated" {
    const p = try Package.init();
    defer p.deinit();
    const said = ".github/workflows/ci.yml is not what generate makes for this package's pins and ci/workflow.json: run `bay generate`";
    // strand's case: ci/workflow.json changed, the caller never generated again.
    try p.write("ci/workflow.json", "{\"targets\":[\"x86_64-linux-gnu\"]}\n");
    try p.git(&.{ "commit", "-q", "-am", "A target, the caller left as it was" });
    const stale = try p.preflight(&.{ "lint", "--skip-glint" });
    if (stale.term != .exited or stale.term.exited == 0 or std.mem.find(u8, stale.stderr, said) == null) {
        std.debug.print("expected lint to refuse, saying:\n{s}\nstderr:\n{s}\n", .{ said, stale.stderr });
        return error.TestUnexpectedResult;
    }
    const generated = try p.preflight(&.{"generate"});
    try std.testing.expect(generated.term == .exited and generated.term.exited == 0);
    try p.git(&.{ "commit", "-q", "-am", "Generated" });
    const current = try p.preflight(&.{ "lint", "--skip-glint" });
    if (std.mem.find(u8, current.stderr, "is not what generate makes") != null) {
        std.debug.print("lint refused a current caller:\n{s}\n", .{current.stderr});
        return error.TestUnexpectedResult;
    }
}

test "the gate changes nothing in the package: a retired key in ci/workflow.json is refused by name, and left for generate" {
    const p = try Package.init();
    defer p.deinit();
    const config = "{\"nightly\":true}\n";
    try p.write("ci/workflow.json", config);
    try p.git(&.{ "commit", "-q", "-am", "A retired trigger" });
    try refused(try p.gate(), "ci/workflow.json: `nightly` is retired: run `bay generate`, which takes it out, and commit it");
    const kept = try p.tmp.dir.readFileAlloc(std.testing.io, "ci/workflow.json", p.arena.allocator(), .limited(4096));
    try std.testing.expectEqualStrings(config, kept);
}

test "a key neither file holds is refused by name, with the file it belongs in" {
    const p = try Package.init();
    defer p.deinit();
    try p.write("ci/workflow.json", "{\"test_roots\":[\"src/a.zig\"]}\n");
    try p.git(&.{ "commit", "-q", "-am", "A source checks key in the workflow's file" });
    try refused(try p.gate(), "ci/workflow.json: refused: `test_roots` is not a key of this file: `test_roots` belongs in ci/preflight.json");
}

test "a local action the workflows use is checked wherever it lives, its own uses followed" {
    const p = try Package.init();
    defer p.deinit();
    try p.write(".github/workflows/other.yml", "name: Other\non: push\njobs:\n  one:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: ./ci/actions/setup\n      - uses: ./ci/actions/missing\n");
    try p.write("ci/actions/setup/action.yml", "name: Setup\nruns:\n  using: composite\n  steps:\n    - uses: ./ci/actions/inner\n");
    try p.write("ci/actions/inner/action.yml", "name: Inner\nruns:\n  using: composite\n  steps:\n    - uses: actions/checkout@v4\n");
    try p.git(&.{ "add", "-A" });
    try p.git(&.{ "commit", "-q", "-m", "Local actions outside .github" });
    const result = try p.gate();
    for ([_][]const u8{ "gate: ci/actions/inner/action.yml:5: `uses: actions/checkout@v4` names no commit", "gate: `uses: ./ci/actions/missing` names no action" }) |said| {
        if (std.mem.find(u8, result.stderr, said) == null) {
            std.debug.print("expected:\n{s}\nstderr:\n{s}\n", .{ said, result.stderr });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
}

test "a package without bay is told to run `zig build generate`, the command it has" {
    const p = try Package.start(.zig);
    defer p.deinit();
    try p.write("ci/workflow.json", "{\"targets\":[\"x86_64-linux-gnu\"]}\n");
    try p.git(&.{ "commit", "-q", "-am", "A target, the caller left as it was" });
    try refused(try p.gate(), ".github/workflows/ci.yml is not what generate makes for this package's pins and ci/workflow.json: run `zig build generate`");
}

test "a package carrying what a release needs passes the gate, which runs no job" {
    const p = try Package.init();
    defer p.deinit();
    const result = try p.gate();
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("stdout:\n{s}\nstderr:\n{s}\n", .{ result.stdout, result.stderr });
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(std.mem.find(u8, result.stdout, "a tag needs a green release run on its commit") != null);
}

test "generate takes the retired triggers and switches out of ci/workflow.json, naming each, and the gate passes after" {
    const p = try Package.init();
    defer p.deinit();
    try p.write("ci/workflow.json", "{\"attest\": true, \"compile_once\": true, \"cross_jobs\": 1, \"nightly\": false}\n");
    try p.git(&.{ "commit", "-q", "-am", "The old triggers" });
    const generated = try p.preflight(&.{"generate"});
    if (generated.term != .exited or generated.term.exited != 0) {
        std.debug.print("stdout:\n{s}\nstderr:\n{s}\n", .{ generated.stdout, generated.stderr });
        return error.TestUnexpectedResult;
    }
    for ([_][]const u8{ "dropped `attest`", "dropped `nightly`", "dropped `compile_once`" }) |said| try std.testing.expect(std.mem.find(u8, generated.stderr, said) != null);
    const config = try p.tmp.dir.readFileAlloc(std.testing.io, "ci/workflow.json", p.arena.allocator(), .limited(4096));
    try std.testing.expectEqualStrings("{\n  \"cross_jobs\": 1\n}\n", config);
    try p.git(&.{ "commit", "-q", "-am", "Generated" });
    const gated = try p.gate();
    if (gated.term != .exited or gated.term.exited != 0) {
        std.debug.print("stdout:\n{s}\nstderr:\n{s}\n", .{ gated.stdout, gated.stderr });
        return error.TestUnexpectedResult;
    }
}

test "the documented snippets are checked on their own, a broken one named where the lint refuses its configuration" {
    const p = try Package.init();
    defer p.deinit();
    // A configuration glint 0.8 refuses (A002 is a rule it no longer has), and a README block
    // that is not what its example makes: the snippets are judged all the same.
    try p.write("ci/preflight.json", "{\"glint\":{\"rules\":[{\"id\":\"A002\",\"level\":\"gate\"}]},\"docs\":{\"usage\":{\"source\":\"usage.zig\",\"region\":\"usage\",\"module\":\"pkg\"}}}\n");
    try p.write("usage.zig", "const pkg = @import(\"pkg\");\npub fn main() void {\n    // --- README:usage ---\n    pkg.run(1);\n    // --- README:usage ---\n}\n");
    try p.write("README.md", "<!-- BEGIN GENERATED usage -->\nstale\n<!-- END GENERATED -->\n");
    const stale = try p.preflight(&.{"snippets"});
    try std.testing.expect(stale.term == .exited and stale.term.exited != 0);
    try std.testing.expect(std.mem.find(u8, stale.stderr, "README.md: generated block 'usage' differs from its example") != null);
    // Written as the example makes it, the snippets pass, whatever the lint says of the rest.
    try p.write("README.md", "<!-- BEGIN GENERATED usage -->\n```zig\nconst pkg = @import(\"pkg\");\n\npkg.run(1);\n```\n<!-- END GENERATED -->\n");
    const current = try p.preflight(&.{"snippets"});
    if (current.term != .exited or current.term.exited != 0) {
        std.debug.print("stdout:\n{s}\nstderr:\n{s}\n", .{ current.stdout, current.stderr });
        return error.TestUnexpectedResult;
    }
}
