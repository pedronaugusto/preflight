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
/// breaking one (`### Breaking` or `### Removed`). Each failure names its fix. A package that
/// has released nothing has no surface to compare with; one whose release tag this clone
/// lacks fails (`lastTag`).
pub fn changelogNamesChanges(c: *src.Context, modules: []const surface.Module) !void {
    if (!try c.exists("CHANGELOG.md") or modules.len == 0) return;
    const tag = (lastTag(c, try c.read("CHANGELOG.md")) catch |err| switch (err) {
        error.HistoryUnreadable, error.ReleaseUnnamed => return,
        else => return err,
    }) orelse return;
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
    // Reported where it was found.
    const gone = surfaceRemoved(c, tag, modules) catch |err| switch (err) {
        error.SurfaceUnreadable, error.HistoryUnreadable => return,
        else => return err,
    };
    if (gone.len != 0 and said != .breaking) {
        c.fail("CHANGELOG.md: since {s} the package removed or changed these public declarations, and no entry since says what breaks; name it under ### Breaking (`surface -- --since {s}` lists them):{s}", .{ tag, tag, try listed(c.a, gone) });
        return;
    }
    // Each one is named where it breaks, so the CHANGELOG tells a user every one: one entry
    // covered them all.
    const breaking = try breakingSince(c.a, try c.read("CHANGELOG.md"), since);
    var unnamed: std.ArrayList([]const u8) = .empty;
    for (gone) |line| if (!namesCode(breaking, declarationPath(line, modules), modules)) try unnamed.append(c.a, line);
    if (unnamed.items.len != 0) {
        c.fail("CHANGELOG.md: since {s} the package removed or changed these public declarations, and no ### Breaking or ### Removed entry since names them; name each there in code form, with its container (`S.field`, `S.run`):{s}", .{ tag, try listed(c.a, unnamed.items) });
        return;
    }
    if (said != .none) return;
    const added = surfaceAdded(c, tag, modules) catch |err| switch (err) {
        error.SurfaceUnreadable, error.HistoryUnreadable => return,
        else => return err,
    };
    if (added.len != 0) c.fail("CHANGELOG.md: since {s} the package added these public declarations or changed these constants, and [Unreleased] names nothing; say what they are under ### Added or ### Changed:{s}", .{ tag, try listed(c.a, added) });
}

/// The entries under `### Breaking` and `### Removed` in `[Unreleased]` and in each release
/// newer than `since`, as one text.
fn breakingSince(a: std.mem.Allocator, text: []const u8, since: ?std.SemanticVersion) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var in_range = false;
    var in_group = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "## [")) {
            const end = std.mem.findScalar(u8, line, ']') orelse line.len;
            const name = line["## [".len..end];
            in_range = if (std.mem.eql(u8, name, "Unreleased")) true else if (changelog.parseVersion(name)) |version| (since == null or version.order(since.?) == .gt) else false;
            in_group = false;
        } else if (std.mem.startsWith(u8, line, "### ")) {
            const heading = std.mem.trim(u8, line["### ".len..], " \t\r");
            in_group = std.mem.eql(u8, heading, "Breaking") or std.mem.eql(u8, heading, "Removed");
        } else if (in_range and in_group) {
            try out.writer.print("{s}\n", .{line});
        }
    }
    return out.toOwnedSlice();
}

/// The declaration a surface line names, below its module (`pkg.S.run fn ...` is `S.run`): its
/// path, with the container that holds it.
fn declarationPath(line: []const u8, modules: []const surface.Module) []const u8 {
    const path = line[0 .. std.mem.findScalar(u8, line, ' ') orelse line.len];
    for (modules) |module| {
        if (path.len > module.name.len and std.mem.startsWith(u8, path, module.name) and path[module.name.len] == '.') return path[module.name.len + 1 ..];
    }
    // A module the package no longer exports: its name has no dot of its own.
    return path[if (std.mem.findScalar(u8, path, '.')) |dot| dot + 1 else 0..];
}

/// Whether `text` names the declaration at `path` in code form: a code span holding the path
/// (`S.run`), its module's name before it (`pkg.S.run`), or either with its parameters after it
/// (`S.run(size: u32)`). A word in prose is not a name: `y` names no field `S.y`.
fn namesCode(text: []const u8, path: []const u8, modules: []const surface.Module) bool {
    if (path.len == 0) return false;
    var spans = std.mem.splitScalar(u8, text, '`');
    // The text before the first backtick is prose; then code and prose take turns.
    _ = spans.next();
    while (spans.next()) |span| {
        const named = std.mem.trim(u8, span[0 .. std.mem.findScalar(u8, span, '(') orelse span.len], " ");
        if (std.mem.eql(u8, named, path)) return true;
        for (modules) |module| {
            if (named.len == module.name.len + 1 + path.len and std.mem.startsWith(u8, named, module.name) and named[module.name.len] == '.' and std.mem.endsWith(u8, named, path)) return true;
        }
        _ = spans.next() orelse break;
    }
    return false;
}

test "a breaking entry names a declaration in code form, with its container" {
    const modules = [_]surface.Module{ .{ .name = "pkg", .root = "src/a.zig" }, .{ .name = "build.zig", .root = "build.zig" } };
    try std.testing.expectEqualStrings("run", declarationPath("pkg.run fn ( usize ) void", &modules));
    try std.testing.expectEqualStrings("S.x", declarationPath("pkg.S.x u32", &modules));
    try std.testing.expectEqualStrings("Config.bench", declarationPath("build.zig.Config.bench ?Bench", &modules));
    try std.testing.expectEqualStrings("T.y", declarationPath("gone.T.y u8", &modules));
    try std.testing.expect(namesCode("- `run` takes a size.\n", "run", &modules));
    try std.testing.expect(namesCode("- `run(size: u32)` takes a smaller size.\n", "run", &modules));
    try std.testing.expect(namesCode("- `pkg.S.x` is gone.\n", "S.x", &modules));
    // A prose word, a field named without its container, another container, a longer name.
    try std.testing.expect(!namesCode("- The x axis is gone; run it again.\n", "S.x", &modules));
    try std.testing.expect(!namesCode("- `x` is gone.\n", "S.x", &modules));
    try std.testing.expect(!namesCode("- `T.S.x` is gone.\n", "S.x", &modules));
    try std.testing.expect(!namesCode("- `runner` takes a size.\n", "run", &modules));
    // The text between two spans is prose.
    try std.testing.expect(!namesCode("- `a` and run and `b`.\n", "run", &modules));
    const text = "# Changelog\n\n## [Unreleased]\n\n### Breaking\n\n- `a` is gone.\n\n### Added\n\n- `b`.\n\n## [0.2.0] - 2026-02-01\n\n### Removed\n\n- `c`.\n\n## [0.1.0] - 2026-01-01\n\n### Breaking\n\n- `d`.\n";
    const said = try breakingSince(std.testing.allocator, text, changelog.parseVersion("0.1.0"));
    defer std.testing.allocator.free(said);
    for ([_][]const u8{ "a", "c" }) |name| try std.testing.expect(namesCode(said, name, &modules));
    for ([_][]const u8{ "b", "d" }) |name| try std.testing.expect(!namesCode(said, name, &modules));
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

/// The release tag the surface is compared with: the newest `v<version>` tag in the commit's
/// history, whatever `CHANGELOG.md` (`text`) says, for git records what was released and the
/// text may say otherwise. The tags are the releases of the package at the repository's top;
/// one below it (a sample, a fixture) has none. A commit that releases, before its tag is made,
/// is so compared with the release before. The text must name that release (`## [X.Y.Z]`): the
/// entries since it are what the comparison reads, and a text naming no release that resolves
/// to a tag fails, as does one naming a release while history holds no tag. Null before the
/// first release (neither a tag nor a release) and on the commit that makes it. A shallow clone
/// and git failing fail too, reported: each would compare the surface with nothing, which
/// passes (a clone fetched without tags passed so).
pub fn lastTag(c: *src.Context, text: []const u8) !?[]const u8 {
    const shallow = try must(c, &.{ "git", "rev-parse", "--is-shallow-repository" });
    if (std.mem.eql(u8, shallow, "true")) {
        c.fail("git: this clone is shallow, so the last release tag may be missing from its history: fetch it whole (`git fetch --unshallow`)", .{});
        return error.HistoryUnreadable;
    }
    var newest: ?struct { name: []const u8, version: std.SemanticVersion } = null;
    // The `v*` tags are the releases of the package at the repository's top: one below it (a
    // sample, a fixture) has none of its own.
    const below = (try must(c, &.{ "git", "rev-parse", "--show-prefix" })).len != 0;
    var tags = std.mem.splitScalar(u8, if (below) "" else try must(c, &.{ "git", "tag", "--list", "--merged", "HEAD", "v*" }), '\n');
    while (tags.next()) |line| {
        const name = std.mem.trim(u8, line, " \r");
        if (!std.mem.startsWith(u8, name, "v")) continue;
        const version = changelog.parseVersion(name["v".len..]) orelse continue;
        if (newest == null or version.order(newest.?.version) == .gt) newest = .{ .name = name, .version = version };
    }
    var releases = releasesOf(text);
    const tag = newest orelse {
        const named = releases.next() orelse return null;
        // The commit that makes the first release, before its tag: Unreleased empty, one release.
        var problem: changelog.Problem = undefined;
        const releasing = if (changelog.unreleased(c.a, text, &problem)) |section| section.empty() else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // changelogNamesChanges reports what is wrong with it.
            error.NoUnreleased, error.Malformed => false,
        };
        if (releasing and releases.next() == null) return null;
        c.fail("git: CHANGELOG.md's release {f} has no tag v{f} in this clone's history, so the surface has nothing to be compared with: fetch the tags (`git fetch --tags`)", .{ named, named });
        return error.HistoryUnreadable;
    };
    while (releases.next()) |release| if (release.order(tag.version) == .eq) return tag.name;
    c.fail("CHANGELOG.md: the newest release tag in this commit's history is {s}, and no `## [{f}] - <date>` heading names it, so what changed since cannot be read; record each release under its version", .{ tag.name, tag.version });
    return error.ReleaseUnnamed;
}

/// The releases `CHANGELOG.md` records, newest first: its `## [X.Y.Z]` headings.
fn releasesOf(text: []const u8) Releases {
    return .{ .lines = std.mem.splitScalar(u8, text, '\n') };
}

const Releases = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    fn next(r: *Releases) ?std.SemanticVersion {
        while (r.lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "## [")) continue;
            const end = std.mem.findScalar(u8, line, ']') orelse continue;
            return changelog.parseVersion(line["## [".len..end]) orelse continue;
        }
        return null;
    }
};

/// What git wrote, trimmed, when it succeeded; else what it said is reported, and the
/// history is unreadable.
fn must(c: *src.Context, argv: []const []const u8) ![]const u8 {
    const result = try git(c.*, argv);
    if (succeeded(result)) return std.mem.trim(u8, result.stdout, " \r\n");
    c.fail("{s}: {s}", .{ try std.mem.join(c.a, " ", argv), std.mem.trim(u8, result.stderr, " \r\n") });
    return error.HistoryUnreadable;
}

/// The lines of the public surface `tag` had that the working tree does not: the public
/// declarations removed or changed since, each module read where `tag`'s `build.zig` rooted it,
/// so a module moved or gone is compared too. `configured` is what the configured build
/// exports now (`modulesSince`).
pub fn surfaceRemoved(c: *src.Context, tag: []const u8, configured: []const surface.Module) ![]const []const u8 {
    const modules = try modulesSince(c, tag, configured);
    return surface.removed(c.a, try surfaceAt(c, tag, modules.then), try surfaceOf(c, modules.now));
}

/// The lines of the working tree's public surface that `tag`'s did not have: declarations added,
/// and constants whose value changed.
pub fn surfaceAdded(c: *src.Context, tag: []const u8, configured: []const surface.Module) ![]const []const u8 {
    const modules = try modulesSince(c, tag, configured);
    return surface.added(c.a, try surfaceAt(c, tag, modules.then), try surfaceOf(c, modules.now));
}

/// The modules the package exported at `tag` and exports now, each read from its `build.zig`
/// (`surface.declaredModules`). Each module the configured build exports must be one the text
/// says, or the text is not the whole of it, and the tag's cannot be read from its text either.
fn modulesSince(c: *src.Context, tag: []const u8, configured: []const surface.Module) !struct { then: []const surface.Module, now: []const surface.Module } {
    const literal = "`b.addModule(\"name\", .{ .root_source_file = b.path(\"src/root.zig\") })`";
    const now = try surface.declaredModules(c.a, try c.read("build.zig")) orelse {
        c.fail("build.zig: an `addModule` names its module or its root through other than a literal ({s}), so what {s} exported cannot be read beside it", .{ literal, tag });
        return error.SurfaceUnreadable;
    };
    for (configured) |module| {
        for (now) |said| {
            if (std.mem.eql(u8, said.name, module.name) and std.mem.eql(u8, said.root, module.root)) break;
        } else {
            c.fail("build.zig exports {s} (rooted at {s}) where no `addModule` in it says so ({s}), so what {s} exported cannot be read from its text", .{ module.name, module.root, literal, tag });
            return error.SurfaceUnreadable;
        }
    }
    const text = try (Revision{ .c = c, .name = tag }).read(c.a, "build.zig") orelse return .{ .then = &.{}, .now = now };
    const then = try surface.declaredModules(c.a, text) orelse {
        c.fail("build.zig at {s}: an `addModule` names its module or its root through other than a literal ({s}), so what {s} exported cannot be read", .{ tag, literal, tag });
        return error.SurfaceUnreadable;
    };
    return .{ .then = then, .now = now };
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

/// The package's files as a revision holds them. A file the revision does not hold is null; git
/// failing otherwise is an error, reported, never a file that is not there.
pub const Revision = struct {
    c: *src.Context,
    name: []const u8,

    pub fn read(at: Revision, a: std.mem.Allocator, path: []const u8) !?[]const u8 {
        if ((try must(at.c, &.{ "git", "ls-tree", "--name-only", at.name, "--", path })).len == 0) return null;
        const result = try git(at.c.*, &.{ "git", "show", try a.print("{s}:./{s}", .{ at.name, path }) });
        if (!succeeded(result)) {
            at.c.fail("git show {s}:./{s}: {s}", .{ at.name, path, std.mem.trim(u8, result.stderr, " \r\n") });
            return error.HistoryUnreadable;
        }
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
        try f.write("build.zig", "pub fn build(b: *@import(\"std\").Build) void {\n    _ = b.addModule(\"pkg\", .{ .root_source_file = b.path(\"src/a.zig\") });\n}\n");
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

test "a module moved or gone since the tag is compared where the tag's build rooted it" {
    const f = try tagged();
    defer f.deinit();
    // The module's root moves, and `run` with it is gone.
    try f.write("src/b.zig", "pub const a = 1;\n");
    try f.write("build.zig", "pub fn build(b: *@import(\"std\").Build) void {\n    _ = b.addModule(\"pkg\", .{ .root_source_file = b.path(\"src/b.zig\") });\n}\n");
    try f.unreleased("### Changed\n\n- The root is b.zig.\n");
    try f.commit("Move");
    const moved = [_]surface.Module{.{ .name = "pkg", .root = "src/b.zig" }};
    var c = f.context();
    try changelogNamesChanges(&c, &moved);
    try std.testing.expectEqual(@as(usize, 1), c.errors);
    try std.testing.expect(std.mem.find(u8, f.held.written(), "pkg.run fn ( usize ) void") != null);
    // The module no longer exported at all: each of its lines is gone.
    try f.write("build.zig", "pub fn build(_: *@import(\"std\").Build) void {}\n");
    try f.commit("Drop");
    var dropped = f.context();
    try changelogNamesChanges(&dropped, &.{.{ .name = "build.zig", .root = "build.zig" }});
    try std.testing.expectEqual(@as(usize, 1), dropped.errors);
    try std.testing.expect(std.mem.find(u8, f.held.written(), "pkg.a const") != null);
    // A module the configured build exports and the text does not say cannot be compared.
    var unsaid = f.context();
    try changelogNamesChanges(&unsaid, &package_modules);
    try std.testing.expectEqual(@as(usize, 1), unsaid.errors);
    try std.testing.expect(std.mem.find(u8, f.held.written(), "where no `addModule` in it says so") != null);
}

test "a release whose tag the clone lacks fails; a commit that releases is compared with the release before" {
    const f = try tagged();
    defer f.deinit();
    // Work after 0.1.0 in a clone without its tag: the removal would pass unseen (review-1029 M7).
    try f.write("src/a.zig", "pub const a = 1;\n");
    try f.unreleased("### Fixed\n\n- x.\n");
    try f.commit("Remove run");
    try f.git(&.{ "tag", "-d", "v0.1.0" });
    var lacking = f.context();
    try changelogNamesChanges(&lacking, &package_modules);
    try std.testing.expectEqual(@as(usize, 1), lacking.errors);
    try std.testing.expect(std.mem.find(u8, f.held.written(), "release 0.1.0 has no tag v0.1.0 in this clone's history") != null);
    // The commit that releases 0.2.0, before its tag is made, is compared with 0.1.0's.
    try f.git(&.{ "tag", "v0.1.0", "HEAD~1" });
    try f.write("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n## [0.2.0] - 2026-02-01\n\n### Fixed\n\n- x.\n\n## [0.1.0] - 2026-01-01\n\n- First.\n");
    try f.commit("Release v0.2.0");
    var releasing = f.context();
    try changelogNamesChanges(&releasing, &package_modules);
    try std.testing.expectEqual(@as(usize, 1), releasing.errors);
    try std.testing.expect(std.mem.find(u8, f.held.written(), "since v0.1.0 the package removed or changed") != null);
}

test "the newest tag in history is the base whatever the headings say, and a CHANGELOG must name it" {
    const f = try tagged();
    defer f.deinit();
    try f.write("src/a.zig", "pub const a = 1;\n");
    // Headings that name no release resolving to the tag: without brackets, with a v, or none
    // (review-1029b N8). Each would leave the removal unseen.
    for ([_][]const u8{
        "# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- x.\n\n## 0.1.0 - 2026-01-01\n\n- First.\n",
        "# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- x.\n\n## [v0.1.0] - 2026-01-01\n\n- First.\n",
        "# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- x.\n",
    }) |text| {
        f.held.clearRetainingCapacity();
        try f.write("CHANGELOG.md", text);
        var c = f.context();
        try changelogNamesChanges(&c, &package_modules);
        try std.testing.expectEqual(@as(usize, 1), c.errors);
        try std.testing.expect(std.mem.find(u8, f.held.written(), "the newest release tag in this commit's history is v0.1.0, and no `## [0.1.0] - <date>` heading names it") != null);
    }
    // A heading for a release never tagged does not move the base: the removal since v0.1.0 is
    // still seen.
    f.held.clearRetainingCapacity();
    try f.write("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n## [0.3.0] - 2026-03-01\n\n### Fixed\n\n- x.\n\n## [0.1.0] - 2026-01-01\n\n- First.\n");
    try f.commit("Remove run");
    var untagged = f.context();
    try changelogNamesChanges(&untagged, &package_modules);
    try std.testing.expectEqual(@as(usize, 1), untagged.errors);
    try std.testing.expect(std.mem.find(u8, f.held.written(), "since v0.1.0 the package removed or changed") != null);
    // A package below the repository's top, as a sample is, has no tags of its own: the
    // repository's are its top package's.
    f.held.clearRetainingCapacity();
    for ([_][]const u8{ "build.zig", "build.zig.zon", "src/a.zig" }) |path| try f.write(try f.arena.allocator().print("sample/{s}", .{path}), try f.read(path));
    try f.write("sample/CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n### Added\n\n- A sample.\n");
    try f.commit("Sample");
    var sample = f.context();
    sample.dir = try f.tmp.dir.openDir(std.testing.io, "sample", .{});
    defer sample.dir.?.close(std.testing.io);
    try changelogNamesChanges(&sample, &package_modules);
    try std.testing.expectEqual(@as(usize, 0), sample.errors);
}

test "a shallow clone and a failing git are errors, never a surface compared with nothing" {
    const f = try tagged();
    defer f.deinit();
    const origin = try f.tmp.dir.realPathFileAlloc(std.testing.io, ".", f.arena.allocator());
    try f.git(&.{ "clone", "--quiet", "--depth", "1", try f.arena.allocator().print("file://{s}", .{origin}), "shallow" });
    var shallow = f.context();
    shallow.dir = try f.tmp.dir.openDir(std.testing.io, "shallow", .{});
    defer shallow.dir.?.close(std.testing.io);
    try changelogNamesChanges(&shallow, &package_modules);
    try std.testing.expectEqual(@as(usize, 1), shallow.errors);
    try std.testing.expect(std.mem.find(u8, f.held.written(), "this clone is shallow") != null);
    var c = f.context();
    try std.testing.expectError(error.HistoryUnreadable, surfaceRemoved(&c, "v9.9.9", &package_modules));
    try std.testing.expectEqual(@as(usize, 1), c.errors);
}
