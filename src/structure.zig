//! Source boundaries. Layer data belongs to this package; graph rules belong to gantry.
const std = @import("std");
const gantry = @import("gantry");
const declared = @import("layers");
const source = @import("checks/source.zig");
const structure = @import("structure/check.zig");

fn keep(_: void, path: []const u8, kind: std.Io.File.Kind) bool {
    if (kind == .directory) return std.mem.eql(u8, path, "src") or std.mem.startsWith(u8, path, "src/");
    return std.mem.startsWith(u8, path, "src/") and std.mem.endsWith(u8, path, ".zig");
}

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var config_path: []const u8 = "ci/preflight.json";
    var audit = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--audit")) {
            audit = true;
        } else if (std.mem.eql(u8, args[index], "--config") and index + 1 < args.len) {
            index += 1;
            config_path = args[index];
        } else return error.UnknownArgument;
    }
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, config_path, a, .limited(64 * 1024 * 1024));
    const config = try std.json.parseFromSliceLeaky(source.Value, a, text, .{});
    const d: structure.Declared = .{
        .layers = declared.layers,
        .required = &declared.required,
        .entries = declared.entries,
        .modules = declared.modules,
        .references = declared.references,
        .owned = if (@hasDecl(declared, "owned")) declared.owned else &.{},
        .test_paths = try source.testPaths(a, config),
    };
    var paths = try gantry.walk(a, init.io, .cwd(), {}, keep);
    defer paths.deinit();
    const reader: gantry.DirReader = .{ .io = init.io, .dir = .cwd() };
    var diagnostic = gantry.ScanDiagnostic.init(a);
    defer diagnostic.deinit();
    var graph = gantry.scanWithDiagnostic(a, paths.items(), reader, gantry.DirReader.read, structure.options(d), &diagnostic) catch |err| {
        if (diagnostic.failure) |failure| std.debug.print("imports: {s}: {s}: {s}\n", .{ failure.path orelse "<scan>", @tagName(failure.phase), @errorName(failure.cause) });
        return err;
    };
    defer graph.deinit();
    var buffer: [4096]u8 = undefined;
    if (audit) {
        var out = std.Io.File.stdout().writer(init.io, &buffer);
        try std.json.Stringify.value(.{ .paths = graph.paths(), .edges = graph.edges(), .references = graph.references() }, .{}, &out.interface);
        try out.interface.writeByte('\n');
        try out.interface.flush();
        return;
    }
    var out = std.Io.File.stderr().writer(init.io, &buffer);
    const problems = try structure.report(a, &graph, d, &out.interface);
    try out.interface.flush();
    if (problems != 0) return error.ImportBoundary;
}
