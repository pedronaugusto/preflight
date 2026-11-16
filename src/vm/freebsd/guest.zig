//! The first process of the FreeBSD test machine (vm/freebsd.zig), started by the
//! kernel from its `init_path`, as vm/guest.zig is the riscv64 Linux machine's. It
//! loads the modules the machine's devices need, makes the program a root of its
//! own, runs the one program the run asks for with its standard streams on the
//! machine's ports, writes how it ended, and powers the machine off.
//!
//! The machine's root is the ISO 9660 image, which cannot be written, so the
//! program's root is the machine's memory (tmpfs at /preflight/root): FreeBSD's
//! system directories in it read-only (nullfs), its own devices (devfs, with every
//! open descriptor at /dev/fd: fdescfs) and /tmp, and the host's directories at their
//! host paths, bound from the host's 9p share. That share
//! and the run's are mounted outside the program's root (/preflight/host and
//! /preflight/run), which the first process takes as its root once it is made, so
//! the program reaches only the directories bound into it.
//!
//! The run is described by the host (vm/host.zig) in files on the `run` share, as
//! for the riscv64 machine: `argv`, `environ`, `binds` (each machine path, then the
//! host's resolved path) and `scratch`, each a list of NUL-terminated strings,
//! `cwd` and `user`. The program's stdin and stdout are the `io` port, its stderr
//! the `err` port. The `status` port takes `started` once the ports are open, which
//! is when the host may send input (a FreeBSD port is a terminal, which drops what
//! arrives before it is opened and set raw), then `exited N`, `signal N` (FreeBSD's
//! number) or `failed <error>`.
const std = @import("std");
const aegis = @import("aegis");
const seam = @import("input.zig");
const c = std.c;
const Io = std.Io;

extern "c" fn reboot(howto: c_int) c_int;
extern "c" fn pause() c_int;
extern "c" fn kldload(file: [*:0]const u8) c_int;
extern "c" fn nmount(iov: [*]c.iovec, niov: c_uint, flags: c_int) c_int;
extern "c" fn chroot(path: [*:0]const u8) c_int;
extern "c" fn setgroups(ngroups: c_int, gidset: [*]const c.gid_t) c_int;
extern "c" fn cfmakeraw(t: *c.termios) void;
extern "c" fn sigprocmask(how: c_int, set: ?*const c.sigset_t, old: ?*c.sigset_t) c_int;

/// sys/reboot.h: power the machine off after halting, without the kernel's own
/// write-back, which the first process has done.
const power_off = 0x4000 | 0x4;
/// sys/mount.h's MNT_RDONLY.
const read_only = 0x1;
/// signal.h's SIG_BLOCK and SIG_SETMASK.
const sig_block = 1;
const sig_setmask = 3;
/// How often a wait for a port looks again: a thousand looks are ten seconds.
const wait_step: aegis.units.Duration(.millisecond, u32) = .literal("10ms");

/// The modules the machine's devices and file systems need; GENERIC builds in the rest,
/// tmpfs among them.
const modules = [_][*:0]const u8{ "virtio_console", "virtio_p9fs", "nullfs", "fdescfs" };
/// The directories of FreeBSD's system the program sees, read-only: every other path
/// in its root is the machine's memory, so that the host's directories can be made
/// at their paths.
const system_dirs = [_][]const u8{ "bin", "boot", "etc", "lib", "libexec", "sbin", "usr" };
const new_root = "/preflight/root";
/// The run's description and the host's file system, at directories of the ISO image
/// outside the program's root: it reaches only what is bound into that root.
const run_mount = "/preflight/run";
const host_mount = "/preflight/host";
const guest_path = "PATH=/sbin:/bin:/usr/sbin:/usr/bin";

pub fn main(init: std.process.Init) void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const status = run(io, gpa) catch |err| blk: {
        say("{t}", .{err});
        break :blk Ending{ .failed = err };
    };
    report(status);
    powerOff();
}

const Ending = union(enum) {
    exited: u8,
    signal: u32,
    failed: anyerror,
};

fn run(io: Io, gpa: std.mem.Allocator) !Ending {
    try holdStandardFds();
    for (modules) |name| {
        // A module GENERIC already holds is loaded: EEXIST.
        if (kldload(name) < 0 and c._errno().* != @backingInt(c.E.EXIST)) {
            say("kldload {s}: {t}", .{ name, @as(c.E, @fromBackingInt(@intCast(c._errno().*))) });
            return error.Module;
        }
    }
    try loopbackUp();
    try makeRoot(io, gpa);
    try mount("run", run_mount, "p9fs", &.{}, 0);
    const argv = try readList(io, gpa, run_mount ++ "/argv");
    const environ = try readList(io, gpa, run_mount ++ "/environ");
    const binds = try readList(io, gpa, run_mount ++ "/binds");
    const scratch = try readList(io, gpa, run_mount ++ "/scratch");
    const cwd = try readFile(io, run_mount ++ "/cwd", gpa, .text);
    const user = try parseUser(try readFile(io, run_mount ++ "/user", gpa, .text));
    if (argv.len == 0) return error.NoProgram;

    // Made before the host's directories are bound, so that it is the machine's own
    // even when the host's HOME holds one of them.
    const home = try makeHome(io, gpa, environ, user);
    try mount("host", host_mount, "p9fs", &.{}, 0);
    if (binds.len % 2 != 0) return error.UnpairedBind;
    var pair: usize = 0;
    var split: Splits = .empty;
    while (pair < binds.len) : (pair += 2) try bindAround(io, gpa, .{ .path = binds[pair], .resolved = binds[pair + 1] }, scratch, user, &split);
    for (scratch) |path| try mountScratch(io, gpa, path);
    // The host's file system stays open past the program's root, for what the program makes
    // in a split directory: it is carried to the host once the program ends.
    const host = try Io.Dir.cwd().openDir(io, host_mount, .{});
    try check(chroot(new_root), error.Root);
    try check(c.chdir("/"), error.Root);
    try checkScratch(io, gpa, scratch);

    const ports = try openPorts(io);
    try writeAll(ports.status, "started\n");
    const ending = try launch(gpa, .{ .argv = argv, .environ = environ, .cwd = cwd, .user = user, .home = home }, ports);
    try copyBack(io, host, &split);
    return ending;
}

/// The kernel starts the first process with no descriptors: /dev/null takes 0, 1 and 2,
/// so that every port and pipe opened after is above them, and the child's dup2 onto
/// each always moves it (a dup2 onto itself would leave it closed on exec).
fn holdStandardFds() !void {
    while (true) {
        const fd = c.open("/dev/null", .{ .ACCMODE = .RDWR, .NOCTTY = true });
        if (fd < 0) return error.StandardFds;
        if (fd > 2) {
            closeFd(fd);
            return;
        }
    }
}

/// net/if.h's struct ifreq: its name, then a union of 16 bytes (a sockaddr, or two
/// pointer-sized words) that begins with the flags.
const InterfaceRequest = extern struct {
    name: [16]u8,
    flags: [2]c_short = .{ 0, 0 },
    rest: [12]u8 = @splat(0),
};
/// net/if.h's struct ifaliasreq with IPv4 addresses.
const AliasRequest = extern struct {
    name: [16]u8,
    addr: c.sockaddr.in,
    broadaddr: c.sockaddr.in,
    mask: c.sockaddr.in,
    vhid: c_int = 0,
};
/// sys/ioccom.h's _IOW and _IOWR, and sys/sockio.h's requests.
fn ioctlRequest(direction: u32, number: u8, size: usize) c_int {
    return @bitCast(direction | (@as(u32, @intCast(size)) << 16) | (@as(u32, 'i') << 8) | number); // safe: an ioctl's size is under 8 KiB
}
const ioc_in = 0x80000000;
const ioc_inout = 0xc0000000;
const set_flags = ioctlRequest(ioc_in, 16, @sizeOf(InterfaceRequest));
const get_flags = ioctlRequest(ioc_inout, 17, @sizeOf(InterfaceRequest));
const add_address = ioctlRequest(ioc_in, 43, @sizeOf(AliasRequest));
/// net/if.h's IFF_UP.
const interface_up = 0x1;

comptime {
    std.debug.assert(@sizeOf(InterfaceRequest) == 32);
    std.debug.assert(@sizeOf(AliasRequest) == 68);
}

/// The loopback interface up with 127.0.0.1/8, as rc's netif makes it on any running
/// system: tests listen on it. Bringing it up gives it ::1 (in6_ifattach).
fn loopbackUp() !void {
    const fd = c.socket(c.AF.INET, c.SOCK.DGRAM | c.SOCK.CLOEXEC, 0);
    if (fd < 0) return error.LoopbackSocket;
    defer closeFd(fd);
    var request: InterfaceRequest = .{ .name = interfaceName("lo0") };
    try check(c.ioctl(fd, get_flags, &request), error.LoopbackUp);
    request.flags[0] |= interface_up;
    try check(c.ioctl(fd, set_flags, &request), error.LoopbackUp);
    var alias: AliasRequest = .{
        .name = interfaceName("lo0"),
        .addr = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) },
        .broadaddr = std.mem.zeroes(c.sockaddr.in),
        .mask = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0xff000000) },
    };
    try check(c.ioctl(fd, add_address, &alias), error.LoopbackAddress);
}

fn interfaceName(comptime text: []const u8) [16]u8 {
    var buffer: [16]u8 = @splat(0);
    @memcpy(buffer[0..text.len], text);
    return buffer;
}

/// The program's root in the machine's memory, at `new_root` (a directory of the
/// ISO image): the system's directories read-only, its own devices, a /tmp and a
/// /var/tmp anyone writes. Its /dev/fd is fdescfs, as a FreeBSD system's fstab
/// mounts it: devfs alone lists descriptors 0, 1 and 2 there, so a test that reads
/// a process's open descriptors from it (conduit's close_all) saw no others.
fn makeRoot(io: Io, gpa: std.mem.Allocator) !void {
    try mount("tmpfs", new_root, "tmpfs", &.{.{ "mode", "755" }}, 0);
    const dir = Io.Dir.cwd();
    for (system_dirs) |name| {
        const target = try gpa.printSentinel("{s}/{s}", .{ new_root, name }, 0);
        try dir.createDirPath(io, target);
        try mount(try gpa.printSentinel("/{s}", .{name}, 0), target, "nullfs", &.{}, read_only);
    }
    for ([_][:0]const u8{ new_root ++ "/dev", new_root ++ "/tmp", new_root ++ "/var/tmp" }) |path| try dir.createDirPath(io, path);
    try mount("devfs", new_root ++ "/dev", "devfs", &.{}, 0);
    try mount("fdescfs", new_root ++ "/dev/fd", "fdescfs", &.{}, 0);
    try mount("tmpfs", new_root ++ "/tmp", "tmpfs", &.{.{ "mode", "1777" }}, 0);
    try mount("tmpfs", new_root ++ "/var/tmp", "tmpfs", &.{.{ "mode", "1777" }}, 0);
}

/// nmount(2): the file system `fstype` from `from` (a device, a share's tag or,
/// for nullfs, a directory) at `fspath`, with `options` beside them, each a name
/// and its value.
fn mount(from: [:0]const u8, fspath: [:0]const u8, fstype: [:0]const u8, options: []const [2][:0]const u8, flags: c_int) !void {
    const max_options = 2;
    if (options.len > max_options) return error.MountOptions;
    var iov: [2 * (3 + max_options)]c.iovec = std.mem.zeroes([2 * (3 + max_options)]c.iovec);
    const pairs = [_][2][:0]const u8{ .{ "fstype", fstype }, .{ "fspath", fspath }, .{ "from", from } };
    for (pairs, 0..) |pair, i| iov[2 * i ..][0..2].* = .{ entry(pair[0]), entry(pair[1]) };
    for (options, pairs.len..) |pair, i| iov[2 * i ..][0..2].* = .{ entry(pair[0]), entry(pair[1]) };
    const count: c_uint = @intCast(2 * (pairs.len + options.len)); // safe: at most ten entries
    if (nmount(&iov, count, flags) < 0) {
        const err: c.E = @fromBackingInt(@intCast(c._errno().*));
        // nullfs's answer when the mount point already shows the directory, through an
        // earlier nullfs mount of it or of a directory above it (null_vfsops.c).
        if (err == .DEADLK) return error.AlreadyThere;
        say("mount {s} at {s}: {t}", .{ fstype, fspath, err });
        return error.Mount;
    }
}

/// An nmount(2) entry: a string with its NUL, as the kernel copies it.
fn entry(text: [:0]const u8) c.iovec {
    return .{ .base = @constCast(text.ptr), .len = text.len + 1 };
}

/// The program's path `path` in its root, before the first process takes that root.
fn inRoot(gpa: std.mem.Allocator, path: []const u8) ![:0]u8 {
    if (!std.fs.path.isAbsolute(path)) return error.RelativePath;
    return gpa.printSentinel("{s}{s}", .{ new_root, path }, 0);
}

/// The host's directory `resolved`, at `path` in the program's root: the path the
/// program has for it, which on the host may pass through links.
fn bind(io: Io, gpa: std.mem.Allocator, path: []const u8, resolved: []const u8) !void {
    const target = try inRoot(gpa, path);
    try Io.Dir.cwd().createDirPath(io, target);
    const source = try gpa.printSentinel("{s}{s}", .{ host_mount, resolved }, 0);
    // A directory under one bound before is already there, at the same path.
    mount(source, target, "nullfs", &.{}, 0) catch |err| switch (err) {
        error.AlreadyThere => {},
        else => |e| return e,
    };
}

/// A host directory at a path in the program's root: the path the program has for it, and
/// the host's resolved path.
const Place = struct { path: []const u8, resolved: []const u8 };

/// A directory of the machine's own in place of a host directory with a scratch beneath it:
/// the host's resolved path, and the names its entries had when the machine bound them.
const Split = struct { resolved: []const u8, names: std.array_hash_map.String(void) };
const Splits = std.array_hash_map.String(Split);

/// Binds the host's `place` as `bind` does, unless a scratch directory lies beneath it. Then
/// its path is the machine's own directory, the run user's, holding a bind of each entry of
/// the host's, and each entry on the way to the scratch is split the same way, so the scratch
/// is mounted on a directory of the machine's own, never on one of the share.
///
/// A mount on a directory of the share does not hold. p9fs knows a vnode by its qid's path
/// and version (p9fs_node_cmp, FreeBSD 15.1's sys/fs/p9fs/p9fs_vfsops.c), and QEMU makes a
/// directory's version of its mtime and size (hw/9pfs/9p.c, stat_to_qid). Once the host
/// makes or removes an entry in `.zig-cache/tmp`, which its build does throughout, the
/// machine's next lookup of it is a new vnode, and nullfs's above it is new too: a tmpfs
/// mounted on the old one is no longer crossed, and the program's writes reached 9p
/// (reactor's FIFO and shakedown's shared mapping, run 43867718536). What the program makes
/// in a split directory is carried to the host when it ends (`copyBack`).
fn bindAround(io: Io, gpa: std.mem.Allocator, place: Place, scratch: []const [:0]const u8, owner: User, split: *Splits) !void {
    if (!holdsScratch(place.path, scratch)) return bind(io, gpa, place.path, place.resolved);
    // A directory split before (a bind below another, or named twice) is already in place.
    if ((try split.getOrPut(gpa, place.path)).found_existing) return;
    const target = try inRoot(gpa, place.path);
    try Io.Dir.cwd().createDirPath(io, target);
    // The program makes its own entries here, as in the host's directory it stands for.
    try check(c.fchownat(c.AT.FDCWD, target, owner.uid, owner.gid, 0), error.SplitOwner);
    const source = try gpa.print("{s}{s}", .{ host_mount, place.resolved });
    var dir = try Io.Dir.cwd().openDir(io, source, .{ .iterate = true });
    defer dir.close(io);
    var names: std.array_hash_map.String(void) = .empty;
    var entries = dir.iterate();
    while (try entries.next(io)) |found| {
        try names.put(gpa, try gpa.dupe(u8, found.name), {});
        const child: Place = .{ .path = try std.fs.path.join(gpa, &.{ place.path, found.name }), .resolved = try std.fs.path.join(gpa, &.{ place.resolved, found.name }) };
        // The scratch itself is the machine's memory, which `mountScratch` makes.
        if (isScratch(child.path, scratch)) continue;
        switch (found.kind) {
            .directory => try bindAround(io, gpa, child, scratch, owner, split),
            .file => try bindFile(io, gpa, child.path, child.resolved),
            .sym_link => {
                var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
                try Io.Dir.cwd().symLink(io, try seam.link(io, dir, found.name, &buffer), try inRoot(gpa, child.path), .{});
            },
            // A socket or FIFO of the host's is nothing the machine can open.
            else => {},
        }
    }
    // A scratch the host has not made yet, or the directories on the way to it, are the
    // machine's (`mountScratch` makes them), not the program's.
    for (scratch) |each| if (beneath(each, place.path)) |rest| {
        try names.put(gpa, rest[0 .. std.mem.findScalar(u8, rest, '/') orelse rest.len], {});
    };
    split.getPtr(place.path).?.* = .{ .resolved = place.resolved, .names = names };
}

/// What follows `path` in `each` when `each` lies beneath it, or null.
fn beneath(each: []const u8, path: []const u8) ?[]const u8 {
    if (each.len <= path.len or !std.mem.startsWith(u8, each, path)) return null;
    if (path.len == 1) return each[1..];
    return if (each[path.len] == '/') each[path.len + 1 ..] else null;
}

/// Carries to the host each entry the program made in a split directory, one the host's
/// directory had no entry of that name for when the machine bound it: a file, a directory
/// with all beneath it, or a link that stays inside the split directory. The rest of a split
/// directory is the host's already, through its binds. What cannot be carried (a FIFO, a
/// socket, a link out of the directory, a name the share refuses, a full disk) fails the
/// run, naming it: never a part of it carried and the run passed.
fn copyBack(io: Io, host: Io.Dir, split: *const Splits) !void {
    for (split.keys(), split.values()) |path, each| {
        var made = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer made.close(io);
        var to = try host.openDir(io, if (each.resolved.len > 1) each.resolved[1..] else ".", .{});
        defer to.close(io);
        var entries = made.iterate();
        while (try entries.next(io)) |found| {
            if (each.names.contains(found.name)) continue;
            carry(io, made, to, found.name, found.kind, 0) catch |err| {
                say("carrying {s}/{s} to the host's {s}: {t}", .{ path, found.name, each.resolved, err });
                return error.CopyBack;
            };
        }
    }
}

/// Copies the entry `name` of `from` to `to`, `depth` directories below the split directory.
fn carry(io: Io, from: Io.Dir, to: Io.Dir, name: []const u8, kind: Io.File.Kind, depth: usize) !void {
    switch (kind) {
        .file => try from.copyFile(name, to, name, io, .{}),
        .directory => {
            to.createDir(io, name, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => |e| return e,
            };
            var inner = try from.openDir(io, name, .{ .iterate = true });
            defer inner.close(io);
            var inner_to = try to.openDir(io, name, .{});
            defer inner_to.close(io);
            var entries = inner.iterate();
            while (try entries.next(io)) |found| try carry(io, inner, inner_to, found.name, found.kind, depth + 1);
        },
        .sym_link => {
            var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
            const target = try seam.link(io, from, name, &buffer);
            if (!staysWithin(target, depth)) return error.LinkLeavesItsDirectory;
            to.symLink(io, target, name, .{}) catch |err| switch (err) {
                // The host made one of that name meanwhile: the program's is the one carried.
                error.PathAlreadyExists => {
                    try to.deleteFile(io, name);
                    try to.symLink(io, target, name, .{});
                },
                else => |e| return e,
            };
        },
        else => return error.NotCarried,
    }
}

/// Whether a link's `target`, from a directory `depth` below the split directory, names a
/// path inside it: a relative path that never climbs above it.
fn staysWithin(target: []const u8, depth: usize) bool {
    if (std.fs.path.isAbsolute(target)) return false;
    var level: usize = depth;
    var parts = std.mem.tokenizeScalar(u8, target, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (level == 0) return false;
            level -= 1;
        } else level += 1;
    }
    return true;
}

/// Whether a scratch directory lies beneath `path`.
fn holdsScratch(path: []const u8, scratch: []const [:0]const u8) bool {
    for (scratch) |each| if (beneath(each, path) != null) return true;
    return false;
}

fn isScratch(path: []const u8, scratch: []const [:0]const u8) bool {
    for (scratch) |each| if (std.mem.eql(u8, each, path)) return true;
    return false;
}

/// The host's file `resolved` at `path` in the program's root, through nullfs, which mounts
/// a file on a file (FreeBSD 14 and later): it is the host's file, written through to it.
fn bindFile(io: Io, gpa: std.mem.Allocator, path: []const u8, resolved: []const u8) !void {
    const target = try inRoot(gpa, path);
    const file = try Io.Dir.cwd().createFile(io, target, .{});
    file.close(io);
    const source = try gpa.printSentinel("{s}{s}", .{ host_mount, resolved }, 0);
    try mount(source, target, "nullfs", &.{}, 0);
}

/// A directory the run writes its scratch files in: the machine's memory, so that
/// they behave as files on a local file system, not a share.
fn mountScratch(io: Io, gpa: std.mem.Allocator, path: []const u8) !void {
    const target = try inRoot(gpa, path);
    try Io.Dir.cwd().createDirPath(io, target);
    try mount("tmpfs", target, "tmpfs", &.{.{ "mode", "1777" }}, 0);
}

/// Fails unless each scratch directory, as the program reaches it from its root, is the
/// machine's memory: a mount of its own, on another device than the directory above it, and
/// named by its own path, not the share's beneath it. A scratch that is not lands on 9p,
/// whose gaps a test of files falls into (reactor's FIFO, shakedown's shared mapping), so the
/// run stops saying which, rather than run the tests on the share.
fn checkScratch(io: Io, gpa: std.mem.Allocator, scratch: []const [:0]const u8) !void {
    for (scratch) |path| {
        const above = std.fs.path.dirname(path) orelse "/";
        var own: c.Stat = undefined;
        var parent: c.Stat = undefined;
        try check(c.fstatat(c.AT.FDCWD, path, &own, 0), error.ScratchUnread);
        try check(c.fstatat(c.AT.FDCWD, try gpa.printSentinel("{s}", .{above}, 0), &parent, 0), error.ScratchUnread);
        if (own.dev == parent.dev) {
            say("scratch {s} is on the device of {s}: the machine's memory is not mounted there", .{ path, above });
            return error.ScratchNotMounted;
        }
        const named = try Io.Dir.cwd().realPathFileAlloc(io, path, gpa);
        if (!std.mem.eql(u8, named, path)) {
            say("scratch {s} names itself {s}", .{ path, named });
            return error.ScratchMisnamed;
        }
    }
}

const Ports = struct { io: c.fd_t, err: c.fd_t, status: c.fd_t };

/// The ports by name (virtio_console's aliases, which appear once QEMU has named
/// them), each a terminal set raw: bytes pass as they are, unechoed.
fn openPorts(io: Io) !Ports {
    const ports: Ports = .{
        .io = try openPort(io, "/dev/vtcon/io"),
        .err = try openPort(io, "/dev/vtcon/err"),
        .status = try openPort(io, "/dev/vtcon/status"),
    };
    status_port = ports.status;
    return ports;
}

fn openPort(io: Io, path: [*:0]const u8) !c.fd_t {
    var tries: usize = 0;
    const fd = while (true) : (tries += 1) {
        const rc = c.open(path, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true });
        if (rc >= 0) break rc;
        switch (@as(c.E, @fromBackingInt(@intCast(c._errno().*)))) {
            .NOENT, .NXIO, .NODEV => if (tries == 1000) {
                say("open {s}: no such port in ten seconds", .{path});
                return error.PortMissing;
            },
            else => |e| {
                say("open {s}: {t}", .{ path, e });
                return error.Open;
            },
        }
        try io.sleep(wait_step.toIoDuration(), .awake);
    };
    var mode: c.termios = std.mem.zeroes(c.termios);
    try check(c.tcgetattr(fd, &mode), error.PortMode);
    cfmakeraw(&mode);
    try check(c.tcsetattr(fd, .NOW, &mode), error.PortMode);
    return fd;
}

var status_port: c.fd_t = -1;

/// Runs the program with pipes for its standard streams, as a build gives a program
/// on any host, and carries them over the ports: the `io` port's frames to its stdin
/// (vm/host.zig frames what the host writes, an empty frame for the end of it), its
/// stdout to the `io` port and its stderr to `err`. Every process that ends meanwhile
/// is reaped; what the program leaves running is killed once it ends, as its machine
/// goes with it.
fn launch(gpa: std.mem.Allocator, program: Program, ports: Ports) !Ending {
    const argv_z = try gpa.allocSentinel(?[*:0]const u8, program.argv.len, null);
    for (program.argv, argv_z) |arg, *slot| slot.* = arg.ptr;
    var env: std.ArrayList(?[*:0]const u8) = .empty;
    for (program.environ) |item| {
        // The machine's own programs and login shell, and its home for the user.
        if (std.mem.startsWith(u8, item, "PATH=") or std.mem.startsWith(u8, item, "SHELL=") or std.mem.startsWith(u8, item, "HOME=")) continue;
        // The host's held git is a host program, and this machine has none of the package's.
        if (std.mem.startsWith(u8, item, "PREFLIGHT_GIT=")) continue;
        try env.append(gpa, item.ptr);
    }
    try env.append(gpa, guest_path);
    try env.append(gpa, "SHELL=/bin/sh");
    try env.append(gpa, (try gpa.printSentinel("HOME={s}", .{program.home}, 0)).ptr);
    const env_z = try env.toOwnedSliceSentinel(gpa, null);
    const cwd_z = try gpa.dupeSentinel(u8, program.cwd, 0);

    // Children's endings arrive as kqueue events, so that the first process reaps
    // each at once, as a system's init does. The signal is blocked here so that it
    // is only counted, and the program gets it unblocked.
    var chld: c.sigset_t = std.mem.zeroes(c.sigset_t);
    chld.__bits[0] = @as(u32, 1) << (@backingInt(c.SIG.CHLD) - 1);
    var unblocked: c.sigset_t = std.mem.zeroes(c.sigset_t);
    try check(sigprocmask(sig_block, &chld, &unblocked), error.SignalMask);

    const stdin = try pipe();
    const stdout = try pipe();
    const stderr = try pipe();
    const child = c.fork();
    if (child < 0) return error.Fork;
    if (child == 0) {
        // The child: only async-signal-safe calls until exec. The pipes' other
        // ends and the ports close on exec.
        if (sigprocmask(sig_setmask, &unblocked, null) != 0) c._exit(126);
        const groups = [_]c.gid_t{program.user.gid};
        if (setgroups(groups.len, &groups) != 0) c._exit(126);
        if (c.setgid(program.user.gid) != 0) c._exit(126);
        if (c.setuid(program.user.uid) != 0) c._exit(126);
        if (c.chdir(cwd_z) != 0) c._exit(126);
        if (c.dup2(stdin[0], 0) < 0 or c.dup2(stdout[1], 1) < 0 or c.dup2(stderr[1], 2) < 0) c._exit(126);
        _ = c.execve(argv_z[0].?, argv_z.ptr, env_z.ptr); // safe: only a failed exec returns
        c._exit(127);
    }
    closeFd(stdin[0]);
    closeFd(stdout[1]);
    closeFd(stderr[1]);

    const kq = c.kqueue();
    if (kq < 0) return error.Kqueue;
    const watch = [_]c.Kevent{
        event(descriptor(ports.io), c.EVFILT.READ, 0),
        event(descriptor(stdout[0]), c.EVFILT.READ, 0),
        event(descriptor(stderr[0]), c.EVFILT.READ, 0),
        event(@intCast(child), c.EVFILT.PROC, c.NOTE.EXIT), // safe: a parent's fork result is the child's id
        event(@backingInt(c.SIG.CHLD), c.EVFILT.SIGNAL, 0),
    };
    var none: [0]c.Kevent = .{};
    if (c.kevent(kq, &watch, watch.len, &none, 0, null) < 0) return error.Kqueue;

    var input: Frames = .{ .to = stdin[1] };
    var open = [_]bool{ true, true, true };
    var buffer: [64 * 1024]u8 = @splat(0);
    var status: ?c_int = null;
    var exited = false;
    while (!exited) {
        var events: [8]c.Kevent = std.mem.zeroes([8]c.Kevent);
        const n = c.kevent(kq, &watch, 0, &events, events.len, null);
        if (n < 0) {
            if (c._errno().* == @backingInt(c.E.INTR)) continue;
            return error.Kqueue;
        }
        for (events[0..@intCast(n)]) |ev| switch (ev.filter) { // safe: kevent returns at most the list's length
            c.EVFILT.READ => {
                const fd: c.fd_t = @intCast(ev.ident); // safe: a descriptor this loop registered
                if (fd == ports.io) {
                    if (!open[0]) continue;
                    const got = try readSome(fd, &buffer);
                    if (got == 0) open[0] = false else try input.feed(buffer[0..got]);
                    if (input.ended) open[0] = false;
                    if (!open[0]) try unwatch(kq, fd);
                } else {
                    const index: usize = if (fd == stdout[0]) 1 else 2;
                    if (!open[index]) continue;
                    const got = try readSome(fd, &buffer);
                    if (got == 0) {
                        open[index] = false;
                        try unwatch(kq, fd);
                    } else try writeAll(if (index == 1) ports.io else ports.err, buffer[0..got]);
                }
            },
            c.EVFILT.PROC => exited = true,
            else => {},
        };
        reap(child, &status);
    }
    // What the program wrote before it ended, up to what is in the pipes now.
    for ([_]usize{ 1, 2 }) |index| if (open[index]) {
        const fd = if (index == 1) stdout[0] else stderr[0];
        _ = c.fcntl(fd, c.F.SETFL, @as(c_int, @bitCast(c.O{ .NONBLOCK = true }))); // safe: a failed change only blocks a drain that ends at EOF
        while (true) {
            const rc = c.read(fd, &buffer, buffer.len);
            if (rc <= 0) break;
            try writeAll(if (index == 1) ports.io else ports.err, buffer[0..@intCast(rc)]); // safe: a positive read count
        }
    };
    while (status == null) {
        var raw_status: c_int = 0;
        if (c.waitpid(child, &raw_status, 0) == child) {
            status = raw_status;
        } else if (c._errno().* != @backingInt(c.E.INTR)) return error.Wait;
    }
    _ = c.kill(-1, .KILL); // safe: no process may be left, and none may be too
    var ignored: ?c_int = null;
    reap(child, &ignored);
    const wait_status: u32 = @bitCast(status.?); // safe: wait status bits, read as unsigned
    return if (std.posix.W.IFEXITED(wait_status)) .{ .exited = std.posix.W.EXITSTATUS(wait_status) } else .{ .signal = @backingInt(std.posix.W.TERMSIG(wait_status)) };
}

/// An open descriptor as a kqueue event's identifier.
fn descriptor(fd: c.fd_t) usize {
    return @intCast(fd); // safe: an open descriptor is nonnegative
}

fn event(ident: usize, filter: i16, fflags: u32) c.Kevent {
    return .{ .ident = ident, .filter = filter, .flags = c.EV.ADD, .fflags = fflags, .data = 0, .udata = 0 };
}

/// Stops watching a stream that has ended.
fn unwatch(kq: c.fd_t, fd: c.fd_t) !void {
    const change = [_]c.Kevent{.{ .ident = descriptor(fd), .filter = c.EVFILT.READ, .flags = c.EV.DELETE, .fflags = 0, .data = 0, .udata = 0 }};
    var none: [0]c.Kevent = .{};
    if (c.kevent(kq, &change, change.len, &none, 0, null) < 0) return error.Kqueue;
}

const User = struct { uid: c.uid_t, gid: c.gid_t };

const Program = struct {
    argv: []const [:0]const u8,
    environ: []const [:0]const u8,
    cwd: []const u8,
    user: User,
    home: []const u8,
};

fn parseUser(text: []const u8) !User {
    var words = std.mem.tokenizeAny(u8, text, " \n");
    const uid = try std.fmt.parseInt(c.uid_t, words.next() orelse return error.User, 10);
    const gid = try std.fmt.parseInt(c.gid_t, words.next() orelse return error.User, 10);
    return .{ .uid = uid, .gid = gid };
}

/// The user's home, empty, at the host's HOME path or /home/user: a test that
/// writes there leaves the host's own home alone.
fn makeHome(io: Io, gpa: std.mem.Allocator, environ: []const [:0]const u8, user: User) ![]const u8 {
    const home = for (environ) |item| {
        if (std.mem.startsWith(u8, item, "HOME=") and item.len > "HOME=/".len) break item["HOME=".len..];
    } else "/home/user";
    const target = try inRoot(gpa, home);
    try Io.Dir.cwd().createDirPath(io, target);
    try check(c.fchownat(c.AT.FDCWD, target, user.uid, user.gid, 0), error.HomeOwner);
    return home;
}

/// The host's input in frames, a little-endian u32 length and that many bytes,
/// written on to the program's stdin; an empty frame ends it.
const Frames = struct {
    to: c.fd_t,
    /// The length bytes of a frame not wholly arrived.
    header: [4]u8 = undefined,
    header_len: usize = 0,
    /// What is left of the frame being written.
    left: usize = 0,
    ended: bool = false,

    fn feed(f: *Frames, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0 and !f.ended) {
            if (f.left == 0) {
                const take = @min(4 - f.header_len, rest.len);
                @memcpy(f.header[f.header_len..][0..take], rest[0..take]);
                f.header_len += take;
                rest = rest[take..];
                if (f.header_len < 4) return;
                f.header_len = 0;
                f.left = std.mem.readInt(u32, &f.header, .little);
                if (f.left == 0) {
                    f.ended = true;
                    closeFd(f.to);
                }
                continue;
            }
            const take = @min(f.left, rest.len);
            // A program that stops reading its stdin keeps what it was sent unread,
            // as with any pipe; one that has ended it takes nothing.
            writeAll(f.to, rest[0..take]) catch |err| switch (err) {
                error.BrokenPipe => {},
                else => |e| return e,
            };
            f.left -= take;
            rest = rest[take..];
        }
    }
};

/// Reaps every process that has ended, keeping the program's status when it is one of them.
fn reap(child: c.pid_t, status: *?c_int) void {
    while (true) {
        var raw_status: c_int = 0;
        const rc = c.waitpid(-1, &raw_status, std.posix.W.NOHANG);
        if (rc < 0 and c._errno().* == @backingInt(c.E.INTR)) continue;
        if (rc <= 0) return;
        if (rc == child) status.* = raw_status;
    }
}

fn pipe() ![2]c.fd_t {
    var fds: [2]c.fd_t = @splat(-1);
    if (c.pipe2(&fds, .{ .CLOEXEC = true }) != 0) return error.Pipe;
    return fds;
}

fn closeFd(fd: c.fd_t) void {
    _ = c.close(fd); // safe: a descriptor closed once, by its only holder
}

fn readSome(fd: c.fd_t, buffer: []u8) !usize {
    while (true) {
        const rc = c.read(fd, buffer.ptr, buffer.len);
        if (rc >= 0) return @intCast(rc); // safe: a nonnegative read count
        switch (@as(c.E, @fromBackingInt(@intCast(c._errno().*)))) {
            .INTR => continue,
            else => |e| {
                say("read: {t}", .{e});
                return error.Read;
            },
        }
    }
}

fn writeAll(fd: c.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (rc >= 0) {
            written += @intCast(rc); // safe: a nonnegative write count
            continue;
        }
        switch (@as(c.E, @fromBackingInt(@intCast(c._errno().*)))) {
            .INTR => continue,
            .PIPE => return error.BrokenPipe,
            else => |e| {
                say("write: {t}", .{e});
                return error.Write;
            },
        }
    }
}

/// The program's ending on the `status` port. A machine whose port is missing or
/// refuses the write leaves no ending, which the host reports with the console.
fn report(ending: Ending) void {
    if (status_port < 0) return;
    var buffer: [128]u8 = undefined;
    const text = switch (ending) {
        .exited => |code| std.mem.print(&buffer, "exited {d}\n", .{code}),
        .signal => |sig| std.mem.print(&buffer, "signal {d}\n", .{sig}),
        .failed => |err| std.mem.print(&buffer, "failed {t}\n", .{err}),
    } catch |err| return say("the status port: {t}", .{err});
    writeAll(status_port, text) catch |err| say("the status port: {t}", .{err});
}

fn powerOff() noreturn {
    // A file the program wrote to a share is the host's once written back: the first
    // process writes the caches back before power-off, as any system's init does.
    c.sync();
    _ = reboot(power_off); // safe: only a failed power-off returns
    // The first process never ends: the kernel panics when it does.
    while (true) _ = pause();
}

fn readList(io: Io, gpa: std.mem.Allocator, path: []const u8) ![]const [:0]const u8 {
    const bytes = try readFile(io, path, gpa, .description);
    var list: std.ArrayList([:0]const u8) = .empty;
    var start: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (byte != 0) continue;
        try list.append(gpa, bytes[start..index :0]);
        start = index + 1;
    }
    if (start != bytes.len) return error.UnterminatedList;
    return list.items;
}

/// A line on the machine's console, which the host shows when the machine ends
/// without the program's ending. A line longer than the buffer is cut, and marked so.
fn say(comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    var line: std.Io.Writer = .fixed(&buffer);
    const text = if (line.print("preflight machine: " ++ format ++ "\n", args)) line.buffered() else |err| switch (err) {
        error.WriteFailed => cut(&buffer),
    };
    const fd = c.open("/dev/console", .{ .ACCMODE = .WRONLY, .NOCTTY = true });
    if (fd < 0) return;
    defer closeFd(fd);
    toConsole(fd, text);
}

/// A line that filled `buffer`: what fits, its end marked as cut.
fn cut(buffer: []u8) []u8 {
    const mark = "...\n";
    @memcpy(buffer[buffer.len - mark.len ..], mark);
    return buffer;
}

/// Writes `bytes` to the console `fd`, again where a write is interrupted. A console that
/// refuses a write takes no more of the line: the console is where the machine's failures
/// are told, so its own has nowhere to be told (`writeAll` tells its failures here, and so
/// cannot be how this writes).
fn toConsole(fd: c.fd_t, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (rc >= 0) {
            written += @intCast(rc); // safe: a nonnegative write count
            continue;
        }
        switch (@as(c.E, @fromBackingInt(@intCast(c._errno().*)))) {
            .INTR => continue,
            else => return,
        }
    }
}

fn readFile(io: Io, path: []const u8, gpa: std.mem.Allocator, limit: seam.Limit) ![]u8 {
    return seam.file(io, Io.Dir.cwd(), path, gpa, limit) catch |err| {
        say("reading {s}: {t}", .{ path, err });
        return err;
    };
}

fn check(rc: c_int, err: anyerror) !void {
    if (rc == 0) return;
    say("{t}: {t}", .{ err, @as(c.E, @fromBackingInt(@intCast(c._errno().*))) });
    return err;
}
