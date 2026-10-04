//! Documentation changes do not need the test gate.
const std = @import("std");
const src = @import("source.zig");

pub fn documentation(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "src/") or std.mem.indexOf(u8, path, "/src/") != null) return false;
    if (std.mem.eql(u8, path, "LICENSE")) return true;
    const extension = std.fs.path.extension(path);
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

pub fn run(c: src.Context, base: []const u8) !bool {
    const result = try std.process.run(c.a, c.io, .{ .argv = &.{ "git", "diff", "--name-only", "--no-renames", "-z", base, "HEAD", "--" } });
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
