//! Timing evidence is recorded by the test runner, never asserted by a test.
const std = @import("std");

pub const Recorder = struct {
    io: std.Io,
    file: ?std.Io.File = null,

    pub fn init(io: std.Io, environ: std.process.Environ) !Recorder {
        var env = try environ.createMap(std.heap.page_allocator);
        defer env.deinit();
        const path = env.get("PREFLIGHT_TIMINGS") orelse return .{ .io = io };
        if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
        return .{ .io = io, .file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true }) };
    }

    pub fn deinit(recorder: Recorder) void {
        if (recorder.file) |file| file.close(recorder.io);
    }

    pub fn record(recorder: Recorder, name: []const u8, nanoseconds: u64, status: []const u8) !void {
        const file = recorder.file orelse return;
        const json = try std.json.Stringify.valueAlloc(std.heap.page_allocator, .{
            .name = name,
            .seconds = @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_s,
            .status = status,
        }, .{});
        defer std.heap.page_allocator.free(json);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(recorder.io, &buffer);
        writer.pos = (try file.stat(recorder.io)).size;
        try writer.interface.writeAll(json);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
    }
};
