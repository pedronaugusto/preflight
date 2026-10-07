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
