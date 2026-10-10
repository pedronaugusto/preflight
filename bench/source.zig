//! The code rules over a repository: policy, selection, project assembly,
//! std's parse and lowering, and every selected rule, as one lint step runs them.
const std = @import("std");
const checks = @import("checks");
const measuring = @import("shakedown").bench;
const metadata = @import("preflight_bench_options");
const WorkloadError = error{ OutOfMemory, UnexpectedFindings, CheckFailed };
const Context = struct {
    scratch: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    config: checks.source.Value,
    fn scan(c: *Context, units: u64) WorkloadError!void {
        for (0..units) |_| {
            var context: checks.source.Context = .{ .a = c.scratch.allocator(), .io = c.io, .dir = c.dir };
            checks.glint.check(&context, .{ .gpa = c.gpa, .config = c.config }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CheckFailed,
            };
            if (context.errors != 0) return error.UnexpectedFindings;
            _ = c.scratch.reset(.retain_capacity);
        }
    }
};
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var text: std.Io.Writer.Allocating = .init(a);
    for (0..100) |i| try text.writer.print("pub fn work{d}() void {{\n    const x = 1;\n    _ = x;\n}}\n", .{i});
    const path = ".zig-cache/preflight-bench-source";
    try std.Io.Dir.cwd().createDirPath(init.io, path ++ "/src");
    var dir = try std.Io.Dir.cwd().openDir(init.io, path, .{});
    defer dir.close(init.io);
    try dir.writeFile(init.io, .{ .sub_path = "src/work.zig", .data = text.written() });
    var context: Context = .{
        .scratch = .init(init.gpa),
        .gpa = init.gpa,
        .io = init.io,
        .dir = dir,
        .config = (try std.json.parseFromSlice(checks.source.Value, a, "{\"glint_paths\":[\"src\"],\"function_limits\":{\"src/**\":120}}", .{})).value,
    };
    defer context.scratch.deinit();
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try measuring.run(WorkloadError, init.gpa, init.io, &output.interface, &context, &.{
        .{ .name = "glint", .unit = "scan", .run = Context.scan },
    }, .{ .commit = metadata.commit, .cpu = metadata.cpu, .os = metadata.os }, .{
        .smoke = args.len == 2 and std.mem.eql(u8, args[1], "--smoke"),
        .prefix = if (args.len == 3 and std.mem.eql(u8, args[1], "--row")) args[2] else "",
    });
    try output.interface.flush();
}
