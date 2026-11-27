//! The CPU time of a process tree, as preflight's watchdog reads it (`runner/cputime.zig`),
//! and the `/proc` lines it parses: tested through the module the runner imports, which a test
//! root reaches by its name alone, since a file is one module's.
const std = @import("std");
const builtin = @import("builtin");
const cpu_time = @import("preflight_cputime");

const os = builtin.target.os.tag;

/// This process's tree's CPU time less this thread's, which reads it.
fn others(io: std.Io, root: cpu_time.Root) !u64 {
    const used = try cpu_time.tree(io, std.testing.allocator, root);
    return used -| (std.math.cast(u64, std.Io.Clock.cpu_thread.now(io).nanoseconds) orelse 0);
}

/// Reads until the tree has grown by `by`, or 30 s have passed; what it grew by.
fn growth(io: std.Io, root: cpu_time.Root, by: u64) !u64 {
    const from = try others(io, root);
    const start: std.Io.Clock.Timestamp = .now(io, .awake);
    while (start.untilNow(io).raw.toSeconds() < 30) {
        try io.sleep(.fromMilliseconds(50), .awake);
        const grown = (try others(io, root)) -| from;
        if (grown >= by) return grown;
    }
    return (try others(io, root)) -| from;
}

const floor_ns = 50 * std.time.ns_per_ms; // `watchdog.progress_floor`

test "a tree's CPU time grows while a process it started works in a group of its own, and not while one is stopped" {
    if (os == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const root = try cpu_time.own();
    // A grandchild in a process group of its own (job control's), as a nested preflight run's
    // tests are: found by its parent links. It ends of itself, after a second of CPU time.
    var working = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", "set -m; /bin/sh -c 'ulimit -t 1; while :; do :; done' & wait" } });
    const grown = growth(io, root, floor_ns);
    _ = try working.wait(io);
    try std.testing.expect(try grown >= floor_ns);
    // A stopped child uses none: half a second of it grows the tree by less than the floor.
    var stopped = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", "kill -STOP $$" } });
    // A stopped process takes no TERM, which `kill` sends: KILL first, which it takes stopped.
    defer {
        _ = std.posix.system.kill(stopped.id.?, .KILL);
        stopped.kill(io);
    }
    try io.sleep(.fromMilliseconds(100), .awake);
    const from = try others(io, root);
    try io.sleep(.fromMilliseconds(500), .awake);
    try std.testing.expect((try others(io, root)) -| from < floor_ns);
}

test "a child's CPU time stays in the tree once it has ended and been waited for" {
    if (os == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const root = try cpu_time.own();
    const from = try others(io, root);
    var child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", "ulimit -t 1; while :; do :; done" } });
    const term = try child.wait(io);
    try std.testing.expectEqual(std.process.Child.Term{ .signal = .XCPU }, term);
    // A second of the child's, less what the clock ticks round off.
    try std.testing.expect((try others(io, root)) -| from >= 900 * std.time.ns_per_ms);
}

test "a Windows job's CPU time grows while a process in it works" {
    if (os != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const job = try cpu_time.own();
    var working = try std.process.spawn(io, .{ .argv = &.{ "cmd.exe", "/c", "for /L %i in (0,0,1) do @rem" } });
    defer working.kill(io);
    try std.testing.expect(try growth(io, job, floor_ns) >= floor_ns);
}

test "a process's group and resident pages are read past a command holding spaces and parentheses" {
    const line = "4242 (zig (build) x) S 4200 4100 4100 0 -1 4194560 100 0 0 0 5 1 0 0 20 0 3 0 777 1234567 2048 18446744073709551615 1 1 0 0 0 0 0 0 0 0 0 17 2 0 0 0 0 0\n";
    const read = cpu_time.proc_stat.groupPages(line).?;
    try std.testing.expectEqual(@as(i64, 4100), read.group);
    try std.testing.expectEqual(@as(u64, 2048), read.pages);
    try std.testing.expectEqual(null, cpu_time.proc_stat.groupPages("4242 (cut) S 1 2"));
    try std.testing.expectEqual(null, cpu_time.proc_stat.groupPages("no parenthesis"));
    try std.testing.expectEqual(@as(?u64, 9_018_311 * 1024), cpu_time.proc_stat.highWater("Name:\tzig\nVmPeak:\t 12000000 kB\nVmHWM:\t 9018311 kB\nVmRSS:\t 100 kB\n"));
    try std.testing.expectEqual(@as(?u64, null), cpu_time.proc_stat.highWater("Name:\tzig\n"));
}

test "a process's parent and CPU ticks, its waited-for children's among them, are read past a command holding spaces and parentheses" {
    const line = "4242 (zig (build) x) S 4200 4100 4100 0 -1 4194560 100 0 0 0 5 1 7 3 20 0 3 0 777 1234567 2048 18446744073709551615 1 1 0 0 0 0 0 0 0 0 0 17 2 0 0 0 0 0\n";
    const read = cpu_time.proc_stat.cpuTicks(line).?;
    try std.testing.expectEqual(@as(i64, 4200), read.parent);
    try std.testing.expectEqual(@as(u64, 5 + 1 + 7 + 3), read.ticks);
    try std.testing.expectEqual(null, cpu_time.proc_stat.cpuTicks("4242 (cut) S 1 2 3"));
    try std.testing.expectEqual(null, cpu_time.proc_stat.cpuTicks("4242 (neg) S 1 2 3 0 -1 0 0 0 0 0 5 1 -7 3"));
}
