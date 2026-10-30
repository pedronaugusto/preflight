//! A package's graph as plain `zig build` fetches it: each dependency's own
//! manifest, as published, with no selection over the pins. bay picks one
//! revision of each package for a build it runs; Zig takes every pin as
//! written, so two packages that pin a third at two revisions link both, and a
//! package that builds under bay breaks for a consumer that builds without it.
const std = @import("std");
const aegis = @import("aegis");
const nested = @import("nested.zig");

/// One revision of a package in the graph, and the package that pins it.
pub const Revision = struct { hash: []const u8, by: []const u8 };

/// A package the graph holds at more than one revision.
pub const Conflict = struct { package: []const u8, revisions: []const Revision };

/// Where the walk finds each pinned package as published.
pub const Packages = struct {
    /// Zig's global cache, whose `p/<hash>` is the package as fetched: the caller's.
    global: aegis.own.Lent(std.Io.Dir),
    /// The Zig that fetches a pin the cache lacks, or null to fetch nothing.
    zig: ?[]const u8 = null,
};

/// The packages the graph of the package whose manifest is `root`, named
/// `name`, holds at more than one revision, but for those its `.coexist`
/// names on different lines. A lazy pin is followed only when it is fetched
/// already: a consumer fetches one only when its build asks for it.
pub fn conflicts(a: std.mem.Allocator, io: std.Io, root: []const u8, name: []const u8, packages: Packages) ![]const Conflict {
    var seen: std.array_hash_map.String(std.ArrayList(Revision)) = .empty;
    var walked: std.array_hash_map.String(void) = .empty;
    var pending: std.ArrayList(struct { text: []const u8, by: []const u8 }) = .empty;
    try pending.append(a, .{ .text = root, .by = name });
    while (pending.pop()) |manifest| {
        for (try nested.pinsIn(a, manifest.text, &.{"dependencies"})) |pin| {
            const package = packageOf(pin.hash);
            const entry = try seen.getOrPut(a, package);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            const known = for (entry.value_ptr.items) |revision| {
                if (std.mem.eql(u8, revision.hash, pin.hash)) break true;
            } else false;
            if (!known) try entry.value_ptr.append(a, .{ .hash = pin.hash, .by = manifest.by });
            if ((try walked.getOrPut(a, pin.hash)).found_existing) continue;
            const text = try published(a, io, packages, pin) orelse continue;
            try pending.append(a, .{ .text = text, .by = labelOf(pin.hash) });
        }
    }
    const coexist = try nested.coexistIn(a, root);
    var found: std.ArrayList(Conflict) = .empty;
    for (seen.keys(), seen.values()) |package, revisions| {
        if (revisions.items.len < 2) continue;
        const allowed = for (coexist) |each| {
            if (std.mem.eql(u8, each, package)) break onDifferentLines(revisions.items);
        } else false;
        if (!allowed) try found.append(a, .{ .package = package, .revisions = revisions.items });
    }
    return found.items;
}

/// The manifest of `pin` as published, fetched first when the cache lacks it and
/// the pin is not lazy; null when it is not there.
fn published(a: std.mem.Allocator, io: std.Io, packages: Packages, pin: nested.Pin) !?[]const u8 {
    const path = try std.Io.Dir.path.join(a, &.{ "p", pin.hash, "build.zig.zon" });
    if (aegis.own.readFile(io, packages.global.get(), path, a, .fromRaw(1024 * 1024))) |text| return text else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const zig = packages.zig orelse return null;
    if (pin.lazy) return null;
    const fetched = try std.process.run(a, io, .{ .argv = &.{ zig, "fetch", pin.url } });
    if (fetched.term != .exited or fetched.term.exited != 0) return error.FetchFailed;
    return aegis.own.readFile(io, packages.global.get(), path, a, .fromRaw(1024 * 1024)) catch |err| switch (err) {
        // A package with no manifest pins nothing.
        error.FileNotFound => null,
        else => err,
    };
}

/// A package's name, from its hash: `name-version-digest`, a name holding no `-`.
fn packageOf(hash: []const u8) []const u8 {
    return hash[0 .. std.mem.findScalar(u8, hash, '-') orelse hash.len];
}

/// `name-version`, the hash without its digest.
fn labelOf(hash: []const u8) []const u8 {
    return hash[0 .. std.mem.findScalarLast(u8, hash, '-') orelse hash.len];
}

/// Whether no two revisions share a release line: the minor below 1.0, else the major.
fn onDifferentLines(revisions: []const Revision) bool {
    for (revisions, 0..) |x, i| for (revisions[i + 1 ..]) |y| {
        if (std.mem.eql(u8, line(x.hash), line(y.hash))) return false;
    };
    return true;
}

fn line(hash: []const u8) []const u8 {
    const label = labelOf(hash);
    const version = label[@min(label.len, packageOf(hash).len + 1)..];
    var parts = std.mem.splitScalar(u8, version, '.');
    const major = parts.next() orelse return version;
    if (!std.mem.eql(u8, major, "0")) return major;
    const minor = parts.next() orelse return version;
    return version[0 .. major.len + 1 + minor.len];
}

/// Writes what `conflicts` found, a line each: the package, each revision and who pins it.
pub fn describe(w: *std.Io.Writer, found: []const Conflict) std.Io.Writer.Error!void {
    for (found) |conflict| {
        try w.print("{s} is in the graph plain zig builds at {d} revisions:", .{ conflict.package, conflict.revisions.len });
        for (conflict.revisions, 0..) |revision, i| try w.print("{s} {s}, pinned by {s}", .{ if (i == 0) "" else ";", labelOf(revision.hash), revision.by });
        try w.writeAll(". bay builds one; a consumer building without bay links each: pin one revision throughout\n");
    }
}

test "two packages that pin a third at two revisions are a conflict; one revision, or two lines it names to coexist, are not" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const digest = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    const aegis4 = "aegis-0.1.4-" ++ digest;
    const aegis5 = "aegis-0.1.5-" ++ digest;
    const ensign = "ensign-0.2.1-" ++ digest;
    for ([_][2][]const u8{
        .{ ensign, ".{ .name = .ensign, .dependencies = .{ .aegis = .{ .url = \"git+https://e.invalid/aegis#4\", .hash = \"" ++ aegis4 ++ "\" } } }" },
        .{ aegis4, ".{ .name = .aegis }" },
        .{ aegis5, ".{ .name = .aegis }" },
    }) |package| {
        const dir = try std.Io.Dir.path.join(a, &.{ "p", package[0] });
        try tmp.dir.createDirPath(io, dir);
        try tmp.dir.writeFile(io, .{ .sub_path = try std.Io.Dir.path.join(a, &.{ dir, "build.zig.zon" }), .data = package[1] });
    }
    const root = ".{ .name = .bay, .dependencies = .{ .aegis = .{ .url = \"git+https://e.invalid/aegis#5\", .hash = \"" ++ aegis5 ++ "\" }, .ensign = .{ .url = \"git+https://e.invalid/ensign#1\", .hash = \"" ++ ensign ++ "\" } } }";
    const found = try conflicts(a, io, root, "bay", .{ .global = .{ .data = tmp.dir } });
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("aegis", found[0].package);
    var text: std.Io.Writer.Allocating = .init(a);
    try describe(&text.writer, found);
    try std.testing.expectEqualStrings("aegis is in the graph plain zig builds at 2 revisions: aegis-0.1.5, pinned by bay; aegis-0.1.4, pinned by ensign-0.2.1. bay builds one; a consumer building without bay links each: pin one revision throughout\n", text.written());
    const agreeing = try std.mem.replaceOwned(u8, a, root, aegis5, aegis4);
    try std.testing.expectEqual(@as(usize, 0), (try conflicts(a, io, agreeing, "bay", .{ .global = .{ .data = tmp.dir } })).len);
    // 0.1.4 and 0.1.5 are one line, so naming aegis to coexist does not allow them.
    const named = try std.mem.replaceOwned(u8, a, root, ".name = .bay,", ".name = .bay, .coexist = .{.aegis},");
    try std.testing.expectEqual(@as(usize, 1), (try conflicts(a, io, named, "bay", .{ .global = .{ .data = tmp.dir } })).len);
}
