//! The FreeBSD machine's own proof (`zig build -Dvm-freebsd-probe vm-freebsd-probe`
//! on a Linux host with KVM): tests built for x86_64 FreeBSD and run on it through
//! `-Dci-vm`'s path, as a package's are, so that what they check is the machine's:
//! FreeBSD's kernel with kernel TLS, the build's user and directory, scratch files
//! of its own, a child's exit code and signal, and the loopback interface. The test
//! runner's protocol over the `io` port is its standard streams' check. Elsewhere
//! they are compiled and skipped: they say what FreeBSD's machine is.
const std = @import("std");
const builtin = @import("builtin");

fn onMachine() !void {
    if (builtin.os.tag != .freebsd) return error.SkipZigTest;
}

fn sysctl(comptime T: type, name: [*:0]const u8) !T {
    var value: T = undefined;
    var len: usize = @sizeOf(T);
    if (std.c.sysctlbyname(name, &value, &len, null, 0) != 0) return error.Sysctl;
    return value;
}

test "the machine runs FreeBSD's kernel, with kernel TLS on" {
    try onMachine();
    var name: [32]u8 = undefined;
    var len: usize = name.len;
    try std.testing.expectEqual(@as(c_int, 0), std.c.sysctlbyname("kern.ostype", &name, &len, null, 0));
    try std.testing.expectEqualStrings("FreeBSD", std.mem.sliceTo(name[0..len], 0));
    try std.testing.expectEqual(@as(c_int, 1), try sysctl(c_int, "kern.ipc.tls.enable"));
}

test "the program runs in the build's directory as the build's user" {
    try onMachine();
    try std.Io.Dir.cwd().access(std.testing.io, "build.zig.zon", .{});
    try std.testing.expect(std.c.getuid() != 0);
}

test "scratch files are the machine's own" {
    try onMachine();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "probe", .data = "machine" });
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("machine", try tmp.dir.readFile(std.testing.io, "probe", &buffer));
}

test "a child's exit code and signal reach its parent" {
    try onMachine();
    const io = std.testing.io;
    var exited = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", "exit 3" } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 3 }, try exited.wait(io));
    var killed = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", "kill -SEGV $$" } });
    try std.testing.expectEqual(std.process.Child.Term{ .signal = .SEGV }, try killed.wait(io));
}

test "the loopback interface takes connections on 127.0.0.1 and ::1" {
    try onMachine();
    const io = std.testing.io;
    for ([_][]const u8{ "127.0.0.1", "::1" }) |text| {
        const address: std.Io.net.IpAddress = try .parse(text, 0);
        var server = try address.listen(io, .{});
        defer server.deinit(io);
        const client = try server.socket.address.connect(io, .{ .mode = .stream });
        defer client.close(io);
        const accepted = try server.accept(io);
        accepted.close(io);
    }
}
