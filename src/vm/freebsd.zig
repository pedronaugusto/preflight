//! The FreeBSD test machine's host side, beside the riscv64 Linux one in host.zig:
//! FreeBSD's own kernel and userland, booted under QEMU with KVM.
//!
//! Both halves are FreeBSD's release files, pinned by hash in preflight's
//! manifest: the kernel distribution set (`kernel.txz`) and the runtime OCI
//! image, whose one layer is the base system a program needs (the run-time
//! linker, libc, libthr, sh). The release's `base.txz` is not among them: Zig's
//! package fetch refuses its hard links (the ustar.zig header), and the loader
//! ships only there, so the machine has none: QEMU starts the kernel at its PVH
//! entry (`-kernel`), with its environment on the command line. The kernel mounts
//! as its root an ISO 9660 image with Rock Ridge (iso9660.zig) made here from the
//! layer, the kernel's modules and the machine's first process (vm/freebsd/guest.zig),
//! since GENERIC builds in cd9660 but not tarfs, and nothing preloads a module
//! without a loader.
const std = @import("std");
const builtin = @import("builtin");
const aegis = @import("aegis");
const Io = std.Io;
const iso9660 = @import("iso9660.zig");
const ustar = @import("ustar.zig");

/// The machine's QEMU, found on PATH.
const qemu = "qemu-system-x86_64";
const memory = "2G";
const max_cpus = 8;
/// How long the machine has to start its program before it is stopped and named a failure.
pub const boot_deadline_seconds = 180;

/// The kernel's environment: its root, the machine's first process, the serial
/// console, and a panic that ends the machine at once instead of waiting at the
/// debugger.
/// Without a loader there is no device.hints: the serial port is named here as the
/// console, as FreeBSD's FIRECRACKER kernel names it. The kernel splits
/// this at spaces and commas. A PVH boot drops the command line's flags (15.1's pv.c
/// keeps only what boot_env_to_howto reads), so the serial console is `boot_serial`,
/// not `-h`: without it the uart ranks below vt, which takes the console to no display.
pub const kernel_environment = "boot_serial=YES vfs.root.mountfrom=cd9660:/dev/vtbd0 vfs.mountroot.timeout=30 init_path=/preflight/init hw.uart.console=io:0x3f8 " ++
    "hint.uart.0.at=isa hint.uart.0.port=0x3F8 hint.uart.0.flags=0x10 hint.uart.0.irq=4 " ++
    "kern.panic_reboot_wait_time=0 debug.debugger_on_panic=0";

pub const ImagePaths = struct { kernel_set: []const u8, runtime: []const u8, init: []const u8, kernel: []const u8, root: []const u8 };

const limit: u64 = 1024 * 1024 * 1024;

/// The boot files: the kernel as QEMU loads it, and the root image holding the
/// runtime layer's members as they are, the kernel and its modules under
/// /boot/kernel, and the first process at /preflight/init.
pub fn image(io: Io, gpa: std.mem.Allocator, paths: ImagePaths) !void {
    const cwd = Io.Dir.cwd();
    var kernel_set = try cwd.openDir(io, paths.kernel_set, .{});
    defer kernel_set.close(io);
    const kernel = try aegis.own.readFile(io, kernel_set, "boot/kernel/kernel", gpa, .fromRaw(limit));
    try cwd.writeFile(io, .{ .sub_path = paths.kernel, .data = kernel });

    var root: iso9660.Writer = try .init(gpa);
    defer root.deinit();
    var runtime = try cwd.openDir(io, paths.runtime, .{});
    defer runtime.close(io);
    for (try layers(io, gpa, runtime)) |layer| try addLayer(&root, layer);

    var modules = try kernel_set.openDir(io, "boot/kernel", .{ .iterate = true });
    defer modules.close(io);
    var files = modules.iterate();
    while (try files.next(io)) |file| {
        if (file.kind != .file) continue;
        const data = try aegis.own.readFile(io, modules, file.name, gpa, .fromRaw(limit));
        try root.add(.{ .name = try gpa.print("boot/kernel/{s}", .{file.name}), .kind = .file, .mode = 0o555, .data = data });
    }
    try root.add(.{ .name = "preflight/init", .kind = .file, .mode = 0o555, .data = try aegis.own.readFile(io, cwd, paths.init, gpa, .fromRaw(limit)) });
    // Where the first process makes the program's root, in the machine's memory.
    try root.add(.{ .name = "preflight/root", .kind = .directory, .mode = 0o755 });

    const out = try cwd.createFile(io, paths.root, .{});
    defer out.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var file_writer = out.writer(io, &buffer);
    try root.finish(&file_writer.interface);
    try file_writer.interface.flush();
}

const Descriptor = struct { mediaType: []const u8 = "", digest: []const u8 };
const Index = struct { manifests: []const Descriptor };
const Manifest = struct { layers: []const Descriptor };

/// The image's layers, uncompressed, in order: the index's one manifest's.
fn layers(io: Io, gpa: std.mem.Allocator, image_dir: Io.Dir) ![]const []const u8 {
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const index = try std.json.parseFromSliceLeaky(Index, gpa, try aegis.own.readFile(io, image_dir, "index.json", gpa, .fromRaw(1024 * 1024)), options);
    if (index.manifests.len != 1) return error.OciManifests;
    const manifest = try std.json.parseFromSliceLeaky(Manifest, gpa, try blob(io, gpa, image_dir, index.manifests[0].digest), options);
    const out = try gpa.alloc([]const u8, manifest.layers.len);
    for (manifest.layers, out) |layer, *bytes| {
        const data = try blob(io, gpa, image_dir, layer.digest);
        bytes.* = if (std.mem.endsWith(u8, layer.mediaType, "+gzip")) try gunzip(gpa, data) else if (std.mem.endsWith(u8, layer.mediaType, ".tar")) data else return error.OciLayerType;
    }
    return out;
}

/// The blob a descriptor names, checked against its digest.
fn blob(io: Io, gpa: std.mem.Allocator, image_dir: Io.Dir, digest: []const u8) ![]const u8 {
    const prefix = "sha256:";
    if (!std.mem.startsWith(u8, digest, prefix)) return error.OciDigest;
    const hex = digest[prefix.len..];
    if (hex.len != 64) return error.OciDigest;
    for (hex) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.OciDigest;
    const data = try aegis.own.readFile(io, image_dir, try gpa.print("blobs/sha256/{s}", .{hex}), gpa, .fromRaw(limit));
    var sum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &sum, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(sum, .lower), hex)) return error.OciDigestMismatch;
    return data;
}

/// A layer's members into the root image; a whiteout (a later layer removing
/// what an earlier one holds) is refused, as the runtime image has one layer.
fn addLayer(root: *iso9660.Writer, layer: []const u8) !void {
    var r: ustar.Reader = .{ .bytes = layer };
    while (try r.next()) |e| {
        const base = std.Io.Dir.path.basename(e.name);
        if (std.mem.startsWith(u8, base, ".wh.")) return error.OciWhiteout;
        switch (e.kind) {
            .directory => try root.add(.{ .name = e.name, .kind = .directory, .mode = e.mode, .uid = e.uid, .gid = e.gid }),
            .file => try root.add(.{ .name = e.name, .kind = .file, .mode = e.mode, .uid = e.uid, .gid = e.gid, .data = e.data }),
            .symlink => try root.add(.{ .name = e.name, .kind = .symlink, .mode = e.mode, .uid = e.uid, .gid = e.gid, .data = e.link }),
            .hard_link => try root.link(e.name, e.link),
        }
    }
}

fn gunzip(gpa: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var input: Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&input, .gzip, &window);
    return decompress.reader.allocRemaining(gpa, .limited(limit));
}

/// Why the machine cannot run here, or null: it needs KVM, which only a Linux host gives.
pub fn hostRefusal(io: Io) ?[]const u8 {
    if (builtin.os.tag != .linux) return "the FreeBSD machine runs under KVM, which only a Linux host has; ci-vm=freebsd runs on the nightly's Linux runner";
    const kvm = Io.Dir.cwd().openFile(io, "/dev/kvm", .{ .mode = .read_write }) catch return "/dev/kvm cannot be opened read-write: KVM is missing or not open to this user (the runner's job sets its udev rule)";
    kvm.close(io);
    return null;
}

/// KVM's processor, with its TSC invariant. A PVH boot sets FreeBSD's early DELAY to
/// Xen's, which reads Xen's shared page and faults on any other hypervisor (15.1's
/// `xen_delay`); the console's first DELAY would fault, and its trap after it. DELAY
/// takes the TSC instead when it is invariant and its frequency is known, which QEMU
/// then reports under KVM at hypervisor leaf 0x40000010.
const kvm_cpu = "host,+invtsc";

pub const Ending = union(enum) { exited: u8, signal: u32 };

/// How the machine's run ended, each with its name.
pub const Outcome = union(enum) {
    /// The program's ending.
    ending: Ending,
    /// The first process failed before the program ended: its error.
    failed: []const u8,
    /// A kernel panic, its line from the console.
    panic: []const u8,
    /// The first process did not start the program by the deadline: the machine was stopped.
    deadline,
    /// QEMU ended with no ending and no panic printed.
    ended,
};

/// Runs the program described in `run_path` (host.zig's `describe`) on the machine
/// and returns its ending, or names why there is none, with the console's last
/// lines, and fails. `forward` carries the host's input to the `io` port; it starts
/// once the first process says its ports are open.
pub fn run(io: Io, gpa: std.mem.Allocator, kernel: []const u8, root: []const u8, run_path: []const u8, forward: *const fn (Io, Io.File) void) !Ending {
    const cwd = Io.Dir.cwd();
    const cpus = @min(std.Thread.getCpuCount() catch 1, max_cpus);
    const console_path = try gpa.print("{s}/console", .{run_path});
    const status_path = try gpa.print("{s}/status", .{run_path});
    const argv = [_][]const u8{
        qemu,                                     "-machine",                                  "pc,accel=kvm",                             "-cpu",                                                                    kvm_cpu,
        "-smp",                                   try gpa.print("{d}", .{cpus}),               "-m",                                       memory,                                                                    "-nodefaults",
        "-display",                               "none",                                      "-no-reboot",                               "-kernel",                                                                 kernel,
        "-append",                                kernel_environment,                          "-drive",                                   try gpa.print("file={s},format=raw,if=none,id=root,readonly=on", .{root}), "-device",
        "virtio-blk-pci,drive=root",              "-serial",                                   try gpa.print("file:{s}", .{console_path}), "-device",                                                                 "virtio-serial-pci",
        "-chardev",                               "stdio,id=io,signal=off",                    "-device",                                  "virtserialport,chardev=io,name=io",
        // Appended, so that a log the host's stderr is redirected to is not truncated.
                                              "-chardev",
        "file,id=err,path=/dev/stderr,append=on", "-device",                                   "virtserialport,chardev=err,name=err",      "-chardev",                                                                try gpa.print("file,id=status,path={s}", .{status_path}),
        "-device",                                "virtserialport,chardev=status,name=status", "-fsdev",                                   try gpa.print("local,id=run,path={s},security_model=none", .{run_path}),   "-device",
        "virtio-9p-pci,fsdev=run,mount_tag=run",  "-fsdev",                                    "local,id=host,path=/,security_model=none", "-device",                                                                 "virtio-9p-pci,fsdev=host,mount_tag=host",
    };
    var child = std.process.spawn(io, .{ .argv = &argv, .stdin = .pipe, .stdout = .inherit, .stderr = .inherit }) catch |err| {
        try Io.File.stderr().writeStreamingAll(io, try gpa.print("preflight-vm: starting {s}: {t}\n", .{ qemu, err }));
        return err;
    };
    var deadline: Deadline = .{ .pid = child.id.?, .status_path = status_path };
    const watch = try std.Thread.spawn(.{}, Deadline.watch, .{ &deadline, io });
    // The input waits for the first process's ports; the pipe stays open after it, as
    // a port whose host end closes stalls the machine's writes to it.
    const feed = try std.Thread.spawn(.{}, Deadline.feed, .{ &deadline, io, child.stdin.?, forward });
    feed.detach();
    const term = try child.wait(io);
    const fired = deadline.finish();
    watch.join();

    const status = aegis.own.readFile(io, cwd, status_path, gpa, .fromRaw(4096)) catch "";
    const console = aegis.own.readFile(io, cwd, console_path, gpa, .fromRaw(64 * 1024 * 1024)) catch "";
    const stderr = Io.File.stderr();
    switch (classify(status, console, fired)) {
        .ending => |ending| return ending,
        .failed => |err| try stderr.writeStreamingAll(io, try gpa.print("preflight-vm: the FreeBSD machine's first process failed: {s}\n", .{err})),
        .panic => |line| try stderr.writeStreamingAll(io, try gpa.print("preflight-vm: the FreeBSD kernel panicked: {s}\n", .{line})),
        .deadline => try stderr.writeStreamingAll(io, try gpa.print("preflight-vm: the FreeBSD machine did not start its program within {d} s and was stopped\n", .{boot_deadline_seconds})),
        .ended => try stderr.writeStreamingAll(io, try gpa.print("preflight-vm: the FreeBSD machine ended ({any}) without its program's ending or a panic\n", .{term})),
    }
    try stderr.writeStreamingAll(io, try gpa.print("preflight-vm: its console ({s}), last 16 KiB:\n", .{console_path}));
    try stderr.writeStreamingAll(io, console[console.len -| 16384..]);
    return error.MachineFailed;
}

/// The outcome the status port's lines (`started`, then the ending), the console
/// and the deadline say.
pub fn classify(status: []const u8, console: []const u8, deadline_fired: bool) Outcome {
    var lines = std.mem.tokenizeAny(u8, whole(status), "\r\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "exited ")) if (std.fmt.parseInt(u8, line["exited ".len..], 10)) |code| return .{ .ending = .{ .exited = code } } else |_| {};
        if (std.mem.startsWith(u8, line, "signal ")) if (std.fmt.parseInt(u32, line["signal ".len..], 10)) |sig| return .{ .ending = .{ .signal = sig } } else |_| {};
        if (std.mem.startsWith(u8, line, "failed ")) return .{ .failed = line["failed ".len..] };
    }
    if (std.mem.find(u8, console, "panic: ")) |at| {
        const end = std.mem.findScalarPos(u8, console, at, '\n') orelse console.len;
        return .{ .panic = std.mem.trimEnd(u8, console[at..end], "\r") };
    }
    if (deadline_fired) return .deadline;
    return .ended;
}

/// Whether the status port says the program has started: its ports are open.
pub fn started(status: []const u8) bool {
    var lines = std.mem.tokenizeAny(u8, whole(status), "\r\n");
    while (lines.next()) |line| if (std.mem.eql(u8, line, "started")) return true;
    return false;
}

/// The status port's whole lines: a line still being written says nothing yet.
fn whole(status: []const u8) []const u8 {
    const end = std.mem.findScalarLast(u8, status, '\n') orelse return "";
    return status[0 .. end + 1];
}

/// FreeBSD's number for a signal as Linux numbers it, for the host to end by, or
/// null for one Linux has not (SIGEMT, SIGINFO, SIGTHR, SIGLIBRT and the real-time
/// ones). sys/signal.h and Linux's asm-generic/signal.h.
pub fn linuxSignal(freebsd_signal: u32) ?u32 {
    const table = [_]u8{
        0, 1, 2, 3, 4, 5, 6, 0, // HUP INT QUIT ILL TRAP ABRT EMT
        8, 9, 7, 11, 31, 13, 14, 15, // FPE KILL BUS SEGV SYS PIPE ALRM TERM
        23, 19, 20, 18, 17, 21, 22, 29, // URG STOP TSTP CONT CHLD TTIN TTOU IO
        24, 25, 26, 27, 28, 0, 10, 12, // XCPU XFSZ VTALRM PROF WINCH INFO USR1 USR2
    };
    if (freebsd_signal >= table.len or table[freebsd_signal] == 0) return null;
    return table[freebsd_signal];
}

/// Stops QEMU, the one process this program started, when the first process has
/// not started the program by the deadline, and lets the host's input through once
/// it has. Once started, the program is the test runner's watchdog's to bound.
const Deadline = struct {
    pid: std.posix.pid_t,
    status_path: []const u8,
    state: aegis.Atomic(State) = .init(.booting),

    const State = enum(u8) { booting, started, done, fired };

    fn watch(d: *Deadline, io: Io) void {
        var tenths: u32 = 0;
        while (tenths < boot_deadline_seconds * 10) : (tenths += 1) {
            if (d.state.load(.acquire) == .done) return;
            var buffer: [256]u8 = undefined;
            // A status not yet written reads as none.
            const status = Io.Dir.cwd().readFile(io, d.status_path, &buffer) catch "";
            if (started(status)) {
                _ = d.state.cmpxchgStrong(.booting, .started, .acq_rel, .acquire); // safe: a run already done keeps its state
                return;
            }
            // A canceled wait counts as the boot over: it is being given up anyway.
            io.sleep(.fromMilliseconds(100), .awake) catch return;
        }
        if (d.state.cmpxchgStrong(.booting, .fired, .acq_rel, .acquire) != null) return;
        // glint-ignore: Z026 -- QEMU may have ended between the check and the signal; its wait reports either way
        std.posix.kill(d.pid, .KILL) catch {};
    }

    /// The host's input to the machine once its program has started; none to a
    /// machine that ends or is stopped first.
    fn feed(d: *Deadline, io: Io, to: Io.File, forward: *const fn (Io, Io.File) void) void {
        while (true) switch (d.state.load(.acquire)) {
            .booting => io.sleep(.fromMilliseconds(20), .awake) catch return,
            .started => return forward(io, to),
            .done, .fired => return,
        };
    }

    /// Marks the run over; whether the deadline had stopped it.
    fn finish(d: *Deadline) bool {
        return d.state.swap(.done, .acq_rel) == .fired;
    }
};

test "a run's ending is named from its status, a failure, a panic on the console, or the deadline" {
    try std.testing.expectEqual(Outcome{ .ending = .{ .exited = 0 } }, classify("started\nexited 0\n", "", false));
    try std.testing.expectEqual(Outcome{ .ending = .{ .exited = 3 } }, classify("started\r\nexited 3\r\n", "", false));
    try std.testing.expectEqual(Outcome{ .ending = .{ .signal = 11 } }, classify("started\nsignal 11\n", "", false));
    // An ending wins over what the console says, the deadline included.
    try std.testing.expectEqual(Outcome{ .ending = .{ .exited = 1 } }, classify("started\nexited 1\n", "panic: later\n", true));
    try std.testing.expectEqualStrings("Mount", classify("failed Mount\n", "", false).failed);
    const console = "Mounting from cd9660:/dev/vtbd0 failed with error 19.\r\npanic: mountroot: unable to mount root\r\ncpuid = 0\r\n";
    try std.testing.expectEqualStrings("panic: mountroot: unable to mount root", classify("", console, true).panic);
    // Started, then the kernel panicked under the program.
    try std.testing.expectEqualStrings("panic: page fault", classify("started\n", "panic: page fault\n", false).panic);
    try std.testing.expectEqual(Outcome.deadline, classify("", "mountroot> ", true));
    try std.testing.expectEqual(Outcome.ended, classify("started\n", "Copyright (c) 1992-2026 The FreeBSD Project.\n", false));
    // A status cut short names no ending.
    try std.testing.expectEqual(Outcome.ended, classify("started\nexited 30", "", false));
    try std.testing.expectEqual(Outcome.ended, classify("started\nexite", "", false));
}

test "input waits for the started line, which a partial write does not say" {
    try std.testing.expect(!started(""));
    try std.testing.expect(!started("star"));
    try std.testing.expect(started("started\n"));
    try std.testing.expect(started("started\nexited 0\n"));
    try std.testing.expect(!started("failed Mount\n"));
}

test "a FreeBSD signal ends the host by Linux's number for it, or by none" {
    try std.testing.expectEqual(@as(?u32, 11), linuxSignal(11)); // SEGV
    try std.testing.expectEqual(@as(?u32, 7), linuxSignal(10)); // BUS
    try std.testing.expectEqual(@as(?u32, 10), linuxSignal(30)); // USR1
    try std.testing.expectEqual(@as(?u32, 17), linuxSignal(20)); // CHLD
    try std.testing.expectEqual(@as(?u32, 31), linuxSignal(12)); // SYS
    try std.testing.expectEqual(@as(?u32, null), linuxSignal(7)); // EMT
    try std.testing.expectEqual(@as(?u32, null), linuxSignal(29)); // INFO
    try std.testing.expectEqual(@as(?u32, null), linuxSignal(32)); // THR
    try std.testing.expectEqual(@as(?u32, null), linuxSignal(0));
}

test "the machine is refused by name on a host without KVM" {
    if (builtin.os.tag == .linux) return;
    try std.testing.expect(std.mem.find(u8, hostRefusal(std.testing.io).?, "Linux host") != null);
}
