//! What a release is checked against, by the gate before its jobs and by the lint on every
//! commit: the manifest's version is the CHANGELOG's newest release, and the CHANGELOG says
//! what changed in the package's public API since its last tag, breaking where the API diff
//! says so. bay releases (`bay release`); preflight only verifies, reading CHANGELOG.md with
//! bay's own reader of it.
const std = @import("std");
const aegis = @import("aegis");
const changelog = @import("changelog");
const src = @import("source.zig");
const zon = @import("../zon.zig");
const surface = @import("surface.zig");

const Manifest = struct { version: []const u8 };

fn parseManifest(c: *src.Context, text: []const u8) !Manifest {
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(
        Manifest,
        .{
            .gpa = c.a,
            .arena = c.a,
            .source = (try zon.source(c.a, text)) orelse {
                c.fail("build.zig.zon: not UTF-8", .{});
                return error.InvalidManifest;
            },
            .diagnostics = &diagnostics,
            .ignore_unknown_fields = true,
        },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            c.fail("{f}", .{diagnostics.fmt("build.zig.zon")});
            return error.InvalidManifest;
        },
    };
}

/// The package's version as `build.zig.zon` declares it: what a tag of the commit names.
pub fn declared(c: *src.Context) !std.SemanticVersion {
    const manifest = try parseManifest(c, try c.read("build.zig.zon"));
    return changelog.parseVersion(manifest.version) orelse {
        c.fail("build.zig.zon: .version \"{s}\" is not major.minor.patch", .{manifest.version});
        return error.InvalidVersion;
    };
}

/// The version `build.zig.zon` declares is the changelog's newest release:
/// what a tag of this commit names, which a fetch of it names itself by.
/// A release cut by hand that set one and not the other is refused here,
/// in every gate, before its tag is made or after (uplink 0.9.0 and 0.9.1
/// were tagged with the manifest at 0.8.7). A package that has released
/// nothing yet has nothing to match.
pub fn versionAgrees(c: *src.Context) !void {
    if (!try c.exists("CHANGELOG.md")) return;
    const newest = changelog.newestReleased(try c.read("CHANGELOG.md")) orelse return;
    const version = declared(c) catch |err| switch (err) {
        // It named its fix.
        error.InvalidVersion, error.InvalidManifest => return,
        else => return err,
    };
    if (version.order(newest) == .eq) return;
    c.fail("build.zig.zon: .version is {f} and CHANGELOG.md's newest release is {f}; a tag of this commit names the one the manifest declares, so set them to one release (`bay release` sets both)", .{ version, newest });
}

/// The CHANGELOG against the package's public API since its last tag: a change to the surface
/// of `modules` (the modules the package exports, and its `build.zig`) needs an entry in
/// `[Unreleased]` or in a release made since, and a removed or changed public declaration a
/// breaking one (`### Breaking` or `### Removed`). Each failure names its fix. A package with
/// no tag yet, or none in this clone's history, has no surface to compare with.
pub fn changelogNamesChanges(c: *src.Context, modules: []const surface.Module) !void {
    if (!try c.exists("CHANGELOG.md") or modules.len == 0) return;
    const tag = try lastTag(c.*) orelse return;
    const since = changelog.parseVersion(std.mem.trimStart(u8, tag, "v"));
    var problem: changelog.Problem = undefined;
    const said = changelog.changedSince(c.a, try c.read("CHANGELOG.md"), since, &problem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoUnreleased => {
            c.fail("CHANGELOG.md: no `## [Unreleased]` section; add one, for what changes next", .{});
            return;
        },
        error.Malformed => {
            c.fail("CHANGELOG.md:{d}: {s}", .{ problem.line, problem.what });
            return;
        },
    };
    const gone = try surfaceRemoved(c, tag, modules);
    if (gone.len != 0 and said != .breaking) {
        c.fail("CHANGELOG.md: since {s} the package removed or changed these public declarations, and no entry since says what breaks; name it under ### Breaking (`surface -- --since {s}` lists them):{s}", .{ tag, tag, try listed(c.a, gone) });
        return;
    }
    if (said != .none) return;
    const added = try surfaceAdded(c, tag, modules);
    if (added.len != 0) c.fail("CHANGELOG.md: since {s} the package added these public declarations, and [Unreleased] names nothing; say what they are under ### Added:{s}", .{ tag, try listed(c.a, added) });
}

/// Up to 20 of `lines`, each on a line of its own, and how many more.
fn listed(a: std.mem.Allocator, lines: []const []const u8) ![]const u8 {
    const shown = @min(lines.len, 20);
    var out: std.Io.Writer.Allocating = .init(a);
    for (lines[0..shown]) |line| try out.writer.print("\n  {s}", .{line});
    if (lines.len > shown) try out.writer.print("\n  and {d} more", .{lines.len - shown});
    return out.written();
}

fn git(c: src.Context, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(c.a, c.io, .{ .argv = argv, .cwd = c.childCwd(), .environ_map = c.environ_map });
}

fn succeeded(result: std.process.RunResult) bool {
    return result.term == .exited and result.term.exited == 0;
}

/// The newest `v*` tag reachable from the commit, or null before the first release.
pub fn lastTag(c: src.Context) !?[]const u8 {
    const result = try git(c, &.{ "git", "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*" });
    if (!succeeded(result)) return null;
    return std.mem.trim(u8, result.stdout, " \r\n");
}

/// The lines of the public surface `tag` had that the working tree does not: the public
/// declarations removed or changed since. The modules are the ones the package exports now,
/// read at `tag` from the same root files.
pub fn surfaceRemoved(c: *src.Context, tag: []const u8, modules: []const surface.Module) ![]const []const u8 {
    return surface.removed(c.a, try surfaceAt(c, tag, modules), try surfaceOf(c, modules));
}

/// The lines of the working tree's public surface that `tag`'s did not have: declarations added.
pub fn surfaceAdded(c: *src.Context, tag: []const u8, modules: []const surface.Module) ![]const []const u8 {
    return surface.removed(c.a, try surfaceOf(c, modules), try surfaceAt(c, tag, modules));
}

/// The working tree's public surface.
pub fn surfaceOf(c: *src.Context, modules: []const surface.Module) ![]const []const u8 {
    return surface.list(c.a, c.a, c.io, modules, Tree{ .c = c });
}

fn surfaceAt(c: *src.Context, revision: []const u8, modules: []const surface.Module) ![]const []const u8 {
    return surface.list(c.a, c.a, c.io, modules, Revision{ .c = c, .name = revision });
}

/// The package's files as the working tree holds them.
pub const Tree = struct {
    c: *const src.Context,

    pub fn read(tree: Tree, a: std.mem.Allocator, path: []const u8) !?[]const u8 {
        if (!try tree.c.exists(path)) return null;
        return try a.dupe(u8, try tree.c.read(path));
    }
};

/// The package's files as a revision holds them.
pub const Revision = struct {
    c: *const src.Context,
    name: []const u8,

    pub fn read(at: Revision, a: std.mem.Allocator, path: []const u8) !?[]const u8 {
        const result = try git(at.c.*, &.{ "git", "show", try a.print("{s}:./{s}", .{ at.name, path }) });
        if (!succeeded(result)) return null;
        return result.stdout;
    }
};

// Tests ------------------------------------------------------------------

// A package in a temporary directory with a git history of its own, away from the user's git configuration.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,
    arena: std.heap.ArenaAllocator,
    /// What a failed decision reports, kept here so that a passing test prints nothing.
    held: std.Io.Writer.Allocating,

    fn init(version: []const u8) !*Fixture {
        const f = try std.testing.allocator.create(Fixture);
        f.arena = .init(std.testing.allocator);
        f.held = .init(std.testing.allocator);
        f.tmp = std.testing.tmpDir(.{});
        f.env = try std.testing.environ.createMap(f.arena.allocator());
        try f.env.put("GIT_CONFIG_NOSYSTEM", "1");
        try f.env.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try f.env.put("HOME", try f.tmp.dir.realPathFileAlloc(std.testing.io, ".", f.arena.allocator()));
        try f.write("build.zig.zon", try f.arena.allocator().print(".{{\n    .name = .pkg,\n    .version = \"{s}\",\n    .paths = .{{ \"build.zig\", \"build.zig.zon\", \"src\", \"CHANGELOG.md\" }},\n}}\n", .{version}));
        try f.write("build.zig", "pub fn build(_: *@import(\"std\").Build) void {}\n");
        try f.write("src/a.zig", "pub const a = 1;\n");
        try f.write("bench/b.zig", "pub const b = 1;\n");
        try f.write("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-01-01\n\n- First.\n\n[Unreleased]: https://github.com/o/r/compare/v0.1.0...HEAD\n[0.1.0]: https://github.com/o/r/releases/tag/v0.1.0\n");
        try f.git(&.{ "init", "-q", "-b", "main" });
        try f.commit("First");
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
        f.held.deinit();
        f.arena.deinit();
        std.testing.allocator.destroy(f);
    }

    fn write(f: *Fixture, path: []const u8, data: []const u8) !void {
        if (std.Io.Dir.path.dirname(path)) |dir| try f.tmp.dir.createDirPath(std.testing.io, dir);
        try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }

    fn git(f: *Fixture, args: []const []const u8) !void {
        const a = f.arena.allocator();
        const argv = try std.mem.concat(a, []const u8, &.{ &.{ "git", "-c", "user.name=Preflight", "-c", "user.email=preflight@example.invalid", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false" }, args });
        const result = try std.process.run(a, std.testing.io, .{ .argv = argv, .cwd = .{ .dir = f.tmp.dir }, .environ_map = &f.env });
        if (!succeeded(result)) return error.FixtureGitFailed;
    }

    fn commit(f: *Fixture, message: []const u8) !void {
        try f.git(&.{ "add", "-A" });
        try f.git(&.{ "commit", "-q", "-m", message });
    }

    fn context(f: *Fixture) src.Context {
        return .{ .a = f.arena.allocator(), .io = std.testing.io, .dir = f.tmp.dir, .environ_map = &f.env, .held = &f.held };
    }

    fn read(f: *Fixture, path: []const u8) ![]const u8 {
        return aegis.own.readFile(std.testing.io, f.tmp.dir, path, f.arena.allocator(), .fromRaw(1 << 20));
    }

    fn unreleased(f: *Fixture, body: []const u8) !void {
        const text = try f.arena.allocator().print("# Changelog\n\n## [Unreleased]\n\n{s}\n## [0.1.0] - 2026-01-01\n\n- First.\n\n[Unreleased]: https://github.com/o/r/compare/v0.1.0...HEAD\n[0.1.0]: https://github.com/o/r/releases/tag/v0.1.0\n", .{body});
        try f.write("CHANGELOG.md", text);
    }
};

test "the declared version is read from the manifest" {
    const f = try Fixture.init("2.0.7");
    defer f.deinit();
    var c = f.context();
    try std.testing.expectEqual(std.SemanticVersion{ .major = 2, .minor = 0, .patch = 7 }, try declared(&c));
    try f.write("build.zig.zon", ".{ .name = .pkg, .version = \"2.0\", .paths = .{\"\"} }\n");
    try std.testing.expectError(error.InvalidVersion, declared(&c));
    try std.testing.expectEqual(@as(usize, 1), c.errors);
}

test "a manifest and a CHANGELOG at different releases are refused, naming both" {
    const f = try Fixture.init("0.1.1");
    defer f.deinit();
    var c = f.context();
    try versionAgrees(&c);
    try std.testing.expectEqual(@as(usize, 1), c.errors);
    try std.testing.expect(std.mem.find(u8, f.held.written(), ".version is 0.1.1 and CHANGELOG.md's newest release is 0.1.0") != null);
}

const package_modules = [_]surface.Module{.{ .name = "pkg", .root = "src/a.zig" }};

/// A package tagged v0.1.0 whose `src/a.zig`, its module's root, declares `run`.
fn tagged() !*Fixture {
    const f = try Fixture.init("0.1.0");
    try f.write("src/a.zig", "pub const a = 1;\npub fn run(size: usize) void { _ = size; }\n");
    try f.commit("Run");
    try f.git(&.{ "tag", "v0.1.0" });
    return f;
}

test "a changed public declaration needs a breaking entry, in [Unreleased] or in a release since the tag" {
    const f = try tagged();
    defer f.deinit();
    try f.write("src/a.zig", "pub const a = 1;\npub fn run(size: u32) void { _ = size; }\n");
    try f.unreleased("### Changed\n\n- A smaller size.\n");
    try f.commit("Change");
    var c = f.context();
    try changelogNamesChanges(&c, &package_modules);
    try std.testing.expectEqual(@as(usize, 1), c.errors);
    try std.testing.expect(std.mem.find(u8, f.held.written(), "pkg.run fn ( usize ) void") != null);
    try f.unreleased("### Breaking\n\n- `run` takes a `u32`.\n");
    var said = f.context();
    try changelogNamesChanges(&said, &package_modules);
    try std.testing.expectEqual(@as(usize, 0), said.errors);
    // Released and not yet tagged, as `bay release` gates it: the release says it.
    try f.write("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n## [0.2.0] - 2026-03-04\n\n### Breaking\n\n- `run` takes a `u32`.\n\n## [0.1.0] - 2026-01-01\n\n- First.\n");
    var released = f.context();
    try changelogNamesChanges(&released, &package_modules);
    try std.testing.expectEqual(@as(usize, 0), released.errors);
}

test "an added public declaration needs an entry; one that only adds needs no breaking one" {
    const f = try tagged();
    defer f.deinit();
    try f.write("src/a.zig", "pub const a = 1;\npub fn run(length: usize) void { _ = length; }\npub fn more() void {}\n");
    try f.commit("More");
    var c = f.context();
    try changelogNamesChanges(&c, &package_modules);
    try std.testing.expectEqual(@as(usize, 1), c.errors);
    try std.testing.expect(std.mem.find(u8, f.held.written(), "added these public declarations") != null);
    try f.unreleased("### Added\n\n- `more`.\n");
    var said = f.context();
    try changelogNamesChanges(&said, &package_modules);
    try std.testing.expectEqual(@as(usize, 0), said.errors);
}

test "a change inside a function, and a package with no tag, need nothing; an entry under no group is refused" {
    const f = try tagged();
    defer f.deinit();
    try f.write("src/a.zig", "pub const a = 1;\npub fn run(size: usize) void { _ = size + 1; }\n");
    try f.commit("Inside");
    var c = f.context();
    try changelogNamesChanges(&c, &package_modules);
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    try f.unreleased("- Loose.\n");
    var loose = f.context();
    try changelogNamesChanges(&loose, &package_modules);
    try std.testing.expectEqual(@as(usize, 1), loose.errors);
    try std.testing.expect(std.mem.find(u8, f.held.written(), "CHANGELOG.md:5: an entry under no group") != null);
    const fresh = try Fixture.init("0.1.0");
    defer fresh.deinit();
    try fresh.write("src/a.zig", "pub fn gone() void {}\n");
    var untagged = fresh.context();
    try changelogNamesChanges(&untagged, &package_modules);
    try std.testing.expectEqual(@as(usize, 0), untagged.errors);
}
