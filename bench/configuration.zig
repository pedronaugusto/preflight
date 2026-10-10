//! Cost of the compiler's trusted loader and the bounded adapter on the same real graph.
const std = @import("std");
const facts = @import("facts");
const configuration = facts.configuration;
const measuring = @import("shakedown").bench;
const metadata = @import("preflight_bench_options");
const WorkloadError = error{ EndOfStream, OutOfMemory, ReadFailed, ConfigurationBudget, MalformedConfiguration, EmptyConfiguration };
const Context = struct {
    scratch: std.heap.ArenaAllocator,
    bytes: []const u8,
    steps: usize = 0,
    fn trusted(c: *Context, units: u64) WorkloadError!void {
        for (0..units) |_| {
            var reader = std.Io.Reader.fixed(c.bytes);
            const graph = try std.Build.Configuration.load(c.scratch.allocator(), &reader);
            std.mem.doNotOptimizeAway(graph);
            c.steps = graph.steps.len;
            _ = c.scratch.reset(.retain_capacity);
        }
        if (c.steps == 0) return error.EmptyConfiguration;
    }
    fn bounded(c: *Context, units: u64) WorkloadError!void {
        for (0..units) |_| {
            const graph = try configuration.load(c.scratch.allocator(), c.bytes);
            std.mem.doNotOptimizeAway(graph);
            c.steps = graph.steps.len;
            _ = c.scratch.reset(.retain_capacity);
        }
        if (c.steps == 0) return error.EmptyConfiguration;
    }
};
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var root = try std.Io.Dir.cwd().openDir(init.io, metadata.root, .{});
    defer root.close(init.io);
    const snapshot = try facts.read(.{ .a = a, .io = init.io, .dir = root }, metadata.zig, &.{"-Dci-bench-smoke=false"});
    var c: Context = .{ .scratch = .init(init.gpa), .bytes = snapshot.bytes };
    defer c.scratch.deinit();
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try measuring.run(WorkloadError, init.gpa, init.io, &writer.interface, &c, &.{
        .{ .name = "compiler trusted configuration load", .unit = "graph", .run = Context.trusted },
        .{ .name = "bounded configuration load", .unit = "graph", .run = Context.bounded },
    }, .{ .commit = metadata.commit, .cpu = metadata.cpu, .os = metadata.os }, .{
        .smoke = args.len == 2 and std.mem.eql(u8, args[1], "--smoke"),
        .prefix = if (args.len == 3 and std.mem.eql(u8, args[1], "--row")) args[2] else "",
    });
    try writer.interface.flush();
}
