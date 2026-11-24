//! Repository files the build script reads, declared to Zig's configuration
//! cache so that creating, changing or deleting one configures the build again.
const std = @import("std");
const family = @import("family.zig");
const input = @import("build/input.zig");

/// Whether `sub_path`, relative to the build root, exists. The root and each
/// directory on the way are declared, so the answer cannot go stale.
pub fn exists(b: *std.Build, sub_path: []const u8) bool {
    b.dependOnDirectoryMetadata(b.path("."));
    var start: usize = 0;
    while (std.mem.findScalarPos(u8, sub_path, start, '/')) |slash| : (start = slash + 1) {
        const parent = sub_path[0..slash];
        if (!present(b, parent)) return false;
        b.dependOnDirectoryMetadata(b.path(parent));
    }
    return present(b, sub_path);
}

/// Whether `sub_path`, relative to the build root, is there; any error but its absence
/// stops the build, naming the path.
fn present(b: *std.Build, sub_path: []const u8) bool {
    b.root.access(b.graph.io, sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => std.debug.panic("{s}: {t}", .{ sub_path, err }),
    };
    return true;
}

/// The contents of the file at `sub_path`, relative to the build root, at most `limit` bytes, or
/// null when it does not exist. Read in the build helper's input seam, through aegis's whole-file
/// read, which aegis's build.zig gives a build script.
pub fn read(b: *std.Build, sub_path: []const u8, limit: u64) ?[]const u8 {
    if (!exists(b, sub_path)) return null;
    b.dependOnFileContents(b.path(sub_path));
    const path = b.root.join(b.allocator, sub_path) catch @panic("OOM");
    return input.file(b.graph.io, path.root_dir.handle, path.sub_path, b.allocator, .{ .configured = limit }) catch |err|
        std.debug.panic("{s}: {t}", .{ sub_path, err });
}

/// The policy the configuration at `sub_path` names (`family.key`), read as the build
/// configures; adapting when there is no configuration. Null for one that names no policy, or
/// is no JSON object, which the caller refuses.
pub fn policy(b: *std.Build, sub_path: []const u8) ?family.Policy {
    const text = read(b, sub_path, 64 * 1024 * 1024) orelse return .adapt;
    const config = std.json.parseFromSliceLeaky(std.json.Value, b.allocator, text, .{}) catch return null;
    if (config != .object) return null;
    return family.of(config.object.get(family.key) orelse .null) catch null;
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
    if (!declares(b, name)) return null;
    return try b.dependencyLazy(name, args);
}

/// Whether the package under test `b` declares a dependency named `name`.
pub fn declares(b: *std.Build, name: []const u8) bool {
    for (b.available_deps) |dependency| {
        if (std.mem.eql(u8, dependency[0], name)) return true;
    }
    return false;
}

/// The dependency `name` of `b`, or null while it is lazy and not fetched yet. Zig fetches it
/// once this configure pass ends and configures again, so a caller given null ends its part of
/// the pass, as Zig's own `lazyDependency` caller does.
pub fn lazy(b: *std.Build, name: []const u8, args: anytype) ?*std.Build.Dependency {
    return b.dependencyLazy(name, args) catch |err| switch (err) {
        // Marked for the fetch: the next pass has it.
        error.LazyDependencyNeeded => null,
    };
}

/// bay, when `b` is a development build: the one that runs it (`BAY`), else the
/// one on PATH. Null when `b` is the package's own build, which `zig build` runs.
pub fn bay(b: *std.Build, package: *std.Build) ?[]const u8 {
    if (package == b) return null;
    return b.graph.environ_map.get("BAY") orelse "bay";
}

/// The command that runs this same build again, for a tool that builds one of
/// its steps from outside (a rerun with other options, a fuzzing session): `bay
/// dev` for a development build; else `zig build`.
pub fn rerun(b: *std.Build, package: *std.Build) []const []const u8 {
    if (bay(b, package)) |path| return b.allocator.dupe([]const u8, &.{ path, "dev" }) catch @panic("OOM");
    return b.allocator.dupe([]const u8, &.{ b.graph.zig_exe, "build" }) catch @panic("OOM");
}

/// The names of preflight's steps the build already had, for `refuseTaken`: the configuring
/// thread's own, as the build graph it configures is.
threadlocal var taken: std.ArrayList([]const u8) = .empty;
/// Every name preflight claimed, which the package's own build must not have
/// either: bay runs a step of the package's build before one of its development build.
threadlocal var claimed: std.ArrayList([]const u8) = .empty;

/// A top-level step of preflight's, `name`, or, when the package already has a step
/// by that name, one under no name: the package's own step keeps the name, nothing
/// is overwritten and the build does not crash, and `refuseTaken` says what to do.
pub fn claim(b: *std.Build, name: []const u8, description: []const u8) *std.Build.Step {
    claimed.append(b.allocator, name) catch @panic("OOM");
    if (b.top_level_steps.get(name) == null) return b.step(name, description);
    taken.append(b.allocator, name) catch @panic("OOM");
    // A step of the top-level kind that no name reaches; others of preflight's may still depend on it.
    const detached = b.allocator.create(std.Build.Step.TopLevel) catch @panic("OOM");
    detached.* = .{ .step = .init(.{ .tag = .top_level, .name = name, .owner = b }), .description = b.graph.dupeString(description) };
    return &detached.step;
}

/// Fails each of `steps` naming every option `package`'s build passes a dependency that it
/// does not declare. Zig 0.17 only logs one
/// ("invalid option", with a stack trace), and only on a configuration it does not take from
/// its cache, then builds on: an option a dependency removed is passed unseen (strand's legs
/// passing `-Dschema`, preflight's `.zig` to gantry after gantry 7c88363). A dependency is
/// `package`'s own when its prefix is the package's and one name more: what it passes its
/// own dependencies is that package's to check.
pub fn refuseUndeclaredOptions(b: *std.Build, package: *std.Build, steps: []const *std.Build.Step) void {
    for (b.graph.dependency_cache.values()) |dependency| {
        const child = dependency.builder;
        if (!directDependency(package.dep_prefix, child.dep_prefix)) continue;
        refuseUndeclaredOf(b, child, steps);
    }
}

/// Whether `prefix` names a dependency of the package whose prefix is `parent`: the
/// parent's, one name, then a dot (`std.Build.createChild`).
fn directDependency(parent: []const u8, prefix: []const u8) bool {
    if (prefix.len <= parent.len + 1 or !std.mem.startsWith(u8, prefix, parent) or prefix[prefix.len - 1] != '.') return false;
    return std.mem.findScalar(u8, prefix[parent.len .. prefix.len - 1], '.') == null;
}

fn refuseUndeclaredOf(b: *std.Build, builder: *std.Build, steps: []const *std.Build.Step) void {
    const name = std.mem.trimEnd(u8, builder.dep_prefix, ".");
    const short = if (std.mem.findScalarLast(u8, name, '.')) |dot| name[dot + 1 ..] else name;
    for (builder.user_input_options.keys()) |option| {
        if (builder.available_options_map.contains(option)) continue;
        const fail = b.addFail(b.fmt("the build passes the dependency {s} the option `{s}`, which {s} does not declare (Zig only logs it, and builds on): drop it", .{ short, option, short }));
        for (steps) |step| step.dependOn(&fail.step);
    }
}

test "a dependency of the package is one name past its prefix" {
    try std.testing.expect(directDependency("", "gantry."));
    try std.testing.expect(directDependency("pkg.", "pkg.gantry."));
    try std.testing.expect(!directDependency("pkg.", "pkg.gantry.glint."));
    try std.testing.expect(!directDependency("pkg.", "pkg."));
    try std.testing.expect(!directDependency("pkg.", "other.gantry."));
    try std.testing.expect(!directDependency("", "gantry.glint."));
}

/// The steps preflight claimed whose names reach them: none the build already had.
pub fn claimedSteps(b: *std.Build) []const *std.Build.Step {
    var steps: std.ArrayList(*std.Build.Step) = .empty;
    for (claimed.items) |name| {
        if (for (taken.items) |other| {
            if (std.mem.eql(u8, other, name)) break true;
        } else false) continue;
        const top = b.top_level_steps.get(name) orelse continue;
        steps.append(b.allocator, &top.step) catch @panic("OOM");
    }
    return steps.items;
}

/// Fails `tests` naming each step of preflight's that the build, or the package's
/// own build, already had: the gate runs preflight's steps by name, so a package
/// step of the same name would run in their place.
pub fn refuseTaken(b: *std.Build, package: *std.Build, tests: *std.Build.Step) void {
    if (package != b) for (claimed.items) |name| {
        if (package.top_level_steps.contains(name)) taken.append(b.allocator, name) catch @panic("OOM");
    };
    for (taken.items) |name| tests.dependOn(&b.addFail(b.fmt("preflight: this package declares a step `{s}`, which preflight's gate runs by name as its own; give the package's step another name", .{name})).step);
    taken.clearRetainingCapacity();
    claimed.clearRetainingCapacity();
}
