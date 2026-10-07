//! Documentation changes do not need the test gate.
const std = @import("std");
const src = @import("source.zig");

pub fn documentation(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "src/") or std.mem.find(u8, path, "/src/") != null) return false;
    if (std.mem.eql(u8, path, "LICENSE")) return true;
    const extension = std.Io.Dir.path.extension(path);
    for ([_][]const u8{ ".md", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".ico", ".avif" }) |allowed| {
        if (std.ascii.eqlIgnoreCase(extension, allowed)) return true;
    }
    return false;
}

pub fn onlyDocs(paths: []const u8) bool {
    var names = std.mem.tokenizeScalar(u8, paths, 0);
    var count: usize = 0;
    while (names.next()) |name| {
        if (!documentation(name)) return false;
        count += 1;
    }
    return count > 0;
}

/// The branch every other is compared with when a run names no base.
pub const default_base = "origin/main";

/// Whether the commits HEAD adds since it left `base` touch documentation
/// alone: the diff from their merge base, as a pull request shows it. A
/// run that names no base (a dispatch) compares with main, never with the
/// last commit alone, so an earlier commit's code keeps the gate. An
/// unknown base keeps it too.
pub fn run(c: src.Context, base: ?[]const u8) !bool {
    const range = try c.a.print("{s}...HEAD", .{base orelse default_base});
    const result = try std.process.run(c.a, c.io, .{ .argv = &.{ "git", "diff", "--name-only", "--no-renames", "-z", range, "--" }, .cwd = c.childCwd(), .environ_map = c.environ_map });
    if (result.term != .exited or result.term.exited != 0) return false;
    return onlyDocs(result.stdout);
}

test "docs-only filtering handles source Markdown, mixed changes and renames" {
    try std.testing.expect(onlyDocs("README.md\x00docs/guide.md\x00LICENSE\x00images/logo.svg\x00"));
    try std.testing.expect(!onlyDocs("src/design.md\x00"));
    try std.testing.expect(!onlyDocs("sample/src/design.md\x00"));
    try std.testing.expect(!onlyDocs("README.md\x00build.zig\x00"));
    try std.testing.expect(!onlyDocs("old.zig\x00docs/new.md\x00"));
    try std.testing.expect(!onlyDocs(""));
}
