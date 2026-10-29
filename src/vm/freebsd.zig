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
/// How long a boot has to report its status before it is stopped and named a failure.
pub const boot_deadline_seconds = 180;

/// The kernel's environment: its root, the machine's first process, the serial
/// console, and a panic that ends the machine at once instead of waiting at the
/// debugger.
/// Without a loader there is no device.hints: the two serial ports are named here, the
/// first the console, as FreeBSD's FIRECRACKER kernel names them. The kernel splits
/// this at spaces and commas.
pub const kernel_environment = "-h vfs.root.mountfrom=cd9660:/dev/vtbd0 vfs.mountroot.timeout=30 init_path=/preflight/init hw.uart.console=io:0x3f8 " ++
    "hint.uart.0.at=isa hint.uart.0.port=0x3F8 hint.uart.0.flags=0x10 hint.uart.0.irq=4 hint.uart.1.at=isa hint.uart.1.port=0x2F8 hint.uart.1.irq=3 " ++
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

/// How a boot ended, each with its name.
pub const Outcome = union(enum) {
    /// The first process's status line.
    status: []const u8,
    /// A kernel panic, its line from the console.
    panic: []const u8,
    /// No status by the deadline: the machine was stopped.
    deadline,
    /// QEMU ended with no status and no panic printed.
    ended,
};

/// Why the machine cannot run here, or null: it needs KVM, which only a Linux host gives.
pub fn hostRefusal(io: Io) ?[]const u8 {
    if (builtin.os.tag != .linux) return "the FreeBSD machine runs under KVM, which only a Linux host has; ci-vm=freebsd runs on the nightly's Linux runner";
    const kvm = Io.Dir.cwd().openFile(io, "/dev/kvm", .{ .mode = .read_write }) catch return "/dev/kvm cannot be opened read-write: KVM is missing or not open to this user (the runner's job sets its udev rule)";
    kvm.close(io);
    return null;
}

/// Boots the machine on `root` and returns how it ended. `console_out` receives its
/// whole console and `qemu_out` QEMU's side (its log of resets and guest errors, and
/// what its monitor says of the processor when the deadline stops it), whatever the
/// outcome, for the job's artifact.
pub fn boot(io: Io, gpa: std.mem.Allocator, kernel: []const u8, root: []const u8, run_path: []const u8, console_out: []const u8, qemu_out: []const u8) !Outcome {
    const cwd = Io.Dir.cwd();
    const cpus = @min(std.Thread.getCpuCount() catch 1, max_cpus);
    const console_path = try gpa.print("{s}/console", .{run_path});
    const status_path = try gpa.print("{s}/status", .{run_path});
    const log_path = try gpa.print("{s}/qemu.log", .{run_path});
    const argv = [_][]const u8{
        qemu,                        "-machine",                    "pc,accel=kvm",                             "-cpu",                                                                    "host",
        "-smp",                      try gpa.print("{d}", .{cpus}), "-m",                                       memory,                                                                    "-nodefaults",
        "-display",                  "none",                        "-no-reboot",                               "-kernel",                                                                 kernel,
        "-append",                   kernel_environment,            "-drive",                                   try gpa.print("file={s},format=raw,if=none,id=root,readonly=on", .{root}), "-device",
        "virtio-blk-pci,drive=root", "-serial",                     try gpa.print("file:{s}", .{console_path}), "-serial",                                                                 try gpa.print("file:{s}", .{status_path}),
        // The monitor on QEMU's own standard streams, for the deadline's questions.
        "-monitor",                  "stdio",                       "-d",                                       "cpu_reset,guest_errors,unimp",                                            "-D",
        log_path,
    };
    var child = std.process.spawn(io, .{ .argv = &argv, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit }) catch |err| {
        try Io.File.stderr().writeStreamingAll(io, try gpa.print("preflight-vm: starting {s}: {t}\n", .{ qemu, err }));
        return err;
    };
    var deadline: Deadline = .{ .pid = child.id.?, .monitor = child.stdin.? };
    const watch = try std.Thread.spawn(.{}, Deadline.watch, .{ &deadline, io });
    _ = try child.wait(io);
    const fired = deadline.finish();
    watch.join();

    var monitor_buffer: [4096]u8 = undefined;
    var monitor = child.stdout.?.readerStreaming(io, &monitor_buffer);
    const answers = monitor.interface.allocRemaining(gpa, .limited(1024 * 1024)) catch "";
    const log = aegis.own.readFile(io, cwd, log_path, gpa, .fromRaw(16 * 1024 * 1024)) catch "";
    const console = aegis.own.readFile(io, cwd, console_path, gpa, .fromRaw(64 * 1024 * 1024)) catch "";
    for ([_][]const u8{ console_out, qemu_out }) |out| if (std.Io.Dir.path.dirname(out)) |dir| try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{ .sub_path = console_out, .data = console });
    try cwd.writeFile(io, .{ .sub_path = qemu_out, .data = try std.mem.concat(gpa, u8, &.{ "QEMU's log (-d cpu_reset,guest_errors,unimp):\n", log, "\nQEMU's monitor:\n", answers }) });
    const status = std.mem.trim(u8, aegis.own.readFile(io, cwd, status_path, gpa, .fromRaw(4096)) catch "", "\r\n ");
    return classify(status, console, fired);
}

/// The outcome a status port's text, a console and the deadline say.
pub fn classify(status: []const u8, console: []const u8, deadline_fired: bool) Outcome {
    if (status.len > 0) return .{ .status = status };
    if (std.mem.find(u8, console, "panic: ")) |at| {
        const end = std.mem.findScalarPos(u8, console, at, '\n') orelse console.len;
        return .{ .panic = std.mem.trimEnd(u8, console[at..end], "\r") };
    }
    if (deadline_fired) return .deadline;
    return .ended;
}

/// Stops QEMU, the one process this program started, when the boot outlives its
/// deadline: first asks its monitor where the processor is and to quit, then, if it
/// has not, ends it.
const Deadline = struct {
    pid: std.posix.pid_t,
    monitor: Io.File,
    state: aegis.Atomic(State) = .init(.running),

    const State = enum(u8) { running, done, fired };
    const questions = "info status\ninfo registers\nx/8i $pc\nquit\n";

    fn watch(d: *Deadline, io: Io) void {
        if (d.waitDone(io, boot_deadline_seconds * 10)) return;
        if (d.state.cmpxchgStrong(.running, .fired, .acq_rel, .acquire) != null) return;
        // glint-ignore: Z026 -- a monitor that cannot be written to leaves the signal below to end QEMU
        d.monitor.writeStreamingAll(io, questions) catch {};
        if (d.waitDone(io, 100)) return;
        // glint-ignore: Z026 -- QEMU may have ended between the check and the signal; its wait reports either way
        std.posix.kill(d.pid, .KILL) catch {};
    }

    /// Whether the boot ended within `tenths` of a second.
    fn waitDone(d: *Deadline, io: Io, tenths: u32) bool {
        var waited: u32 = 0;
        while (waited < tenths) : (waited += 1) {
            if (d.state.load(.acquire) == .done) return true;
            // A canceled wait counts as the boot over: it is being given up anyway.
            io.sleep(.fromMilliseconds(100), .awake) catch return true;
        }
        return d.state.load(.acquire) == .done;
    }

    /// Marks the boot over; whether the deadline had stopped it.
    fn finish(d: *Deadline) bool {
        return d.state.swap(.done, .acq_rel) == .fired;
    }
};

test "a boot's ending is named from its status, a panic on the console, or the deadline" {
    try std.testing.expectEqualStrings("booted 15.1-RELEASE", classify("booted 15.1-RELEASE", "", false).status);
    // A status wins over what the console says, the deadline included.
    try std.testing.expectEqualStrings("booted", classify("booted", "panic: later\n", true).status);
    const console = "Mounting from cd9660:/dev/vtbd0 failed with error 19.\r\npanic: mountroot: unable to mount root\r\ncpuid = 0\r\n";
    try std.testing.expectEqualStrings("panic: mountroot: unable to mount root", classify("", console, true).panic);
    try std.testing.expectEqual(Outcome.deadline, classify("", "mountroot> ", true));
    try std.testing.expectEqual(Outcome.ended, classify("", "Copyright (c) 1992-2026 The FreeBSD Project.\n", false));
}

test "the machine is refused by name on a host without KVM" {
    if (builtin.os.tag == .linux) return;
    try std.testing.expect(std.mem.find(u8, hostRefusal(std.testing.io).?, "Linux host") != null);
}
