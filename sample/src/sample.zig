const std = @import("std");
const builtin = @import("builtin");

pub fn sum(a: u32, b: u32) u32 {
    return a + b;
}

test "sum" {
    try std.testing.expectEqual(5, sum(2, 3));
}

test "sum of each fixture case" {
    const fixture = @import("testing/cases.zig");
    for (fixture.cases) |case| try std.testing.expectEqual(case.sum, sum(case.a, case.b));
}

test "the riscv64 machine has the Alpine package the sample's build declares" {
    if (builtin.target.cpu.arch != .riscv64 or builtin.target.os.tag != .linux) return error.SkipZigTest;
    // Only preflight's machine: an Alpine system made for the tests.
    std.Io.Dir.cwd().access(std.testing.io, "/etc/alpine-release", .{}) catch return error.SkipZigTest;
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "tree", "--version" } });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "tree v"));
}

test "a test's scratch keeps what a test of files relies on, on preflight's machines too" {
    // A shared mapping's write that a read sees, and a directory that syncs: the 9p share a
    // machine reads the package from has neither, so a test's scratch (std.testing.tmpDir,
    // TMPDIR) is the machine's memory there.
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try expectLocal(io, tmp.dir, "mapped");
    const scratch = std.testing.environ.getPosix("TMPDIR") orelse return;
    var dir = try std.Io.Dir.cwd().openDir(io, scratch, .{});
    defer dir.close(io);
    var random: [8]u8 = undefined;
    io.random(&random);
    const hex = std.fmt.hex(@as(u64, @bitCast(random)));
    try expectLocal(io, dir, "preflight-sample-" ++ hex);
}

/// Expects a file `name` made in `dir` to read back a shared mapping's write, and `dir`
/// to sync; the file is gone after.
fn expectLocal(io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    const file = try dir.createFile(io, name, .{ .read = true, .exclusive = true });
    try file.writePositionalAll(io, "abc", 0);
    var map = try std.Io.File.MemoryMap.create(io, file, .{ .len = 3 });
    map.memory[0] = 'M';
    try map.write(io);
    map.destroy(io);
    var bytes: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try file.readPositionalAll(io, &bytes, 0));
    try std.testing.expectEqualStrings("Mbc", &bytes);
    file.close(io);
    try dir.deleteFile(io, name);
    const listing: std.Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try listing.sync(io);
}

test {
    _ = @import("testing/hardened.zig");
}
