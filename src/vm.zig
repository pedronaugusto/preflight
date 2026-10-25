//! `-Dci-vm`: the tests and programs a build runs for riscv64 Linux, which no
//! hosted runner is, run on a riscv64 Linux kernel booted under QEMU's system
//! emulation, not under its user mode, which emulates one process and leaves out
//! what a kernel does (process reaping, pidfds, io_uring, file maps). The
//! machine is Alpine Linux's kernel and root file system, pinned by hash in
//! preflight's manifest and fetched only by a build that asks for the machine,
//! with preflight's own first process (vm/guest.zig) and host side (vm/host.zig).
const std = @import("std");

/// How many times slower a test runs on the machine than on the host, at most:
/// QEMU translates every instruction of a whole system, on one host thread per
/// processor it emulates, where a riscv64 board runs it natively. The watchdog's
/// bound scales by it.
pub const slowdown = 10;

/// Puts the machine in front of each run under `tests` of an artifact built for
/// riscv64 Linux. `pkg` is the preflight whose sources and pins the machine
/// comes from; `packages` are the Alpine packages installed on it beside its
/// minimal system. Called after every other part of the gate has added its runs.
pub fn add(b: *std.Build, tests: *std.Build.Step, pkg: *std.Build, host: std.Build.ResolvedTarget, packages: []const []const u8) void {
    for (packages) |package| if (refusal(package)) |reason| {
        tests.dependOn(&b.addFail(b.fmt("vm_packages: {s}: {s}", .{ package, reason })).step);
        return;
    };
    // Fetched on first use: a build that asks for the machine configures again once they land.
    const alpine = pkg.dependencyLazy("alpine_riscv64", .{}) catch return;
    const rootfs = pkg.dependencyLazy("alpine_riscv64_rootfs", .{}) catch return;
    const riscv64 = b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .none });
    const guest = b.addExecutable(.{ .name = "preflight-vm-init", .root_module = b.createModule(.{
        .root_source_file = pkg.path("src/vm/guest.zig"),
        .target = riscv64,
        .optimize = .safe,
        .imports = &.{.{ .name = "aegis", .module = pkg.dependency("aegis", .{ .target = riscv64, .optimize = .safe }).module("aegis") }},
    }) });
    const runner = b.addExecutable(.{ .name = "preflight-vm", .root_module = b.createModule(.{
        .root_source_file = pkg.path("src/vm/host.zig"),
        .target = host,
        .optimize = .safe,
        .imports = &.{.{ .name = "aegis", .module = pkg.dependency("aegis", .{ .target = host, .optimize = .safe }).module("aegis") }},
    }) });
    const boot = b.addRunArtifact(runner);
    boot.addArg("image");
    boot.addDirectoryArg2(alpine.path("."), .{});
    boot.addDirectoryArg2(rootfs.path("."), .{});
    boot.addArtifactArg2(guest, .{});
    const kernel = boot.addOutputFileArg2("Image", .{});
    const base = boot.addOutputFileArg2("initrd.cpio", .{});
    const initrd = if (packages.len == 0) base else installed: {
        const install = b.addRunArtifact(runner);
        install.addArg("install");
        install.addFileArg(kernel);
        install.addFileArg(base);
        install.addDirectoryArg2(rootfs.path("."), .{});
        const out = install.addOutputFileArg2("initrd-packages.cpio", .{});
        install.addArgs(packages);
        break :installed out;
    };
    const machine: Machine = .{ .runner = runner, .kernel = kernel, .initrd = initrd };
    var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    visit(b, tests, machine, &seen);
}

const Machine = struct {
    runner: *std.Build.Step.Compile,
    kernel: std.Build.LazyPath,
    initrd: std.Build.LazyPath,
};

fn visit(b: *std.Build, step: *std.Build.Step, machine: Machine, seen: *std.AutoHashMapUnmanaged(*std.Build.Step, void)) void {
    if ((seen.getOrPut(b.allocator, step) catch @panic("OOM")).found_existing) return;
    for (step.dependencies.items) |child| visit(b, child, machine, seen);
    const run = step.cast(std.Build.Step.Run) orelse return;
    if (run.argv.items.len == 0 or run.argv.items[0] != .artifact) return;
    const target = run.argv.items[0].artifact.artifact.root_module.resolved_target.?.result;
    if (!needsMachine(target, b.graph.host.result)) return;
    // `preflight-vm run <kernel> <initrd>` in front of the run's own command line,
    // whose program and arguments the machine receives as they are.
    const own = b.allocator.dupe(std.Build.Step.Run.Arg, run.argv.items) catch @panic("OOM");
    run.argv.clearRetainingCapacity();
    run.addArtifactArg2(machine.runner, .{});
    run.addArg("run");
    run.addFileArg(machine.kernel);
    run.addFileArg(machine.initrd);
    run.argv.appendSlice(b.graph.arena, own) catch @panic("OOM");
}

/// Why a `vm_packages` entry is refused, or null. An entry is apk's own: a package
/// from the release (`git`), or one from Alpine's edge (`git@edge=2.56.0-r0`), which
/// moves on where a release keeps its packages' lines, so it states the build it is:
/// when edge has another, apk fails making the machine, naming the package, where an
/// unstated one would drift with edge.
pub fn refusal(entry: []const u8) ?[]const u8 {
    const at = std.mem.findScalar(u8, entry, '@') orelse return null;
    const compare = std.mem.findAny(u8, entry, "<>=~") orelse return "a package from edge states its version, name@edge=version";
    if (compare < at or !std.mem.eql(u8, entry[at + 1 .. compare], "edge")) return "the one repository beside the release is edge, name@edge=version";
    if (entry[compare] != '=' or compare + 1 == entry.len or std.mem.findAny(u8, entry[compare + 1 ..], "<>=~") != null) return "a package from edge states its version exactly, name@edge=version";
    return null;
}

test "a package from edge states its version exactly, and edge is the one other repository" {
    try std.testing.expectEqual(null, refusal("git"));
    try std.testing.expectEqual(null, refusal("git=2.54.0-r0"));
    try std.testing.expectEqual(null, refusal("git@edge=2.56.0-r0"));
    try std.testing.expect(refusal("git@edge") != null);
    try std.testing.expect(refusal("git@edge>=2.56.0-r0") != null);
    try std.testing.expect(refusal("git@edge~2.56") != null);
    try std.testing.expect(refusal("git@edge=") != null);
    try std.testing.expect(refusal("git@testing=2.56.0-r0") != null);
}

/// A run for riscv64 Linux on a host that is not one.
pub fn needsMachine(target: std.Target, host: std.Target) bool {
    return target.os.tag == .linux and target.cpu.arch == .riscv64 and !(host.os.tag == .linux and host.cpu.arch == .riscv64);
}

test "only a riscv64 Linux run on another host needs the machine" {
    const riscv = try std.zig.system.resolveTargetQuery(std.testing.io, .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .musl });
    const arm = try std.zig.system.resolveTargetQuery(std.testing.io, .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu });
    const mac = try std.zig.system.resolveTargetQuery(std.testing.io, .{ .cpu_arch = .aarch64, .os_tag = .macos });
    try std.testing.expect(needsMachine(riscv, arm));
    try std.testing.expect(needsMachine(riscv, mac));
    try std.testing.expect(!needsMachine(riscv, riscv));
    try std.testing.expect(!needsMachine(arm, mac));
}
