//! Source-check costs over one namespace with many functions. ReleaseFast;
//! parsing is outside the timed region; `--smoke` executes each row once.
const std = @import("std");
const checks = @import("checks");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const smoke = args.len == 2 and std.mem.eql(u8, args[1], "--smoke");
    var text: std.Io.Writer.Allocating = .init(a);
    for (0..100) |i| try text.writer.print("pub fn work{d}() void {{\n    const x = 1;\n    _ = x;\n}}\n", .{i});
    const source = try checks.source.Source.parse(a, "src/tools/work.zig", text.written());
    const config = (try std.json.parseFromSlice(checks.source.Value, a, "{\"test_support\":[\"src/testing/**\"],\"function_limits\":{\"src/**\":120}}", .{})).value;
    var out_buffer: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &out_buffer);
    for ([_][]const u8{ "quality", "lengths" }) |name| {
        var scratch = std.heap.ArenaAllocator.init(init.gpa);
        defer scratch.deinit();
        var context: checks.source.Context = .{ .a = scratch.allocator(), .io = init.io };
        const start = std.Io.Clock.awake.now(init.io).nanoseconds;
        const rounds: usize = if (smoke) 1 else 1000;
        for (0..rounds) |_| {
            if (std.mem.eql(u8, name, "quality")) {
                const findings = try checks.quality.findings(context.a, &.{source}, config);
                if (findings.len != 0) return error.UnexpectedFindings;
            } else try checks.policy.lengths(&context, &.{source}, config);
            _ = scratch.reset(.retain_capacity);
        }
        const elapsed = std.Io.Clock.awake.now(init.io).nanoseconds - start;
        try out.interface.print("{s}: {d:.3} ns/op\n", .{ name, @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(rounds)) });
    }
    try out.interface.flush();
}
