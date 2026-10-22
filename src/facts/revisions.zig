//! The linked graph of each artifact the package builds: what its modules import,
//! package by package. Two checks hold it to one shape, for any project:
//!
//! - one revision of each package: two revisions are two sets of types that do
//!   not unify, and two sets of any state the package holds once per program;
//! - no cycle between packages: a package that links back to one it is linked
//!   by makes every move of either ripple through both.
//!
//! The package under test is held to the first as much as any other: a package
//! cannot pin its own commit, so a second revision of it in its own artifact is
//! always a cycle through a dependency's pin. A dependency that links the package
//! (test support built on its types) and is given the package's own module, as
//! bay gives it, holds one copy and no pin, so that edge is no cycle.
//!
//! A package that may be linked in two revisions is named in the manifest's
//! `.coexist`, the field bay reads for the same choice.
//!
//! The check reads the configured build, not the manifests: a revision that an
//! injected module or a dependency's own pin brings is as much in the artifact
//! as one the package names. Programs built from another package's sources (a
//! checker's tools) link nothing of the package and are not its artifacts.
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

/// The packages `links` holds in more than one revision. A package `coexist` names
/// may hold one revision per line (a major version, or below 1.0 a minor one), as
/// bay selects it: two revisions on one line are still a conflict.
/// `root_name` names the package under test, whose revision is empty.
pub fn conflicts(a: std.mem.Allocator, links: []const Link, root_name: []const u8, coexist: []const []const u8) ![]const Conflict {
    // One group per package, or per package and line for a package that may coexist.
    var groups: std.ArrayList([]const u8) = .empty;
    for (links) |link| {
        const group = try groupOf(a, link, coexist);
        if (!has(groups.items, group)) try groups.append(a, group);
    }
    var found: std.ArrayList(Conflict) = .empty;
    for (groups.items) |group| {
        const name = group[0 .. std.mem.findScalar(u8, group, '@') orelse group.len];
        var revisions: std.ArrayList(Conflict.Revision) = .empty;
        var pullers: std.ArrayList(std.ArrayList([]const u8)) = .empty;
        for (links) |link| {
            if (!std.mem.eql(u8, try groupOf(a, link, coexist), group)) continue;
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
        for (revisions.items, pullers.items) |*revision, *list| revision.pullers = try list.toOwnedSlice(a);
        if (revisions.items.len > 1) try found.append(a, .{ .name = name, .revisions = revisions.items });
    }
    return found.items;
}

/// The group a link is counted in: its package, and for a package `coexist` names
/// its line too, as `name@line`.
fn groupOf(a: std.mem.Allocator, link: Link, coexist: []const []const u8) ![]const u8 {
    if (!has(coexist, link.name)) return link.name;
    return a.print("{s}@{s}", .{ link.name, try line(a, link.revision) });
}

/// The line of a package hash, `name-version-<44 characters>`: the major version, or
/// below 1.0 `0.minor`. A hash with no version Zig gave (a path's) is a line of its own.
pub fn line(a: std.mem.Allocator, hash: []const u8) ![]const u8 {
    const name = packageName(hash);
    if (hash.len < name.len + 1 + 1 + 1 + 44) return hash;
    const version = std.SemanticVersion.parse(hash[name.len + 1 .. hash.len - 45]) catch return hash;
    return if (version.major == 0) a.print("0.{d}", .{version.minor}) else a.print("{d}", .{version.major});
}

fn has(list: []const []const u8, item: []const u8) bool {
    for (list) |known| if (std.mem.eql(u8, known, item)) return true;
    return false;
}

/// The name a package hash starts with: `aegis` of `aegis-0.0.0-AAAA...`.
pub fn packageName(hash: []const u8) []const u8 {
    return hash[0 .. std.mem.findScalar(u8, hash, '-') orelse hash.len];
}

/// An import between two packages of an artifact, by name: the importer's and the imported's.
pub const Edge = struct { from: []const u8, to: []const u8 };

/// A cycle among the packages `edges` join, as the names along it with the first
/// repeated at the end, or null when they form none.
pub fn cycle(a: std.mem.Allocator, edges: []const Edge) !?[]const []const u8 {
    var names: std.array_hash_map.String(void) = .empty;
    for (edges) |edge| {
        try names.put(a, edge.from, {});
        try names.put(a, edge.to, {});
    }
    const State = enum { new, open, done };
    const state = try a.alloc(State, names.count());
    @memset(state, .new);
    var path: std.ArrayList(usize) = .empty;
    for (0..names.count()) |start| {
        if (state[start] != .new) continue;
        if (try visit(a, names.keys(), edges, state, &path, start)) |closing| {
            const at = std.mem.findScalar(usize, path.items, closing).?;
            var found: std.ArrayList([]const u8) = .empty;
            for (path.items[at..]) |index| try found.append(a, names.keys()[index]);
            try found.append(a, names.keys()[closing]);
            return found.items;
        }
    }
    return null;
}

/// Depth-first from `node`: the node an edge closes a cycle on, with `path` left
/// holding the walk to it, or null.
fn visit(a: std.mem.Allocator, names: []const []const u8, edges: []const Edge, state: anytype, path: *std.ArrayList(usize), node: usize) !?usize {
    state[node] = .open;
    try path.append(a, node);
    for (edges) |edge| {
        if (!std.mem.eql(u8, edge.from, names[node])) continue;
        const next = for (names, 0..) |name, i| {
            if (std.mem.eql(u8, name, edge.to)) break i;
        } else unreachable; // every edge's ends were named
        switch (state[next]) {
            .open => return next,
            .new => if (try visit(a, names, edges, state, path, next)) |closing| return closing,
            .done => {},
        }
    }
    _ = path.pop();
    state[node] = .done;
    return null;
}

/// What an artifact links: its root module's package, and each package one of its
/// modules imports a module of, with the package that imports it; and the imports
/// between packages, by name, but for a dependency given the package's own module.
pub const Graph = struct { links: []const Link, edges: []const Edge };

/// The packages an artifact links: `package` is the one checked, the root or, under
/// bay, the root's dependency at its directory, and is named `root_name`.
pub fn artifactGraph(a: std.mem.Allocator, config: *const C, package: C.Package.Index, root: C.Module.Index, root_name: []const u8) !Graph {
    var links: std.ArrayList(Link) = .empty;
    var edges: std.ArrayList(Edge) = .empty;
    var seen: std.AutoHashMapUnmanaged(C.Module.Index, void) = .empty;
    var pending: std.ArrayList(C.Module.Index) = .empty;
    try pending.append(a, root);
    try links.append(a, try linkOf(a, config, package, root.get(config).owner, root_name, ""));
    while (pending.pop()) |id| {
        if ((try seen.getOrPut(a, id)).found_existing) continue;
        const module = id.get(config);
        const puller = try label(a, config, module.owner);
        const from = (try linkOf(a, config, package, module.owner, root_name, "")).name;
        const imports = module.import_table.get(config).imports.mal;
        for (imports.items(.module)) |imported| {
            try pending.append(a, imported);
            const owner = imported.get(config).owner;
            if (owner == module.owner) continue;
            const link = try linkOf(a, config, package, owner, root_name, puller);
            try links.append(a, link);
            // A dependency given the package's own module (as bay gives it) holds no second copy.
            // A second revision of the same package is the revision check's to report and except.
            if (!checked(config, owner, package) and !std.mem.eql(u8, from, link.name)) try edges.append(a, .{ .from = from, .to = link.name });
        }
    }
    return .{ .links = links.items, .edges = edges.items };
}

fn label(a: std.mem.Allocator, config: *const C, owner: C.Package.Index) ![]const u8 {
    const prefix = owner.depPrefixSlice(config);
    return a.dupe(u8, std.mem.trimEnd(u8, prefix, "."));
}

/// Whether `owner` is the checked package: the root, or any instance of the package
/// (a build makes one per set of options it is asked with), all at one root.
fn checked(config: *const C, owner: C.Package.Index, package: C.Package.Index) bool {
    if (owner == .root or owner == package) return true;
    const mine = package.get(config) orelse return false;
    const theirs = owner.get(config) orelse return false;
    return std.mem.eql(u8, mine.root_path.slice(config), theirs.root_path.slice(config));
}

fn linkOf(a: std.mem.Allocator, config: *const C, checked_package: C.Package.Index, owner: C.Package.Index, root_name: []const u8, puller: []const u8) !Link {
    if (checked(config, owner, checked_package)) return .{ .name = root_name, .revision = "", .puller = puller };
    const package = owner.get(config).?;
    const hash = try a.dupe(u8, package.hash.slice(config));
    return .{ .name = packageName(hash), .revision = hash, .puller = puller };
}

/// Whether the module's root file is the package's own, or generated; a file of a dependency is not.
fn ownSource(config: *const C, package: C.Package.Index, module: C.Module.Index) bool {
    const file = module.get(config).root_source_file.unwrap() orelse return true;
    return switch (file.get(config)) {
        .source_path => |source| checked(config, source.owner, package),
        else => true,
    };
}

/// Fails the check for each cycle and each package in two revisions in an artifact of the root package.
pub fn check(c: *src.Context, config: *const C, package: C.Package.Index, root_name: []const u8, coexist: []const []const u8) !void {
    if (has(coexist, root_name)) c.fail("build.zig.zon: .coexist names {s} itself; a package builds one line of itself", .{root_name});
    // The same finding in several artifacts is reported once.
    var findings: std.array_hash_map.String(std.ArrayList([]const u8)) = .empty;
    for (config.steps) |step| {
        if (!checked(config, step.owner, package)) continue;
        const compile = step.extended.cast(config, C.Step.Compile) orelse continue;
        // A checker's own tools, built in the package's graph from the checker's sources, are not the package's.
        if (!ownSource(config, package, compile.root_module)) continue;
        const graph = try artifactGraph(c.a, config, package, compile.root_module, root_name);
        var texts: std.ArrayList([]const u8) = .empty;
        var cyclic: []const []const u8 = &.{};
        if (try cycle(c.a, graph.edges)) |names| {
            cyclic = names;
            var text: std.Io.Writer.Allocating = .init(c.a);
            try text.writer.writeAll("the linked packages form a cycle: ");
            for (names, 0..) |name, i| try text.writer.print("{s}{s}", .{ if (i == 0) "" else " -> ", name });
            try text.writer.writeAll("\n  a package linked by another must not link it back: a dependency that needs this package's types is given its module, as bay gives it; one only CI or tests use is a dev dependency, or lazy, and stays out of the artifact");
            try texts.append(c.a, text.written());
        }
        for (try conflicts(c.a, graph.links, root_name, coexist)) |conflict| {
            // A cycle through a pin shows as two revisions of a package on it; the cycle says why.
            if (has(cyclic, conflict.name)) continue;
            var text: std.Io.Writer.Allocating = .init(c.a);
            try text.writer.print("{s} is linked in {d} revisions:", .{ conflict.name, conflict.revisions.len });
            for (conflict.revisions) |revision| {
                try text.writer.print("\n  {s} pulled by ", .{if (revision.revision.len == 0) "this package" else revision.revision});
                for (revision.pullers, 0..) |puller, i| try text.writer.print("{s}{s}", .{ if (i == 0) "" else ", ", puller });
            }
            try text.writer.writeAll("\n  one revision of each package in an artifact: build with bay, which selects one version of each package for the graph, or pin the same revision everywhere; a package two revisions of which may meet is named in build.zig.zon's .coexist");
            try texts.append(c.a, text.written());
        }
        for (texts.items) |text| {
            const entry = try findings.getOrPut(c.a, text);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(c.a, step.name.slice(config));
        }
    }
    for (findings.keys(), findings.values()) |text, artifacts| {
        c.fail("{s}\n  in `{s}`{s}", .{
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
    const found = try conflicts(a, &links, "conduit", &.{});
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
    try std.testing.expectEqual(@as(usize, 0), (try conflicts(arena.allocator(), &links, "conduit", &.{})).len);
}

test "the package under test is held to one revision of itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const links = [_]Link{
        .{ .name = "aegis", .revision = "", .puller = "" },
        .{ .name = "aegis", .revision = "aegis-0.0.0-pinned", .puller = "shakedown" },
        .{ .name = "glint", .revision = "glint-0.1.0-a", .puller = "" },
        .{ .name = "glint", .revision = "glint-0.1.0-b", .puller = "gantry" },
    };
    const found = try conflicts(a, &links, "aegis", &.{});
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("aegis", found[0].name);
    try std.testing.expectEqualStrings("aegis", found[0].revisions[0].pullers[0]);
    try std.testing.expectEqualStrings("glint", found[1].name);
}

test "a package named in .coexist holds one revision per line, and two on one line still conflict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tail = "-" ++ @as([44]u8, @splat('A'));
    const lines = [_]Link{
        .{ .name = "glint", .revision = "glint-0.1.0" ++ tail, .puller = "" },
        .{ .name = "glint", .revision = "glint-0.2.0" ++ tail, .puller = "gantry" },
    };
    try std.testing.expectEqual(@as(usize, 1), (try conflicts(a, &lines, "app", &.{})).len);
    try std.testing.expectEqual(@as(usize, 0), (try conflicts(a, &lines, "app", &.{"glint"})).len);
    const same_line = lines ++ [_]Link{.{ .name = "glint", .revision = "glint-0.2.1" ++ tail, .puller = "sweep" }};
    const found = try conflicts(a, &same_line, "app", &.{"glint"});
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("glint", found[0].name);
    try std.testing.expectEqual(@as(usize, 2), found[0].revisions.len);
    try std.testing.expectEqualStrings("1", try line(a, "aegis-1.4.2" ++ tail));
    try std.testing.expectEqualStrings("0.3", try line(a, "aegis-0.3.9" ++ tail));
}

test "imports between packages that loop back are a cycle, named along it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(?[]const []const u8, null), try cycle(a, &.{}));
    const tree = [_]Edge{ .{ .from = "app", .to = "net" }, .{ .from = "app", .to = "core" }, .{ .from = "net", .to = "core" } };
    try std.testing.expectEqual(@as(?[]const []const u8, null), try cycle(a, &tree));
    const loop = [_]Edge{ .{ .from = "app", .to = "lint" }, .{ .from = "lint", .to = "core" }, .{ .from = "core", .to = "lint" } };
    const found = (try cycle(a, &loop)).?;
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqualStrings("lint", found[0]);
    try std.testing.expectEqualStrings("core", found[1]);
    try std.testing.expectEqualStrings("lint", found[2]);
    const self = [_]Edge{ .{ .from = "core", .to = "test-support" }, .{ .from = "test-support", .to = "core" } };
    try std.testing.expectEqualStrings("core", (try cycle(a, &self)).?[0]);
}

test "a package name is the start of its hash" {
    try std.testing.expectEqualStrings("aegis", packageName("aegis-0.0.0-rsxouifgBgBOnC8-wtmFrZSIUjR9aEYPYmZD1G-hASAz"));
    try std.testing.expectEqualStrings("odd", packageName("odd"));
}
