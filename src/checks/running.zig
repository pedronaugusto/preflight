//! The commands a gate's jobs are running, each the leader of a process group of its own,
//! ended with the gate: a gate stopped by a signal (Ctrl-C, a `kill` of it alone, its
//! terminal gone) ends every job's build and what that build started, which would
//! otherwise run on with no gate to wait for them. Not on Windows, where a gate does not
//! run.
const std = @import("std");
const builtin = @import("builtin");

/// Whether a job's command leads a process group of its own here.
pub const grouped = builtin.target.os.tag != .windows;

const Pid = if (grouped) std.posix.pid_t else i32;

/// The leaders running now; 0 is a free place. Read by the signal handler, so only atomics.
pub var leaders: [256]std.atomic.Value(Pid) = @splat(.init(0));

/// Holds `pid`, a command a job started at the head of its own group, until `release`.
/// With every place taken it is not held, and a stopped gate leaves it running.
pub fn hold(pid: Pid) void {
    for (&leaders) |*place| if (place.cmpxchgStrong(0, pid, .acq_rel, .monotonic) == null) return;
}

/// Lets go of `pid`, which has ended.
pub fn release(pid: Pid) void {
    for (&leaders) |*place| if (place.cmpxchgStrong(pid, 0, .acq_rel, .monotonic) == null) return;
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
        const pid = place.load(.acquire);
        if (pid != 0) _ = std.posix.system.kill(-pid, .TERM);
    }
}

fn stopped(sig: std.posix.SIG) callconv(.c) void {
    endAll();
    // The handler was reset as it ran (`RESETHAND`): the signal again ends the gate.
    // glint-ignore: Z026 -- a signal this process cannot raise leaves the gate to end with its jobs ended
    std.posix.raise(sig) catch {};
}

test "a held command is let go of, and a place is free again" {
    hold(4242);
    try std.testing.expect(for (&leaders) |*place| {
        if (place.load(.monotonic) == 4242) break true;
    } else false);
    release(4242);
    try std.testing.expect(for (&leaders) |*place| {
        if (place.load(.monotonic) == 4242) break false;
    } else true);
}
