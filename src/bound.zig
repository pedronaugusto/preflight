//! `<limit_ns> <step> [--path=DIR]... -- <program> <arg>...`: runs a program the tests step runs
//! that is no test (an example, a generator, a smoke run), and every process it starts, under
//! the watchdog each test runs under: once it has run `limit_ns`, or when the hosted job's
//! deadline (`PREFLIGHT_DEADLINE`) comes sooner, its processes are killed and the run fails
//! naming the step and its command. Zig's own bound, `--test-timeout`, holds unit tests alone,
//! so an example that never ended ran 45 hours (blackbox). Otherwise this process ends as the
//! program ended, its exit status or signal its own. Each `--path` directory joins `PATH`
//! first: Windows finds the build's DLLs there, which Zig adds for the program it runs, and
//! here that program is this one. Std alone, as the test runner.
const std = @import("std");
const builtin = @import("builtin");
const watchdog = @import("watchdog.zig");
const process_tree = @import("runner/tree.zig");

const usage = "preflight-bound: usage: <limit_ns> <step> [--path=DIR]... -- <program> <arg>...";

const Given = struct {
    limit: std.Io.Duration,
    step: []const u8,
    paths: []const []const u8,
    argv: []const []const u8,
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    const given = parse(a, args) catch |err| fail("{s} ({t})\n", .{ usage, err });
    const environ = init.environ_map;
    for (given.paths) |dir| {
        const delimiter: u8 = if (builtin.target.os.tag == .windows) ';' else ':';
        const joined = if (environ.get("PATH")) |previous| try a.print("{s}{c}{s}", .{ dir, delimiter, previous }) else dir;
        try environ.put("PATH", joined);
    }
    const deadline = watchdog.parseDeadline(environ.get("PREFLIGHT_DEADLINE")) catch fail("preflight-bound: PREFLIGHT_DEADLINE is no whole number of seconds\n", .{});
    const wait = watchdog.bound(io, given.limit, deadline);
    const command = try std.mem.join(a, " ", given.argv);
    if (wait.job and wait.limit.nanoseconds == 0) say(given, wait, command);
    var child = std.process.spawn(io, .{
        .argv = given.argv,
        .environ_map = environ,
        .pgid = if (builtin.target.os.tag == .windows) null else 0,
        .start_suspended = builtin.target.os.tag == .windows,
    }) catch |err| fail("preflight: `{s}` could not start {s}: {t}\n", .{ given.step, given.argv[0], err });
    const tree = try process_tree.Tree.hold(&child);
    var watch: Watch = .{ .given = given, .wait = wait, .command = command, .tree = tree };
    const thread = try std.Thread.spawn(.{}, Watch.run, .{ &watch, io });
    const status = process_tree.waitStatus(&child);
    const term = try child.wait(io);
    watch.done.set(io);
    thread.join();
    tree.end(io);
    // The watch named the run and ended it: the program's ending is the kill's.
    if (watch.expired.load(.acquire)) std.process.exit(1);
    process_tree.exitAs(term, status, "preflight-bound");
}

/// The thread that ends the program's tree once its wait is up.
const Watch = struct {
    given: Given,
    wait: watchdog.Bound,
    command: []const u8,
    tree: process_tree.Tree,
    done: std.Io.Event = .unset,
    expired: std.atomic.Value(bool) = .init(false),

    fn run(watch: *Watch, io: std.Io) void {
        if (!watchdog.expired(io, &watch.done, watch.wait.limit)) return;
        watch.expired.store(true, .release);
        say(watch.given, watch.wait, watch.command);
        watch.tree.kill();
    }
};

/// Names the run whose wait is up, and, but for one that never started, ends its tree.
fn say(given: Given, wait: watchdog.Bound, command: []const u8) void {
    const limit_ms = @divTrunc(given.limit.nanoseconds, std.time.ns_per_ms);
    switch (watchdog.ending(wait)) {
        .not_started => fail("\npreflight: watchdog: `{s}` did not start: the job's time had run out before its turn; it runs {s}\n", .{ given.step, command }),
        .job_ran_out => report("\npreflight: watchdog: `{s}` was running when the job's time ran out, {f} into it; it runs {s}\n", .{ given.step, wait.limit, command }),
        .over_limit => report("\npreflight: watchdog: `{s}` exceeded {d} ms; it runs {s}. A run that needs longer names its bound, with its reason, in the build's `run_bounds`\n", .{ given.step, limit_ms, command }),
    }
}

fn fail(comptime format: []const u8, args: anytype) noreturn {
    report(format, args);
    std.process.exit(1);
}

/// Writes to stderr, where the build shows a failed run's output; a line lost there leaves
/// the run's failure unnamed, never passed.
fn report(comptime format: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    stderr.file_writer.interface.print(format, args) catch {};
    stderr.file_writer.interface.flush() catch {};
}

fn parse(a: std.mem.Allocator, args: []const [:0]const u8) !Given {
    if (args.len < 5) return error.TooFewArguments;
    const limit = try std.fmt.parseInt(u64, args[1], 10);
    if (limit == 0) return error.ZeroBound;
    var paths: std.ArrayList([]const u8) = .empty;
    var index: usize = 3;
    while (index < args.len and !std.mem.eql(u8, args[index], "--")) : (index += 1) {
        const path = std.mem.cutPrefix(u8, args[index], "--path=") orelse return error.UnknownOption;
        try paths.append(a, path);
    }
    if (index + 1 >= args.len) return error.NoProgram;
    const argv = try a.alloc([]const u8, args.len - index - 1);
    for (args[index + 1 ..], argv) |arg, *slot| slot.* = arg;
    return .{ .limit = .fromNanoseconds(limit), .step = args[2], .paths = paths.items, .argv = argv };
}
