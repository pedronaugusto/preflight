//! Offline caller generation; shakedown owns measurement policy and JSONL.
const std = @import("std");
const checks = @import("checks");
const measuring = @import("shakedown").bench;
const metadata = @import("preflight_bench_options");
const Context = struct {
    scratch: std.heap.ArenaAllocator,
    config: checks.source.Value,
    bytes: usize = 0,
    fn generate(c: *Context, units: u64) !void {
        for (0..units) |_| {
            c.bytes = (try checks.workflow.render(c.scratch.allocator(), c.config, "9af905ed85cab6dbb19d9431c65ee3f41fbaa74d", ".", false)).len;
            _ = c.scratch.reset(.retain_capacity);
        }
        if (c.bytes == 0) return error.EmptyCaller;
    }
};
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const config = (try std.json.parseFromSlice(checks.source.Value, a,
        \\{"compile_once":true,"shards":{"windows":3,"macos":2},"targets":["x86_64-linux-gnu","aarch64-linux-gnu","x86_64-linux-musl","x86_64-windows-gnu","aarch64-windows-gnu","x86_64-macos","aarch64-macos"]}
    , .{})).value;
    var context: Context = .{ .scratch = .init(init.gpa), .config = config };
    defer context.scratch.deinit();
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try measuring.run(init.gpa, init.io, &output.interface, &context, &.{.{ .name = "caller generation", .unit = "render", .run = Context.generate }}, .{ .commit = metadata.commit, .cpu = metadata.cpu, .os = metadata.os }, .{
        .smoke = args.len == 2 and std.mem.eql(u8, args[1], "--smoke"),
        .prefix = if (args.len == 3 and std.mem.eql(u8, args[1], "--row")) args[2] else "",
    });
    try output.interface.flush();
}
