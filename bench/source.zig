//! Source checks with parsing outside the measured region.
const std = @import("std");
const checks = @import("checks");
const measuring = @import("shakedown").bench;
const metadata = @import("preflight_bench_options");
const Context = struct {
    scratch: std.heap.ArenaAllocator,
    io: std.Io,
    source: checks.source.Source,
    config: checks.source.Value,
    fn quality(c: *Context, units: u64) !void {
        for (0..units) |_| {
            const findings = try checks.quality.findings(c.scratch.allocator(), &.{c.source}, c.config);
            if (findings.len != 0) return error.UnexpectedFindings;
            _ = c.scratch.reset(.retain_capacity);
        }
    }
    fn lengths(c: *Context, units: u64) !void {
        for (0..units) |_| {
            var context: checks.source.Context = .{ .a = c.scratch.allocator(), .io = c.io };
            try checks.policy.lengths(&context, &.{c.source}, c.config);
            _ = c.scratch.reset(.retain_capacity);
        }
    }
};
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var text: std.Io.Writer.Allocating = .init(a);
    for (0..100) |i| try text.writer.print("pub fn work{d}() void {{\n    const x = 1;\n    _ = x;\n}}\n", .{i});
    var context: Context = .{
        .scratch = .init(init.gpa),
        .io = init.io,
        .source = try checks.source.Source.parse(a, "src/tools/work.zig", text.written()),
        .config = (try std.json.parseFromSlice(checks.source.Value, a, "{\"test_support\":[\"src/testing/**\"],\"function_limits\":{\"src/**\":120}}", .{})).value,
    };
    defer context.scratch.deinit();
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try measuring.run(init.gpa, init.io, &output.interface, &context, &.{
        .{ .name = "quality", .unit = "scan", .run = Context.quality },
        .{ .name = "lengths", .unit = "scan", .run = Context.lengths },
    }, .{ .commit = metadata.commit, .cpu = metadata.cpu, .os = metadata.os }, .{
        .smoke = args.len == 2 and std.mem.eql(u8, args[1], "--smoke"),
        .prefix = if (args.len == 3 and std.mem.eql(u8, args[1], "--row")) args[2] else "",
    });
    try output.interface.flush();
}
