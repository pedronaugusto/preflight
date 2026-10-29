//! The first process of the test machine: a Linux kernel booted under QEMU's
//! system emulation for a target no runner is. It mounts what a test expects of
//! a Linux system, loads the kernel modules the machine's devices need, takes
//! the host's directories the run names over 9p at their host paths, runs the
//! one program the run asks for with its standard streams on the machine's
//! serial ports, writes how it ended, and powers the machine off.
//!
//! The program runs as the host's user (the `user` file: uid and gid), as a build
//! runs it on the host, with the machine's own PATH and SHELL and an empty home
//! at the host's HOME path.
//!
//! The run is described by the host (vm/host.zig) in files on the `run` share:
//! `argv`, `environ`, `binds` (each machine path, then the host's resolved
//! path) and `scratch`, each a list of NUL-terminated strings, and `cwd`; a
//! `network` file asks for QEMU's user network, which only an install has. The program's stdin and stdout are the `io` port, its
//! stderr the `err` port, and `status` takes `exited N` or `signal N`.
const std = @import("std");
const aegis = @import("aegis");
const linux = std.os.linux;
const Io = std.Io;

/// The modules the boot image's own tree holds, loaded first: the serial ports,
/// and the block loop and squashfs that open the rest of the kernel's modules.
const boot_modules = [_][]const u8{ "virtio_mmio", "virtio_console", "loop", "squashfs" };
/// From the full module tree: 9p over virtio, which carries the host's files.
const share_modules = [_][]const u8{ "9pnet_virtio", "9p" };
/// From the full module tree, for an install: the network device.
const network_modules = [_][]const u8{"virtio_net"};
/// The full module tree, a squashfs image the boot image carries.
const module_image = "/preflight/modules.squashfs";
const module_mount = "/run/modules";
const run_mount = "/run/preflight";
const host_mount = "/run/host";
const guest_path = "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

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
    signal: linux.SIG,
    failed: anyerror,
};

fn run(io: Io, gpa: std.mem.Allocator) !Ending {
    try mountSystem();
    try loopbackUp();
    var uts: linux.utsname = undefined;
    if (linux.errno(linux.uname(&uts)) != .SUCCESS) return error.Uname;
    const release = std.mem.sliceTo(&uts.release, 0);

    const boot_tree = try gpa.print("/usr/lib/modules/{s}", .{release});
    try loadModules(io, gpa, boot_tree, &boot_modules);
    try mountModuleImage(io);
    const full_tree = try findModuleTree(io, gpa, release);
    try loadModules(io, gpa, full_tree, &share_modules);

    try mount9p("run", run_mount);
    if (exists(io, run_mount ++ "/network")) {
        try loadModules(io, gpa, full_tree, &network_modules);
        try networkUp(io);
    }
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
    try mount9p("host", host_mount);
    if (binds.len % 2 != 0) return error.UnpairedBind;
    var pair: usize = 0;
    while (pair < binds.len) : (pair += 2) try bind(io, gpa, binds[pair], binds[pair + 1]);
    for (scratch) |path| try mountScratch(io, gpa, path);
    try check(linux.umount2(host_mount, linux.MNT.DETACH), error.UnmountHost);

    const ports = try openPorts(io, gpa);
    return try launch(gpa, .{ .argv = argv, .environ = environ, .cwd = cwd, .user = user, .home = home }, ports);
}

/// What a test expects of a Linux system: proc, sys, devices and pseudo-terminals,
/// shared memory, a scratch /tmp and /run, and the cgroup tree.
fn mountSystem() !void {
    const Mount = struct { source: [*:0]const u8, target: [*:0]const u8, fstype: [*:0]const u8, data: ?[*:0]const u8 = null };
    const mounts = [_]Mount{
        .{ .source = "proc", .target = "/proc", .fstype = "proc" },
        .{ .source = "sysfs", .target = "/sys", .fstype = "sysfs" },
        .{ .source = "devtmpfs", .target = "/dev", .fstype = "devtmpfs" },
        .{ .source = "devpts", .target = "/dev/pts", .fstype = "devpts", .data = "ptmxmode=0666,mode=0620" },
        .{ .source = "shm", .target = "/dev/shm", .fstype = "tmpfs", .data = "mode=1777" },
        .{ .source = "tmpfs", .target = "/tmp", .fstype = "tmpfs", .data = "mode=1777" },
        .{ .source = "tmpfs", .target = "/run", .fstype = "tmpfs", .data = "mode=0755" },
        .{ .source = "cgroup2", .target = "/sys/fs/cgroup", .fstype = "cgroup2" },
    };
    for (mounts) |m| {
        _ = linux.mkdirat(linux.AT.FDCWD, m.target, 0o755); // safe: an existing directory serves
        const data: usize = if (m.data) |d| @intFromPtr(d) else 0;
        const rc = linux.mount(m.source, m.target, m.fstype, 0, data);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            // The kernel mounts devtmpfs itself when built to.
            .BUSY => {},
            else => |e| {
                say("mount {s}: {t}", .{ m.target, e });
                return error.MountSystem;
            },
        }
    }
    // The links a running system's device manager makes beside devtmpfs's nodes.
    const links = [_][2][*:0]const u8{
        .{ "/proc/self/fd", "/dev/fd" },
        .{ "/proc/self/fd/0", "/dev/stdin" },
        .{ "/proc/self/fd/1", "/dev/stdout" },
        .{ "/proc/self/fd/2", "/dev/stderr" },
    };
    for (links) |link| switch (linux.errno(linux.symlinkat(link[0], linux.AT.FDCWD, link[1]))) {
        .SUCCESS, .EXIST => {},
        else => return error.DeviceLinks,
    };
}

/// The loopback interface up, as on any running system: tests listen on 127.0.0.1.
fn loopbackUp() !void {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.LoopbackSocket;
    const fd: linux.fd_t = @intCast(rc); // safe: a successful socket call returns a descriptor
    defer _ = linux.close(fd); // safe: closing a socket only we hold
    var request: linux.ifreq = std.mem.zeroes(linux.ifreq);
    @memcpy(request.ifrn.name[0..2], "lo");
    request.ifru.flags = .{ .UP = true, .LOOPBACK = true, .RUNNING = true };
    try check(linux.ioctl(fd, linux.SIOCSIFFLAGS, @intFromPtr(&request)), error.LoopbackUp);
}

/// QEMU's user network on the first Ethernet device: the machine at 10.0.2.15/24,
/// its gateway at 10.0.2.2 and its resolver at 10.0.2.3, as QEMU always places them.
fn networkUp(io: Io) !void {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.NetworkSocket;
    const fd: linux.fd_t = @intCast(rc); // safe: a successful socket call returns a descriptor
    defer _ = linux.close(fd); // safe: closing a socket only we hold
    var request: linux.ifreq = std.mem.zeroes(linux.ifreq);
    @memcpy(request.ifrn.name[0..4], "eth0");
    request.ifru.addr = inet(.{ 10, 0, 2, 15 });
    // The device registers as its driver probes it; wait for it as for a device node.
    var tries: usize = 0;
    while (true) : (tries += 1) {
        const set = linux.ioctl(fd, linux.SIOCSIFADDR, @intFromPtr(&request));
        switch (linux.errno(set)) {
            .SUCCESS => break,
            .NODEV => if (tries == 1000) return error.NetworkMissing,
            else => |e| {
                say("eth0 address: {t}", .{e});
                return error.NetworkAddress;
            },
        }
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    request.ifru.netmask = inet(.{ 255, 255, 255, 0 });
    try check(linux.ioctl(fd, linux.SIOCSIFNETMASK, @intFromPtr(&request)), error.NetworkMask);
    request.ifru.flags = .{ .UP = true, .RUNNING = true };
    try check(linux.ioctl(fd, linux.SIOCSIFFLAGS, @intFromPtr(&request)), error.NetworkUp);
    var route: Route = .{ .gateway = inet(.{ 10, 0, 2, 2 }), .flags = route_up | route_gateway };
    try check(linux.ioctl(fd, linux.SIOCADDRT, @intFromPtr(&route)), error.NetworkRoute);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = "/etc/resolv.conf", .data = "nameserver 10.0.2.3\n" });
}

/// Linux's `struct rtentry`, for SIOCADDRT: a default route has every address
/// but its gateway's zero.
const Route = extern struct {
    pad1: c_ulong = 0,
    destination: linux.sockaddr = inet(.{ 0, 0, 0, 0 }),
    gateway: linux.sockaddr,
    mask: linux.sockaddr = inet(.{ 0, 0, 0, 0 }),
    flags: c_ushort,
    pad2: c_short = 0,
    pad3: c_ulong = 0,
    pad4: ?*anyopaque = null,
    metric: c_short = 0,
    device: ?[*:0]u8 = null,
    mtu: c_ulong = 0,
    window: c_ulong = 0,
    irtt: c_ushort = 0,
};
const route_up = 0x1;
const route_gateway = 0x2;

/// An IPv4 address with no port, as `struct sockaddr_in` lays it out.
fn inet(address: [4]u8) linux.sockaddr {
    var data: [14]u8 = @splat(0);
    data[2..6].* = address;
    return .{ .family = linux.AF.INET, .data = data };
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Loads `names` and what they depend on, from `tree`'s `modules.dep`, each once;
/// a module built in or loaded already is passed over.
fn loadModules(io: Io, gpa: std.mem.Allocator, tree: []const u8, names: []const []const u8) !void {
    const dep_path = try std.Io.Dir.path.join(gpa, &.{ tree, "modules.dep" });
    const deps = try readFile(io, dep_path, gpa, 16 * 1024 * 1024);
    for (names) |name| {
        const line = findModule(deps, name) orelse {
            say("no module {s} in {s}", .{ name, tree });
            return error.ModuleMissing;
        };
        const colon = std.mem.findScalar(u8, line, ':') orelse return error.ModulesDep;
        // modules.dep lists what a module needs, nearest first; load the farthest first.
        var needed: std.ArrayList([]const u8) = .empty;
        var words = std.mem.tokenizeScalar(u8, line[colon + 1 ..], ' ');
        while (words.next()) |word| try needed.append(gpa, word);
        var index = needed.items.len;
        while (index > 0) {
            index -= 1;
            try insertModule(io, gpa, tree, needed.items[index]);
        }
        try insertModule(io, gpa, tree, line[0..colon]);
    }
}

/// The `modules.dep` line of the module `name`, whose file name is `name` with
/// `-` and `_` alike, as the kernel takes them.
fn findModule(deps: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, deps, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const base = std.Io.Dir.path.basename(line[0..colon]);
        const stem_end = std.mem.find(u8, base, ".ko") orelse continue;
        const stem = base[0..stem_end];
        if (stem.len != name.len) continue;
        const same = for (stem, name) |a, b| {
            const x: u8 = if (a == '-') '_' else a;
            const y: u8 = if (b == '-') '_' else b;
            if (x != y) break false;
        } else true;
        if (same) return line;
    }
    return null;
}

fn insertModule(io: Io, gpa: std.mem.Allocator, tree: []const u8, relative: []const u8) !void {
    const path = try std.Io.Dir.path.join(gpa, &.{ tree, relative });
    const file = try readFile(io, path, gpa, 64 * 1024 * 1024);
    const image = if (std.mem.endsWith(u8, relative, ".gz")) try gunzip(gpa, file) else file;
    const rc = linux.syscall3(.init_module, @intFromPtr(image.ptr), image.len, @intFromPtr(""));
    switch (linux.errno(rc)) {
        .SUCCESS, .EXIST => {},
        else => |e| {
            say("loading {s}: {t}", .{ relative, e });
            return error.ModuleLoad;
        },
    }
}

fn gunzip(gpa: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var input: Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&input, .gzip, &window);
    return decompress.reader.allocRemaining(gpa, .limited(256 * 1024 * 1024));
}

/// The full module tree, read-only through a loop device.
fn mountModuleImage(io: Io) !void {
    const control = try openPath("/dev/loop-control", .{ .ACCMODE = .RDWR, .CLOEXEC = true });
    defer _ = linux.close(control); // safe: closing a control descriptor only we hold
    const free = linux.ioctl(control, loop_ctl_get_free, 0);
    if (linux.errno(free) != .SUCCESS) return error.LoopDevice;
    var name_buffer: [32]u8 = undefined;
    const device = try std.mem.printSentinel(&name_buffer, "/dev/loop{d}", .{free}, 0);
    // devtmpfs adds the node as the device appears.
    const loop = try waitOpen(io, device, .{ .ACCMODE = .RDWR, .CLOEXEC = true });
    defer _ = linux.close(loop); // safe: the attached device keeps its own reference
    const backing = try openPath(module_image, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    defer _ = linux.close(backing); // safe: the loop device keeps its own reference
    try check(linux.ioctl(loop, loop_set_fd, @intCast(backing)), error.LoopAttach); // safe: an open descriptor is not negative
    _ = linux.mkdirat(linux.AT.FDCWD, module_mount, 0o755); // safe: an existing directory serves
    try check(linux.mount(device, module_mount, "squashfs", linux.MS.RDONLY, 0), error.MountModules);
}

const loop_ctl_get_free = 0x4C82;
const loop_set_fd = 0x4C00;

/// The image's tree for this kernel: `modules/<release>` or `<release>` at its root.
fn findModuleTree(io: Io, gpa: std.mem.Allocator, release: []const u8) ![]const u8 {
    for ([_][]const u8{ "modules", "lib/modules", "" }) |prefix| {
        const tree = try std.Io.Dir.path.join(gpa, &.{ module_mount, prefix, release });
        Io.Dir.cwd().access(io, tree, .{}) catch continue;
        return tree;
    }
    return error.ModuleTreeMissing;
}

/// A share of the host's, uncached but for shared mappings: a program maps a file
/// as on a local file system (9p uncached refuses a shared writable map).
fn mount9p(tag: [*:0]const u8, target: [*:0]const u8) !void {
    _ = linux.mkdirat(linux.AT.FDCWD, target, 0o755); // safe: an existing directory serves
    const options = "trans=virtio,version=9p2000.L,msize=524288,cache=mmap";
    try check(linux.mount(tag, target, "9p", 0, @intFromPtr(options.ptr)), error.Mount9p);
}

/// The host's directory `resolved`, at `path` in the machine: the path the program
/// has for it, which on the host may pass through links.
fn bind(io: Io, gpa: std.mem.Allocator, path: []const u8, resolved: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, path);
    const source = try gpa.printSentinel("{s}{s}", .{ host_mount, resolved }, 0);
    const target = try gpa.dupeSentinel(u8, path, 0);
    try check(linux.mount(source, target, null, linux.MS.BIND | linux.MS.REC, 0), error.Bind);
}

/// A directory the run writes its scratch files in: the machine's memory, so that
/// they behave as files on a local file system, not a share.
fn mountScratch(io: Io, gpa: std.mem.Allocator, path: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, path);
    const target = try gpa.dupeSentinel(u8, path, 0);
    try check(linux.mount("tmpfs", target, "tmpfs", 0, @intFromPtr("mode=1777")), error.Scratch);
}

const Ports = struct { io: linux.fd_t, err: linux.fd_t, status: linux.fd_t };

/// The serial ports by name: the kernel numbers them, their names are in sysfs.
fn openPorts(io: Io, gpa: std.mem.Allocator) !Ports {
    var tries: usize = 0;
    while (true) : (tries += 1) {
        if (try findPorts(io, gpa)) |ports| {
            status_port = ports.status;
            return ports;
        }
        if (tries == 1000) return error.PortsMissing;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
}

fn findPorts(io: Io, gpa: std.mem.Allocator) !?Ports {
    var ports: Ports = .{ .io = -1, .err = -1, .status = -1 };
    var dir = Io.Dir.cwd().openDir(io, "/sys/class/virtio-ports", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const name_path = try gpa.print("{s}/name", .{entry.name});
        const raw = try aegis.own.readFile(io, dir, name_path, gpa, .fromRaw(256));
        const name = std.mem.trimEnd(u8, raw, "\n");
        const device = try gpa.printSentinel("/dev/{s}", .{entry.name}, 0);
        const slot: *linux.fd_t = if (std.mem.eql(u8, name, "io")) &ports.io else if (std.mem.eql(u8, name, "err")) &ports.err else if (std.mem.eql(u8, name, "status")) &ports.status else continue;
        if (slot.* < 0) slot.* = try waitOpen(io, device, .{ .ACCMODE = .RDWR, .CLOEXEC = true });
    }
    if (ports.io < 0 or ports.err < 0 or ports.status < 0) {
        for ([_]linux.fd_t{ ports.io, ports.err, ports.status }) |fd| if (fd >= 0) {
            _ = linux.close(fd); // safe: a port opened in a scan that found too few
        };
        return null;
    }
    return ports;
}

// aegis: design(A007): the test machine's first process, one thread and std alone, as its kernel runs it
var status_port: linux.fd_t = -1;

/// Runs the program with pipes for its standard streams, as a build gives a program
/// on any host, and carries them over the ports: the `io` port's frames to its stdin
/// (vm/host.zig frames what the host writes, an empty frame for the end of it), its
/// stdout to the `io` port and its stderr to `err`. A port is a device that blocks a
/// read past what has arrived, so a program reading it directly with `readv` would
/// wait on its second buffer. Every process that ends meanwhile is reaped; what the
/// program leaves running is killed once it ends, as its machine goes with it.
fn launch(gpa: std.mem.Allocator, program: Program, ports: Ports) !Ending {
    const argv_z = try gpa.allocSentinel(?[*:0]const u8, program.argv.len, null);
    for (program.argv, argv_z) |arg, *slot| slot.* = arg.ptr;
    var env: std.ArrayList(?[*:0]const u8) = .empty;
    for (program.environ) |entry| {
        // The machine's own programs and login shell, and its home for the user.
        if (std.mem.startsWith(u8, entry, "PATH=") or std.mem.startsWith(u8, entry, "SHELL=") or std.mem.startsWith(u8, entry, "HOME=")) continue;
        try env.append(gpa, entry.ptr);
    }
    try env.append(gpa, guest_path);
    try env.append(gpa, "SHELL=/bin/sh");
    try env.append(gpa, (try gpa.printSentinel("HOME={s}", .{program.home}, 0)).ptr);
    const env_z = try env.toOwnedSliceSentinel(gpa, null);
    const cwd_z = try gpa.dupeSentinel(u8, program.cwd, 0);

    // Children end with a signal the first process takes from a descriptor, so that
    // it reaps each at once, as a system's init does: a process that is gone is
    // gone, not a zombie its parent's death left to the first process.
    var chld = linux.sigemptyset();
    linux.sigaddset(&chld, .CHLD);
    var unblocked: linux.sigset_t = undefined;
    try check(linux.sigprocmask(linux.SIG.BLOCK, &chld, &unblocked), error.SignalMask);
    const child_ended = linux.signalfd(-1, &chld, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK);
    if (linux.errno(child_ended) != .SUCCESS) return error.SignalFd;

    const stdin = try pipe();
    const stdout = try pipe();
    const stderr = try pipe();
    const forked = linux.fork();
    if (linux.errno(forked) != .SUCCESS) return error.Fork;
    if (forked == 0) {
        // The child: only async-signal-safe calls until exec. The pipes' other
        // ends and the ports close on exec.
        if (linux.errno(linux.sigprocmask(linux.SIG.SETMASK, &unblocked, null)) != .SUCCESS) linux.exit(126);
        const groups = [_]linux.gid_t{program.user.gid};
        if (linux.errno(linux.setgroups(groups.len, &groups)) != .SUCCESS) linux.exit(126);
        if (linux.errno(linux.setgid(program.user.gid)) != .SUCCESS) linux.exit(126);
        if (linux.errno(linux.setuid(program.user.uid)) != .SUCCESS) linux.exit(126);
        if (linux.errno(linux.chdir(cwd_z)) != .SUCCESS) linux.exit(126);
        if (linux.errno(linux.dup2(stdin[0], 0)) != .SUCCESS) linux.exit(126);
        if (linux.errno(linux.dup2(stdout[1], 1)) != .SUCCESS) linux.exit(126);
        if (linux.errno(linux.dup2(stderr[1], 2)) != .SUCCESS) linux.exit(126);
        _ = linux.execve(argv_z[0].?, argv_z.ptr, env_z.ptr); // safe: only a failed exec returns
        linux.exit(127);
    }
    const child: linux.pid_t = @intCast(forked); // safe: a parent's fork result is the child's id
    closeFd(stdin[0]);
    closeFd(stdout[1]);
    closeFd(stderr[1]);
    const ended = linux.pidfd_open(child, 0);
    if (linux.errno(ended) != .SUCCESS) return error.PidFd;

    var input: Frames = .{ .to = stdin[1] };
    var fds = [_]linux.pollfd{
        .{ .fd = ports.io, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = stdout[0], .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = stderr[0], .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = @intCast(ended), .events = linux.POLL.IN, .revents = 0 }, // safe: a successful pidfd_open returns a descriptor
        .{ .fd = @intCast(child_ended), .events = linux.POLL.IN, .revents = 0 }, // safe: a successful signalfd returns a descriptor
    };
    var buffer: [64 * 1024]u8 = undefined;
    var status: ?u32 = null;
    while (fds[3].revents == 0) {
        const rc = linux.poll(&fds, fds.len, -1);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.Poll,
        }
        if (fds[0].revents != 0) {
            const n = try readSome(ports.io, &buffer);
            if (n == 0) fds[0].fd = -1 else try input.feed(buffer[0..n]);
            if (input.ended) fds[0].fd = -1;
        }
        for ([_]usize{ 1, 2 }) |index| if (fds[index].revents != 0) {
            const n = try readSome(fds[index].fd, &buffer);
            if (n == 0) fds[index].fd = -1 else try writeAll(if (index == 1) ports.io else ports.err, buffer[0..n]);
        };
        if (fds[4].revents != 0) {
            var info: [@sizeOf(linux.signalfd_siginfo) * 16]u8 = undefined;
            _ = linux.read(fds[4].fd, &info, info.len); // safe: the signals only say to reap, which follows
        }
        reap(child, &status);
    }
    // What the program wrote before it ended, up to what is in the pipes now.
    for ([_]usize{ 1, 2 }) |index| if (fds[index].fd >= 0) {
        _ = linux.fcntl(fds[index].fd, linux.F.SETFL, @as(u32, @bitCast(linux.O{ .NONBLOCK = true }))); // safe: a failed change only blocks a drain that ends at EOF
        while (true) {
            const rc = linux.read(fds[index].fd, &buffer, buffer.len);
            if (linux.errno(rc) != .SUCCESS or rc == 0) break;
            try writeAll(if (index == 1) ports.io else ports.err, buffer[0..rc]);
        }
    };
    while (status == null) {
        var raw_status: i32 = 0;
        const rc = linux.wait4(child, &raw_status, 0, null);
        switch (linux.errno(rc)) {
            .SUCCESS => status = @bitCast(raw_status), // safe: wait status bits, read as unsigned
            .INTR => continue,
            else => return error.Wait,
        }
    }
    _ = linux.kill(-1, .KILL); // safe: no process may be left, and none may be too
    var ignored: ?u32 = null;
    reap(child, &ignored);
    const wait_status = status.?;
    return if (linux.W.IFEXITED(wait_status)) .{ .exited = linux.W.EXITSTATUS(wait_status) } else .{ .signal = linux.W.TERMSIG(wait_status) };
}

const User = struct { uid: linux.uid_t, gid: linux.gid_t };

const Program = struct {
    argv: []const [:0]const u8,
    environ: []const [:0]const u8,
    cwd: []const u8,
    user: User,
    home: []const u8,
};

fn parseUser(text: []const u8) !User {
    var words = std.mem.tokenizeAny(u8, text, " \n");
    const uid = try std.fmt.parseInt(linux.uid_t, words.next() orelse return error.User, 10);
    const gid = try std.fmt.parseInt(linux.gid_t, words.next() orelse return error.User, 10);
    return .{ .uid = uid, .gid = gid };
}

/// The user's home, empty, at the host's HOME path or /home/user: a test that
/// writes there leaves the host's own home alone.
fn makeHome(io: Io, gpa: std.mem.Allocator, environ: []const [:0]const u8, user: User) ![]const u8 {
    const home = for (environ) |entry| {
        if (std.mem.startsWith(u8, entry, "HOME=") and entry.len > "HOME=/".len) break entry["HOME=".len..];
    } else "/home/user";
    try Io.Dir.cwd().createDirPath(io, home);
    const path = try gpa.dupeSentinel(u8, home, 0);
    try check(linux.chown(path, user.uid, user.gid), error.HomeOwner);
    return home;
}

/// The host's input in frames, a little-endian u32 length and that many bytes,
/// written on to the program's stdin; an empty frame ends it.
const Frames = struct {
    to: linux.fd_t,
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
fn reap(child: linux.pid_t, status: *?u32) void {
    while (true) {
        var raw_status: i32 = 0;
        const rc = linux.wait4(-1, &raw_status, linux.W.NOHANG, null);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return,
        }
        if (rc == 0) return;
        if (@as(linux.pid_t, @intCast(rc)) == child) status.* = @bitCast(raw_status); // safe: wait4 returns a process id
    }
}

fn pipe() ![2]linux.fd_t {
    var fds: [2]linux.fd_t = undefined;
    try check(linux.pipe2(&fds, .{ .CLOEXEC = true }), error.Pipe);
    return fds;
}

fn closeFd(fd: linux.fd_t) void {
    _ = linux.close(fd); // safe: a descriptor closed once, by its only holder
}

fn readSome(fd: linux.fd_t, buffer: []u8) !usize {
    while (true) {
        const rc = linux.read(fd, buffer.ptr, buffer.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            else => |e| {
                say("read: {t}", .{e});
                return error.Read;
            },
        }
    }
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        switch (linux.errno(rc)) {
            .SUCCESS => written += rc,
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
/// refuses the write leaves no status, which the host reports with the console.
fn report(ending: Ending) void {
    if (status_port < 0) return;
    var buffer: [128]u8 = undefined;
    const text = switch (ending) {
        .exited => |code| std.mem.print(&buffer, "exited {d}\n", .{code}),
        .signal => |sig| std.mem.print(&buffer, "signal {d}\n", .{@backingInt(sig)}),
        .failed => |err| std.mem.print(&buffer, "failed {t}\n", .{err}),
    } catch return;
    writeAll(status_port, text) catch return;
}

fn powerOff() noreturn {
    // A file the program mapped from a share is the host's once written back. The test
    // machine's first process is its init, writing the caches back before power-off as any
    // system does: no file's durability is promised here.
    _ = linux.sync(); // safe: sync reports nothing
    _ = linux.reboot(.MAGIC1, .MAGIC2, .POWER_OFF, null); // safe: only a failed power-off returns
    while (true) _ = linux.pause();
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
/// without the program's status.
fn say(comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const text = std.mem.print(&buffer, "preflight machine: " ++ format ++ "\n", args) catch return;
    writeAll(2, text) catch return;
}

fn readFile(io: Io, path: []const u8, gpa: std.mem.Allocator, limit: u64) ![]u8 {
    return aegis.own.readFile(io, Io.Dir.cwd(), path, gpa, .fromRaw(limit)) catch |err| {
        say("reading {s}: {t}", .{ path, err });
        return err;
    };
}

fn openPath(path: [*:0]const u8, flags: linux.O) !linux.fd_t {
    const rc = linux.openat(linux.AT.FDCWD, path, flags, 0);
    if (linux.errno(rc) != .SUCCESS) {
        say("open {s}: {t}", .{ path, linux.errno(rc) });
        return error.Open;
    }
    return @intCast(rc); // safe: a successful open returns a descriptor
}

/// Opens a device node devtmpfs adds once its device appears, waiting up to ten seconds.
fn waitOpen(io: Io, path: [*:0]const u8, flags: linux.O) !linux.fd_t {
    var tries: usize = 0;
    while (true) : (tries += 1) {
        const rc = linux.openat(linux.AT.FDCWD, path, flags, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc), // safe: a successful open returns a descriptor
            .NOENT, .NXIO, .NODEV => if (tries == 1000) return error.DeviceMissing,
            else => |e| {
                say("open {s}: {t}", .{ path, e });
                return error.Open;
            },
        }
        try io.sleep(.fromMilliseconds(10), .awake);
    }
}

fn check(rc: usize, err: anyerror) !void {
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => |e| {
            say("{t}: {t}", .{ err, e });
            return err;
        },
    }
}
