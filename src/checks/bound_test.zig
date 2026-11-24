//! The bound program (`bound.zig`) as the build puts it before a run: it ends as its program
//! ended, by the program's own signal, and a program its bound ends is named as the bound's.
const std = @import("std");
const builtin = @import("builtin");
const test_options = @import("test_options");

/// `preflight-bound` run on `sh -c script` under `limit_ns` (0: the job's deadline alone), with no
/// job deadline in its environment.
fn bound(a: std.mem.Allocator, limit_ns: []const u8, script: []const u8) !std.process.RunResult {
    const inherited = try std.testing.environ.createMap(a);
    var environ: std.process.Environ.Map = .init(a);
    if (inherited.get("PATH")) |path| try environ.put("PATH", path);
    const program = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, test_options.bound, a);
    return std.process.run(a, std.testing.io, .{ .argv = &.{ program, limit_ns, "the run", "--", "/bin/sh", "-c", script }, .environ_map = &environ });
}

test "a program killed by KILL ends the bound by KILL, as its own ending" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try bound(arena.allocator(), "0", "kill -KILL $$");
    try std.testing.expectEqual(std.process.Child.Term{ .signal = .KILL }, result.term);
}

test "a program stopped, then killed at its bound, ends as the bound's kill, named" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try bound(arena.allocator(), "300000000", "kill -STOP $$");
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
    try std.testing.expect(std.mem.find(u8, result.stderr, "preflight: watchdog: `the run` exceeded 300ms; it runs /bin/sh -c kill -STOP $$; it printed nothing") != null);
}
