//! The one bound on every child process preflight starts that may run long: a run of the tests
//! step that is no test (`bound.zig`, which the build puts before the run's command), and each
//! nested build the gate runs (`checks.command.execute`, a cross-compile's targets among them).
//! The program and every process it starts are one tree (`runner/tree.zig`); its output reaches
//! this process's own streams, and the last of it is kept. Once its tree makes no progress for
//! its bound (it uses no CPU time: `watchdog.watch`), or when the hosted job's deadline
//! (`PREFLIGHT_DEADLINE`) comes, the tree is killed and the run named: its step or target, its
//! command, and the last line it printed (two strand cross-compile jobs hung to the job's limit,
//! and the host kept no log). A run a busy machine slows still makes progress, and runs on. Zig's `--test-timeout` bounds unit tests
//! alone, so an example that never ended ran 45 hours. Std alone.
const std = @import("std");
const builtin = @import("builtin");
const watchdog = @import("watchdog.zig");
const process_tree = @import("runner/tree.zig");
const cpu_time = @import("runner/cputime.zig");
const inbound = @import("runner/input.zig");
const proc_stat = @import("runner/proc_stat.zig");

/// What to run, and the name its timeout gives it.
pub const Command = struct {
    /// The step or target, as the build or the plan names it.
    name: []const u8,
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    environ_map: ?*const std.process.Environ.Map = null,
    /// The run's own bound: how long its tree may make no progress; null bounds it by the job's
    /// deadline alone.
    limit: ?std.Io.Duration,
    /// The hosted job's deadline, whole seconds of the real clock; null outside a hosted job.
    deadline: ?i64,
    /// What the timeout's message says after the run is named: how to give it longer.
    hint: []const u8 = "",
    /// Whether to keep the peak of the memory the run's tree holds (`Tree.memory`), sampled
    /// while it runs: what a plan sizes the jobs a build runs at once by.
    measure: bool = false,
};

/// How a run ended: of itself, or at its bound, named.
pub const Ended = union(enum) {
    exited: struct {
        term: std.process.Child.Term,
        /// Windows' exit status whole, where `term` keeps its low byte.
        status: u32,
        /// The most memory the run's tree held, and any one process of it, where `measure` asked
        /// for it and the system's is read (`Tree.memory`); null otherwise.
        peak: ?process_tree.Usage = null,
    },
    expired,

    /// Whether the run ended of itself with status 0.
    pub fn passed(ended: Ended) bool {
        return ended == .exited and ended.exited.term == .exited and ended.exited.term.exited == 0;
    }
};

/// How long the output of a run that has ended may still be held by a process it left: one
/// that is ending lets go well within it, as the test runner's supervisor allows.
const release: std.Io.Duration = .fromSeconds(2);

/// Runs `command` under its bound. `gpa` holds what the forwarding of its output needs; when a
/// process outside the tree (one that made a session of its own) still holds that output past
/// `release`, the forwarding is left to end with this process, and what it holds with it.
pub fn run(io: std.Io, gpa: std.mem.Allocator, command: Command) !Ended {
    const wait = watchdog.bound(io, command.limit, command.deadline);
    const bounded = command.limit != null or command.deadline != null;
    if (wait.job) |left| if (left.nanoseconds == 0) {
        try say(command, .not_started, wait, "");
        return .expired;
    };
    var child = try std.process.spawn(io, .{
        .argv = command.argv,
        .cwd = command.cwd,
        .environ_map = command.environ_map,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (builtin.target.os.tag == .windows) null else 0,
        .start_suspended = builtin.target.os.tag == .windows,
    });
    const tree = try process_tree.Tree.hold(&child);
    const output = try gpa.create(Output);
    output.* = .{ .io = io };
    // The pipes are the forwarding's: `wait` closes what the child still names.
    const streams = [2]std.Io.File{ child.stdout.?, child.stderr.? };
    child.stdout = null;
    child.stderr = null;
    var forwarders: [2]std.Thread = undefined;
    for (streams, [2]std.Io.File{ .stdout(), .stderr() }, &forwarders) |from, to, *thread| thread.* = try std.Thread.spawn(.{}, Output.forward, .{ output, from, to });
    var watch: Watch = .{ .bound = wait, .tree = tree };
    const watcher: ?std.Thread = if (bounded) try std.Thread.spawn(.{}, Watch.run, .{ &watch, io }) else null;
    var measure: Measure = .{ .tree = tree };
    const measurer: ?std.Thread = if (command.measure) try std.Thread.spawn(.{}, Measure.run, .{ &measure, io }) else null;
    const status = process_tree.waitStatus(&child);
    const term = try child.wait(io);
    watch.done.set(io);
    if (watcher) |thread| thread.join();
    measure.done.set(io);
    if (measurer) |thread| {
        thread.join();
        // Windows' job keeps its own peak: read once more, all of the run in it.
        measure.take(io);
    }
    tree.end(io);
    const held = watchdog.expired(io, &output.ended, release);
    if (held) {
        // Held past `release`: the forwarding, and `output`, are left to end with this process.
        for (forwarders) |thread| thread.detach();
    } else {
        for (forwarders) |thread| thread.join();
        for (streams) |stream| stream.close(io);
    }
    defer if (!held) gpa.destroy(output);
    if (watch.expired.load(.acquire)) {
        try say(command, watch.ending, wait, output.lastLine());
        return .expired;
    }
    return .{ .exited = .{ .term = term, .status = status, .peak = measure.peak } };
}

/// How often the tree's memory is sampled for its peak: a compile's peak lasts seconds.
const sample_every: std.Io.Duration = .fromMilliseconds(250);

/// The thread that samples the run's tree for the most memory it holds, until the run ends.
const Measure = struct {
    tree: process_tree.Tree,
    done: std.Io.Event = .unset,
    peak: ?process_tree.Usage = null,

    fn run(measure: *Measure, io: std.Io) void {
        while (true) {
            measure.take(io);
            if (!watchdog.expired(io, &measure.done, sample_every)) return;
        }
    }

    fn take(measure: *Measure, io: std.Io) void {
        const now = (if (builtin.target.os.tag == .linux) groupResident(io, measure.tree.group) else measure.tree.memory()) orelse return;
        const was = measure.peak orelse now;
        measure.peak = .{ .tree = @max(was.tree, now.tree), .single = @max(was.single, now.single) };
    }
};

/// The resident bytes of every process whose group is `group`, and the most any one of them
/// has held, read from `/proc`; null where `/proc` cannot be listed. A process that ends while
/// it is read is not counted.
fn groupResident(io: std.Io, group: std.posix.pid_t) ?process_tree.Usage {
    var proc = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch return null;
    defer proc.close(io);
    var entries = proc.iterate();
    var pages: u64 = 0;
    var single: u64 = 0;
    var buffer: [1024]u8 = undefined;
    while (entries.next(io) catch return null) |entry| {
        // A process's directory is its number; the others (self, net) are the kernel's.
        if (entry.name.len == 0 or std.mem.findNone(u8, entry.name, "0123456789") != null) continue;
        var process = proc.openDir(io, entry.name, .{}) catch |err| switch (err) {
            // A process that ended since the listing holds nothing.
            error.FileNotFound => continue,
            // Any other failure leaves the tree's memory unread rather than counted short.
            else => return null,
        };
        defer process.close(io);
        const line = inbound.file(io, process, "stat", &buffer) catch |err| switch (err) {
            error.FileNotFound => continue, // it ended since it was opened
            else => return null, // unread rather than counted short
        };
        const read = proc_stat.groupPages(line) orelse return null;
        if (read.group != group) continue;
        pages +|= read.pages;
        const status = inbound.file(io, process, "status", &buffer) catch |err| switch (err) {
            error.FileNotFound => continue, // it ended since its stat was read
            else => return null, // unread rather than counted short
        };
        single = @max(single, proc_stat.highWater(status) orelse (read.pages *| std.heap.pageSize()));
    }
    return .{ .tree = pages *| std.heap.pageSize(), .single = single };
}

/// The thread that ends the run's tree once it makes no progress for its bound, or the job's
/// time runs out.
const Watch = struct {
    bound: watchdog.Bound,
    tree: process_tree.Tree,
    done: std.Io.Event = .unset,
    expired: std.atomic.Value(bool) = .init(false),
    /// How the watch ended, once `expired` is set.
    ending: watchdog.Ending = .done,

    fn run(watch: *Watch, io: std.Io) void {
        const ending = watchdog.watch(io, &watch.done, watch.bound, Progress{ .io = io, .tree = watch.tree });
        if (ending == .done) return;
        watch.ending = ending;
        watch.expired.store(true, .release);
        watch.tree.kill();
    }

    /// The run's progress: its tree's CPU time. The watching thread is this process's, outside
    /// the tree; it reads with an allocator of its own, the caller's being the caller's thread's.
    const Progress = struct {
        io: std.Io,
        tree: process_tree.Tree,

        pub fn cpu(progress: Progress) !u64 {
            const root = if (builtin.target.os.tag == .windows) progress.tree.job else progress.tree.group;
            return cpu_time.tree(progress.io, std.heap.page_allocator, root);
        }
    };
};

/// The run's output on its way to this process's streams, and the last of it.
const Output = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    tail: [tail_len]u8 = undefined,
    len: usize = 0,
    /// Set once both streams have ended.
    ended: std.Io.Event = .unset,
    open: std.atomic.Value(u8) = .init(2),

    const tail_len = 4096;

    fn forward(output: *Output, from: std.Io.File, to: std.Io.File) void {
        defer if (output.open.fetchSub(1, .acq_rel) == 1) output.ended.set(output.io);
        var buffer: [4096]u8 = undefined;
        // A stream this process can no longer write loses only the copy: the tail keeps the rest.
        var copying = true;
        while (true) {
            // The stream's end and a read that fails alike end the forwarding.
            const n = inbound.chunk(output.io, from, &buffer) catch 0;
            if (n == 0) return;
            if (copying) to.writeStreamingAll(output.io, buffer[0..n]) catch {
                copying = false;
            };
            output.keep(buffer[0..n]);
        }
    }

    fn keep(output: *Output, bytes: []const u8) void {
        output.mutex.lockUncancelable(output.io);
        defer output.mutex.unlock(output.io);
        const kept = bytes[bytes.len -| tail_len..];
        const room = tail_len - kept.len;
        if (output.len > room) {
            @memmove(output.tail[0..room], output.tail[output.len - room .. output.len]);
            output.len = room;
        }
        @memcpy(output.tail[output.len..][0..kept.len], kept);
        output.len += kept.len;
    }

    fn lastLine(output: *Output) []const u8 {
        output.mutex.lockUncancelable(output.io);
        defer output.mutex.unlock(output.io);
        return last(output.tail[0..output.len]);
    }
};

/// The last line of `text` that holds more than whitespace, at most its last 300 bytes.
fn last(text: []const u8) []const u8 {
    var lines = std.mem.splitBackwardsScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len != 0) return trimmed[trimmed.len -| 300..];
    }
    return "";
}

/// Names the run whose wait is up, on stderr, where a failed run is read; a stderr that takes
/// none of it is the caller's error, the run failed either way.
fn say(command: Command, ending: watchdog.Ending, wait: watchdog.Bound, line: []const u8) std.Io.Writer.Error!void {
    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    const w = &stderr.file_writer.interface;
    try w.print("\npreflight: watchdog: `{s}` ", .{command.name});
    switch (ending) {
        .done => unreachable, // a run that ended of itself is not named
        .not_started => try w.writeAll("did not start: the job's time had run out before its turn"),
        .job_ran_out => try w.print("was running when the job's time ran out, {f} into it", .{wait.job.?}),
        .stalled => try w.print("made no progress for {f}: its processes used under {f} of CPU time in it", .{ wait.limit.?, watchdog.progress_floor }),
        .unread => |err| try w.print("was ended: its processes' CPU time is unread ({t}), so its progress is unknown", .{err}),
    }
    try w.writeAll("; it runs");
    for (command.argv) |arg| try w.print(" {s}", .{arg});
    if (ending != .not_started) {
        if (line.len == 0) try w.writeAll("; it printed nothing") else try w.print("; its last line: {s}", .{line});
    }
    try w.print("{s}\n", .{command.hint});
    try w.flush();
}
