//! `<zig> <library>`: a run given the build's Zig (`.zig_exe`) and its library (`.zig_lib`)
//! runs that Zig where the run runs. Under `-Dci-vm` it is the machine's own build of the
//! pinned version (vm.zig's `guestZig`), not the host's, which ended InvalidExe on both
//! machines (glint-0.8's soundness suite). It reports its version, this program's own, and the
//! library holds std.
const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.ZigArguments;
    const stderr = std.Io.File.stderr();
    const ran = std.process.run(a, io, .{ .argv = &.{ args[1], "version" } }) catch |err| {
        try stderr.writeStreamingAll(io, try a.print("zig argument: {s} does not run here ({t}): the run was given another machine's Zig\n", .{ args[1], err }));
        return 1;
    };
    const version = std.mem.trimEnd(u8, ran.stdout, "\r\n");
    if (ran.term != .exited or ran.term.exited != 0 or !std.mem.eql(u8, version, builtin.zig_version_string)) {
        try stderr.writeStreamingAll(io, try a.print("zig argument: {s} version ended {any} and printed \"{s}\" ({s}); this program was built by Zig {s}\n", .{ args[1], ran.term, version, ran.stderr, builtin.zig_version_string }));
        return 1;
    }
    std.Io.Dir.cwd().access(io, try std.Io.Dir.path.join(a, &.{ args[2], "std", "std.zig" }), .{}) catch |err| {
        try stderr.writeStreamingAll(io, try a.print("zig argument: the library {s} holds no std/std.zig ({t})\n", .{ args[2], err }));
        return 1;
    };
    return 0;
}
