//! The program's ending as a test machine's first process reports it on the status
//! port: `exited N` or `signal N`. Both machines' hosts (host.zig's riscv64 Linux one,
//! freebsd.zig's) read it here and end as it says.
const std = @import("std");

pub const Ending = union(enum) {
    exited: u8,
    signal: u32,

    /// The ending one status line names, or none: a number that does not parse, or is
    /// past its type, is no ending.
    pub fn parse(line: []const u8) ?Ending {
        if (std.mem.startsWith(u8, line, "exited ")) return .{ .exited = std.fmt.parseInt(u8, line["exited ".len..], 10) catch return null };
        if (std.mem.startsWith(u8, line, "signal ")) return .{ .signal = std.fmt.parseInt(u32, line["signal ".len..], 10) catch return null };
        return null;
    }
};

test "a status line reads as the ending it names, or as none" {
    try std.testing.expectEqual(Ending{ .exited = 3 }, Ending.parse("exited 3").?);
    try std.testing.expectEqual(Ending{ .signal = 6 }, Ending.parse("signal 6").?);
    try std.testing.expectEqual(@as(?Ending, null), Ending.parse("exited 300"));
    try std.testing.expectEqual(@as(?Ending, null), Ending.parse("signal x"));
    try std.testing.expectEqual(@as(?Ending, null), Ending.parse("failed Mount9p"));
    try std.testing.expectEqual(@as(?Ending, null), Ending.parse(""));
}
