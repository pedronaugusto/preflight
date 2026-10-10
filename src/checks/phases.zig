//! Where a hosted job's time goes. The gate times each command it runs and
//! each source check, prints the phase as it ends and adds it to the job's
//! summary, so a change to the gate is judged on numbers and not on the
//! timestamps of a log.
const std = @import("std");
const src = @import("source.zig");

pub const Timer = struct {
    label: []const u8,
    start: std.Io.Clock.Timestamp,

    pub fn begin(c: src.Context, label: []const u8) Timer {
        return .{ .label = label, .start = .now(c.io, .awake) };
    }

    /// Seconds since `begin`.
    pub fn seconds(timer: Timer, c: src.Context) f64 {
        return @as(f64, @floatFromInt(timer.start.untilNow(c.io).raw.nanoseconds)) / std.time.ns_per_s;
    }

    /// Prints the phase and adds it to `summary`, the job's step summary, when
    /// the job has one. A summary that cannot be written loses only its line.
    pub fn end(timer: Timer, c: src.Context, summary: ?[]const u8) void {
        const elapsed = timer.seconds(c);
        c.report("preflight: phase {s}: {d:.1} s\n", .{ timer.label, elapsed });
        const path = summary orelse return;
        const line = c.a.print("- phase `{s}`: {d:.1} s\n", .{ timer.label, elapsed }) catch return;
        append(c, path, line) catch return;
    }
};

fn append(c: src.Context, path: []const u8, text: []const u8) !void {
    const file = try c.directory().createFile(c.io, path, .{ .truncate = false, .read = true });
    defer file.close(c.io);
    var buffer: [1024]u8 = undefined;
    var writer = file.writer(c.io, &buffer);
    writer.pos = (try file.stat(c.io)).size;
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

test "a phase is added to the summary as a line, after what the file holds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    try tmp.dir.writeFile(c.io, .{ .sub_path = "summary.md", .data = "kept\n" });
    Timer.begin(c, "lint").end(c, "summary.md");
    Timer.begin(c, "tests").end(c, "summary.md");
    const text = try c.read("summary.md");
    try std.testing.expect(std.mem.startsWith(u8, text, "kept\n- phase `lint`: "));
    try std.testing.expect(std.mem.find(u8, text, "\n- phase `tests`: ") != null);
}
