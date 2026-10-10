//! One revision of each package in any artifact of the package under test. Two
//! revisions of a package are two sets of types that do not unify, and two sets
//! of any state the package holds once per program. The check reads the
//! configured build, not the manifests: a revision that an injected module or a
//! dependency's own pin brings is as much in the artifact as one the package names.
const std = @import("std");
const src = @import("../checks/source.zig");
const C = std.Build.Configuration;

/// A module of one package linked into an artifact, and the package whose module imports it.
pub const Link = struct {
    /// The package's name; the root package's is its manifest's.
    name: []const u8,
    /// The package's content hash, empty for the root package: the revision.
    revision: []const u8,
    /// The dependency path of the importing package, empty for the root package.
    puller: []const u8,
};

/// A package that an artifact holds in more than one revision.
pub const Conflict = struct {
    name: []const u8,
    /// Each revision with the packages that pull it.
    revisions: []const Revision,
    pub const Revision = struct { revision: []const u8, pullers: []const []const u8 };
};

/// The packages `links` holds in more than one revision, except those `allowed` names
/// and the package under test (`root_name`), which cannot pin its own commit.
pub fn conflicts(a: std.mem.Allocator, links: []const Link, root_name: []const u8, allowed: src.Value) ![]const Conflict {
    var names: std.ArrayList([]const u8) = .empty;
    for (links) |link| {
        if (std.mem.eql(u8, link.name, root_name) or src.get(allowed, link.name) != .null) continue;
        if (!has(names.items, link.name)) try names.append(a, link.name);
    }
    var found: std.ArrayList(Conflict) = .empty;
    for (names.items) |name| {
        var revisions: std.ArrayList(Conflict.Revision) = .empty;
        var pullers: std.ArrayList(std.ArrayList([]const u8)) = .empty;
        for (links) |link| {
            if (!std.mem.eql(u8, link.name, name)) continue;
            const index = for (revisions.items, 0..) |known, i| {
                if (std.mem.eql(u8, known.revision, link.revision)) break i;
            } else add: {
                try revisions.append(a, .{ .revision = link.revision, .pullers = &.{} });
                try pullers.append(a, .empty);
                break :add revisions.items.len - 1;
            };
            const puller = if (link.puller.len == 0) root_name else link.puller;
            if (!has(pullers.items[index].items, puller)) try pullers.items[index].append(a, puller);
        }
        for (revisions.items, pullers.items) |*revision, list| revision.pullers = list.items;
        if (revisions.items.len > 1) try found.append(a, .{ .name = name, .revisions = revisions.items });
    }
    return found.items;
}

fn has(list: []const []const u8, item: []const u8) bool {
    for (list) |known| if (std.mem.eql(u8, known, item)) return true;
    return false;
}

/// The name a package hash starts with: `aegis` of `aegis-0.0.0-AAAA...`.
pub fn packageName(hash: []const u8) []const u8 {
    return hash[0 .. std.mem.findScalar(u8, hash, '-') orelse hash.len];
}

/// The links an artifact holds: its root module's package, and each package one of
/// the artifact's modules imports a module of, with the package that imports it.
pub fn artifactLinks(a: std.mem.Allocator, config: *const C, root: C.Module.Index, root_name: []const u8) ![]const Link {
    var links: std.ArrayList(Link) = .empty;
    var seen: std.AutoHashMapUnmanaged(C.Module.Index, void) = .empty;
    var pending: std.ArrayList(C.Module.Index) = .empty;
    try pending.append(a, root);
    try links.append(a, try linkOf(a, config, root.get(config).owner, root_name, ""));
    while (pending.pop()) |id| {
        if ((try seen.getOrPut(a, id)).found_existing) continue;
        const module = id.get(config);
        const puller = try label(a, config, module.owner);
        const imports = module.import_table.get(config).imports.mal;
        for (imports.items(.module)) |imported| {
            try pending.append(a, imported);
            const owner = imported.get(config).owner;
            if (owner != module.owner) try links.append(a, try linkOf(a, config, owner, root_name, puller));
        }
    }
    return links.items;
}

fn label(a: std.mem.Allocator, config: *const C, owner: C.Package.Index) ![]const u8 {
    const prefix = owner.depPrefixSlice(config);
    return a.dupe(u8, std.mem.trimEnd(u8, prefix, "."));
}

fn linkOf(a: std.mem.Allocator, config: *const C, owner: C.Package.Index, root_name: []const u8, puller: []const u8) !Link {
    const package = owner.get(config) orelse return .{ .name = root_name, .revision = "", .puller = puller };
    const hash = try a.dupe(u8, package.hash.slice(config));
    return .{ .name = packageName(hash), .revision = hash, .puller = puller };
}

/// Whether the module's root file is the package's own, or generated; a file of a dependency is not.
fn ownSource(config: *const C, module: C.Module.Index) bool {
    const file = module.get(config).root_source_file.unwrap() orelse return true;
    return switch (file.get(config)) {
        .source_path => |source| source.owner == .root,
        else => true,
    };
}

/// Fails the check for each package that an artifact of the root package links in two revisions.
pub fn check(c: *src.Context, config: *const C, root_name: []const u8, allowed: src.Value) !void {
    if (allowed != .null and allowed != .object) {
        c.fail("ci/preflight.json: revision_exceptions maps each package to why two of its revisions may meet", .{});
        return;
    }
    if (allowed == .object) for (allowed.object.keys(), allowed.object.values()) |name, reason| {
        if (src.string(reason, "").len == 0) c.fail("ci/preflight.json: revision_exceptions: {s}: say why two revisions may meet", .{name});
    };
    // The same revisions meeting in several artifacts are one finding.
    var findings: std.array_hash_map.String(std.ArrayList([]const u8)) = .empty;
    for (config.steps) |step| {
        if (step.owner != .root) continue;
        const compile = step.extended.cast(config, C.Step.Compile) orelse continue;
        // preflight's own tools (the checks, the structure runner) are built in the package's graph from preflight's sources: the checker's toolchain, not the package's code.
        if (!ownSource(config, compile.root_module)) continue;
        const links = try artifactLinks(c.a, config, compile.root_module, root_name);
        for (try conflicts(c.a, links, root_name, allowed)) |conflict| {
            var text: std.Io.Writer.Allocating = .init(c.a);
            try text.writer.print("{s} is linked in {d} revisions:", .{ conflict.name, conflict.revisions.len });
            for (conflict.revisions) |revision| {
                try text.writer.print("\n  {s} pulled by ", .{if (revision.revision.len == 0) "this package" else revision.revision});
                for (revision.pullers, 0..) |puller, i| try text.writer.print("{s}{s}", .{ if (i == 0) "" else ", ", puller });
            }
            const entry = try findings.getOrPut(c.a, text.written());
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(c.a, step.name.slice(config));
        }
    }
    for (findings.keys(), findings.values()) |text, artifacts| {
        c.fail("{s}\n  in `{s}`{s}; one revision of each package in a build graph: pin the same one everywhere, or say in ci/preflight.json revision_exceptions why they may meet", .{
            text,
            artifacts.items[0],
            if (artifacts.items.len > 1) try c.a.print(" and {d} more artifacts", .{artifacts.items.len - 1}) else "",
        });
    }
}

test "a package linked in two revisions names both and who pulls each" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const links = [_]Link{
        .{ .name = "conduit", .revision = "", .puller = "" },
        .{ .name = "aegis", .revision = "aegis-0.0.0-one", .puller = "" },
        .{ .name = "shakedown", .revision = "shakedown-0.1.0-s", .puller = "" },
        .{ .name = "aegis", .revision = "aegis-0.0.0-two", .puller = "shakedown" },
        .{ .name = "aegis", .revision = "aegis-0.0.0-one", .puller = "reactor" },
        .{ .name = "aegis", .revision = "aegis-0.0.0-one", .puller = "reactor" },
    };
    const found = try conflicts(a, &links, "conduit", .null);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("aegis", found[0].name);
    try std.testing.expectEqual(@as(usize, 2), found[0].revisions.len);
    try std.testing.expectEqualStrings("aegis-0.0.0-one", found[0].revisions[0].revision);
    try std.testing.expectEqual(@as(usize, 2), found[0].revisions[0].pullers.len);
    try std.testing.expectEqualStrings("conduit", found[0].revisions[0].pullers[0]);
    try std.testing.expectEqualStrings("reactor", found[0].revisions[0].pullers[1]);
    try std.testing.expectEqualStrings("aegis-0.0.0-two", found[0].revisions[1].revision);
    try std.testing.expectEqualStrings("shakedown", found[0].revisions[1].pullers[0]);
}

test "one revision, however many packages pull it, is no conflict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const links = [_]Link{
        .{ .name = "aegis", .revision = "aegis-0.0.0-one", .puller = "" },
        .{ .name = "aegis", .revision = "aegis-0.0.0-one", .puller = "shakedown" },
        .{ .name = "aegis", .revision = "aegis-0.0.0-one", .puller = "reactor" },
    };
    try std.testing.expectEqual(@as(usize, 0), (try conflicts(arena.allocator(), &links, "conduit", .null)).len);
}

test "the package under test and a named exception may meet a second revision of themselves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const links = [_]Link{
        .{ .name = "aegis", .revision = "", .puller = "" },
        .{ .name = "aegis", .revision = "aegis-0.0.0-pinned", .puller = "shakedown" },
        .{ .name = "glint", .revision = "glint-0.1.0-a", .puller = "" },
        .{ .name = "glint", .revision = "glint-0.1.0-b", .puller = "gantry" },
    };
    const found = try conflicts(a, &links, "aegis", .null);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("glint", found[0].name);
    const allowed = (try std.json.parseFromSlice(src.Value, a, "{\"glint\":\"gantry waits for its glint pin\"}", .{})).value;
    try std.testing.expectEqual(@as(usize, 0), (try conflicts(a, &links, "aegis", allowed)).len);
}

test "a package name is the start of its hash" {
    try std.testing.expectEqualStrings("aegis", packageName("aegis-0.0.0-rsxouifgBgBOnC8-wtmFrZSIUjR9aEYPYmZD1G-hASAz"));
    try std.testing.expectEqualStrings("odd", packageName("odd"));
}
