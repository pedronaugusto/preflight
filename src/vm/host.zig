//! The test machine's host side: a program built for a Linux target no runner
//! is runs on that target's own kernel, booted under QEMU's system emulation,
//! with the host's files at their paths, its standard streams on the
//! machine's serial ports, and its ending as the host's own.
//!
//! `preflight-vm image <alpine> <rootfs> <init> <kernel> <initrd>` makes the
//! boot image once per build, from Alpine Linux's boot files and root file
//! system and the machine's first process (vm/guest.zig). `preflight-vm install
//! <kernel> <initrd> <rootfs> <initrd-out> <package>...` adds the Alpine packages
//! a package's tests need to it, installed by Alpine's own `apk` on the machine.
//! `preflight-vm run <kernel> <initrd> <program> [args...]` runs one program on
//! it: the build puts it in front of each run of a riscv64 test or program.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const cpio = @import("cpio.zig");

const usage =
    \\usage: preflight-vm image <alpine> <rootfs> <init> <kernel-out> <initrd-out>
    \\       preflight-vm install <kernel> <initrd> <rootfs> <initrd-out> <package>...
    \\       preflight-vm run <kernel> <initrd> <program> [args...]
    \\
;

/// The machine's QEMU, found on PATH.
const qemu = "qemu-system-riscv64";
/// The machine's memory, which also holds its scratch files.
const memory = "2G";
const max_cpus = 8;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len >= 7 and std.mem.eql(u8, args[1], "image")) {
        try image(io, gpa, .{ .alpine = args[2], .rootfs = args[3], .init = args[4], .kernel = args[5], .initrd = args[6] });
        return 0;
    }
    if (args.len >= 7 and std.mem.eql(u8, args[1], "install")) return install(io, gpa, .{ .kernel = args[2], .initrd = args[3], .rootfs = args[4], .out = args[5] }, args[6..]);
    if (args.len >= 5 and std.mem.eql(u8, args[1], "run")) return run(io, gpa, init.environ_map, args[2], args[3], args[4..]);
    try Io.File.stderr().writeStreamingAll(io, usage);
    return 2;
}

const ImagePaths = struct { alpine: []const u8, rootfs: []const u8, init: []const u8, kernel: []const u8, initrd: []const u8 };

/// The boot files: the kernel as QEMU loads it (a raw image; Alpine ships it
/// compressed), and one archive holding the root file system, the kernel's
/// modules out of Alpine's own initramfs, the image of its full module tree, and
/// the machine's first process as `/init`.
fn image(io: Io, gpa: std.mem.Allocator, paths: ImagePaths) !void {
    const cwd = Io.Dir.cwd();
    var alpine = try cwd.openDir(io, paths.alpine, .{});
    defer alpine.close(io);
    const limit: Io.Limit = .limited(512 * 1024 * 1024);

    const kernel = try alpine.readFileAlloc(io, "boot/vmlinuz-lts", gpa, limit);
    const raw_kernel = if (std.mem.startsWith(u8, kernel, "\x1f\x8b")) try gunzip(gpa, kernel) else kernel;
    try cwd.writeFile(io, .{ .sub_path = paths.kernel, .data = raw_kernel });

    const out = try cwd.createFile(io, paths.initrd, .{});
    defer out.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var file_writer = out.writer(io, &buffer);
    var archive: cpio.Writer = .{ .out = &file_writer.interface };

    var rootfs = try cwd.openDir(io, paths.rootfs, .{ .iterate = true });
    defer rootfs.close(io);
    try addTree(io, gpa, &archive, rootfs, &.{}, null);

    const initramfs = try gunzip(gpa, try alpine.readFileAlloc(io, "boot/initramfs-lts", gpa, limit));
    var modules: cpio.Reader = .{ .bytes = initramfs };
    while (try modules.next()) |entry| {
        const name = std.mem.trimStart(u8, entry.name, "./");
        if (!std.mem.eql(u8, name, "usr/lib/modules") and !std.mem.startsWith(u8, name, "usr/lib/modules/")) continue;
        try archive.add(.{ .name = name, .kind = entry.kind, .mode = entry.mode, .data = entry.data });
    }

    try archive.add(.{ .name = "preflight", .kind = .directory, .mode = 0o755 });
    try archive.add(.{ .name = "preflight/modules.squashfs", .kind = .file, .mode = 0o644, .data = try alpine.readFileAlloc(io, "boot/modloop-lts", gpa, limit) });
    try archive.add(.{ .name = "init", .kind = .file, .mode = 0o755, .data = try cwd.readFileAlloc(io, paths.init, gpa, limit) });
    try archive.finish();
    try file_writer.interface.flush();
}

/// Every member of a root file system, parents before what they hold, but those
/// under `leave`. The package cache keeps no owners and only the executable bit,
/// so files are root's, 0755 or 0644. A tree unpacked over `over` keeps that
/// tree's links where it has a directory: what it holds goes through the link.
fn addTree(io: Io, gpa: std.mem.Allocator, archive: *cpio.Writer, root: Io.Dir, leave: []const []const u8, over: ?Io.Dir) !void {
    var walker = try root.walk(gpa);
    defer walker.deinit();
    var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    while (try walker.next(io)) |entry| {
        if (leftOut(entry.path, leave)) {
            if (entry.kind == .directory) walker.leave(io);
            continue;
        }
        switch (entry.kind) {
            .directory => {
                if (over) |base| {
                    const stat: ?Io.File.Stat = base.statFile(io, entry.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
                        error.FileNotFound, error.NotDir => null,
                        else => |e| return e,
                    };
                    if (stat) |found| if (found.kind == .sym_link) continue;
                }
                try archive.add(.{ .name = entry.path, .kind = .directory, .mode = 0o755 });
            },
            .sym_link => {
                const len = try root.readLink(io, entry.path, &link_buffer);
                try archive.add(.{ .name = entry.path, .kind = .symlink, .mode = 0o777, .data = link_buffer[0..len] });
            },
            .file => {
                const stat = try root.statFile(io, entry.path, .{});
                const executable = stat.permissions.toMode() & 0o111 != 0;
                const data = try root.readFileAlloc(io, entry.path, gpa, .limited(512 * 1024 * 1024));
                try archive.add(.{ .name = entry.path, .kind = .file, .mode = if (executable) 0o755 else 0o644, .data = data });
            },
            else => return error.UnsupportedRootMember,
        }
    }
}

fn gunzip(gpa: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var input: Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&input, .gzip, &window);
    return decompress.reader.allocRemaining(gpa, .limited(1024 * 1024 * 1024));
}

/// Runs `argv` on the machine and ends as it ended: its exit code, or its signal.
fn run(io: Io, gpa: std.mem.Allocator, environ: *const std.process.Environ.Map, kernel: []const u8, initrd: []const u8, argv: []const []const u8) !u8 {
    const cwd = Io.Dir.cwd();
    const here = try cwd.realPathFileAlloc(io, ".", gpa);
    const run_path = try runDirectory(io, gpa, here);
    // glint-ignore: Z026 -- a scratch directory left behind is the cache's to prune; the run's ending is the result
    defer cwd.deleteTree(io, run_path) catch {};
    var run_dir = try cwd.openDir(io, run_path, .{});
    defer run_dir.close(io);

    const program = try cwd.realPathFileAlloc(io, argv[0], gpa);
    var guest_argv: std.ArrayList(u8) = .empty;
    try appendEntry(gpa, &guest_argv, program);
    for (argv[1..]) |arg| try appendEntry(gpa, &guest_argv, arg);
    try run_dir.writeFile(io, .{ .sub_path = "argv", .data = guest_argv.items });

    var guest_environ: std.ArrayList(u8) = .empty;
    for (environ.keys(), environ.values()) |key, value| {
        // The progress pipe is the host's, and the machine has its own programs.
        if (std.mem.eql(u8, key, "ZIG_PROGRESS") or std.mem.eql(u8, key, "PATH")) continue;
        try guest_environ.print(gpa, "{s}={s}\x00", .{ key, value });
    }
    try run_dir.writeFile(io, .{ .sub_path = "environ", .data = guest_environ.items });

    // The directories the program can name: where it runs, where it is, and where
    // any of its arguments points. Each is bound at the path the program has for
    // it, from the host's resolved path.
    var binds: std.ArrayList(u8) = .empty;
    var bound: std.array_hash_map.String(void) = .empty;
    try addBind(io, gpa, &binds, &bound, here);
    try addBind(io, gpa, &binds, &bound, std.Io.Dir.path.dirname(program) orelse "/");
    for (argv[1..]) |arg| {
        const value = if (std.mem.startsWith(u8, arg, "--")) if (std.mem.findScalar(u8, arg, '=')) |eq| arg[eq + 1 ..] else continue else arg;
        if (!std.Io.Dir.path.isAbsolute(value)) continue;
        const stat = cwd.statFile(io, value, .{}) catch continue;
        try addBind(io, gpa, &binds, &bound, if (stat.kind == .directory) value else std.Io.Dir.path.dirname(value) orelse "/");
    }
    try run_dir.writeFile(io, .{ .sub_path = "binds", .data = binds.items });
    // Test files go where `std.testing.tmpDir` makes them: on the machine's own file system.
    var scratch: std.ArrayList(u8) = .empty;
    try appendEntry(gpa, &scratch, try std.Io.Dir.path.join(gpa, &.{ here, ".zig-cache", "tmp" }));
    try run_dir.writeFile(io, .{ .sub_path = "scratch", .data = scratch.items });
    try run_dir.writeFile(io, .{ .sub_path = "cwd", .data = here });
    // The machine runs the program as this user, as the build does here.
    try run_dir.writeFile(io, .{ .sub_path = "user", .data = try gpa.print("{d} {d}\n", .{ std.posix.system.getuid(), std.posix.system.getgid() }) });

    switch (try boot(io, gpa, kernel, initrd, run_path, .offline)) {
        .exited => |code| return code,
        .signal => |sig| raiseOwn(sig),
    }
}

const InstallPaths = struct { kernel: []const u8, initrd: []const u8, rootfs: []const u8, out: []const u8 };

/// Where the machine's `apk` installs, on the run's share.
const install_root = "/run/preflight/root";

/// The boot image with `packages` added: Alpine's `apk` installs them and what they
/// need on the machine, from the release's own repositories over QEMU's user
/// network, into a root on the run's share, trusting the release's own signing
/// keys; that root follows the image as a second archive, which the kernel
/// unpacks over the first. Alpine keeps only the newest build of a package in a
/// release's repositories, so the packages are the release's current ones when
/// the image is made, as a hosted runner's tools are its image's.
fn install(io: Io, gpa: std.mem.Allocator, paths: InstallPaths, packages: []const []const u8) !u8 {
    const cwd = Io.Dir.cwd();
    const here = try cwd.realPathFileAlloc(io, ".", gpa);
    const run_path = try runDirectory(io, gpa, here);
    // glint-ignore: Z026 -- a scratch directory left behind is the cache's to prune; the image is the result
    defer cwd.deleteTree(io, run_path) catch {};
    var run_dir = try cwd.openDir(io, run_path, .{});
    defer run_dir.close(io);

    // apk reads the keys it trusts and the repositories it installs from under its root.
    var rootfs = try cwd.openDir(io, paths.rootfs, .{});
    defer rootfs.close(io);
    try run_dir.createDirPath(io, "root/etc/apk/keys");
    var keys = try rootfs.openDir(io, "etc/apk/keys", .{ .iterate = true });
    defer keys.close(io);
    var key_files = keys.iterate();
    while (try key_files.next(io)) |key| {
        if (key.kind != .file) continue;
        const data = try keys.readFileAlloc(io, key.name, gpa, .limited(64 * 1024));
        try run_dir.writeFile(io, .{ .sub_path = try gpa.print("root/etc/apk/keys/{s}", .{key.name}), .data = data });
    }
    try run_dir.writeFile(io, .{ .sub_path = "root/etc/apk/repositories", .data = try rootfs.readFileAlloc(io, "etc/apk/repositories", gpa, .limited(64 * 1024)) });

    var guest_argv: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "/sbin/apk", "add", "--root", install_root, "--initdb", "--usermode", "--no-scripts", "--no-cache", "--no-progress" }) |arg| try appendEntry(gpa, &guest_argv, arg);
    for (packages) |package| try appendEntry(gpa, &guest_argv, package);
    try run_dir.writeFile(io, .{ .sub_path = "argv", .data = guest_argv.items });
    for ([_][]const u8{ "environ", "binds", "scratch" }) |name| try run_dir.writeFile(io, .{ .sub_path = name, .data = "" });
    try run_dir.writeFile(io, .{ .sub_path = "cwd", .data = "/" });
    // As the build's user, who owns the share: apk's user mode leaves owners alone,
    // which the share could not keep.
    try run_dir.writeFile(io, .{ .sub_path = "user", .data = try gpa.print("{d} {d}\n", .{ std.posix.system.getuid(), std.posix.system.getgid() }) });

    switch (try boot(io, gpa, paths.kernel, paths.initrd, run_path, .online)) {
        .exited => |code| if (code != 0) {
            try Io.File.stderr().writeStreamingAll(io, try gpa.print("preflight-vm: apk could not install {s} (exit {d})\n", .{ try std.mem.join(gpa, " ", packages), code }));
            return code;
        },
        .signal => |sig| raiseOwn(sig),
    }

    const out = try cwd.createFile(io, paths.out, .{});
    defer out.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var file_writer = out.writer(io, &buffer);
    try file_writer.interface.writeAll(try cwd.readFileAlloc(io, paths.initrd, gpa, .limited(1024 * 1024 * 1024)));
    var archive: cpio.Writer = .{ .out = &file_writer.interface };
    var root = try run_dir.openDir(io, "root", .{ .iterate = true });
    defer root.close(io);
    // The package database stays the image's own: these files are tools for tests.
    try addTree(io, gpa, &archive, root, &.{ "etc/apk", "lib/apk", "var/cache/apk" }, rootfs);
    try archive.finish();
    try file_writer.interface.flush();
    return 0;
}

/// A scratch directory for one boot, shared with the machine as `run`.
fn runDirectory(io: Io, gpa: std.mem.Allocator, here: []const u8) ![]const u8 {
    var random: [8]u8 = undefined;
    io.random(&random);
    const run_path = try gpa.print("{s}/.zig-cache/tmp/preflight-vm-{x}", .{ here, random });
    try Io.Dir.cwd().createDirPath(io, run_path);
    return run_path;
}

/// Whether the machine reaches the network: only to install packages.
const Network = enum { offline, online };

/// Boots the machine on the run described in `run_path` and returns how its
/// program ended.
fn boot(io: Io, gpa: std.mem.Allocator, kernel: []const u8, initrd: []const u8, run_path: []const u8, network: Network) !Ending {
    const cwd = Io.Dir.cwd();
    const cpus = @min(std.Thread.getCpuCount() catch 1, max_cpus);
    const console = try gpa.print("file:{s}/console", .{run_path});
    const status_path = try gpa.print("{s}/status", .{run_path});
    const share = try gpa.print("local,id=run,path={s},security_model=none", .{run_path});
    const machine_argv = [_][]const u8{
        qemu,                                       "-machine",                                  "virt",                                     "-cpu",                              "rv64",
        "-smp",                                     try gpa.print("{d}", .{cpus}),               "-m",                                       memory,                              "-nodefaults",
        "-display",                                 "none",                                      "-no-reboot",                               "-bios",                             "default",
        "-kernel",                                  kernel,                                      "-initrd",                                  initrd,                              "-append",
        "console=ttyS0 loglevel=4 panic=-1",        "-serial",                                   console,                                    "-device",                           "virtio-serial-device",
        "-chardev",                                 "stdio,id=io,signal=off",                    "-device",                                  "virtserialport,chardev=io,name=io",
        // Appended, so that a log the host's stderr is redirected to is not truncated.
        "-chardev",
        "file,id=err,path=/dev/stderr,append=on",   "-device",                                   "virtserialport,chardev=err,name=err",      "-chardev",                          try gpa.print("file,id=status,path={s}", .{status_path}),
        "-device",                                  "virtserialport,chardev=status,name=status", "-fsdev",                                   share,                               "-device",
        "virtio-9p-device,fsdev=run,mount_tag=run", "-fsdev",                                    "local,id=host,path=/,security_model=none", "-device",                           "virtio-9p-device,fsdev=host,mount_tag=host",
    };
    // QEMU's user network: the machine is 10.0.2.15 behind a gateway at 10.0.2.2
    // and a resolver at 10.0.2.3, which the first process sets up when told to.
    const network_argv = [_][]const u8{ "-netdev", "user,id=net", "-device", "virtio-net-device,netdev=net" };
    const online_argv = machine_argv ++ network_argv;
    const qemu_argv: []const []const u8 = switch (network) {
        .offline => &machine_argv,
        .online => &online_argv,
    };
    if (network == .online) try cwd.writeFile(io, .{ .sub_path = try gpa.print("{s}/network", .{run_path}), .data = "" });
    var child = std.process.spawn(io, .{ .argv = qemu_argv, .stdin = .pipe, .stdout = .inherit, .stderr = .inherit }) catch |err| {
        try Io.File.stderr().writeStreamingAll(io, try gpa.print("preflight-vm: starting {s}: {t}\n", .{ qemu, err }));
        return err;
    };
    // The machine's port has no end of input to give: a host that stops writing would
    // stall its writes. The pipe stays open, and the host's input reaches it as it comes.
    const forward = try std.Thread.spawn(.{}, forwardInput, .{ io, child.stdin.? });
    forward.detach();
    const term = try child.wait(io);

    const status = cwd.readFileAlloc(io, status_path, gpa, .limited(256)) catch "";
    if (parseStatus(status)) |ending| return ending;
    try Io.File.stderr().writeStreamingAll(io, try gpa.print("preflight-vm: the machine ended ({any}) without its program's status \"{s}\"; its console:\n", .{ term, std.mem.trimEnd(u8, status, "\n") }));
    const log = cwd.readFileAlloc(io, try gpa.print("{s}/console", .{run_path}), gpa, .limited(16 * 1024 * 1024)) catch "";
    try Io.File.stderr().writeStreamingAll(io, log[log.len -| 8192..]);
    return error.MachineFailed;
}

/// Whether `path` is one of `leave` or lies under one.
fn leftOut(path: []const u8, leave: []const []const u8) bool {
    for (leave) |prefix| {
        if (std.mem.eql(u8, path, prefix)) return true;
        if (path.len > prefix.len and std.mem.startsWith(u8, path, prefix) and path[prefix.len] == '/') return true;
    }
    return false;
}

fn appendEntry(gpa: std.mem.Allocator, list: *std.ArrayList(u8), entry: []const u8) !void {
    try list.appendSlice(gpa, entry);
    try list.append(gpa, 0);
}

/// Binds `path` once: the machine's path, then the host's resolved one.
fn addBind(io: Io, gpa: std.mem.Allocator, binds: *std.ArrayList(u8), bound: *std.array_hash_map.String(void), path: []const u8) !void {
    if ((try bound.getOrPut(gpa, path)).found_existing) return;
    const resolved = try Io.Dir.cwd().realPathFileAlloc(io, path, gpa);
    try appendEntry(gpa, binds, path);
    try appendEntry(gpa, binds, resolved);
}

/// The host's input, framed for the machine's first process (vm/guest.zig): a
/// little-endian u32 length and the bytes, and an empty frame at its end. The pipe
/// to QEMU stays open after it: a port whose host end closes stalls the machine's
/// writes to it.
fn forwardInput(io: Io, to: Io.File) void {
    var chunk: [16 * 1024]u8 = undefined;
    var out_buffer: [16 * 1024 + 4]u8 = undefined;
    var output = to.writerStreaming(io, &out_buffer);
    const stdin = Io.File.stdin();
    while (true) {
        // The end of the host's input, or a read of it that failed: the program's input ends either way.
        const n = stdin.readStreaming(io, &.{&chunk}) catch 0;
        output.interface.writeInt(u32, @intCast(n), .little) catch return; // safe: at most the chunk's length
        output.interface.writeAll(chunk[0..n]) catch return;
        output.interface.flush() catch return;
        if (n == 0) return;
    }
}

pub const Ending = union(enum) { exited: u8, signal: u32 };

/// What the machine's first process wrote: `exited N` or `signal N`.
pub fn parseStatus(text: []const u8) ?Ending {
    const line = std.mem.trimEnd(u8, text, "\n");
    if (std.mem.startsWith(u8, line, "exited ")) return .{ .exited = std.fmt.parseInt(u8, line["exited ".len..], 10) catch return null };
    if (std.mem.startsWith(u8, line, "signal ")) return .{ .signal = std.fmt.parseInt(u32, line["signal ".len..], 10) catch return null };
    return null;
}

/// Ends this process by the signal that ended the program, so that the build sees
/// the crash as its own. Linux numbers signals alike on every architecture it runs
/// tests on; a host that numbers them otherwise ends with 128 + the number.
fn raiseOwn(sig: u32) noreturn {
    if (builtin.target.os.tag == .linux and sig > 0 and sig < 32) {
        const signal: std.posix.SIG = @fromBackingInt(@intCast(sig)); // safe: checked to lie between 1 and 31 above
        var default: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(signal, &default, null);
        // glint-ignore: Z026 -- the exit below ends the process either way, with 128 + the signal
        std.posix.raise(signal) catch {};
    }
    std.process.exit(@truncate(128 +% sig)); // safe: an exit code is a byte, as a shell takes 128 + a signal
}

test "a path is left out when it is one of those named or lies under one" {
    const leave = [_][]const u8{ "etc/apk", "lib/apk" };
    try std.testing.expect(leftOut("etc/apk", &leave));
    try std.testing.expect(leftOut("etc/apk/keys/a.pub", &leave));
    try std.testing.expect(!leftOut("etc/apk-tools", &leave));
    try std.testing.expect(!leftOut("etc", &leave));
    try std.testing.expect(!leftOut("usr/bin/git", &leave));
}

test "the first process's status reads back as an ending" {
    try std.testing.expectEqual(Ending{ .exited = 3 }, parseStatus("exited 3\n").?);
    try std.testing.expectEqual(Ending{ .signal = 6 }, parseStatus("signal 6\n").?);
    try std.testing.expectEqual(@as(?Ending, null), parseStatus("failed Mount9p\n"));
    try std.testing.expectEqual(@as(?Ending, null), parseStatus(""));
}

test "any status text reads as an ending or as none, never past its bytes" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buffer: [64]u8 = undefined;
            const len = smith.slice(&buffer);
            const text = buffer[0..len];
            const ending = parseStatus(text) orelse return;
            try std.testing.expect(std.mem.startsWith(u8, text, "exited ") or std.mem.startsWith(u8, text, "signal "));
            _ = ending;
        }
    }.one, .{ .corpus = &.{ "exited 0\n", "signal 11\n", "exited 300\n", "failed Mount9p\n" } });
}
