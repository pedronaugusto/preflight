//! `<library> <out>`: writes into `out` the absolute path of Zig's library, `library` as
//! the build names it (`addTestZigLib`'s file, which the tests read).
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.ZigLibArguments;
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = try cwd.realPathFileAlloc(io, args[1], a) });
}
