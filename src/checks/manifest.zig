//! What a fetched package holds: `build.zig.zon`'s `.paths` names exactly
//! what a consumer's build reads (the build files and the source roots)
//! and the three files a user reads (licence, README, changelog). Anything
//! else, benchmarks, CI or examples, stays in the repository.
const std = @import("std");
const src = @import("source.zig");

/// The files every fetched package ships besides its source roots.
pub const shipped = [_][]const u8{ "build.zig", "build.zig.zon", "LICENSE", "README.md", "CHANGELOG.md" };

const Manifest = struct { paths: []const []const u8 };

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
    for (wanted.items) |path| if (!contains(listed, path))
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
}
