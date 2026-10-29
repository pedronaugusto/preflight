//! The first process of the FreeBSD test machine (vm/freebsd.zig), started by the
//! kernel from its `init_path`, as vm/guest.zig is the riscv64 Linux machine's. It
//! loads the modules the machine's devices need, makes the program a root of its
//! own, runs the one program the run asks for with its standard streams on the
//! machine's ports, writes how it ended, and powers the machine off.
//!
//! The machine's root is the ISO 9660 image, which cannot be written, so the
//! program's root is the machine's memory (tmpfs at /preflight/root): FreeBSD's
//! system directories in it read-only (nullfs), its own devices and /tmp, and the
//! host's directories at their host paths, over the host's 9p share; the first
//! process takes it as its root before it reads the run.
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
const c = std.c;
const Io = std.Io;

// aegis: boundary(A019): libc's reboot(2), which std.c does not declare for FreeBSD
extern "c" fn reboot(howto: c_int) c_int;
// aegis: boundary(A019): libc's pause(3), which std.c does not declare
extern "c" fn pause() c_int;
// aegis: boundary(A019): libc's kldload(2), which std.c does not declare
extern "c" fn kldload(file: [*:0]const u8) c_int;
// aegis: boundary(A019): libc's nmount(2), which std.c does not declare; its options are name and value pairs
extern "c" fn nmount(iov: [*]c.iovec, niov: c_uint, flags: c_int) c_int;
// aegis: boundary(A019): libc's chroot(2), which std.c does not declare
extern "c" fn chroot(path: [*:0]const u8) c_int;
// aegis: boundary(A019): libc's setgroups(2), which std.c does not declare for FreeBSD
extern "c" fn setgroups(ngroups: c_int, gidset: [*]const c.gid_t) c_int;
// aegis: boundary(A019): libc's cfmakeraw(3), which std.c does not declare
extern "c" fn cfmakeraw(t: *c.termios) void;
// aegis: boundary(A019): libc's sigprocmask(2) on FreeBSD's own sigset_t
extern "c" fn sigprocmask(how: c_int, set: ?*const c.sigset_t, old: ?*c.sigset_t) c_int;

/// sys/reboot.h: power the machine off after halting, without the kernel's own
/// write-back, which the first process has done.
const power_off = 0x4000 | 0x4;
/// sys/mount.h's MNT_RDONLY.
const read_only = 0x1;
/// signal.h's SIG_BLOCK and SIG_SETMASK.
const sig_block = 1;
const sig_setmask = 3;

/// The modules the machine's devices and file systems need; GENERIC builds in the rest,
/// tmpfs among them.
const modules = [_][*:0]const u8{ "virtio_console", "virtio_p9fs", "nullfs" };
/// The directories of FreeBSD's system the program sees, read-only: every other path
/// in its root is the machine's memory, so that the host's directories can be made
/// at their paths.
const system_dirs = [_][]const u8{ "bin", "boot", "etc", "lib", "libexec", "sbin", "usr" };
const new_root = "/preflight/root";
const run_mount = "/run/preflight";
const host_mount = "/run/host";
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
    for (modules) |name| {
        // A module GENERIC already holds is loaded: EEXIST.
        if (kldload(name) < 0 and c._errno().* != @backingInt(c.E.EXIST)) {
            say("kldload {s}: {t}", .{ name, @as(c.E, @fromBackingInt(@intCast(c._errno().*))) });
            return error.Module;
        }
    }
    try makeRoot(io, gpa);
    try check(chroot(new_root), error.Root);
    try check(c.chdir("/"), error.Root);

    try mountP9(io, "run", run_mount);
    const argv = try readList(io, gpa, run_mount ++ "/argv");
    const environ = try readList(io, gpa, run_mount ++ "/environ");
    const binds = try readList(io, gpa, run_mount ++ "/binds");
    const scratch = try readList(io, gpa, run_mount ++ "/scratch");
    const cwd = try readFile(io, run_mount ++ "/cwd", gpa, 4096);
    const user = try parseUser(try readFile(io, run_mount ++ "/user", gpa, 64));
    if (argv.len == 0) return error.NoProgram;

    // Made before the host's directories are bound, so that it is the machine's own
    // even when the host's HOME holds one of them.
    const home = try makeHome(io, gpa, environ, user);
    try mountP9(io, "host", host_mount);
    if (binds.len % 2 != 0) return error.UnpairedBind;
    var pair: usize = 0;
    while (pair < binds.len) : (pair += 2) try bind(io, gpa, binds[pair], binds[pair + 1]);
    for (scratch) |path| try mountScratch(io, gpa, path);

    const ports = try openPorts(io);
    try writeAll(ports.status, "started\n");
    return try launch(gpa, .{ .argv = argv, .environ = environ, .cwd = cwd, .user = user, .home = home }, ports);
}

/// The program's root in the machine's memory, at `new_root` (a directory of the
/// ISO image): the system's directories read-only, its own devices, a /tmp and a
/// /var/tmp anyone writes.
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
    try mount("tmpfs", new_root ++ "/tmp", "tmpfs", &.{.{ "mode", "1777" }}, 0);
    try mount("tmpfs", new_root ++ "/var/tmp", "tmpfs", &.{.{ "mode", "1777" }}, 0);
}

/// nmount(2): the file system `fstype` from `from` (a device, a share's tag or,
/// for nullfs, a directory) at `fspath`, with `options` beside them, each a name
/// and its value.
fn mount(from: [:0]const u8, fspath: [:0]const u8, fstype: [:0]const u8, options: []const [2][:0]const u8, flags: c_int) !void {
    const max_options = 2;
    if (options.len > max_options) return error.MountOptions;
    var iov: [2 * (3 + max_options)]c.iovec = undefined;
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
    return .{ .base = @constCast(text.ptr), .len = text.len + 1 }; // aegis: boundary(A019): nmount(2) only reads its options; C's iovec has no const pointer
}

fn mountP9(io: Io, tag: [:0]const u8, target: [:0]const u8) !void {
    try Io.Dir.cwd().createDirPath(io, target);
    try mount(tag, target, "p9fs", &.{}, 0);
}

/// The host's directory `resolved`, at `path` in the machine: the path the program
/// has for it, which on the host may pass through links.
fn bind(io: Io, gpa: std.mem.Allocator, path: []const u8, resolved: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, path);
    const source = try gpa.printSentinel("{s}{s}", .{ host_mount, resolved }, 0);
    // A directory under one bound before is already there, at the same path.
    mount(source, try gpa.dupeSentinel(u8, path, 0), "nullfs", &.{}, 0) catch |err| switch (err) {
        error.AlreadyThere => {},
        else => |e| return e,
    };
}

/// A directory the run writes its scratch files in: the machine's memory, so that
/// they behave as files on a local file system, not a share.
fn mountScratch(io: Io, gpa: std.mem.Allocator, path: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, path);
    try mount("tmpfs", try gpa.dupeSentinel(u8, path, 0), "tmpfs", &.{.{ "mode", "1777" }}, 0);
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
        try io.sleep(.fromMilliseconds(10), .awake);
    };
    var mode: c.termios = undefined;
    try check(c.tcgetattr(fd, &mode), error.PortMode);
    cfmakeraw(&mode);
    try check(c.tcsetattr(fd, .NOW, &mode), error.PortMode);
    return fd;
}

// aegis: design(A007): the test machine's first process, one thread and std alone, as its kernel runs it
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
    var unblocked: c.sigset_t = undefined;
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
    var none: [0]c.Kevent = undefined;
    if (c.kevent(kq, &watch, watch.len, &none, 0, null) < 0) return error.Kqueue;

    var input: Frames = .{ .to = stdin[1] };
    var open = [_]bool{ true, true, true };
    var buffer: [64 * 1024]u8 = undefined;
    var status: ?c_int = null;
    var exited = false;
    while (!exited) {
        var events: [8]c.Kevent = undefined;
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
    var none: [0]c.Kevent = undefined;
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
    try Io.Dir.cwd().createDirPath(io, home);
    try check(c.fchownat(c.AT.FDCWD, try gpa.dupeSentinel(u8, home, 0), user.uid, user.gid, 0), error.HomeOwner);
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
    var fds: [2]c.fd_t = undefined;
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
    } catch return;
    writeAll(status_port, text) catch return;
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
    const bytes = try readFile(io, path, gpa, 16 * 1024 * 1024);
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
/// without the program's ending.
fn say(comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const text = std.mem.print(&buffer, "preflight machine: " ++ format ++ "\n", args) catch return;
    const fd = c.open("/dev/console", .{ .ACCMODE = .WRONLY, .NOCTTY = true });
    if (fd < 0) return;
    defer closeFd(fd);
    writeAll(fd, text) catch return;
}

fn readFile(io: Io, path: []const u8, gpa: std.mem.Allocator, limit: u64) ![]u8 {
    return aegis.own.readFile(io, Io.Dir.cwd(), path, gpa, .fromRaw(limit)) catch |err| {
        say("reading {s}: {t}", .{ path, err });
        return err;
    };
}

fn check(rc: c_int, err: anyerror) !void {
    if (rc == 0) return;
    say("{t}: {t}", .{ err, @as(c.E, @fromBackingInt(@intCast(c._errno().*))) });
    return err;
}
