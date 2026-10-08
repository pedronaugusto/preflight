//! Offline caller generation cost. ReleaseFast; parse inputs outside timing,
//! reset a scratch arena between renders. Smoke runs measure nothing useful.
const std = @import("std");
const checks = @import("checks");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const smoke = args.len == 2 and std.mem.eql(u8, args[1], "--smoke");
    const config = (try std.json.parseFromSlice(checks.source.Value, a,
        \\{"compile_once":true,"shards":{"windows":3,"macos":2},"targets":["x86_64-linux-gnu","aarch64-linux-gnu","x86_64-linux-musl","x86_64-windows-gnu","aarch64-windows-gnu","x86_64-macos","aarch64-macos"]}
    , .{})).value;
    var scratch = std.heap.ArenaAllocator.init(init.gpa);
    defer scratch.deinit();
    const rounds: usize = if (smoke) 1 else 1000;
    var bytes: usize = 0;
    const start = std.Io.Clock.awake.now(init.io).nanoseconds;
    for (0..rounds) |_| {
        const text = try checks.workflow.render(scratch.allocator(), config, "9af905ed85cab6dbb19d9431c65ee3f41fbaa74d", ".", false);
        bytes = text.len;
        _ = scratch.reset(.retain_capacity);
    }
    const elapsed = std.Io.Clock.awake.now(init.io).nanoseconds - start;
    var buffer: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try out.interface.print("caller generation: {d:.3} ns/render; {d} bytes; {d} rounds\n", .{ @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(rounds)), bytes, rounds });
    try out.interface.flush();
}
