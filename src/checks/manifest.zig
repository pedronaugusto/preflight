//! What a fetched package holds: `build.zig.zon`'s `.paths` names exactly
//! what a consumer's build reads (the build files and the source roots)
//! and the three files a user reads (licence, README, changelog). Anything
//! else, benchmarks, CI or examples, stays in the repository.
const std = @import("std");
const gantry = @import("gantry");
const src = @import("source.zig");
const configure = @import("../configure.zig");

/// The files every fetched package ships besides its source roots.
pub const shipped = [_][]const u8{ "build.zig", "build.zig.zon", "LICENSE", "README.md", "CHANGELOG.md" };

const Manifest = struct { paths: []const []const u8 };

/// The package's name, as its manifest declares it.
pub fn name(c: *src.Context) ![]const u8 {
    const source = try c.a.dupeSentinel(u8, try c.read("build.zig.zon"), 0);
    const ast = try std.zig.Ast.parse(c.a, source, .{ .mode = .zon });
    const zoir = try std.zig.ZonGen.generate(c.a, ast, .{});
    if (zoir.hasCompileErrors()) {
        c.fail("build.zig.zon: not valid ZON", .{});
        return error.InvalidManifest;
    }
    const root = std.zig.Zoir.Node.Index.root.get(&zoir);
    if (root != .struct_literal) return error.InvalidManifest;
    for (root.struct_literal.names, 0..) |field, i| {
        if (!std.mem.eql(u8, field.get(&zoir), "name")) continue;
        const value = root.struct_literal.vals.at(@intCast(i)).get(&zoir);
        if (value != .enum_literal) return error.InvalidManifest;
        return try c.a.dupe(u8, value.enum_literal.get(&zoir));
    }
    return error.InvalidManifest;
}

pub fn paths(c: *src.Context, config: src.Value) !void {
    const text = try c.a.dupeSentinel(u8, try c.read("build.zig.zon"), 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = std.zon.parse.fromSlice(Manifest, .{
        .gpa = c.a,
        .arena = c.a,
        .source = text,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            c.fail("{f}", .{diagnostics.fmt("build.zig.zon")});
            return;
        },
    };
    try check(c, manifest.paths, try src.roots(c.a, config), src.get(config, "shipped"));
}

/// `listed` is the manifest's `.paths`; `extra` maps each further path the
/// package ships to why a consumer's build needs it.
fn check(c: *src.Context, listed: []const []const u8, roots: []const []const u8, extra: src.Value) !void {
    var wanted: std.ArrayList([]const u8) = .empty;
    try wanted.appendSlice(c.a, &shipped);
    try wanted.appendSlice(c.a, roots);
    if (extra != .null and extra != .object) {
        c.fail("ci/preflight.json: shipped maps each path to its reason", .{});
        return;
    }
    if (extra == .object) for (extra.object.keys(), extra.object.values()) |path, reason| {
        if (src.string(reason, "").len == 0) c.fail("ci/preflight.json: shipped: {s}: say why a consumer's build needs it", .{path});
        try wanted.append(c.a, path);
    };
    // A package without a README or a changelog is not made to write one; one it has, it ships.
    for (wanted.items) |path| if (!contains(listed, path) and c.exists(path))
        c.fail("build.zig.zon: .paths leaves out {s}, which a fetched package needs", .{path});
    for (listed) |path| if (!c.exists(path))
        c.fail("build.zig.zon: .paths names {s}, which does not exist", .{path});
    for (listed) |path| if (!contains(wanted.items, path))
        c.fail("build.zig.zon: .paths ships {s}, which no consumer's build reads; drop it, or name it in ci/preflight.json shipped with its reason", .{path});
}

fn contains(list: []const []const u8, path: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, path)) return true;
    return false;
}

test "a package ships its build, its sources and what a user reads, and nothing else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (shipped) |file| try tmp.dir.writeFile(io, .{ .sub_path = file, .data = "" });
    for ([_][]const u8{ "src", "bench", ".github", "data", "fixtures" }) |dir| try tmp.dir.createDirPath(io, dir);
    var c: src.Context = .{ .a = a, .io = io, .dir = tmp.dir };
    const exact = shipped ++ [_][]const u8{"src"};
    try check(&c, &exact, &.{"src"}, .null);
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    // Benchmarks, CI and a missing changelog.
    try check(&c, &.{ "build.zig", "build.zig.zon", "LICENSE", "README.md", "src", "bench", ".github" }, &.{"src"}, .null);
    try std.testing.expectEqual(@as(usize, 3), c.errors);
    c.errors = 0;
    const data = (try std.json.parseFromSlice(src.Value, a, "{\"data\":\"the tables the module embeds\",\"fixtures\":\"\"}", .{})).value;
    try check(&c, &(exact ++ [_][]const u8{ "data", "fixtures" }), &.{"src"}, data);
    try std.testing.expectEqual(@as(usize, 1), c.errors);
}

test "a path .paths names must exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (shipped) |file| if (!std.mem.eql(u8, file, "LICENSE")) try tmp.dir.writeFile(io, .{ .sub_path = file, .data = "" });
    try tmp.dir.createDirPath(io, "src");
    var c: src.Context = .{ .a = arena.allocator(), .io = io, .dir = tmp.dir };
    try check(&c, &(shipped ++ [_][]const u8{"src"}), &.{"src"}, .null);
    try std.testing.expectEqual(@as(usize, 1), c.errors);
    // Nor is a file the package does not have required of it.
    c.errors = 0;
    try check(&c, &.{ "build.zig", "build.zig.zon", "README.md", "CHANGELOG.md", "src" }, &.{"src"}, .null);
    try std.testing.expectEqual(@as(usize, 0), c.errors);
}

/// Every other manifest in the repository (a fixture's, a conformance build's)
/// pins each package the package's own manifest pins exactly as it does: a
/// fixture that pins its own copy goes stale at the next re-pin, and tests a
/// revision nothing ships. A package it does not share is its own business.
pub fn nested(c: *src.Context) !void {
    const own = try gantry.manifests.parse(c.a, "build.zig.zon", try c.read("build.zig.zon"));
    var dir = try c.directory().openDir(c.io, ".", .{ .iterate = true });
    defer dir.close(c.io);
    var walker = try dir.walkSelectively(c.a);
    defer walker.deinit();
    while (try walker.next(c.io)) |entry| {
        if (entry.kind == .directory) {
            if (!configure.generated(entry.basename)) try walker.enter(c.io, entry);
            continue;
        }
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, "build.zig.zon") or std.mem.eql(u8, entry.path, "build.zig.zon")) continue;
        const path = try c.a.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, path, '\\', '/');
        const pins = gantry.manifests.parse(c.a, "build.zig.zon", try c.read(path)) catch {
            c.fail("{s}: not a manifest preflight can read", .{path});
            continue;
        };
        for (try drift(c.a, own, pins)) |found| c.fail("{s}: pins {s} at {s}, while build.zig.zon pins it at {s}; give it the same .url and .hash, or take the package by .path", .{ path, found.name, found.theirs, found.ours });
    }
}

pub const Drift = struct { name: []const u8, ours: []const u8, theirs: []const u8 };

/// The remote pins in `pins` that name a package `own` also pins remotely, at another revision.
pub fn drift(a: std.mem.Allocator, own: []const gantry.Dependency, pins: []const gantry.Dependency) ![]const Drift {
    var found: std.ArrayList(Drift) = .empty;
    for (pins) |pin| {
        if (pin.origin != .remote) continue;
        for (own) |ours| {
            if (ours.origin != .remote or !std.mem.eql(u8, ours.name, pin.name)) continue;
            if (std.mem.eql(u8, ours.source, pin.source) and std.mem.eql(u8, ours.requirement, pin.requirement)) continue;
            try found.append(a, .{ .name = pin.name, .ours = ours.source, .theirs = pin.source });
        }
    }
    return found.items;
}

test "a nested manifest pins a shared package as the package does, and anything else as it likes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const own = try gantry.manifests.parse(a, "build.zig.zon",
        \\.{ .name = .pkg, .version = "0.0.0", .dependencies = .{
        \\    .core = .{ .url = "git+https://example.com/core#1111111111111111111111111111111111111111", .hash = "core-0.1.0-AAAA" },
        \\    .tools = .{ .url = "git+https://example.com/tools#2222222222222222222222222222222222222222", .hash = "tools-0.1.0-BBBB", .lazy = true },
        \\} }
    );
    const same = try gantry.manifests.parse(a, "build.zig.zon",
        \\.{ .name = .fixture, .version = "0.0.0", .dependencies = .{
        \\    .pkg = .{ .path = "../.." },
        \\    .core = .{ .url = "git+https://example.com/core#1111111111111111111111111111111111111111", .hash = "core-0.1.0-AAAA" },
        \\    .emulator = .{ .url = "git+https://example.com/emulator#3333333333333333333333333333333333333333", .hash = "emulator-1-CCCC" },
        \\} }
    );
    try std.testing.expectEqual(@as(usize, 0), (try drift(a, own, same)).len);
    const stale = try gantry.manifests.parse(a, "build.zig.zon",
        \\.{ .name = .fixture, .version = "0.0.0", .dependencies = .{
        \\    .core = .{ .url = "git+https://example.com/core#0000000000000000000000000000000000000000", .hash = "core-0.1.0-ZZZZ" },
        \\    .tools = .{ .url = "git+https://example.com/tools#2222222222222222222222222222222222222222", .hash = "tools-0.1.0-YYYY" },
        \\} }
    );
    const found = try drift(a, own, stale);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("core", found[0].name);
    try std.testing.expectEqualStrings("tools", found[1].name);
}
