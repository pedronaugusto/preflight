//! `gate`: the release tier's jobs a machine at hand runs, for a landing gated on the machines
//! the person has rather than by a hosted run. A job runs here when its runner's system is this
//! one's, so that a Linux machine of either architecture runs the Linux suites and the jobs
//! the hosted gate runs on Linux (the source checks, every target's compile), a Mac the macOS
//! suites; the hardened runs, which each system decides for itself, run on each machine. What
//! this machine cannot run is said, never skipped quietly: another system's suite, ThreadSanitizer off x86_64 and aarch64 Linux, riscv64 with no QEMU here.
const std = @import("std");
const matrix = @import("matrix.zig");

/// The machine the gate runs on.
pub const Host = struct {
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
    /// QEMU's user mode for riscv64 is on the PATH.
    qemu: bool,
};

/// A job of the plan, and whether it runs here or why not.
pub const Decision = union(enum) {
    run,
    elsewhere: []const u8,
    /// What another job this machine runs builds already: the same build, or the hosted
    /// gate's compile-once link of a suite that runs here.
    covered,
};

/// What `host` does with each of `jobs`, in their order.
pub fn decide(a: std.mem.Allocator, jobs: []const matrix.Job, host: Host) ![]Decision {
    const decisions = try a.alloc(Decision, jobs.len);
    for (jobs, decisions, 0..) |job, *decision, index| {
        decision.* = one(job, host);
        if (decision.* != .run) continue;
        for (jobs[0..index], decisions[0..index]) |earlier, earlier_decision| {
            if (earlier_decision == .run and same(earlier, job)) decision.* = .covered;
        }
    }
    return decisions;
}

fn one(job: matrix.Job, host: Host) Decision {
    // ThreadSanitizer runs on Linux, x86_64 and aarch64.
    if (std.mem.eql(u8, job.step, "hardened-tsan")) {
        return if (host.os == .linux and (host.arch == .x86_64 or host.arch == .aarch64)) .run else .{ .elsewhere = "ThreadSanitizer runs on x86_64 or aarch64 Linux" };
    }
    if (job.qemu) return if (host.os != .linux) .{ .elsewhere = "riscv64 runs under QEMU on Linux" } else if (!host.qemu) .{ .elsewhere = "no qemu-riscv64 on the PATH" } else .run;
    if (anywhere(job)) return .run;
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
/// one: the hardened runs, whose faults and allocator are each system's own. The source
/// checks and every compile of named targets say the same anywhere, and run once, where
/// their runner's system is.
fn anywhere(job: matrix.Job) bool {
    if (job.declared) return false;
    for ([_][]const u8{ "hardened", "hardened-fuzz" }) |step| if (std.mem.eql(u8, job.step, step)) return true;
    return false;
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

test "a Mac runs its own suites and the hardened runs, and names the rest" {
    const a = std.testing.allocator;
    const jobs = [_]matrix.Job{
        .{ .os = "ubuntu-latest", .name = "test (ubuntu-latest, Debug)", .args = "-Doptimize=debug" },
        .{ .os = "macos-latest", .name = "test (macos-latest, Debug)", .args = "-Doptimize=debug" },
        .{ .os = "windows-latest", .name = "test (windows-latest, Debug)", .args = "-Doptimize=debug" },
        .{ .os = "ubuntu-latest", .name = "source checks", .step = "lint" },
        .{ .os = "ubuntu-latest", .name = "Cross compile 1/2", .step = "preflight-cross-bench", .operation = .objects, .targets = "x86_64-linux-gnu" },
        .{ .os = "ubuntu-latest", .name = "hardened", .step = "hardened" },
        .{ .os = "ubuntu-latest", .name = "hardened-tsan", .step = "hardened-tsan" },
        .{ .os = "ubuntu-latest", .name = "test (riscv64-linux under QEMU, Debug)", .qemu = true },
        .{ .os = "ubuntu-latest", .name = "conformance", .step = "conformance", .declared = true },
    };
    const decisions = try decide(a, &jobs, .{ .os = .macos, .arch = .aarch64, .qemu = false });
    defer a.free(decisions);
    const expected = [_]std.meta.Tag(Decision){ .elsewhere, .run, .elsewhere, .elsewhere, .elsewhere, .run, .elsewhere, .elsewhere, .elsewhere };
    for (expected, decisions) |want, got| try std.testing.expectEqual(want, std.meta.activeTag(got));
}

test "an ARM Linux machine runs the Linux suites once each, and riscv64 with QEMU" {
    const a = std.testing.allocator;
    const jobs = [_]matrix.Job{
        .{ .os = "ubuntu-latest", .name = "test (ubuntu-latest, Debug)", .args = "-Doptimize=debug" },
        .{ .os = "ubuntu-latest", .name = "test (ubuntu-latest, ReleaseFast)", .args = "-Doptimize=fast" },
        .{ .os = "ubuntu-24.04-arm", .name = "test (ubuntu-24.04-arm, Debug)", .args = "-Doptimize=debug" },
        .{ .os = "macos-latest", .name = "native link for test (macos-latest, Debug)", .step = "ci-build", .operation = .link },
        .{ .os = "ubuntu-latest", .name = "test (riscv64-linux under QEMU, Debug)", .qemu = true },
        .{ .os = "ubuntu-latest", .name = "conformance", .step = "conformance", .declared = true },
    };
    const decisions = try decide(a, &jobs, .{ .os = .linux, .arch = .aarch64, .qemu = true });
    defer a.free(decisions);
    const expected = [_]std.meta.Tag(Decision){ .run, .run, .covered, .elsewhere, .run, .run };
    for (expected, decisions) |want, got| try std.testing.expectEqual(want, std.meta.activeTag(got));
}

test "a replay runs as the suite on the system it was linked for" {
    const a = std.testing.allocator;
    const jobs = [_]matrix.Job{
        .{ .os = "macos-latest", .name = "native link for test (macos-latest, Debug)", .step = "ci-build", .args = "-Doptimize=debug -Dtarget=aarch64-macos", .operation = .link },
        .{ .os = "macos-latest", .name = "test (macos-latest, Debug)", .step = "ci-run", .args = "-Doptimize=debug", .operation = .replay },
    };
    const decisions = try decide(a, &jobs, .{ .os = .macos, .arch = .aarch64, .qemu = false });
    defer a.free(decisions);
    try std.testing.expectEqual(Decision.covered, decisions[0]);
    try std.testing.expectEqual(Decision.run, decisions[1]);
    try std.testing.expectEqualStrings("ci", stepOf(jobs[1]));
}
