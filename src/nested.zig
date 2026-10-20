//! A build nested in the package (a conformance build against an emulator that is not the package's,
//! a fixture), assembled under the cache and run there: its files copied from the package's
//! `directory`, its manifest written from the package's own, so a package it shares with the package
//! is pinned once and cannot drift. Nothing is written into the package's tree, which keeps only the
//! nested build's sources, and the package may be the root or a dependency, as in a development
//! build. The build runs this file as a program to assemble and run the nested build.
const std = @import("std");
const configure = @import("configure.zig");

/// A package pinned by its source and hash.
pub const Pin = struct { name: []const u8, url: []const u8, hash: []const u8, lazy: bool = false };

/// A package taken by path.
pub const PathDependency = struct { name: []const u8, path: []const u8 };

pub const Options = struct {
    /// The nested build's directory, relative to the package.
    directory: []const u8,
    /// The manifest's `.name`.
    name: []const u8,
    fingerprint: u64,
    version: []const u8 = "0.0.0",
    minimum_zig_version: []const u8 = "0.17.0",
    /// What the manifest names as its own files.
    paths: []const []const u8 = &.{ "build.zig", "build.zig.zon" },
    /// Packages taken by path from the nested directory; the package itself is `.{ .name = "pkg", .path = ".." }`.
    path_dependencies: []const PathDependency = &.{},
    /// Packages the package pins and the nested build uses at the same revision: their source and hash are
    /// read from the package's `build.zig.zon` when the build is configured.
    shared: []const []const u8 = &.{},
    /// Packages only the nested build pins.
    pins: []const Pin = &.{},
    /// What follows `zig build` in the nested build: its step and options.
    args: []const []const u8 = &.{"test"},
};

/// Adds the step that assembles the build nested in `package` under `b`'s cache and runs
/// it there with `options.args`. `b` is the build that owns the step: the package's own,
/// where `zig build` runs it, or its development build, where `bay build` does, so the
/// nested graph is resolved as the package's is: one version of each package, a shared
/// package's own pins included.
pub fn add(b: *std.Build, package: *std.Build, options: Options) *std.Build.Step {
    const root = configure.read(package, "build.zig.zon", .limited(1024 * 1024)) orelse std.debug.panic("addNestedBuild: {s} has no build.zig.zon to share pins from", .{options.directory});
    const text = generate(b.allocator, root, options) catch |err| std.debug.panic("addNestedBuild: {s}: {t}", .{ options.directory, err });
    const manifest = b.addWriteFiles().add("build.zig.zon", text);
    // Fetched lazily: until it is, this configure pass ends and the step is never run.
    const pkg = b.dependencyLazy("preflight", .{}) catch return &b.addWriteFiles().step;
    const program = b.addExecutable(.{ .name = "preflight-nested", .root_module = b.createModule(.{
        .root_source_file = pkg.builder.path("src/nested.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    }) });
    const run = b.addRunArtifact(program);
    run.addArg(configure.bay(b, package) orelse b.graph.zig_exe);
    _ = run.addOutputDirectoryArg2(options.name, .{});
    run.addDirectoryArg2(package.path(options.directory), .{});
    run.addFileArg(manifest);
    for (options.paths) |path| if (!std.mem.eql(u8, path, "build.zig.zon")) run.addArg(path);
    run.addArg("--");
    run.addArgs(options.args);
    run.has_side_effects = true;
    return &run.step;
}

/// `<zig or bay> <out> <nested> <manifest> <path>... -- <build arguments>`: copies each path
/// of the nested build from `nested` into `out`, writes `manifest` there with every path
/// dependency, written relative to `nested`, made relative to `out`, and runs `<zig or bay>
/// build` in `out`, exiting as it exits.
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 6) return error.MissingNestedArguments;
    const cwd = std.Io.Dir.cwd();
    const out = try cwd.realPathFileAlloc(io, args[2], a);
    const nested = try cwd.realPathFileAlloc(io, args[3], a);
    var source = try cwd.openDir(io, nested, .{ .iterate = true });
    defer source.close(io);
    var target = try cwd.openDir(io, out, .{});
    defer target.close(io);
    var next: usize = 5;
    while (next < args.len and !std.mem.eql(u8, args[next], "--")) : (next += 1) try copy(io, a, source, target, args[next]);
    if (next == args.len) return error.MissingNestedArguments;
    const text = try cwd.readFileAlloc(io, args[4], a, .limited(1024 * 1024));
    try target.writeFile(io, .{ .sub_path = "build.zig.zon", .data = try relocate(a, text, nested, out) });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ args[1], "build" });
    try argv.appendSlice(a, args[next + 1 ..]);
    var child = try std.process.spawn(io, .{ .argv = argv.items, .cwd = .{ .path = out } });
    const term = try child.wait(io);
    std.process.exit(if (term == .exited) term.exited else 1);
}

/// Copies `path`, a file or a directory, from `from` to `to`.
fn copy(io: std.Io, a: std.mem.Allocator, from: std.Io.Dir, to: std.Io.Dir, path: []const u8) !void {
    const stat = try from.statFile(io, path, .{});
    if (stat.kind != .directory) {
        if (std.Io.Dir.path.dirname(path)) |parent| try to.createDirPath(io, parent);
        return from.copyFile(path, to, path, io, .{});
    }
    var dir = try from.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const inner = try std.Io.Dir.path.join(a, &.{ path, entry.path });
        switch (entry.kind) {
            .directory => try to.createDirPath(io, inner),
            .file => try copy(io, a, from, to, inner),
            else => {},
        }
    }
}

/// `manifest` with each `.path = "<p>"`, relative to `from`, made relative to `to`, with `/`.
pub fn relocate(a: std.mem.Allocator, manifest: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    const key = ".path = \"";
    var out: std.Io.Writer.Allocating = .init(a);
    var rest = manifest;
    while (std.mem.find(u8, rest, key)) |at| {
        const start = at + key.len;
        const end = std.mem.findScalarPos(u8, rest, start, '"') orelse return error.InvalidManifest;
        const absolute = try std.Io.Dir.path.resolveAlloc(a, &.{ from, rest[start..end] });
        const relative = try std.Io.Dir.path.relativeAlloc(a, to, null, to, absolute);
        std.mem.replaceScalar(u8, relative, '\\', '/');
        try out.writer.print("{s}{f}", .{ rest[0..start], std.zig.fmtString(relative) });
        rest = rest[end..];
    }
    try out.writer.writeAll(rest);
    return out.written();
}

/// The nested manifest for `options`, its shared pins taken from the package's manifest `root`.
pub fn generate(a: std.mem.Allocator, root: []const u8, options: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print(
        \\// Generated by preflight from the package's build.zig.zon: do not edit or commit.
        \\.{{
        \\    .name = .{f},
        \\    .version = "{f}",
        \\    .fingerprint = 0x{x},
        \\    .minimum_zig_version = "{f}",
        \\    .paths = .{{
    , .{ std.zig.fmtId(options.name), std.zig.fmtString(options.version), options.fingerprint, std.zig.fmtString(options.minimum_zig_version) });
    for (options.paths, 0..) |path, i| try w.print("{s} \"{f}\"", .{ if (i == 0) "" else ",", std.zig.fmtString(path) });
    try w.writeAll(" },\n    .dependencies = .{\n");
    for (options.path_dependencies) |dependency| try w.print("        .{f} = .{{ .path = \"{f}\" }},\n", .{ std.zig.fmtId(dependency.name), std.zig.fmtString(dependency.path) });
    for (options.shared) |name| try pin(w, try sharedPin(a, root, name));
    for (options.pins) |each| try pin(w, each);
    try w.writeAll("    },\n}\n");
    return out.written();
}

fn pin(w: *std.Io.Writer, each: Pin) !void {
    try w.print("        .{f} = .{{\n            .url = \"{f}\",\n            .hash = \"{f}\",\n        }},\n", .{ std.zig.fmtId(each.name), std.zig.fmtString(each.url), std.zig.fmtString(each.hash) });
}

/// The source and hash `root` (a `build.zig.zon`) pins `name` at, as a dependency
/// or a dev dependency.
pub fn sharedPin(a: std.mem.Allocator, root: []const u8, name: []const u8) !Pin {
    const source = try a.dupeSentinel(u8, root, 0);
    const ast = try std.zig.Ast.parse(a, source, .{ .mode = .zon });
    const zoir = try std.zig.ZonGen.generate(a, ast, .{});
    if (zoir.hasCompileErrors()) return error.InvalidManifest;
    const top = std.zig.Zoir.Node.Index.root.get(&zoir);
    if (top != .struct_literal) return error.InvalidManifest;
    const entry = for ([_][]const u8{ "dependencies", "dev_dependencies" }) |list| {
        const dependencies = field(&zoir, top, list) orelse continue;
        if (dependencies == .empty_literal) continue;
        if (dependencies != .struct_literal) return error.InvalidManifest;
        if (field(&zoir, dependencies, name)) |found| break found;
    } else return error.NotPinnedByPackage;
    if (entry != .struct_literal) return error.InvalidManifest;
    const url = field(&zoir, entry, "url") orelse return error.SharedPackageIsNotPinned;
    const hash = field(&zoir, entry, "hash") orelse return error.SharedPackageIsNotPinned;
    if (url != .string_literal or hash != .string_literal) return error.InvalidManifest;
    return .{ .name = name, .url = url.string_literal, .hash = hash.string_literal };
}

/// Every package `root` (a `build.zig.zon`) pins by source and hash: its dependencies, then its
/// dev dependencies. A package taken by path is no pin.
pub fn pins(a: std.mem.Allocator, root: []const u8) ![]const Pin {
    return pinsIn(a, root, &.{ "dependencies", "dev_dependencies" });
}

/// The pins of the lists named, of `.dependencies` and `.dev_dependencies`.
pub fn pinsIn(a: std.mem.Allocator, root: []const u8, lists: []const []const u8) ![]const Pin {
    const source = try a.dupeSentinel(u8, root, 0);
    const ast = try std.zig.Ast.parse(a, source, .{ .mode = .zon });
    const zoir = try std.zig.ZonGen.generate(a, ast, .{});
    if (zoir.hasCompileErrors()) return error.InvalidManifest;
    const top = std.zig.Zoir.Node.Index.root.get(&zoir);
    if (top != .struct_literal) return error.InvalidManifest;
    var found: std.ArrayList(Pin) = .empty;
    for (lists) |list| {
        const dependencies = field(&zoir, top, list) orelse continue;
        if (dependencies == .empty_literal) continue;
        if (dependencies != .struct_literal) return error.InvalidManifest;
        for (dependencies.struct_literal.names, 0..) |name, i| {
            const entry = dependencies.struct_literal.vals.at(@intCast(i)).get(&zoir); // safe: i < names.len, which is vals.len, a u32
            if (entry != .struct_literal) return error.InvalidManifest;
            const url = field(&zoir, entry, "url") orelse continue;
            const hash = field(&zoir, entry, "hash") orelse continue;
            if (url != .string_literal or hash != .string_literal) return error.InvalidManifest;
            const lazy = if (field(&zoir, entry, "lazy")) |value| value == .true else false;
            try found.append(a, .{ .name = name.get(&zoir), .url = url.string_literal, .hash = hash.string_literal, .lazy = lazy });
        }
    }
    return found.items;
}

/// The names `.coexist` lists, which may meet in a graph at one revision per line.
pub fn coexistIn(a: std.mem.Allocator, root: []const u8) ![]const []const u8 {
    const source = try a.dupeSentinel(u8, root, 0);
    const ast = try std.zig.Ast.parse(a, source, .{ .mode = .zon });
    const zoir = try std.zig.ZonGen.generate(a, ast, .{});
    if (zoir.hasCompileErrors()) return error.InvalidManifest;
    const top = std.zig.Zoir.Node.Index.root.get(&zoir);
    if (top != .struct_literal) return error.InvalidManifest;
    const list = field(&zoir, top, "coexist") orelse return &.{};
    var names: std.ArrayList([]const u8) = .empty;
    switch (list) {
        .empty_literal => {},
        .array_literal => |items| for (0..items.len) |i| {
            const item = items.at(@intCast(i)).get(&zoir); // safe: i < items.len, a u32
            // As bay reads it: `.coexist = .{ .name }`.
            if (item != .enum_literal) return error.InvalidManifest;
            try names.append(a, item.enum_literal.get(&zoir));
        },
        else => return error.InvalidManifest,
    }
    return names.items;
}

fn field(zoir: *const std.zig.Zoir, node: std.zig.Zoir.Node, name: []const u8) ?std.zig.Zoir.Node {
    for (node.struct_literal.names, 0..) |each, i| {
        if (std.mem.eql(u8, each.get(zoir), name)) return node.struct_literal.vals.at(@intCast(i)).get(zoir);
    }
    return null;
}

const root_manifest =
    \\.{
    \\    .name = .pkg,
    \\    .version = "0.3.0",
    \\    .dependencies = .{
    \\        .shakedown = .{
    \\            .url = "git+https://example.invalid/shakedown#1111111111111111111111111111111111111111",
    \\            .hash = "shakedown-0.1.0-AAAA",
    \\            .lazy = true,
    \\        },
    \\        .local = .{ .path = "local" },
    \\    },
    \\}
    \\
;

test "a nested manifest pins a shared package as the package does, and the rest as it is told" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try generate(a, root_manifest, .{
        .directory = "conformance",
        .name = "pkg_conformance",
        .fingerprint = 0xabc,
        .paths = &.{ "build.zig", "build.zig.zon", "main.zig" },
        .path_dependencies = &.{.{ .name = "pkg", .path = ".." }},
        .shared = &.{"shakedown"},
        .pins = &.{.{ .name = "emulator", .url = "git+https://example.invalid/emulator#2222", .hash = "emulator-1-BBBB" }},
    });
    try std.testing.expectEqualStrings(
        \\// Generated by preflight from the package's build.zig.zon: do not edit or commit.
        \\.{
        \\    .name = .pkg_conformance,
        \\    .version = "0.0.0",
        \\    .fingerprint = 0xabc,
        \\    .minimum_zig_version = "0.17.0",
        \\    .paths = .{ "build.zig", "build.zig.zon", "main.zig" },
        \\    .dependencies = .{
        \\        .pkg = .{ .path = ".." },
        \\        .shakedown = .{
        \\            .url = "git+https://example.invalid/shakedown#1111111111111111111111111111111111111111",
        \\            .hash = "shakedown-0.1.0-AAAA",
        \\        },
        \\        .emulator = .{
        \\            .url = "git+https://example.invalid/emulator#2222",
        \\            .hash = "emulator-1-BBBB",
        \\        },
        \\    },
        \\}
        \\
    , text);
    // The generated text is a manifest the lint check reads, and it shares the pin exactly.
    const back = try sharedPin(a, text, "shakedown");
    const original = try sharedPin(a, root_manifest, "shakedown");
    try std.testing.expectEqualStrings(original.url, back.url);
    try std.testing.expectEqualStrings(original.hash, back.hash);
}

test "a shared package the package does not pin by source is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.NotPinnedByPackage, sharedPin(a, root_manifest, "missing"));
    try std.testing.expectError(error.SharedPackageIsNotPinned, sharedPin(a, root_manifest, "local"));
}

test "the pins of a manifest are both lists' packages by source, and none by path" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found = try pins(a, root_manifest);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("shakedown", found[0].name);
    const developed = try pins(a, ".{ .dependencies = .{ .a = .{ .url = \"u\", .hash = \"h\" } }, .dev_dependencies = .{ .b = .{ .url = \"v\", .hash = \"i\" }, .c = .{ .path = \"c\" } } }");
    try std.testing.expectEqual(@as(usize, 2), developed.len);
    try std.testing.expectEqualStrings("b", developed[1].name);
    try std.testing.expectEqualStrings("i", developed[1].hash);
    try std.testing.expectEqual(@as(usize, 0), (try pins(a, ".{ .dependencies = .{} }")).len);
}

test "a shared package pinned as a dev dependency is pinned as the package does" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const developed = ".{ .dependencies = .{}, .dev_dependencies = .{ .shakedown = .{ .url = \"git+https://example.invalid/shakedown#1\", .hash = \"shakedown-1\" } } }";
    const shared = try sharedPin(a, developed, "shakedown");
    try std.testing.expectEqualStrings("git+https://example.invalid/shakedown#1", shared.url);
    try std.testing.expectEqualStrings("shakedown-1", shared.hash);
}

test "a nested manifest's path dependencies are made relative to where the build is assembled" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const manifest = ".{ .dependencies = .{ .pkg = .{ .path = \"..\" }, .tool = .{ .path = \"../tools/one\" }, .x = .{ .url = \"u\", .hash = \"h\" } } }";
    const moved = try relocate(a, manifest, "/repo/conformance", "/repo/.zig-cache/o/abc/conformance");
    try std.testing.expectEqualStrings(".{ .dependencies = .{ .pkg = .{ .path = \"../../../..\" }, .tool = .{ .path = \"../../../../tools/one\" }, .x = .{ .url = \"u\", .hash = \"h\" } } }", moved);
}
