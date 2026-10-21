//! ZON a package's files hold, as std's readers take it.
const std = @import("std");

/// `text` as source for std's ZON readers, or null when it is not UTF-8. Zig
/// source is UTF-8, and std's literal parsing reads past a sequence cut short
/// (`'\xc3'` panics in `std.zig.parseCharLiteral`, Zig 0.17.0), so text that
/// is not is refused before std reads it.
pub fn source(a: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!?[:0]const u8 {
    if (!std.unicode.utf8ValidateSlice(text)) return null;
    return try a.dupeSentinel(u8, text, 0);
}

test "text that is not UTF-8 is no source, and std's reader never sees it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(try source(arena.allocator(), ".{ .x = '\xc3' }") == null);
    try std.testing.expectEqualStrings(".{ .x = 'é' }", (try source(arena.allocator(), ".{ .x = 'é' }")).?);
}
