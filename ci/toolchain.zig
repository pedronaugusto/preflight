//! The toolchain rule: preflight, gantry and sweep build from std, outside
//! packages and each other, so no other package of the family can ever
//! enter the closure of the tool every package's gate runs.
//! `check-toolchain <name> <build.zig.zon>...` reads each toolchain
//! package's manifest and fails on any other family package it names.
const std = @import("std");
const gantry = @import("gantry");

/// Where the family's packages live.
const family = "github.com/pedronaugusto/";

/// The family packages a toolchain manifest may name: the toolchain itself;
/// ziglint, our fork of an outside linter; and shakedown, the test doubles,
/// which `test_dependencies` keeps out of every build but the tests.
const allowed = [_][]const u8{ "preflight", "gantry", "sweep", "ziglint", "shakedown" };

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 3 or args.len % 2 == 0) return error.ExpectedNamesAndManifests;
    var buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(init.io, &buffer);
    var found: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        const text = try std.Io.Dir.cwd().readFileAlloc(init.io, args[i + 1], a, .limited(1 << 20));
        found += try check(a, args[i], text, &stderr.interface);
    }
    try stderr.interface.flush();
    if (found != 0) return error.OutsideTheToolchain;
}

/// Writes one line per family package outside the toolchain that `package`'s
/// manifest names, and returns how many there are.
fn check(arena: std.mem.Allocator, package: []const u8, manifest: []const u8, out: *std.Io.Writer) !usize {
    var found: usize = 0;
    for (try gantry.manifests.parse(arena, "build.zig.zon", manifest)) |dependency| {
        const repository = familyRepository(dependency.source) orelse continue;
        for (allowed) |name| {
            if (std.mem.eql(u8, name, repository)) break;
        } else {
            try out.print("check-toolchain: {s} depends on {s} ({s}), a family package outside the toolchain\n", .{ package, dependency.name, dependency.source });
            found += 1;
        }
    }
    return found;
}

/// The family repository a dependency's URL names, or null for any other.
fn familyRepository(url: []const u8) ?[]const u8 {
    const at = std.mem.find(u8, url, family) orelse return null;
    const rest = url[at + family.len ..];
    return rest[0 .. std.mem.findAny(u8, rest, "/#?") orelse rest.len];
}

test "a toolchain manifest names only the toolchain, ziglint and shakedown" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    const clean =
        \\.{ .name = .gantry, .version = "0.1.0", .paths = .{""}, .dependencies = .{
        \\    .sweep = .{ .url = "git+https://github.com/pedronaugusto/sweep#c6b0c6d", .hash = "h" },
        \\    .preflight = .{ .url = "git+https://github.com/pedronaugusto/preflight#f6a5191", .hash = "h", .lazy = true },
        \\    .doubles = .{ .url = "git+https://github.com/pedronaugusto/shakedown#4f59016", .hash = "h", .lazy = true },
        \\    .uucode = .{ .url = "git+https://github.com/jacobsandlund/uucode#1", .hash = "h" },
        \\} }
    ;
    try std.testing.expectEqual(@as(usize, 0), try check(a, "gantry", clean, &out.writer));
    const reaching =
        \\.{ .name = .gantry, .version = "0.1.0", .paths = .{""}, .dependencies = .{
        \\    .strand = .{ .url = "git+https://github.com/pedronaugusto/strand#1", .hash = "h" },
        \\    .sweep = .{ .url = "git+https://github.com/pedronaugusto/sweep#c6b0c6d", .hash = "h" },
        \\} }
    ;
    try std.testing.expectEqual(@as(usize, 1), try check(a, "gantry", reaching, &out.writer));
    try std.testing.expectEqualStrings("check-toolchain: gantry depends on strand (git+https://github.com/pedronaugusto/strand#1), a family package outside the toolchain\n", out.written());
}

test "closure rejects mutable dependency pins" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    const manifest = ".{ .dependencies = .{ .sweep = .{ .url = \"git+https://github.com/pedronaugusto/sweep#main\", .hash = \"sweep-hash\" } } }";
    try std.testing.expectError(error.UnpinnedDependency, check(arena.allocator(), "preflight", manifest, &out.writer));
}

test "closure does not mistake an unrelated URL path for a family identity" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    const manifest = ".{ .dependencies = .{ .external = .{ .url = \"https://example.invalid/github.com/pedronaugusto/strand/archive.tar.gz\", .hash = \"external-content-hash\" } } }";
    try std.testing.expectEqual(@as(usize, 0), try check(arena.allocator(), "preflight", manifest, &out.writer));
}
