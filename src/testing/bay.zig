//! A stand-in for bay that the facts' tests run in its place: `locate --dev` names
//! `FAKE_BAY_ROOT`, or, without it, fails as a bay from before `locate` does.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = (try init.minimal.args.toSlice(a))[1..];
    if (args.len == 0 or !std.mem.eql(u8, args[0], "locate")) return error.UnknownCommand;
    const root = init.environ_map.get("FAKE_BAY_ROOT") orelse {
        var buffer: [256]u8 = undefined;
        var err = std.Io.File.stderr().writerStreaming(init.io, &buffer);
        try err.interface.writeAll("bay: no command or step named locate\n");
        try err.interface.flush();
        std.process.exit(1);
    };
    var buffer: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try out.interface.print("{s}\n", .{root});
    try out.interface.flush();
}
