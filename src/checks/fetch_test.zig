//! The plain graph's fetch (`plain.zig`) of a pin the global cache lacks: one that cannot be
//! fetched ends the walk named, with what `zig fetch` said.
const std = @import("std");
const test_options = @import("test_options");
const plain = @import("../plain.zig");

test "a pin no fetch reaches ends the walk naming its url, how zig fetch ended and what it said" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const url = "file:///nonexistent/preflight-fetch-test/unreachable.tar.gz";
    const root = ".{ .name = .bay, .dependencies = .{ .gone = .{ .url = \"" ++ url ++ "\", .hash = \"gone-0.1.0-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\" } } }";
    const found = try plain.conflicts(a, std.testing.io, root, "bay", .{ .global = .of(tmp.dir), .zig = test_options.zig });
    const failure = found.fetch_failed;
    try std.testing.expectEqualStrings(url, failure.url);
    try std.testing.expect(failure.term == .exited and failure.term.exited != 0);
    try std.testing.expect(std.mem.trim(u8, failure.stderr, " \n").len != 0);
    var text: std.Io.Writer.Allocating = .init(a);
    try plain.describeFetch(&text.writer, failure);
    try std.testing.expect(std.mem.startsWith(u8, text.written(), "zig fetch " ++ url ++ " exited "));
    try std.testing.expect(std.mem.find(u8, text.written(), failure.stderr[0..@min(failure.stderr.len, 20)]) != null);
}
