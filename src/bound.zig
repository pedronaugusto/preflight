//! `<limit_ns> <step> [--path=DIR]... -- <program> <arg>...`: runs a run of preflight's steps
//! that is no test under preflight's bound (`bounded.zig`), `limit_ns`, or the hosted job's
//! deadline alone where it is 0, as the build puts it before the run's command (`runs.zig`),
//! and ends as the program ended,
//! its exit status or signal its own. Each `--path` directory joins `PATH` first: Windows finds
//! the build's DLLs there, which Zig adds for the program it runs, and here that program is
//! this one. Std alone, as the test runner.
const std = @import("std");
const builtin = @import("builtin");
const watchdog = @import("watchdog.zig");
const bounded = @import("bounded.zig");
const process_tree = @import("runner/tree.zig");

const usage = "preflight-bound: usage: <limit_ns> <step> [--path=DIR]... -- <program> <arg>...";

const Given = struct {
    /// Null: the job's deadline alone.
    limit: ?std.Io.Duration,
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
    const ended = bounded.run(io, init.gpa, .{
        .name = given.step,
        .argv = given.argv,
        .environ_map = environ,
        .limit = given.limit,
        .deadline = deadline,
        .hint = ". A run that needs longer names its bound, with its reason, in the build's `run_bounds`",
    }) catch |err| fail("preflight: `{s}` could not run {s}: {t}\n", .{ given.step, given.argv[0], err });
    switch (ended) {
        // The bound named the run and ended it.
        .expired => std.process.exit(1),
        .exited => |exited| process_tree.exitAs(exited.term, exited.status, "preflight-bound"),
    }
}

fn fail(comptime format: []const u8, args: anytype) noreturn {
    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    // A stderr that takes none of it leaves the status alone to say the bound failed.
    stderr.file_writer.interface.print(format, args) catch std.process.exit(1);
    stderr.file_writer.interface.flush() catch std.process.exit(1);
    std.debug.unlockStderr();
    std.process.exit(1);
}

fn parse(a: std.mem.Allocator, args: []const [:0]const u8) !Given {
    if (args.len < 5) return error.TooFewArguments;
    const limit = try std.fmt.parseInt(u64, args[1], 10);
    var paths: std.ArrayList([]const u8) = .empty;
    var index: usize = 3;
    while (index < args.len and !std.mem.eql(u8, args[index], "--")) : (index += 1) {
        const path = std.mem.cutPrefix(u8, args[index], "--path=") orelse return error.UnknownOption;
        try paths.append(a, path);
    }
    if (index + 1 >= args.len) return error.NoProgram;
    const argv = try a.alloc([]const u8, args.len - index - 1);
    for (args[index + 1 ..], argv) |arg, *slot| slot.* = arg;
    return .{ .limit = if (limit == 0) null else .fromNanoseconds(limit), .step = args[2], .paths = paths.items, .argv = argv };
}
