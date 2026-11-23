//! What Linux says of a process's memory, parsed from the lines `/proc/<pid>/stat` and
//! `/proc/<pid>/status` hold: the reads are the caller's, through its input seam
//! (`bounded.zig`). Std alone.
const std = @import("std");

/// The most a process has held resident, from its `/proc/<pid>/status` (`VmHWM`, in kB).
pub fn highWater(status: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        const rest = std.mem.cutPrefix(u8, line, "VmHWM:") orelse continue;
        var fields = std.mem.tokenizeAny(u8, rest, " \t");
        const kb = std.fmt.parseUnsigned(u64, fields.next() orelse return null, 10) catch return null;
        return kb *| 1024;
    }
    return null;
}

/// A process's group and resident pages, from its `/proc/<pid>/stat` line: fields 5 and 24,
/// counted after the command's closing parenthesis, which may itself hold spaces and `)`.
pub fn groupPages(line: []const u8) ?struct { group: i64, pages: u64 } {
    const close = std.mem.findScalarLast(u8, line, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, line[close + 1 ..], ' ');
    var index: usize = 3;
    var group: ?i64 = null;
    while (fields.next()) |field| : (index += 1) {
        if (index == 5) group = std.fmt.parseInt(i64, field, 10) catch return null;
        if (index == 24) return .{ .group = group orelse return null, .pages = std.fmt.parseUnsigned(u64, field, 10) catch return null };
    }
    return null;
}

test "a process's group and resident pages are read past a command holding spaces and parentheses" {
    const line = "4242 (zig (build) x) S 4200 4100 4100 0 -1 4194560 100 0 0 0 5 1 0 0 20 0 3 0 777 1234567 2048 18446744073709551615 1 1 0 0 0 0 0 0 0 0 0 17 2 0 0 0 0 0\n";
    const read = groupPages(line).?;
    try std.testing.expectEqual(@as(i64, 4100), read.group);
    try std.testing.expectEqual(@as(u64, 2048), read.pages);
    try std.testing.expectEqual(null, groupPages("4242 (cut) S 1 2"));
    try std.testing.expectEqual(null, groupPages("no parenthesis"));
    try std.testing.expectEqual(@as(?u64, 9_018_311 * 1024), highWater("Name:\tzig\nVmPeak:\t 12000000 kB\nVmHWM:\t 9018311 kB\nVmRSS:\t 100 kB\n"));
    try std.testing.expectEqual(@as(?u64, null), highWater("Name:\tzig\n"));
}
