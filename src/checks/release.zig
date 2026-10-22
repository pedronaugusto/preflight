//! `preflight release`: the version a landing gives a package that changed.
//!
//! The version is decided from what the package says it changed: the CHANGELOG's
//! `[Unreleased]` headings. A `### Breaking` entry bumps the minor below 1.0 and
//! the major from 1.0; anything else bumps the patch. The command rewrites
//! `build.zig.zon` and `CHANGELOG.md` and nothing else, so the commit it leaves
//! is the one the gate tests and the landing tags.
const std = @import("std");
const src = @import("source.zig");
const zon = @import("../zon.zig");
const surface = @import("surface.zig");

/// A release number. Pre-release and build parts are not versions a package releases.
pub const Version = struct {
    major: u64,
    minor: u64,
    patch: u64,

    pub fn parse(text: []const u8) !Version {
        var parts = std.mem.splitScalar(u8, text, '.');
        var numbers: [3]u64 = undefined;
        for (&numbers) |*number| {
            const part = parts.next() orelse return error.InvalidVersion;
            if (part.len == 0 or (part.len > 1 and part[0] == '0')) return error.InvalidVersion;
            number.* = std.fmt.parseInt(u64, part, 10) catch return error.InvalidVersion;
        }
        if (parts.next() != null) return error.InvalidVersion;
        return .{ .major = numbers[0], .minor = numbers[1], .patch = numbers[2] };
    }

    pub fn format(v: Version, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
    }

    /// The next release: a breaking change moves the minor below 1.0 and the major from it.
    pub fn next(v: Version, breaking: bool) Version {
        if (!breaking) return .{ .major = v.major, .minor = v.minor, .patch = v.patch + 1 };
        if (v.major == 0) return .{ .major = 0, .minor = v.minor + 1, .patch = 0 };
        return .{ .major = v.major + 1, .minor = 0, .patch = 0 };
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        const major = std.math.order(a.major, b.major);
        if (major != .eq) return major;
        const minor = std.math.order(a.minor, b.minor);
        if (minor != .eq) return minor;
        return std.math.order(a.patch, b.patch);
    }
};

/// What the changelog's `[Unreleased]` section holds.
pub const Unreleased = struct {
    /// Any entry at all, under any heading.
    entries: bool = false,
    /// An entry under a `### Breaking` heading.
    breaking: bool = false,
};

const heading = "## [Unreleased]";

fn isLinkReference(line: []const u8) bool {
    if (line.len < 4 or line[0] != '[') return false;
    const close = std.mem.findScalar(u8, line, ']') orelse return false;
    return close + 1 < line.len and line[close + 1] == ':';
}

/// Where the lines after the `[Unreleased]` heading start and end: up to the next release or the link references.
pub fn unreleasedRange(changelog: []const u8) ?struct { start: usize, end: usize } {
    var offset: usize = 0;
    var start: ?usize = null;
    while (offset < changelog.len) {
        const end = std.mem.findScalarPos(u8, changelog, offset, '\n') orelse changelog.len;
        const line = std.mem.trimEnd(u8, changelog[offset..end], " \t\r");
        if (start) |from| {
            if (std.mem.startsWith(u8, line, "## ") or isLinkReference(line)) return .{ .start = from, .end = offset };
        } else if (std.mem.eql(u8, line, heading)) start = @min(end + 1, changelog.len);
        offset = end + 1;
    }
    return if (start) |from| .{ .start = from, .end = changelog.len } else null;
}

/// The lines after the `[Unreleased]` heading up to the next release or the link references.
fn unreleasedBody(changelog: []const u8) ?[]const u8 {
    const range = unreleasedRange(changelog) orelse return null;
    return changelog[range.start..range.end];
}

pub fn unreleased(changelog: []const u8) !Unreleased {
    const body = unreleasedBody(changelog) orelse return error.NoUnreleasedSection;
    var found: Unreleased = .{};
    var in_breaking = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#")) {
            in_breaking = std.mem.startsWith(u8, line, "### Breaking");
            continue;
        }
        found.entries = true;
        if (in_breaking) found.breaking = true;
    }
    return found;
}

/// The changelog with `[Unreleased]` turned into release `version` dated `date`, under a fresh empty
/// `[Unreleased]`, and the link references following: `[Unreleased]` compares from the new tag, and
/// the new release compares the previous tag with it.
pub fn cut(a: std.mem.Allocator, changelog: []const u8, version: Version, date: []const u8) ![]const u8 {
    const at = std.mem.find(u8, changelog, heading) orelse return error.NoUnreleasedSection;
    const after = at + heading.len;
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("{s}{s}\n\n## [{f}] - {s}", .{ changelog[0..at], heading, version, date });
    try w.writeAll(changelog[after..]);
    const text = out.written();
    const reference = "[Unreleased]: ";
    const line_start = blk: {
        if (std.mem.startsWith(u8, text, reference)) break :blk @as(usize, 0);
        const found = std.mem.find(u8, text, "\n" ++ reference) orelse return text;
        break :blk found + 1;
    };
    const line_end = std.mem.findScalarPos(u8, text, line_start, '\n') orelse text.len;
    const url = std.mem.trim(u8, text[line_start + reference.len .. line_end], " \t\r");
    const compare = "/compare/";
    const base_end = std.mem.find(u8, url, compare) orelse return text;
    const base = url[0..base_end];
    const range = url[base_end + compare.len ..];
    const dots = std.mem.find(u8, range, "...") orelse return text;
    const previous = range[0..dots];
    var result: std.Io.Writer.Allocating = .init(a);
    const r = &result.writer;
    try r.writeAll(text[0..line_start]);
    try r.print("{s}{s}/compare/v{f}...HEAD\n", .{ reference, base, version });
    if (previous.len > 0 and !std.mem.eql(u8, previous, "HEAD")) {
        try r.print("[{f}]: {s}/compare/{s}...v{f}", .{ version, base, previous, version });
    } else try r.print("[{f}]: {s}/releases/tag/v{f}", .{ version, base, version });
    try r.writeAll(text[@min(line_end, text.len)..]);
    return result.written();
}

/// `build.zig.zon` with its package `.version` replaced.
pub fn setVersion(a: std.mem.Allocator, manifest: []const u8, version: Version) ![]const u8 {
    const key = ".version = \"";
    var offset: usize = 0;
    while (offset < manifest.len) {
        const end = std.mem.findScalarPos(u8, manifest, offset, '\n') orelse manifest.len;
        const line = std.mem.trimStart(u8, manifest[offset..end], " \t");
        if (std.mem.startsWith(u8, line, key)) {
            const open = offset + (manifest[offset..end].len - line.len) + key.len;
            const close = std.mem.findScalarPos(u8, manifest, open, '"') orelse return error.InvalidManifest;
            return a.print("{s}{f}{s}", .{ manifest[0..open], version, manifest[close..] });
        }
        offset = end + 1;
    }
    return error.InvalidManifest;
}

const Manifest = struct { version: []const u8, paths: []const []const u8 };

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

/// The package's version as `build.zig.zon` declares it: what the landing tags.
pub fn declared(c: *src.Context) !Version {
    const manifest = try parseManifest(c, try c.read("build.zig.zon"));
    return Version.parse(manifest.version) catch {
        c.fail("build.zig.zon: .version \"{s}\" is not major.minor.patch", .{manifest.version});
        return error.InvalidVersion;
    };
}

/// The newest release the changelog records: its first `## [X.Y.Z]` heading,
/// or null before any.
pub fn newestReleased(changelog: []const u8) ?Version {
    var lines = std.mem.splitScalar(u8, changelog, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "## [")) continue;
        const end = std.mem.findScalar(u8, line, ']') orelse continue;
        return Version.parse(line["## [".len..end]) catch continue;
    }
    return null;
}

/// The version `build.zig.zon` declares is the changelog's newest release:
/// what a tag of this commit names, which a fetch of it names itself by.
/// A release cut by hand that set one and not the other is refused here,
/// in every gate, before its tag is made or after (uplink 0.9.0 and 0.9.1
/// were tagged with the manifest at 0.8.7). A package that has released
/// nothing yet has nothing to match.
pub fn versionAgrees(c: *src.Context) !void {
    if (!c.exists("CHANGELOG.md")) return;
    const newest = newestReleased(try c.read("CHANGELOG.md")) orelse return;
    const version = declared(c) catch |err| switch (err) {
        // It named its fix.
        error.InvalidVersion, error.InvalidManifest => return,
        else => return err,
    };
    if (version.order(newest) == .eq) return;
    c.fail("build.zig.zon: .version is {f} and CHANGELOG.md's newest release is {f}; a tag of this commit names the one the manifest declares, so set them to one release (`ready` sets both)", .{ version, newest });
}

test "the newest release is the first released heading, past [Unreleased]" {
    try std.testing.expectEqual(Version{ .major = 0, .minor = 9, .patch = 0 }, newestReleased("# Changelog\n\n## [Unreleased]\n\n## [0.9.0] - 2026-10-21\n\n## [0.8.7] - 2026-10-20\n").?);
    try std.testing.expectEqual(@as(?Version, null), newestReleased("# Changelog\n\n## [Unreleased]\n\n- something\n"));
}

/// Whether `path` is one of the manifest's `.paths` or under one.
pub fn shipped(listed: []const []const u8, path: []const u8) bool {
    for (listed) |entry| {
        const dir = std.mem.trimEnd(u8, entry, "/");
        if (dir.len == 0) return true;
        if (std.mem.eql(u8, dir, path)) return true;
        if (path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/') return true;
    }
    return false;
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

fn tagExists(c: src.Context, name: []const u8) !bool {
    const ref = try c.a.print("refs/tags/{s}", .{name});
    return succeeded(try git(c, &.{ "git", "rev-parse", "-q", "--verify", ref }));
}

/// Whether anything the manifest ships, `except` aside, differs between `tag` and the working tree.
fn changedSince(c: src.Context, tag: []const u8, listed: []const []const u8, except: ?[]const u8) !bool {
    const result = try git(c, &.{ "git", "diff", "--name-only", "--no-renames", "-z", tag, "--" });
    if (!succeeded(result)) return error.GitFailed;
    var names = std.mem.tokenizeScalar(u8, result.stdout, 0);
    while (names.next()) |name| {
        if (except) |path| if (std.mem.eql(u8, name, path)) continue;
        // A manifest whose development pins alone moved ships what it shipped.
        if (std.mem.eql(u8, name, "build.zig.zon") and !try manifestShipsOther(c, tag)) continue;
        if (shipped(listed, name)) return true;
    }
    return false;
}

/// Whether the manifest differs from `tag`'s in anything a consumer's build reads:
/// `.dev_dependencies` is not read by one, so a development pin moving ships nothing.
fn manifestShipsOther(c: src.Context, tag: []const u8) !bool {
    const released = try git(c, &.{ "git", "show", try c.a.print("{s}:./build.zig.zon", .{tag}) });
    if (!succeeded(released)) return true;
    const now = c.read("build.zig.zon") catch return true;
    const before = shippedTokens(c.a, released.stdout) catch return true;
    const after = shippedTokens(c.a, now) catch return true;
    return !std.mem.eql(u8, before, after);
}

/// The manifest's tokens without its `.dev_dependencies` field, one space apart: what a
/// consumer's build reads of it, whatever its layout and comments.
pub fn shippedTokens(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const ast = try std.zig.Ast.parse(a, try a.dupeSentinel(u8, text, 0), .{ .mode = .zon });
    if (ast.errors.len != 0) return error.InvalidManifest;
    // The skipped tokens, `[from, to)`: `.dev_dependencies = .{ ... },`.
    var from: usize = 0;
    var to: usize = 0;
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    if (ast.fullStructInit(&buffer, ast.rootDecls()[0])) |init| for (init.ast.fields) |value| {
        const first = ast.firstToken(value);
        if (first < 3 or !std.mem.eql(u8, ast.tokenSlice(first - 2), "dev_dependencies")) continue;
        from = first - 3;
        to = ast.lastToken(value) + 1;
        if (to < ast.tokens.len and ast.tokenTag(@intCast(to)) == .comma) to += 1; // safe: to < tokens.len, a u32 count
    };
    var kept: std.ArrayList(std.zig.Ast.TokenIndex) = .empty;
    for (0..ast.tokens.len) |i| if (i < from or i >= to) try kept.append(a, @intCast(i)); // safe: i < tokens.len, a u32 count
    var out: std.Io.Writer.Allocating = .init(a);
    for (kept.items, 0..) |token, k| {
        // A comma before a closing brace is layout, as is one the removed field leaves.
        if (ast.tokenTag(token) == .comma and k + 1 < kept.items.len and ast.tokenTag(kept.items[k + 1]) == .r_brace) continue;
        try out.writer.writeAll(ast.tokenSlice(token));
        try out.writer.writeByte(' ');
    }
    return out.written();
}

test "a manifest whose development pins alone moved ships the same; any other change ships" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try shippedTokens(a, ".{ .name = .pkg, .version = \"0.1.0\", .dependencies = .{ .lib = .{ .url = \"u1\", .hash = \"h1\" } }, .dev_dependencies = .{ .tool = .{ .url = \"t1\", .hash = \"th1\" } }, .paths = .{\"\"} }");
    // A development pin moved, the layout changed and a comment came: the same.
    try std.testing.expectEqualStrings(base, try shippedTokens(a,
        \\.{
        \\    .name = .pkg,
        \\    .version = "0.1.0",
        \\    .dependencies = .{ .lib = .{ .url = "u1", .hash = "h1" } },
        \\    // A tool the package develops with.
        \\    .dev_dependencies = .{ .tool = .{ .url = "t2", .hash = "th2" } },
        \\    .paths = .{""},
        \\}
    ));
    // No development pins at all: the same.
    try std.testing.expectEqualStrings(base, try shippedTokens(a, ".{ .name = .pkg, .version = \"0.1.0\", .dependencies = .{ .lib = .{ .url = \"u1\", .hash = \"h1\" } }, .paths = .{\"\"} }"));
    // A dependency a consumer fetches moved: not the same.
    try std.testing.expect(!std.mem.eql(u8, base, try shippedTokens(a, ".{ .name = .pkg, .version = \"0.1.0\", .dependencies = .{ .lib = .{ .url = \"u2\", .hash = \"h2\" } }, .dev_dependencies = .{ .tool = .{ .url = \"t1\", .hash = \"th1\" } }, .paths = .{\"\"} }")));
}

/// Whether a file the manifest ships other than `except` differs between `tag` and the working tree.
pub fn changedBesides(c: *src.Context, tag: []const u8, except: []const u8) !bool {
    const manifest = try parseManifest(c, try c.read("build.zig.zon"));
    return changedSince(c.*, tag, manifest.paths, except);
}

pub const Outcome = union(enum) {
    /// Nothing the package ships changed since this tag.
    unchanged: []const u8,
    /// The version is already in the manifest and the changelog and waits for its tag.
    prepared: Version,
    released: struct { from: Version, to: Version, breaking: bool },
};

/// Decides, then writes the new version and the changelog. A failed decision names its fix and writes nothing.
/// `modules` are the modules the package exports: a release that removes or changes a public
/// declaration of one is breaking, and refuses unless [Unreleased] says so.
pub fn run(c: *src.Context, date: []const u8, modules: []const surface.Module) !Outcome {
    const manifest_text = try c.read("build.zig.zon");
    const manifest = try parseManifest(c, manifest_text);
    const current = Version.parse(manifest.version) catch {
        c.fail("build.zig.zon: .version \"{s}\" is not major.minor.patch", .{manifest.version});
        return error.InvalidVersion;
    };
    const tag = try lastTag(c.*);
    if (tag) |name| if (!try changedSince(c.*, name, manifest.paths, null)) return .{ .unchanged = name };
    const changelog = c.read("CHANGELOG.md") catch {
        c.fail("CHANGELOG.md: a release is written from it; add one with an [Unreleased] section", .{});
        return error.NoChangelog;
    };
    const found = unreleased(changelog) catch {
        c.fail("CHANGELOG.md: no `## [Unreleased]` section; add one and list what changed under it", .{});
        return error.NoUnreleasedSection;
    };
    if (!found.entries) {
        // A release made and not yet tagged is not a second one; a first one has no tag before it.
        const marker = try c.a.print("## [{f}]", .{current});
        if (tag) |name| {
            if (Version.parse(std.mem.trimStart(u8, name, "v")) catch null) |tagged|
                if (current.order(tagged) == .gt and std.mem.find(u8, changelog, marker) != null) {
                    try requireBreaking(c, name, modules, current.order(tagged.next(false)) == .gt);
                    return .{ .prepared = current };
                };
        } else if (std.mem.find(u8, changelog, marker) != null) return .{ .prepared = current };
        c.fail("CHANGELOG.md: the package changed since {s}, and [Unreleased] lists nothing; add what changed under it ({s})", .{ tag orelse "its start", "### Breaking for an incompatible change, otherwise ### Changed, ### Added or ### Fixed" });
        return error.EmptyUnreleased;
    }
    if (tag) |name| try requireBreaking(c, name, modules, found.breaking);
    // The first release is the version the manifest names: nothing came before it to move from.
    const to = if (tag == null) current else current.next(found.breaking);
    const name = try c.a.print("v{f}", .{to});
    if (try tagExists(c.*, name)) {
        c.fail("tag {s} exists: a tag is never moved; the version in build.zig.zon is behind the tags, set it to the newest release and run again", .{name});
        return error.TagExists;
    }
    const cut_changelog = try cut(c.a, changelog, to, date);
    const cut_manifest = try setVersion(c.a, manifest_text, to);
    const dir = c.directory();
    try dir.writeFile(c.io, .{ .sub_path = "CHANGELOG.md", .data = cut_changelog });
    try dir.writeFile(c.io, .{ .sub_path = "build.zig.zon", .data = cut_manifest });
    return .{ .released = .{ .from = current, .to = to, .breaking = found.breaking } };
}

/// The changelog's entry for `version`: the lines under its `## [X.Y.Z]` heading, up to the
/// next release or the link references; null when it has none.
pub fn notes(a: std.mem.Allocator, changelog: []const u8, version: Version) !?[]const u8 {
    const at = std.mem.find(u8, changelog, try a.print("## [{f}]", .{version})) orelse return null;
    const start = (std.mem.findScalarPos(u8, changelog, at, '\n') orelse return null) + 1;
    var offset = start;
    while (offset < changelog.len) {
        const end = std.mem.findScalarPos(u8, changelog, offset, '\n') orelse changelog.len;
        const line = changelog[offset..end];
        if (std.mem.startsWith(u8, line, "## ") or isLinkReference(line)) break;
        offset = end + 1;
    }
    return std.mem.trim(u8, changelog[start..@min(offset, changelog.len)], "\n");
}

test "a release's notes are the lines under its heading" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const log = "# Changelog\n\n## [Unreleased]\n\n## [0.2.0] - 2026-01-02\n\n### Breaking\n\n- Less.\n\n## [0.1.0] - 2026-01-01\n\n- First.\n\n[0.1.0]: https://example.invalid\n";
    try std.testing.expectEqualStrings("### Breaking\n\n- Less.", (try notes(a, log, .{ .major = 0, .minor = 2, .patch = 0 })).?);
    try std.testing.expectEqualStrings("- First.", (try notes(a, log, .{ .major = 0, .minor = 1, .patch = 0 })).?);
    try std.testing.expect(try notes(a, log, .{ .major = 0, .minor = 3, .patch = 0 }) == null);
}

/// Refuses a release that is not `breaking` while a public declaration of `modules` that
/// `tag` had is gone or changed, naming them.
fn requireBreaking(c: *src.Context, tag: []const u8, modules: []const surface.Module, breaking: bool) !void {
    if (breaking or modules.len == 0) return;
    const gone = try surfaceRemoved(c, tag, modules);
    if (gone.len == 0) return;
    const shown = @min(gone.len, 20);
    var listed: std.Io.Writer.Allocating = .init(c.a);
    for (gone[0..shown]) |line| try listed.writer.print("\n  {s}", .{line});
    if (gone.len > shown) try listed.writer.print("\n  and {d} more", .{gone.len - shown});
    c.fail("CHANGELOG.md: since {s} the package removed or changed these public declarations, and [Unreleased] has no ### Breaking entry; say what breaks under ### Breaking (`surface -- --since {s}` lists them):{s}", .{ tag, tag, listed.written() });
    return error.UndeclaredBreaking;
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
    return surface.list(c.a, c.a, modules, Tree{ .c = c });
}

fn surfaceAt(c: *src.Context, revision: []const u8, modules: []const surface.Module) ![]const []const u8 {
    return surface.list(c.a, c.a, modules, Revision{ .c = c, .name = revision });
}

/// The package's files as the working tree holds them.
pub const Tree = struct {
    c: *const src.Context,

    pub fn read(tree: Tree, a: std.mem.Allocator, path: []const u8) !?[]const u8 {
        if (!tree.c.exists(path)) return null;
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

/// `YYYY-MM-DD` of the current UTC day.
pub fn today(a: std.mem.Allocator, io: std.Io) ![]const u8 {
    // aegis: no-danger: the wall clock read once for a release's date
    const seconds: u64 = @intCast(@max(0, std.Io.Clock.real.now(io).toSeconds()));
    const day = (std.time.epoch.EpochSeconds{ .secs = seconds }).getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    return a.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ day.year, month_day.month.numeric(), month_day.day_index + 1 });
}

// Tests ------------------------------------------------------------------

const changelog_text =
    \\# Changelog
    \\
    \\## [Unreleased]
    \\
    \\### Changed
    \\
    \\- Something.
    \\
    \\## [0.1.0] - 2026-01-01
    \\
    \\### Added
    \\
    \\- First.
    \\
    \\[Unreleased]: https://github.com/o/r/compare/v0.1.0...HEAD
    \\[0.1.0]: https://github.com/o/r/releases/tag/v0.1.0
    \\
;

test "the bump follows the breaking entries and the major version" {
    const v = try Version.parse("0.3.4");
    try std.testing.expectEqual(Version{ .major = 0, .minor = 3, .patch = 5 }, v.next(false));
    try std.testing.expectEqual(Version{ .major = 0, .minor = 4, .patch = 0 }, v.next(true));
    const stable = try Version.parse("1.2.3");
    try std.testing.expectEqual(Version{ .major = 1, .minor = 2, .patch = 4 }, stable.next(false));
    try std.testing.expectEqual(Version{ .major = 2, .minor = 0, .patch = 0 }, stable.next(true));
    for ([_][]const u8{ "1.2", "1.2.3.4", "01.2.3", "1.2.x", "1.2.3-rc1", "" }) |bad| try std.testing.expectError(error.InvalidVersion, Version.parse(bad));
}

test "unreleased reads the entries and the breaking ones, and stops at the next release" {
    const found = try unreleased(changelog_text);
    try std.testing.expect(found.entries and !found.breaking);
    const breaking = try unreleased("## [Unreleased]\n\n### Breaking\n\n- Gone.\n\n## [0.1.0] - x\n");
    try std.testing.expect(breaking.breaking);
    // A heading with nothing under it, and entries of a release already made, are not entries.
    const empty = try unreleased("## [Unreleased]\n\n### Breaking\n\n## [0.1.0] - x\n\n- Old.\n");
    try std.testing.expect(!empty.entries and !empty.breaking);
    const bare = try unreleased("## [Unreleased]\n\n[Unreleased]: https://example.invalid/compare/v1...HEAD\n");
    try std.testing.expect(!bare.entries);
    try std.testing.expectError(error.NoUnreleasedSection, unreleased("# Changelog\n"));
}

test "a cut changelog keeps its link references right" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try cut(arena.allocator(), changelog_text, .{ .major = 0, .minor = 1, .patch = 1 }, "2026-02-03");
    try std.testing.expect(std.mem.find(u8, text, "## [Unreleased]\n\n## [0.1.1] - 2026-02-03\n\n### Changed\n\n- Something.\n\n## [0.1.0] - 2026-01-01") != null);
    try std.testing.expect(std.mem.find(u8, text, "[Unreleased]: https://github.com/o/r/compare/v0.1.1...HEAD\n[0.1.1]: https://github.com/o/r/compare/v0.1.0...v0.1.1\n[0.1.0]: https://github.com/o/r/releases/tag/v0.1.0\n") != null);
    // The first release has no previous tag to compare with.
    const first = try cut(arena.allocator(), "## [Unreleased]\n\n- A.\n\n[Unreleased]: https://github.com/o/r/compare/HEAD...HEAD\n", .{ .major = 0, .minor = 1, .patch = 0 }, "2026-02-03");
    try std.testing.expect(std.mem.find(u8, first, "[0.1.0]: https://github.com/o/r/releases/tag/v0.1.0") != null);
    // A changelog with no references gets none.
    const plain = try cut(arena.allocator(), "## [Unreleased]\n\n- A.\n", .{ .major = 0, .minor = 1, .patch = 0 }, "2026-02-03");
    try std.testing.expect(std.mem.find(u8, plain, "compare") == null);
}

test "the manifest's version is replaced and nothing else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try setVersion(arena.allocator(), ".{\n    .name = .x,\n    .version = \"0.1.0\",\n    .dependencies = .{ .d = .{ .url = \"u\", .hash = \"h-0.1.0-x\" } },\n}\n", .{ .major = 0, .minor = 2, .patch = 0 });
    try std.testing.expectEqualStrings(".{\n    .name = .x,\n    .version = \"0.2.0\",\n    .dependencies = .{ .d = .{ .url = \"u\", .hash = \"h-0.1.0-x\" } },\n}\n", text);
}

test "a path is shipped when the manifest names it or a directory above it" {
    const listed: []const []const u8 = &.{ "build.zig", "src", "docs/" };
    try std.testing.expect(shipped(listed, "build.zig"));
    try std.testing.expect(shipped(listed, "src/a/b.zig"));
    try std.testing.expect(shipped(listed, "docs/design.md"));
    try std.testing.expect(!shipped(listed, "srcs/a.zig"));
    try std.testing.expect(!shipped(listed, "bench/a.zig"));
    try std.testing.expect(shipped(&.{""}, "anything"));
}

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
        return f.tmp.dir.readFileAlloc(std.testing.io, path, f.arena.allocator(), .limited(1 << 20));
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
    try std.testing.expectEqual(Version{ .major = 2, .minor = 0, .patch = 7 }, try declared(&c));
    try f.write("build.zig.zon", ".{ .name = .pkg, .version = \"2.0\", .paths = .{\"\"} }\n");
    try std.testing.expectError(error.InvalidVersion, declared(&c));
    try std.testing.expectEqual(@as(usize, 1), c.errors);
}

test "a package that did not change since its tag is not released" {
    const f = try Fixture.init("0.1.0");
    defer f.deinit();
    try f.git(&.{ "tag", "v0.1.0" });
    // Code outside .paths and a change to a file nobody ships do not count.
    try f.write("bench/b.zig", "pub const b = 2;\n");
    try f.commit("Bench");
    var c = f.context();
    const outcome = try run(&c, "2026-03-04", &.{});
    try std.testing.expectEqualStrings("v0.1.0", outcome.unchanged);
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    try std.testing.expect(std.mem.find(u8, try f.read("build.zig.zon"), "0.1.0") != null);
}

test "a changed package gets the patch, the minor below 1.0 for a breaking entry, and the major from 1.0" {
    {
        const f = try Fixture.init("0.1.0");
        defer f.deinit();
        try f.git(&.{ "tag", "v0.1.0" });
        try f.write("src/a.zig", "pub const a = 2;\n");
        try f.unreleased("### Fixed\n\n- A fix.\n");
        try f.commit("Fix");
        var c = f.context();
        const outcome = try run(&c, "2026-03-04", &.{});
        try std.testing.expectEqual(Version{ .major = 0, .minor = 1, .patch = 1 }, outcome.released.to);
        try std.testing.expect(std.mem.find(u8, try f.read("build.zig.zon"), ".version = \"0.1.1\"") != null);
        const log = try f.read("CHANGELOG.md");
        try std.testing.expect(std.mem.find(u8, log, "## [Unreleased]\n\n## [0.1.1] - 2026-03-04\n\n### Fixed") != null);
        try std.testing.expect(std.mem.find(u8, log, "[Unreleased]: https://github.com/o/r/compare/v0.1.1...HEAD\n[0.1.1]: https://github.com/o/r/compare/v0.1.0...v0.1.1\n") != null);
    }
    {
        const f = try Fixture.init("0.1.0");
        defer f.deinit();
        try f.git(&.{ "tag", "v0.1.0" });
        try f.write("src/a.zig", "pub const a = 2;\n");
        try f.unreleased("### Added\n\n- More.\n\n### Breaking\n\n- Less.\n");
        try f.commit("Break");
        var c = f.context();
        const outcome = try run(&c, "2026-03-04", &.{});
        try std.testing.expectEqual(Version{ .major = 0, .minor = 2, .patch = 0 }, outcome.released.to);
        try std.testing.expect(outcome.released.breaking);
    }
    {
        const f = try Fixture.init("1.4.2");
        defer f.deinit();
        try f.git(&.{ "tag", "v1.4.2" });
        try f.write("src/a.zig", "pub const a = 2;\n");
        try f.unreleased("### Breaking\n\n- Gone.\n");
        try f.commit("Break");
        var c = f.context();
        const outcome = try run(&c, "2026-03-04", &.{});
        try std.testing.expectEqual(Version{ .major = 2, .minor = 0, .patch = 0 }, outcome.released.to);
    }
}

test "a release that removes or changes a public declaration refuses without a Breaking entry, and is breaking with one" {
    const modules = [_]surface.Module{.{ .name = "pkg", .root = "src/a.zig" }};
    {
        const f = try Fixture.init("0.1.0");
        defer f.deinit();
        try f.write("src/a.zig", "pub const a = 1;\npub fn run(size: usize) void { _ = size; }\n");
        try f.commit("Run");
        try f.git(&.{ "tag", "v0.1.0" });
        // An added declaration and a renamed parameter are no break.
        try f.write("src/a.zig", "pub const a = 1;\npub fn run(length: usize) void { _ = length; }\npub fn more() void {}\n");
        try f.unreleased("### Added\n\n- More.\n");
        try f.commit("More");
        var c = f.context();
        const outcome = try run(&c, "2026-03-04", &modules);
        try std.testing.expectEqual(Version{ .major = 0, .minor = 1, .patch = 1 }, outcome.released.to);
    }
    {
        const f = try Fixture.init("0.1.0");
        defer f.deinit();
        try f.write("src/a.zig", "pub const a = 1;\npub fn run(size: usize) void { _ = size; }\n");
        try f.commit("Run");
        try f.git(&.{ "tag", "v0.1.0" });
        try f.write("src/a.zig", "pub const a = 1;\npub fn run(size: u32) void { _ = size; }\n");
        try f.unreleased("### Changed\n\n- A smaller size.\n");
        try f.commit("Change");
        var c = f.context();
        const before = try f.read("CHANGELOG.md");
        try std.testing.expectError(error.UndeclaredBreaking, run(&c, "2026-03-04", &modules));
        try std.testing.expectEqual(@as(usize, 1), c.errors);
        try std.testing.expect(std.mem.find(u8, f.held.written(), "pkg.run fn ( usize ) void") != null);
        try std.testing.expectEqualStrings(before, try f.read("CHANGELOG.md"));
        try f.unreleased("### Breaking\n\n- `run` takes a `u32`.\n");
        try f.commit("Say so");
        var again = f.context();
        const outcome = try run(&again, "2026-03-04", &modules);
        try std.testing.expectEqual(Version{ .major = 0, .minor = 2, .patch = 0 }, outcome.released.to);
    }
}

test "a changed package with an empty Unreleased fails and writes nothing" {
    const f = try Fixture.init("0.1.0");
    defer f.deinit();
    try f.git(&.{ "tag", "v0.1.0" });
    try f.write("src/a.zig", "pub const a = 2;\n");
    try f.commit("Change");
    var c = f.context();
    const before = try f.read("CHANGELOG.md");
    try std.testing.expectError(error.EmptyUnreleased, run(&c, "2026-03-04", &.{}));
    try std.testing.expectEqual(@as(usize, 1), c.errors);
    try std.testing.expectEqualStrings(before, try f.read("CHANGELOG.md"));
}

test "a package with no tag yet is released at the manifest's version, and once made is not made again" {
    const f = try Fixture.init("0.1.0");
    defer f.deinit();
    try f.unreleased("- First change.\n");
    try f.commit("Entry");
    var c = f.context();
    const outcome = try run(&c, "2026-03-04", &.{});
    try std.testing.expectEqual(Version{ .major = 0, .minor = 1, .patch = 0 }, outcome.released.to);
    try f.commit("Release");
    var again = f.context();
    try std.testing.expectEqual(Version{ .major = 0, .minor = 1, .patch = 0 }, (try run(&again, "2026-03-04", &.{})).prepared);
    try std.testing.expectEqual(@as(usize, 0), again.errors);
}

test "a release made and not yet tagged is not made twice" {
    const f = try Fixture.init("0.1.0");
    defer f.deinit();
    try f.git(&.{ "tag", "v0.1.0" });
    try f.write("src/a.zig", "pub const a = 2;\n");
    try f.unreleased("- A change.\n");
    try f.commit("Change");
    var c = f.context();
    _ = try run(&c, "2026-03-04", &.{});
    try f.commit("Release");
    var again = f.context();
    const outcome = try run(&again, "2026-03-04", &.{});
    try std.testing.expectEqual(Version{ .major = 0, .minor = 1, .patch = 1 }, outcome.prepared);
    try std.testing.expectEqual(@as(usize, 0), again.errors);
}

test "a version whose tag exists is refused, never moved" {
    const f = try Fixture.init("0.1.0");
    defer f.deinit();
    try f.git(&.{ "tag", "v0.1.0" });
    try f.write("src/a.zig", "pub const a = 2;\n");
    try f.unreleased("- A change.\n");
    try f.commit("Change");
    try f.git(&.{ "tag", "v0.1.1" });
    // The tag on the newest release is the one describe finds; the version to come exists too.
    try f.write("src/a.zig", "pub const a = 3;\n");
    try f.commit("More");
    var c = f.context();
    try std.testing.expectError(error.TagExists, run(&c, "2026-03-04", &.{}));
    try std.testing.expect(c.errors == 1);
}
