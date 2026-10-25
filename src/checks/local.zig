//! `gate`: the release tier's jobs a machine at hand runs, for a landing gated on the machines
//! the person has rather than by a hosted run. A job runs here when its runner's system is this
//! one's, so that a Linux machine of either architecture runs the Linux suites, a Mac the macOS
//! suites; the hardened runs, which each system decides for itself, run on each machine. The
//! jobs that say the same on any machine (the source checks, every compile of named targets),
//! which the hosted gate runs on Linux, run here too, unless the gate's caller runs them on
//! another of its machines (`PREFLIGHT_PORTABLE=elsewhere`): a gate on one Mac would
//! otherwise release a package whose source checks no machine ran. What this machine cannot
//! run is said, never skipped quietly: another system's suite, ThreadSanitizer off x86_64 and
//! aarch64 Linux, riscv64 with no QEMU here.
const std = @import("std");
const matrix = @import("matrix.zig");

/// The machine the gate runs on.
pub const Host = struct {
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
    /// QEMU's riscv64 system emulation is on the PATH.
    qemu: bool,
};

/// Where the jobs that say the same on any machine run: here, or on another machine of the
/// gate, whose caller sets `PREFLIGHT_PORTABLE=elsewhere` for every machine but the one that
/// runs them. The environment carries it, as it carries a job's shard and targets, so a caller
/// gating packages that pin an older preflight, which reads no such setting, can set it for all.
pub const Portable = enum {
    here,
    elsewhere,

    /// `PREFLIGHT_PORTABLE`, `here` when unset; null for a value that is neither.
    pub fn from(environ: *const std.process.Environ.Map) ?Portable {
        const value = environ.get("PREFLIGHT_PORTABLE") orelse return .here;
        return std.meta.stringToEnum(Portable, value);
    }
};

/// A job of the plan, and whether it runs here or why not.
pub const Decision = union(enum) {
    run,
    elsewhere: []const u8,
    /// What another job this machine runs builds already: the same build, or the hosted
    /// gate's compile-once link of a suite that runs here.
    covered,
};

/// What `host` does with each of `jobs`, in their order, the portable ones where `portable` says.
pub fn decide(a: std.mem.Allocator, jobs: []const matrix.Job, host: Host, portable: Portable) ![]Decision {
    const decisions = try a.alloc(Decision, jobs.len);
    for (jobs, decisions, 0..) |job, *decision, index| {
        decision.* = one(job, host, portable);
        if (decision.* != .run) continue;
        for (jobs[0..index], decisions[0..index]) |earlier, earlier_decision| {
            if (earlier_decision == .run and same(earlier, job)) decision.* = .covered;
        }
    }
    return decisions;
}

fn one(job: matrix.Job, host: Host, portable: Portable) Decision {
    // ThreadSanitizer runs on Linux and macOS, x86_64 and aarch64.
    if (std.mem.eql(u8, job.step, "hardened-tsan")) {
        return if ((host.os == .linux or host.os == .macos) and (host.arch == .x86_64 or host.arch == .aarch64)) .run else .{ .elsewhere = "ThreadSanitizer runs on x86_64 or aarch64 Linux or macOS" };
    }
    // Zig's native fuzzer runs on 64-bit hosts other than Windows (hardened.zig fails the
    // step anywhere else), so the campaign is another machine's there.
    if (std.mem.eql(u8, job.step, "hardened-fuzz") and (host.os == .windows or std.Target.ptrBitWidth_arch_abi(host.arch, .none) != 64)) {
        return .{ .elsewhere = "Zig's fuzzer runs on a 64-bit host that is not Windows" };
    }
    if (job.qemu) return if (host.os != .linux) .{ .elsewhere = "riscv64 runs under QEMU on Linux" } else if (!host.qemu) .{ .elsewhere = "no qemu-system-riscv64 on the PATH" } else .run;
    if (anywhere(job)) return .run;
    if (sameAnywhere(job)) return switch (portable) {
        .here => .run,
        .elsewhere => .{ .elsewhere = "another machine of this gate" },
    };
    const system = systemOf(job.os) orelse return .{ .elsewhere = "a runner no machine here is" };
    if (system != host.os) return .{ .elsewhere = switch (system) {
        .windows => "a Windows runner",
        .macos => "a Mac",
        else => "a Linux machine",
    } };
    return switch (job.operation) {
        // The compile-once split is the hosted gate's: here the suite runs where it builds.
        .link => .covered,
        .execute, .replay, .objects => .run,
    };
}

/// A job whose outcome depends on the system it runs on although the hosted gate runs it on
/// one: the hardened runs, whose faults and allocator are each system's own; each machine
/// runs them.
fn anywhere(job: matrix.Job) bool {
    if (job.declared) return false;
    for ([_][]const u8{ "hardened", "hardened-fuzz" }) |step| if (std.mem.eql(u8, job.step, step)) return true;
    return false;
}

/// A job that says the same on any machine, which the hosted gate runs on one: the source
/// checks, and the compiles of named targets (a compile for its runner's own system, as
/// ReleaseSmall's, and a link against a system's SDK are that system's). A declared job runs
/// as declared.
fn sameAnywhere(job: matrix.Job) bool {
    if (job.declared) return false;
    return std.mem.eql(u8, job.step, "lint") or job.operation == .objects;
}

/// The system a hosted runner label is.
pub fn systemOf(os: []const u8) ?std.Target.Os.Tag {
    for (matrix.hosts ++ matrix.arm_hosts) |label| if (std.mem.eql(u8, os, label)) {
        if (std.mem.startsWith(u8, label, "ubuntu")) return .linux;
        if (std.mem.startsWith(u8, label, "macos")) return .macos;
        return .windows;
    };
    return null;
}

/// The step, its arguments as they run here, and where: what the gate builds.
fn same(x: matrix.Job, y: matrix.Job) bool {
    return std.mem.eql(u8, stepOf(x), stepOf(y)) and std.mem.eql(u8, x.args, y.args) and std.mem.eql(u8, x.directory, y.directory) and std.mem.eql(u8, x.targets, y.targets) and std.mem.eql(u8, x.shard, y.shard);
}

/// The step a job runs here: a replay's run is the suite's own step.
pub fn stepOf(job: matrix.Job) []const u8 {
    return if (job.operation == .replay) "ci" else job.step;
}

test "a Mac runs its own suites, the hardened runs and the jobs that say the same anywhere, and names the rest" {
    const a = std.testing.allocator;
    const jobs = [_]matrix.Job{
        .{ .os = "ubuntu-latest", .name = "test (ubuntu-latest, Debug)", .args = "-Doptimize=debug" },
        .{ .os = "macos-latest", .name = "test (macos-latest, Debug)", .args = "-Doptimize=debug" },
        .{ .os = "windows-latest", .name = "test (windows-latest, Debug)", .args = "-Doptimize=debug" },
        .{ .os = "ubuntu-latest", .name = "source checks", .step = "lint" },
        .{ .os = "ubuntu-latest", .name = "Cross compile 1/2", .step = "preflight-cross-bench", .operation = .objects, .targets = "x86_64-linux-gnu" },
        .{ .os = "ubuntu-latest", .name = "compile (ReleaseSmall)", .step = "check", .args = "-Doptimize=small" },
        .{ .os = "windows-latest", .name = "SDK link (x86_64-windows-gnu)", .step = "ci-link", .operation = .link },
        .{ .os = "ubuntu-latest", .name = "hardened", .step = "hardened" },
        .{ .os = "ubuntu-latest", .name = "hardened-tsan", .step = "hardened-tsan" },
        .{ .os = "ubuntu-latest", .name = "test (riscv64-linux on its kernel under QEMU, Debug)", .qemu = true },
        .{ .os = "ubuntu-latest", .name = "conformance", .step = "conformance", .declared = true },
    };
    const host: Host = .{ .os = .macos, .arch = .aarch64, .qemu = false };
    // The gate's one machine runs the source checks and the compiles of named targets: no
    // other machine would. ReleaseSmall's compile is for its runner's own system, Linux.
    const alone = try decide(a, &jobs, host, .here);
    defer a.free(alone);
    const expected = [_]std.meta.Tag(Decision){ .elsewhere, .run, .elsewhere, .run, .run, .elsewhere, .elsewhere, .run, .run, .elsewhere, .elsewhere };
    for (expected, alone) |want, got| try std.testing.expectEqual(want, std.meta.activeTag(got));
    // A machine whose gate's caller runs them on another machine names them as that machine's.
    const beside = try decide(a, &jobs, host, .elsewhere);
    defer a.free(beside);
    for (expected, beside, 0..) |want, got, index| {
        if (index == 3 or index == 4) {
            try std.testing.expectEqualStrings("another machine of this gate", got.elsewhere);
        } else try std.testing.expectEqual(want, std.meta.activeTag(got));
    }
}

test "an ARM Linux machine runs the Linux suites once each, and riscv64 with QEMU" {
    const a = std.testing.allocator;
    const jobs = [_]matrix.Job{
        .{ .os = "ubuntu-latest", .name = "test (ubuntu-latest, Debug)", .args = "-Doptimize=debug" },
        .{ .os = "ubuntu-latest", .name = "test (ubuntu-latest, ReleaseFast)", .args = "-Doptimize=fast" },
        .{ .os = "ubuntu-24.04-arm", .name = "test (ubuntu-24.04-arm, Debug)", .args = "-Doptimize=debug" },
        .{ .os = "macos-latest", .name = "native link for test (macos-latest, Debug)", .step = "ci-build", .operation = .link },
        .{ .os = "ubuntu-latest", .name = "test (riscv64-linux on its kernel under QEMU, Debug)", .qemu = true },
        .{ .os = "ubuntu-latest", .name = "conformance", .step = "conformance", .declared = true },
    };
    const decisions = try decide(a, &jobs, .{ .os = .linux, .arch = .aarch64, .qemu = true }, .here);
    defer a.free(decisions);
    const expected = [_]std.meta.Tag(Decision){ .run, .run, .covered, .elsewhere, .run, .run };
    for (expected, decisions) |want, got| try std.testing.expectEqual(want, std.meta.activeTag(got));
}

test "the fuzz campaign runs only where Zig's fuzzer does: a 64-bit host that is not Windows" {
    const a = std.testing.allocator;
    const jobs = [_]matrix.Job{
        .{ .os = "ubuntu-latest", .name = "hardened", .step = "hardened" },
        .{ .os = "ubuntu-latest", .name = "hardened-fuzz", .step = "hardened-fuzz" },
    };
    for ([_]struct { host: Host, fuzz: std.meta.Tag(Decision) }{
        .{ .host = .{ .os = .windows, .arch = .x86_64, .qemu = false }, .fuzz = .elsewhere },
        .{ .host = .{ .os = .windows, .arch = .aarch64, .qemu = false }, .fuzz = .elsewhere },
        .{ .host = .{ .os = .linux, .arch = .x86, .qemu = false }, .fuzz = .elsewhere },
        .{ .host = .{ .os = .linux, .arch = .x86_64, .qemu = false }, .fuzz = .run },
        .{ .host = .{ .os = .macos, .arch = .aarch64, .qemu = false }, .fuzz = .run },
    }) |case| {
        const decisions = try decide(a, &jobs, case.host, .here);
        defer a.free(decisions);
        // The hardened suite runs on every host: its faults are each system's own.
        try std.testing.expectEqual(Decision.run, decisions[0]);
        try std.testing.expectEqual(case.fuzz, std.meta.activeTag(decisions[1]));
    }
}

test "a replay runs as the suite on the system it was linked for" {
    const a = std.testing.allocator;
    const jobs = [_]matrix.Job{
        .{ .os = "macos-latest", .name = "native link for test (macos-latest, Debug)", .step = "ci-build", .args = "-Doptimize=debug -Dtarget=aarch64-macos", .operation = .link },
        .{ .os = "macos-latest", .name = "test (macos-latest, Debug)", .step = "ci-run", .args = "-Doptimize=debug", .operation = .replay },
    };
    const decisions = try decide(a, &jobs, .{ .os = .macos, .arch = .aarch64, .qemu = false }, .here);
    defer a.free(decisions);
    try std.testing.expectEqual(Decision.covered, decisions[0]);
    try std.testing.expectEqual(Decision.run, decisions[1]);
    try std.testing.expectEqualStrings("ci", stepOf(jobs[1]));
}

test "where the portable jobs run is read from the environment, here when it is unset" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try std.testing.expectEqual(Portable.here, Portable.from(&environ));
    try environ.put("PREFLIGHT_PORTABLE", "elsewhere");
    try std.testing.expectEqual(Portable.elsewhere, Portable.from(&environ));
    try environ.put("PREFLIGHT_PORTABLE", "somewhere");
    try std.testing.expectEqual(null, Portable.from(&environ));
}
