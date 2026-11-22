//! The one bound on every child process preflight starts that may run long: a run of the tests
//! step that is no test (`bound.zig`, which the build puts before the run's command), and each
//! nested build the gate runs (`checks.command.execute`, a cross-compile's targets among them).
//! The program and every process it starts are one tree (`runner/tree.zig`); its output reaches
//! this process's own streams, and the last of it is kept. Past its bound, or when the hosted
//! job's deadline (`PREFLIGHT_DEADLINE`) comes sooner, the tree is killed and the run named: its
//! step or target, its command, and the last line it printed (two strand cross-compile jobs
//! hung to the job's limit, and the host kept no log). Zig's `--test-timeout` bounds unit tests
//! alone, so an example that never ended ran 45 hours. Std alone.
const std = @import("std");
const builtin = @import("builtin");
const watchdog = @import("watchdog.zig");
const process_tree = @import("runner/tree.zig");
const inbound = @import("runner/input.zig");

/// What to run, and the name its timeout gives it.
pub const Command = struct {
    /// The step or target, as the build or the plan names it.
    name: []const u8,
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    environ_map: ?*const std.process.Environ.Map = null,
    /// Where the run's output goes, held whole: a program whose output is its answer (glint's
    /// report). The caller's, lent for the run; null forwards it to this process's own.
    stdout: ?*const std.Io.File = null,
    /// The run's own bound; null bounds it by the job's deadline alone.
    limit: ?std.Io.Duration,
    /// The hosted job's deadline, whole seconds of the real clock; null outside a hosted job.
    deadline: ?i64,
    /// What the timeout's message says after the run is named: how to give it longer.
    hint: []const u8 = "",
};

/// How a run ended: of itself, or at its bound, named.
pub const Ended = union(enum) {
    exited: struct {
        term: std.process.Child.Term,
        /// Windows' exit status whole, where `term` keeps its low byte.
        status: u32,
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
    const wait = watchdog.bound(io, command.limit orelse .max, command.deadline);
    const bounded = command.limit != null or command.deadline != null;
    if (bounded and wait.job and wait.limit.nanoseconds == 0) {
        try say(command, wait, "");
        return .expired;
    }
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
    for (streams, [2]std.Io.File{ if (command.stdout) |file| file.* else .stdout(), .stderr() }, &forwarders) |from, to, *thread| thread.* = try std.Thread.spawn(.{}, Output.forward, .{ output, from, to });
    var watch: Watch = .{ .limit = wait.limit, .tree = tree };
    const watcher: ?std.Thread = if (bounded) try std.Thread.spawn(.{}, Watch.run, .{ &watch, io }) else null;
    const status = process_tree.waitStatus(&child);
    // A wait that fails, canceled among the reasons, ends the tree and reaps the child before
    // the error goes on, after the forwarding ends as it does for any run: no command outlives
    // the gate that ran it.
    var failed: ?std.process.Child.WaitError = null;
    const term: std.process.Child.Term = child.wait(io) catch |err| ended: {
        tree.kill();
        child.kill(io);
        failed = err;
        break :ended .{ .unknown = 0 };
    };
    watch.done.set(io);
    if (watcher) |thread| thread.join();
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
    if (failed) |err| return err;
    if (watch.expired.load(.acquire)) {
        try say(command, wait, output.lastLine());
        return .expired;
    }
    return .{ .exited = .{ .term = term, .status = status } };
}

/// The thread that ends the run's tree once its wait is up.
const Watch = struct {
    limit: std.Io.Duration,
    tree: process_tree.Tree,
    done: std.Io.Event = .unset,
    expired: std.atomic.Value(bool) = .init(false),

    fn run(watch: *Watch, io: std.Io) void {
        if (!watchdog.expired(io, &watch.done, watch.limit)) return;
        watch.expired.store(true, .release);
        watch.tree.kill();
    }
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
fn say(command: Command, wait: watchdog.Bound, line: []const u8) std.Io.Writer.Error!void {
    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    const w = &stderr.file_writer.interface;
    try w.print("\npreflight: watchdog: `{s}` ", .{command.name});
    switch (watchdog.ending(wait)) {
        .not_started => try w.writeAll("did not start: the job's time had run out before its turn"),
        .job_ran_out => try w.print("was running when the job's time ran out, {f} into it", .{wait.limit}),
        .over_limit => try w.print("exceeded {d} ms", .{wait.limit.toMilliseconds()}),
    }
    try w.writeAll("; it runs");
    for (command.argv) |arg| try w.print(" {s}", .{arg});
    if (watchdog.ending(wait) != .not_started) {
        if (line.len == 0) try w.writeAll("; it printed nothing") else try w.print("; its last line: {s}", .{line});
    }
    try w.print("{s}\n", .{command.hint});
    try w.flush();
}
