//! What the lint hands glint of the package: the files it selects (what the package ships,
//! the directories a repository keeps code in, and what the repository names) and the build's
//! configured modules, through which glint resolves each import as the compiler will. How an
//! import resolves is glint's (its assembly, contract v1); a path's one form is this file's.
const std = @import("std");
const builtin = @import("builtin");
const configure = @import("../../configure.zig");
const src = @import("../source.zig");
const policy_module = @import("policy.zig");
const Policy = policy_module.Policy;

/// What the build says about imports: the configured modules and where Zig's
/// standard library is.
pub const Build = struct {
    modules: []const src.BuildModule = &.{},
    /// Zig's `lib/std`; without it `std` stays unresolved.
    std_dir: ?[]const u8 = null,
    /// The root of each module the package exports (each `b.addModule`'s): glint reads the
    /// public surface as what these reach through `pub` declarations.
    exported: []const []const u8 = &.{},
};

/// The Zig files to check: every one the package ships (`build.zig.zon`'s `.paths`), those
/// in the directories a repository keeps code in beside them, and `build.zig`, with
/// `glint_paths` adding to them, never narrowing them. A named path that is not there is
/// an error; a shipped or default one that is not is not part of this repository.
pub fn select(c: *src.Context, policy: Policy) !?[]const []const u8 {
    var found: std.array_hash_map.String(void) = .empty;
    const before = c.errors;
    for (policy.shipped) |path| _ = try take(c, path, .ships, &found);
    for (src.code_directories) |path| _ = try take(c, path, .kept, &found);
    _ = try take(c, "build.zig", .ships, &found);
    for (policy.paths orelse &.{}) |path| switch (try take(c, path, .kept, &found)) {
        .taken => {},
        .absent => c.fail("glint: glint_paths: {s}: not found", .{path}),
        .other => c.fail("glint: glint_paths: {s}: not a Zig file or a directory", .{path}),
    };
    if (c.errors != before) return null;
    if (found.count() == 0) {
        c.fail("glint: no Zig file is selected: the package ships none, and `glint_paths` names none", .{});
        return null;
    }
    const paths = found.keys();
    std.mem.sort([]const u8, paths, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return paths;
}

/// Whether a path is what the package ships, or code the repository keeps beside it.
const Scope = enum { ships, kept };

/// Adds the Zig files at `path`: the file, or those under the directory. What ships is
/// taken whole, since every file of it reaches the package's users, a nested
/// `build.zig.zon` among them; beside it, a nested package is left to its own build.
fn take(c: *src.Context, path: []const u8, scope: Scope, found: *std.array_hash_map.String(void)) !enum { taken, absent, other } {
    const clean = try normalize(c.a, path);
    const stat = c.directory().statFile(c.io, clean, .{}) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => return err,
    };
    if (stat.kind == .directory) {
        if (scope == .ships or !try nested(c, clean)) try collect(c, clean, scope, found);
    } else if (std.mem.endsWith(u8, clean, ".zig")) {
        try found.put(c.a, clean, {});
    } else return .other;
    return .taken;
}

fn collect(c: *src.Context, root: []const u8, scope: Scope, found: *std.array_hash_map.String(void)) !void {
    var dir = try c.directory().openDir(c.io, root, .{ .iterate = true });
    defer dir.close(c.io);
    var walker = try dir.walkSelectively(c.a);
    defer walker.deinit();
    while (try walker.next(c.io)) |entry| {
        if (entry.kind == .directory) {
            if (!configure.generated(entry.basename) and (scope == .ships or !try nested(c, try std.Io.Dir.path.join(c.a, &.{ root, entry.path })))) try walker.enter(c.io, entry);
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        try found.put(c.a, try normalize(c.a, try std.Io.Dir.path.join(c.a, &.{ root, entry.path })), {});
    }
}

/// Whether `directory` is a build of its own: one with its own `build.zig.zon`, or its own
/// `build.zig`, the build root `zig build` runs there, whose manifest `addNestedBuild` writes
/// under the cache from the package's. Its files only that build compiles, with the modules it
/// binds; its imports would not resolve in this build's lint, so it is left to that build.
fn nested(c: *src.Context, directory: []const u8) !bool {
    for ([_][]const u8{ "build.zig.zon", "build.zig" }) |name| {
        if (try c.exists(try std.Io.Dir.path.join(c.a, &.{ directory, name }))) return true;
    }
    return false;
}

/// A path in one lexical form: `/` separators, no `.` or `..` components
/// where they can be removed.
pub fn normalize(a: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]const u8 {
    const resolved = try std.Io.Dir.path.resolveAlloc(a, &.{path});
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, resolved, '\\', '/');
    return resolved;
}

fn parsed(a: std.mem.Allocator, text: []const u8) !src.Value {
    return (try std.json.parseFromSlice(src.Value, a, text, .{ .allocate = .alloc_always })).value;
}

fn write(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.Io.Dir.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

test "default selection is what the package ships and the directories a repository keeps code in, build outputs and caches left out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "src/a.zig", "src/deep/b.zig", "bench/run.zig", "examples/use.zig", "ci/layers.zig", "conformance/run.zig", "build.zig", "src/note.md", "zig-pkg/dep/x.zig", "src/zig-out/y.zig", ".zig-cache/z.zig", "docs/skip.zig", "bench/zig-pkg/q.zig", "bench/emulator/build.zig", "bench/emulator/build.zig.zon", "bench/emulator/main.zig" }) |path| try write(tmp.dir, path, "pub const x = 1;\n");
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = .of(tmp.dir) };
    const config = try parsed(c.a, "{}");
    const policy = (try policy_module.parse(&c, config, test_shipped)).?;
    const paths = (try select(&c, policy)).?;
    try std.testing.expectEqual(@as(usize, 7), paths.len);
    for ([_][]const u8{ "bench/run.zig", "build.zig", "ci/layers.zig", "conformance/run.zig", "examples/use.zig", "src/a.zig", "src/deep/b.zig" }, paths) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "a directory with a build.zig of its own is a nested build, left out, its manifest in the tree or written by addNestedBuild under the cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // morse's and visor's conformance builds: a build.zig and its sources, the manifest written
    // from the package's at configure time, the emulator's modules bound only there.
    for ([_][]const u8{ "src/a.zig", "conformance/build.zig", "conformance/main.zig", "conformance/deep/c.zig", "bench/run.zig" }) |path| try write(tmp.dir, path, "pub const x = 1;\n");
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = .of(tmp.dir) };
    for ([_][]const u8{ "{}", "{\"glint_paths\":[\"conformance\"]}" }) |text| {
        const config = try parsed(c.a, text);
        const policy = (try policy_module.parse(&c, config, test_shipped)).?;
        const paths = (try select(&c, policy)).?;
        try std.testing.expectEqual(@as(usize, 2), paths.len);
        for ([_][]const u8{ "bench/run.zig", "src/a.zig" }, paths) |want, got| try std.testing.expectEqualStrings(want, got);
    }
}

test "a nested build kept beside what ships is its own package, left out; one inside what ships is linted with it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "src/a.zig", "conformance/build.zig", "conformance/build.zig.zon", "conformance/main.zig", "bench/run.zig", "bench/emulator/build.zig.zon", "bench/emulator/main.zig", "src/vendor/build.zig.zon", "src/vendor/x.zig" }) |path| try write(tmp.dir, path, "pub const x = 1;\n");
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = .of(tmp.dir) };
    const config = try parsed(c.a, "{}");
    const policy = (try policy_module.parse(&c, config, test_shipped)).?;
    const paths = (try select(&c, policy)).?;
    // A nested manifest inside `src` ships with it, so its files reach users (review-1029 M6).
    try std.testing.expectEqual(@as(usize, 3), paths.len);
    for ([_][]const u8{ "bench/run.zig", "src/a.zig", "src/vendor/x.zig" }, paths) |want, got| try std.testing.expectEqualStrings(want, got);
}

const test_shipped: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "README.md" };

test "named paths add to what the package ships, never narrow it, and fail when absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "src/a.zig", "bench/run.zig", "docs/skip.zig", "tools/t.zig", "README.md" }) |path| try write(tmp.dir, path, "pub const x = 1;\n");
    var held: std.Io.Writer.Allocating = .init(arena.allocator());
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = .of(tmp.dir), .held = &held };
    var config = try parsed(c.a, "{\"glint_paths\":[\"./tools/t.zig\"]}");
    var policy = (try policy_module.parse(&c, config, test_shipped)).?;
    const paths = (try select(&c, policy)).?;
    try std.testing.expectEqual(@as(usize, 3), paths.len);
    for ([_][]const u8{ "bench/run.zig", "src/a.zig", "tools/t.zig" }, paths) |want, got| try std.testing.expectEqualStrings(want, got);
    for ([_][]const u8{ "{\"glint_paths\":[\"missing\"]}", "{\"glint_paths\":[\"README.md\"]}" }) |text| {
        c.errors = 0;
        config = try parsed(c.a, text);
        policy = (try policy_module.parse(&c, config, test_shipped)).?;
        try std.testing.expectEqual(@as(?[]const []const u8, null), try select(&c, policy));
        try std.testing.expect(c.errors != 0);
    }
    // A selection that finds nothing is an error, not a pass over nothing.
    var bare = std.testing.tmpDir(.{});
    defer bare.cleanup();
    c.dir = .of(bare.dir);
    c.errors = 0;
    config = try parsed(c.a, "{}");
    try bare.dir.createDirPath(std.testing.io, "src");
    policy = (try policy_module.parse(&c, config, test_shipped)).?;
    try std.testing.expectEqual(@as(?[]const []const u8, null), try select(&c, policy));
    try std.testing.expect(c.errors != 0);
    for ([_][]const u8{ "glint_paths: missing: not found", "glint_paths: README.md: not a Zig file", "no Zig file is selected" }) |said| try std.testing.expect(std.mem.find(u8, held.written(), said) != null);
}
