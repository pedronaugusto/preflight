//! The commands a gate's jobs are running, each the leader of a process group of its own,
//! ended with the gate: a gate stopped by a signal (Ctrl-C, a `kill` of it alone, its
//! terminal gone) ends every job's build and what that build started, which would
//! otherwise run on with no gate to wait for them. Not on Windows, where a gate does not
//! run.
const std = @import("std");
const builtin = @import("builtin");
const aegis = @import("aegis");

/// Whether a job's command leads a process group of its own here.
pub const grouped = builtin.target.os.tag != .windows;

const Pid = if (grouped) std.posix.pid_t else i32;

/// A place in `leaders`: free, or the pid of a command leading a process group of its own.
pub const Leader = enum(Pid) { free = 0, _ };

/// The leaders running now. Read by the signal handler, so only atomics.
pub var leaders: [256]aegis.Atomic(Leader) = @splat(.init(.free));

/// Holds `pid`, a command a job started at the head of its own group, until `release`.
/// With every place taken it is not held, and a stopped gate leaves it running.
pub fn hold(pid: Pid) void {
    for (&leaders) |*place| if (place.cmpxchgStrong(.free, @fromBackingInt(pid), .acq_rel, .monotonic) == null) return;
}

/// Lets go of `pid`, which has ended.
pub fn release(pid: Pid) void {
    for (&leaders) |*place| if (place.cmpxchgStrong(@fromBackingInt(pid), .free, .acq_rel, .monotonic) == null) return;
}

/// Ends the gate's commands on the signals that stop a gate, then lets the signal end
/// the gate as it would have.
pub fn endWithGate() void {
    if (!grouped) return;
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = stopped }, .mask = std.posix.sigemptyset(), .flags = std.posix.SA.RESETHAND };
    for ([_]std.posix.SIG{ .INT, .TERM, .HUP }) |sig| std.posix.sigaction(sig, &action, null);
}

/// Ends the group of every command held now, with what each started.
pub fn endAll() void {
    if (!grouped) return;
    for (&leaders) |*place| {
        const leader = place.load(.acquire);
        if (leader != .free) _ = std.posix.system.kill(-@backingInt(leader), .TERM);
    }
}

fn stopped(sig: std.posix.SIG) callconv(.c) void {
    endAll();
    // The handler was reset as it ran (`RESETHAND`): the signal again ends the gate.
    // glint-ignore: Z026 -- a signal this process cannot raise leaves the gate to end with its jobs ended
    std.posix.raise(sig) catch {};
}

test "a held command is let go of, and a place is free again" {
    const leader: Leader = @fromBackingInt(4242);
    hold(4242);
    try std.testing.expect(for (&leaders) |*place| {
        if (place.load(.monotonic) == leader) break true;
    } else false);
    release(4242);
    try std.testing.expect(for (&leaders) |*place| {
        if (place.load(.monotonic) == leader) break false;
    } else true);
}
