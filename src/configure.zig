//! Repository files the build script reads, declared to Zig's configuration
//! cache so that creating, changing or deleting one configures the build again.
const std = @import("std");

/// Whether `sub_path`, relative to the build root, exists. The root and each
/// directory on the way are declared, so the answer cannot go stale.
pub fn exists(b: *std.Build, sub_path: []const u8) bool {
    const io = b.graph.io;
    b.dependOnDirectoryMetadata(b.path("."));
    var start: usize = 0;
    while (std.mem.findScalarPos(u8, sub_path, start, '/')) |slash| : (start = slash + 1) {
        const parent = sub_path[0..slash];
        b.root.access(io, parent, .{}) catch return false;
        b.dependOnDirectoryMetadata(b.path(parent));
    }
    b.root.access(io, sub_path, .{}) catch return false;
    return true;
}

/// The contents of the file at `sub_path`, relative to the build root, or
/// null when it does not exist.
pub fn read(b: *std.Build, sub_path: []const u8, limit: std.Io.Limit) ?[]const u8 {
    if (!exists(b, sub_path)) return null;
    b.dependOnFileContents(b.path(sub_path));
    const path = b.root.join(b.allocator, sub_path) catch @panic("OOM");
    return path.root_dir.handle.readFileAlloc(b.graph.io, path.sub_path, b.allocator, limit) catch |err|
        std.debug.panic("{s}: {t}", .{ sub_path, err });
}

/// The directories a build makes beside its manifest -- its outputs and the
/// packages it fetched -- which are never a repository's source, wherever a
/// build of its own (a conformance build under `conformance/`) puts them.
/// `zig fmt` passes over hidden directories, `.zig-cache` among them, by
/// itself, and over neither of these.
pub const build_directories = [_][]const u8{ "zig-out", "zig-pkg" };

/// Whether a directory named `name` holds no repository source: a hidden one,
/// such as `.zig-cache`, or one of `build_directories`.
pub fn generated(name: []const u8) bool {
    if (name.len != 0 and name[0] == '.') return true;
    for (build_directories) |directory| {
        if (std.mem.eql(u8, name, directory)) return true;
    }
    return false;
}

/// The build directories directly under `sub_path`, relative to the build
/// root, that exist: what a format check of `sub_path` leaves out.
pub fn buildDirectoriesUnder(b: *std.Build, sub_path: []const u8) []const std.Build.LazyPath {
    var out: std.ArrayList(std.Build.LazyPath) = .empty;
    for (build_directories) |directory| {
        const path = b.pathJoin(&.{ sub_path, directory });
        if (exists(b, path)) out.append(b.allocator, b.path(path)) catch @panic("OOM");
    }
    return out.items;
}

test "a build's outputs, fetched packages and hidden directories are not sources" {
    for ([_][]const u8{ "zig-out", "zig-pkg", ".zig-cache", ".git" }) |name| try std.testing.expect(generated(name));
    for ([_][]const u8{ "src", "conformance", "zig", "pkg", "zig-pkgs" }) |name| try std.testing.expect(!generated(name));
}

/// The dependency `name` of the package under test `b`, or preflight's own pin
/// of it when the package declares none. A package preflight adds to the test
/// and benchmark artifacts (aegis, shakedown) is the package's own revision
/// where it has one: two revisions of it in an artifact do not unify, and
/// the family keeps one revision of each package in any build graph.
pub fn dependency(b: *std.Build, pkg: *std.Build, name: []const u8, args: anytype) error{LazyDependencyNeeded}!*std.Build.Dependency {
    for (b.available_deps) |declared| {
        if (std.mem.eql(u8, declared[0], name)) return b.dependencyLazy(name, args);
    }
    return pkg.dependencyLazy(name, args);
}
