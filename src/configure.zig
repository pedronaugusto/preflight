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

/// The dependency `name` the package under test `b` declares, or null when it
/// declares none. preflight adds nothing of its own to a package's artifacts:
/// what it builds for them is the package's own, so they never hold a second
/// copy of a package beside the package's.
pub fn declared(b: *std.Build, name: []const u8, args: anytype) error{LazyDependencyNeeded}!?*std.Build.Dependency {
    for (b.available_deps) |dependency| {
        if (std.mem.eql(u8, dependency[0], name)) return try b.dependencyLazy(name, args);
    }
    return null;
}

/// The names of preflight's steps the package already had, for `refuseTaken`.
var taken: std.ArrayList([]const u8) = .empty;

/// A top-level step of preflight's, `name`, or, when the package already has a step
/// by that name, one under no name: the package's own step keeps the name, nothing
/// is overwritten and the build does not crash, and `refuseTaken` says what to do.
pub fn claim(b: *std.Build, name: []const u8, description: []const u8) *std.Build.Step {
    if (b.top_level_steps.get(name) == null) return b.step(name, description);
    taken.append(b.allocator, name) catch @panic("OOM");
    // A step of the top-level kind that no name reaches; others of preflight's may still depend on it.
    const detached = b.allocator.create(std.Build.Step.TopLevel) catch @panic("OOM");
    detached.* = .{ .step = .init(.{ .tag = .top_level, .name = name, .owner = b }), .description = b.dupe(description) };
    return &detached.step;
}

/// Fails `tests` naming each step `claim` found the package already had: the
/// gate runs preflight's steps by name, so a package step of the same name would
/// run in their place.
pub fn refuseTaken(b: *std.Build, tests: *std.Build.Step) void {
    for (taken.items) |name| tests.dependOn(&b.addFail(b.fmt("preflight: this package declares a step `{s}`, which preflight's gate runs by name as its own; give the package's step another name", .{name})).step);
    taken.clearRetainingCapacity();
}
