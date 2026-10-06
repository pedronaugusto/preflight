const std = @import("std");
const src = @import("source.zig");

pub fn trim(c: src.Context, path: []const u8, cap_kib: usize) !void {
    if (cap_kib == 0) return error.InvalidCacheCap;
    const stat = std.Io.Dir.cwd().statFile(c.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .directory) return error.InvalidCacheDirectory;
    var dir = try std.Io.Dir.cwd().openDir(c.io, path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(c.io);
    var walker = try dir.walk(c.a);
    defer walker.deinit();
    var bytes: u64 = 0;
    while (try walker.next(c.io)) |entry| {
        if (entry.kind == .file) bytes +|= (try entry.dir.statFile(c.io, entry.basename, .{})).size;
    }
    if (bytes / 1024 <= cap_kib) return;
    c.report("cache: {d} KiB exceeds {d} KiB; rebuilding products\n", .{ bytes / 1024, cap_kib });
    for ([_][]const u8{ "o", "h", "z", "tmp" }) |name| try dir.deleteTree(c.io, name);
}

test "cache pruning keeps fetched packages and tools, missing cache stays missing" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    for ([_][]const u8{ "o", "h", "z", "tmp", "p", "ziglint" }) |name| {
        try tmp.dir.createDir(io, name, .default_dir);
        const file = try std.fs.path.join(a, &.{ name, "kept" });
        defer a.free(file);
        try tmp.dir.writeFile(io, .{ .sub_path = file, .data = &(@as([16384]u8, @splat('x'))) });
    }
    const c: src.Context = .{ .a = a, .io = io };
    try trim(c, path, 1024);
    try tmp.dir.access(io, "o/kept", .{});
    try trim(c, path, 1);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "o", .{}));
    try tmp.dir.access(io, "p/kept", .{});
    try tmp.dir.access(io, "ziglint/kept", .{});
    try trim(c, path, 1);
    const missing = try std.fs.path.join(a, &.{ path, "absent" });
    defer a.free(missing);
    try trim(c, missing, 1);
}
