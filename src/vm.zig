//! `-Dci-vm`: the tests and programs a build runs for a target no hosted runner
//! is run on that target's own kernel. riscv64 Linux's is booted under QEMU's
//! system emulation, not under its user mode, which emulates one process and
//! leaves out what a kernel does (process reaping, pidfds, io_uring, file maps):
//! Alpine Linux's kernel and root file system, with preflight's own first process
//! (vm/guest.zig) and host side (vm/host.zig). x86_64 FreeBSD's is FreeBSD's
//! kernel and runtime image under KVM, with vm/freebsd/guest.zig and
//! vm/freebsd.zig (`ci-vm=freebsd`, an x86_64 Linux host's only). Each machine is pinned
//! by hash in preflight's manifest and fetched only by a build that runs on it.
const std = @import("std");
const held = @import("held.zig");
const Tool = @import("tool.zig").Tool;

/// How many times slower a test runs on the machine than on the host, at most:
/// QEMU translates every instruction of a whole system, on one host thread per
/// processor it emulates, where a riscv64 board runs it natively. The watchdog's
/// bound scales by it.
pub const slowdown = 10;

/// Puts a machine in front of each run under `tests` of an artifact built for a
/// target no runner is: riscv64 Linux's (vm/host.zig), or x86_64 FreeBSD's
/// (vm/freebsd.zig), which runs under KVM and so is refused by name on a host
/// other than x86_64 Linux. `pkg` is the preflight whose sources and pins the machines
/// come from, each fetched only when a run needs it; `packages` are the Alpine
/// packages installed on the riscv64 machine beside its minimal system; the package's held
/// git (`git` in its ci/workflow.json), built for the machine, joins them. Called after every
/// other part of the gate has added its runs.
pub fn add(b: *std.Build, tests: *std.Build.Step, package: *std.Build, pkg: *std.Build, tool: Tool, host: std.Build.ResolvedTarget, packages: []const []const u8) void {
    const holds_git = held.named(package);
    for (packages) |entry| if (refusal(entry, holds_git)) |reason| {
        tests.dependOn(&b.addFail(b.fmt("vm_packages: {s}: {s}", .{ entry, reason })).step);
        return;
    };
    var runs: Runs = .initFill(.empty);
    var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    visit(b, tests, &runs, &seen);
    if (runs.get(.riscv64_linux).items.len > 0) {
        const machine = riscv64Machine(b, package, pkg, tool, host, packages, holds_git) orelse return;
        for (runs.get(.riscv64_linux).items) |run| machine.wrap(b, run);
    }
    if (runs.get(.x86_64_freebsd).items.len > 0) {
        if (host.result.os.tag != .linux or host.result.cpu.arch != .x86_64) {
            tests.dependOn(&b.addFail("ci-vm=freebsd: the FreeBSD machine is x86_64 under KVM, which only an x86_64 Linux host runs; it runs on the release tier's x86_64 Linux runner").step);
            return;
        }
        const machine = freebsdMachine(b, pkg, host) orelse return;
        for (runs.get(.x86_64_freebsd).items) |run| machine.wrap(b, run);
    }
}

/// The machine a run's target needs.
pub const Kind = enum { riscv64_linux, x86_64_freebsd };

/// A machine's first process, preflight's own (vm/guest.zig, vm/freebsd/guest.zig), for that
/// machine's target. It needs no image to compile: preflight's `check` compiles both, so the
/// code a machine boots is built, and linted, on every host, not only under `-Dci-vm`.
pub fn guestModule(b: *std.Build, pkg: *std.Build, kind: Kind) *std.Build.Module {
    const target = switch (kind) {
        .riscv64_linux => b.resolveTargetQuery(.{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .none }),
        .x86_64_freebsd => b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .freebsd }),
    };
    return b.createModule(.{
        .root_source_file = pkg.path(switch (kind) {
            .riscv64_linux => "src/vm/guest.zig",
            .x86_64_freebsd => "src/vm/freebsd/guest.zig",
        }),
        .target = target,
        .optimize = .safe,
        .link_libc = kind == .x86_64_freebsd,
        .imports = &.{.{ .name = "aegis", .module = pkg.dependency("aegis", .{ .target = target, .optimize = .safe }).module("aegis") }},
    });
}

/// The runs each machine takes.
const Runs = std.EnumArray(Kind, std.ArrayList(*std.Build.Step.Run));

fn runner(b: *std.Build, pkg: *std.Build, host: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    return b.addExecutable(.{ .name = "preflight-vm", .root_module = b.createModule(.{
        .root_source_file = pkg.path("src/vm/host.zig"),
        .target = host,
        .optimize = .safe,
        .imports = &.{.{ .name = "aegis", .module = pkg.dependency("aegis", .{ .target = host, .optimize = .safe }).module("aegis") }},
    }) });
}

/// The riscv64 Linux machine: Alpine's kernel and root file system with preflight's
/// first process, the packages installed on it and the package's held git; null until its
/// pins are fetched.
fn riscv64Machine(b: *std.Build, package: *std.Build, pkg: *std.Build, tool: Tool, host: std.Build.ResolvedTarget, packages: []const []const u8, holds_git: bool) ?Machine {
    // Fetched on first use: a build that asks for the machine configures again once they land.
    const alpine = pkg.dependencyLazy("alpine_riscv64", .{}) catch return null;
    const rootfs = pkg.dependencyLazy("alpine_riscv64_rootfs", .{}) catch return null;
    const guest = b.addExecutable(.{ .name = "preflight-vm-init", .root_module = guestModule(b, pkg, .riscv64_linux) });
    const vm = runner(b, pkg, host);
    const boot = b.addRunArtifact(vm);
    boot.addArg("image");
    boot.addDirectoryArg2(alpine.path("."), .{});
    boot.addDirectoryArg2(rootfs.path("."), .{});
    boot.addArtifactArg2(guest, .{});
    const kernel = boot.addOutputFileArg2("Image", .{});
    const base = boot.addOutputFileArg2("initrd.cpio", .{});
    const initrd = if (packages.len == 0) base else installed: {
        const install = b.addRunArtifact(vm);
        install.addArg("install");
        install.addFileArg(kernel);
        install.addFileArg(base);
        install.addDirectoryArg2(rootfs.path("."), .{});
        const out = install.addOutputFileArg2("initrd-packages.cpio", .{});
        install.addArgs(packages);
        break :installed out;
    };
    const image = if (!holds_git) initrd else with_git: {
        // Built on the host with zig cc for the machine, as every held git is, and kept in the store.
        const build = held.run(b, package, pkg, tool, "riscv64-linux-musl") orelse return null;
        build.addArg("--copy-to");
        const tree = build.addOutputDirectoryArg("held-git");
        const add_git = b.addRunArtifact(vm);
        add_git.addArg("overlay");
        add_git.addFileArg(initrd);
        add_git.addDirectoryArg2(tree, .{});
        break :with_git add_git.addOutputFileArg2("initrd-git.cpio", .{});
    };
    return .{ .runner = vm, .command = "run", .kernel = kernel, .image = image };
}

/// The x86_64 FreeBSD machine: FreeBSD's kernel set and runtime image with
/// preflight's first process (vm/freebsd/guest.zig); null until its pins are fetched.
fn freebsdMachine(b: *std.Build, pkg: *std.Build, host: std.Build.ResolvedTarget) ?Machine {
    const kernel_set = pkg.dependencyLazy("freebsd_amd64_kernel", .{}) catch return null;
    const runtime = pkg.dependencyLazy("freebsd_amd64_runtime", .{}) catch return null;
    const guest = b.addExecutable(.{ .name = "preflight-vm-init", .root_module = guestModule(b, pkg, .x86_64_freebsd) });
    const vm = runner(b, pkg, host);
    const make = b.addRunArtifact(vm);
    make.addArg("freebsd-image");
    make.addDirectoryArg2(kernel_set.path("."), .{});
    make.addDirectoryArg2(runtime.path("."), .{});
    make.addArtifactArg2(guest, .{});
    const kernel = make.addOutputFileArg2("kernel", .{});
    const root = make.addOutputFileArg2("root.iso", .{});
    return .{ .runner = vm, .command = "freebsd-run", .kernel = kernel, .image = root };
}

const Machine = struct {
    runner: *std.Build.Step.Compile,
    /// preflight-vm's command for one run on it.
    command: []const u8,
    kernel: std.Build.LazyPath,
    /// The riscv64 machine's initrd, the FreeBSD one's root image.
    image: std.Build.LazyPath,

    /// `preflight-vm <command> <kernel> <image>` in front of the run's own command
    /// line, whose program and arguments the machine receives as they are.
    fn wrap(machine: Machine, b: *std.Build, run: *std.Build.Step.Run) void {
        const own = b.allocator.dupe(std.Build.Step.Run.Arg, run.argv.items) catch @panic("OOM");
        run.argv.clearRetainingCapacity();
        run.addArtifactArg2(machine.runner, .{});
        run.addArg(machine.command);
        run.addFileArg(machine.kernel);
        run.addFileArg(machine.image);
        run.argv.appendSlice(b.graph.arena, own) catch @panic("OOM");
    }
};

fn visit(b: *std.Build, step: *std.Build.Step, runs: *Runs, seen: *std.AutoHashMapUnmanaged(*std.Build.Step, void)) void {
    if ((seen.getOrPut(b.allocator, step) catch @panic("OOM")).found_existing) return;
    for (step.dependencies.items) |child| visit(b, child, runs, seen);
    const run = step.cast(std.Build.Step.Run) orelse return;
    if (run.argv.items.len == 0 or run.argv.items[0] != .artifact) return;
    const target = run.argv.items[0].artifact.artifact.root_module.resolved_target.?.result;
    const kind = machineFor(target, b.graph.host.result) orelse return;
    runs.getPtr(kind).append(b.allocator, run) catch @panic("OOM");
}

/// Why a `vm_packages` entry is refused, or null. An entry is a package of the release's
/// repositories, as apk names it (`openssl`, `bash=5.3.3-r1`). A tagged repository is
/// refused: edge keeps no build a pin names once it has the next (relic's
/// `git@edge=2.56.0-r0` stopped the machine being made when edge moved to 2.56.1), so a
/// pin from it always rots. git is refused beside the package's held git, which the
/// machine has already, built from git's own release.
pub fn refusal(entry: []const u8, holds_git: bool) ?[]const u8 {
    if (std.mem.findScalar(u8, entry, '@') != null) return "a package comes from the release's repositories: edge drops the build a pin names; for git, name the held git (`preflight held-git-pin <version>`), built from git's own release";
    const name = entry[0 .. std.mem.findAny(u8, entry, "<>=~") orelse entry.len];
    if (holds_git and std.mem.eql(u8, name, "git")) return "the machine has the package's held git (ci/workflow.json's git); a second git would shadow it";
    return null;
}

test "a package comes from the release, never edge, and git is the held one where the package holds one" {
    try std.testing.expectEqual(null, refusal("git", false));
    try std.testing.expectEqual(null, refusal("bash=5.3.3-r1", true));
    try std.testing.expect(refusal("git", true) != null);
    try std.testing.expect(refusal("git=2.54.0-r0", true) != null);
    try std.testing.expect(refusal("git@edge=2.56.0-r0", false) != null);
    try std.testing.expect(refusal("openssl@testing", false) != null);
}

/// The machine a run for `target` needs on `host`, or null for one the host runs itself.
pub fn machineFor(target: std.Target, host: std.Target) ?Kind {
    if (target.os.tag == .linux and target.cpu.arch == .riscv64 and !(host.os.tag == .linux and host.cpu.arch == .riscv64)) return .riscv64_linux;
    if (target.os.tag == .freebsd and target.cpu.arch == .x86_64 and !(host.os.tag == .freebsd and host.cpu.arch == .x86_64)) return .x86_64_freebsd;
    return null;
}

test "a riscv64 Linux or x86_64 FreeBSD run on another host needs its machine" {
    const riscv = try std.zig.system.resolveTargetQuery(std.testing.io, .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .musl });
    const arm = try std.zig.system.resolveTargetQuery(std.testing.io, .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu });
    const x86 = try std.zig.system.resolveTargetQuery(std.testing.io, .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu });
    const mac = try std.zig.system.resolveTargetQuery(std.testing.io, .{ .cpu_arch = .aarch64, .os_tag = .macos });
    const freebsd = try std.zig.system.resolveTargetQuery(std.testing.io, .{ .cpu_arch = .x86_64, .os_tag = .freebsd });
    const arm_freebsd = try std.zig.system.resolveTargetQuery(std.testing.io, .{ .cpu_arch = .aarch64, .os_tag = .freebsd });
    try std.testing.expectEqual(Kind.riscv64_linux, machineFor(riscv, arm).?);
    try std.testing.expectEqual(Kind.riscv64_linux, machineFor(riscv, mac).?);
    try std.testing.expectEqual(null, machineFor(riscv, riscv));
    try std.testing.expectEqual(null, machineFor(arm, mac));
    try std.testing.expectEqual(Kind.x86_64_freebsd, machineFor(freebsd, x86).?);
    try std.testing.expectEqual(Kind.x86_64_freebsd, machineFor(freebsd, mac).?);
    try std.testing.expectEqual(null, machineFor(freebsd, freebsd));
    // No machine runs aarch64 FreeBSD: its build compiles it and runs nothing.
    try std.testing.expectEqual(null, machineFor(arm_freebsd, x86));
}
