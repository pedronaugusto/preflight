const std = @import("std");
const measuring = @import("shakedown").bench;
const sample = @import("sample");
const provenance = @import("preflight_bench_options");
const Context = struct {
    result: u32 = 0,
    fn sum(c: *Context, units: u64) !void {
        for (0..units) |i| {
            c.result = sample.sum(@intCast(i & 0xffff), 1);
            std.mem.doNotOptimizeAway(c.result);
        }
    }
};
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var c: Context = .{};
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try measuring.run(init.gpa, init.io, &writer.interface, &c, &.{.{ .name = "sum", .unit = "call", .run = Context.sum }}, .{ .commit = provenance.commit, .cpu = provenance.cpu, .os = provenance.os }, .{ .smoke = args.len == 2 and std.mem.eql(u8, args[1], "--smoke"), .prefix = if (args.len == 3 and std.mem.eql(u8, args[1], "--row")) args[2] else "" });
    try writer.interface.flush();
}
