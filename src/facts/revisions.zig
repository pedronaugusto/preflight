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
//! always a cycle through a dependency's pin. A dependency that must link the
//! package (test support built on its types) takes the package's own module,
//! bound by the build script; that edge is one copy and no pin, so it is no cycle.
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

/// The packages `links` holds in more than one revision, except those `allowed` names.
/// `root_name` names the package under test, whose revision is empty.
pub fn conflicts(a: std.mem.Allocator, links: []const Link, root_name: []const u8, allowed: src.Value) ![]const Conflict {
    var names: std.ArrayList([]const u8) = .empty;
    for (links) |link| {
        if (src.get(allowed, link.name) != .null) continue;
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
/// between packages, by name, but for a dependency bound to the package's own module.
pub const Graph = struct { links: []const Link, edges: []const Edge };

pub fn artifactGraph(a: std.mem.Allocator, config: *const C, root: C.Module.Index, root_name: []const u8) !Graph {
    var links: std.ArrayList(Link) = .empty;
    var edges: std.ArrayList(Edge) = .empty;
    var seen: std.AutoHashMapUnmanaged(C.Module.Index, void) = .empty;
    var pending: std.ArrayList(C.Module.Index) = .empty;
    try pending.append(a, root);
    try links.append(a, try linkOf(a, config, root.get(config).owner, root_name, ""));
    while (pending.pop()) |id| {
        if ((try seen.getOrPut(a, id)).found_existing) continue;
        const module = id.get(config);
        const puller = try label(a, config, module.owner);
        const from = (try linkOf(a, config, module.owner, root_name, "")).name;
        const imports = module.import_table.get(config).imports.mal;
        for (imports.items(.module)) |imported| {
            try pending.append(a, imported);
            const owner = imported.get(config).owner;
            if (owner == module.owner) continue;
            const link = try linkOf(a, config, owner, root_name, puller);
            try links.append(a, link);
            // A dependency bound to the package's own module holds no second copy and no pin.
            // A second revision of the same package is the revision check's to report and except.
            if (owner != .root and !std.mem.eql(u8, from, link.name)) try edges.append(a, .{ .from = from, .to = link.name });
        }
    }
    return .{ .links = links.items, .edges = edges.items };
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

/// Fails the check for each cycle and each package in two revisions in an artifact of the root package.
pub fn check(c: *src.Context, config: *const C, root_name: []const u8, allowed: src.Value) !void {
    if (allowed != .null and allowed != .object) {
        c.fail("ci/preflight.json: revision_exceptions maps each package to why two of its revisions may meet", .{});
        return;
    }
    if (allowed == .object) for (allowed.object.keys(), allowed.object.values()) |name, reason| {
        if (src.string(reason, "").len == 0) c.fail("ci/preflight.json: revision_exceptions: {s}: say why two revisions may meet", .{name});
    };
    // The same finding in several artifacts is reported once.
    var findings: std.array_hash_map.String(std.ArrayList([]const u8)) = .empty;
    for (config.steps) |step| {
        if (step.owner != .root) continue;
        const compile = step.extended.cast(config, C.Step.Compile) orelse continue;
        // A checker's own tools, built in the package's graph from the checker's sources, are not the package's.
        if (!ownSource(config, compile.root_module)) continue;
        const graph = try artifactGraph(c.a, config, compile.root_module, root_name);
        var texts: std.ArrayList([]const u8) = .empty;
        var cyclic: []const []const u8 = &.{};
        if (try cycle(c.a, graph.edges)) |names| {
            cyclic = names;
            var text: std.Io.Writer.Allocating = .init(c.a);
            try text.writer.writeAll("the linked packages form a cycle: ");
            for (names, 0..) |name, i| try text.writer.print("{s}{s}", .{ if (i == 0) "" else " -> ", name });
            try text.writer.writeAll("\n  a package linked by another must not link it back: a dependency that needs this package's types takes its module, bound by the build script; one only CI or tests use is lazy and stays out of the artifact");
            try texts.append(c.a, text.written());
        }
        for (try conflicts(c.a, graph.links, root_name, allowed)) |conflict| {
            // A cycle through a pin shows as two revisions of a package on it; the cycle says why.
            if (has(cyclic, conflict.name)) continue;
            var text: std.Io.Writer.Allocating = .init(c.a);
            try text.writer.print("{s} is linked in {d} revisions:", .{ conflict.name, conflict.revisions.len });
            for (conflict.revisions) |revision| {
                try text.writer.print("\n  {s} pulled by ", .{if (revision.revision.len == 0) "this package" else revision.revision});
                for (revision.pullers, 0..) |puller, i| try text.writer.print("{s}{s}", .{ if (i == 0) "" else ", ", puller });
            }
            try text.writer.writeAll("\n  one revision of each package in an artifact: pin the same one everywhere, bind a dependency to this package's own module, or say in ci/preflight.json revision_exceptions why they may meet");
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

test "the package under test is held to one revision of itself, and a named exception may meet two" {
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
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("aegis", found[0].name);
    try std.testing.expectEqualStrings("aegis", found[0].revisions[0].pullers[0]);
    try std.testing.expectEqualStrings("glint", found[1].name);
    const allowed = (try std.json.parseFromSlice(src.Value, a, "{\"glint\":\"gantry waits for its glint pin\"}", .{})).value;
    try std.testing.expectEqual(@as(usize, 1), (try conflicts(a, &links, "aegis", allowed)).len);
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
