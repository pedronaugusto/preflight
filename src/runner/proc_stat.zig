//! What Linux says of a process's memory and CPU time, parsed from the lines `/proc/<pid>/stat`
//! and `/proc/<pid>/status` hold: the reads are the caller's, through its input seam
//! (`bounded.zig`, `cputime.zig`). Std alone.
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

/// A process's parent and the CPU time it and the children it has waited for have used, in
/// clock ticks, from its `/proc/<pid>/stat` line: fields 4 and 14 to 17 (user, system, and the
/// waited-for children's user and system), counted after the command's closing parenthesis.
pub fn cpuTicks(line: []const u8) ?struct { parent: i64, ticks: u64 } {
    const close = std.mem.findScalarLast(u8, line, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, line[close + 1 ..], ' ');
    var index: usize = 3;
    var parent: ?i64 = null;
    var ticks: u64 = 0;
    while (fields.next()) |field| : (index += 1) {
        if (index == 4) parent = std.fmt.parseInt(i64, field, 10) catch return null;
        if (index >= 14 and index <= 17) {
            // The children's are signed in the kernel's own type; never negative in fact.
            const count = std.fmt.parseInt(i64, field, 10) catch return null;
            ticks +|= std.math.cast(u64, count) orelse return null;
        }
        if (index == 17) return .{ .parent = parent orelse return null, .ticks = ticks };
    }
    return null;
}
