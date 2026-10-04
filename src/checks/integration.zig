const std = @import("std");
const root = @import("test_options").root;

fn fixture(a: std.mem.Allocator, dir: std.Io.Dir) !void {
    const io = std.testing.io;
    for ([_][]const u8{ "src", "ci" }) |path| try dir.createDir(io, path, .default_dir);
    for ([_][]const u8{ "build.zig", "src/sample.zig", "ci/layers.zig", "ci/preflight.json" }) |path| {
        const input = try std.fs.path.join(a, &.{ root, "sample", path });
        defer a.free(input);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, input, a, .limited(1024 * 1024));
        defer a.free(text);
        try dir.writeFile(io, .{ .sub_path = path, .data = text });
    }
    const fixture_root = try dir.realPathFileAlloc(io, ".", a);
    defer a.free(fixture_root);
    const relative = try std.fs.path.relative(a, root, null, fixture_root, root);
    defer a.free(relative);
    const manifest = try std.fmt.allocPrint(a, ".{{ .name = .preflight_sample, .version = \"0.0.0\", .minimum_zig_version = \"0.16.0\", .fingerprint = 0x5460136369dcf618, .paths = .{{ \"\" }}, .dependencies = .{{ .preflight = .{{ .path = \"{f}\" }} }} }}", .{std.zig.fmtString(relative)});
    defer a.free(manifest);
    try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = manifest });
}

fn run(a: std.mem.Allocator, dir: std.Io.Dir) !std.process.RunResult {
    return std.process.run(a, std.testing.io, .{ .argv = &.{ "zig", "build", "check-imports" }, .cwd = .{ .dir = dir } });
}

test "structure runner rejects undeclared imports and duplicate layer owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    const valid = try run(a, tmp.dir);
    if (valid.term != .exited or valid.term.exited != 0) std.debug.print("{s}", .{valid.stderr});
    try std.testing.expect(valid.term == .exited and valid.term.exited == 0);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sample.zig", .data = "const unknown = @import(\"undeclared_fixture\");\n" });
    const unknown = try run(a, tmp.dir);
    try std.testing.expect(unknown.term == .exited and unknown.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, unknown.stderr, "named dependencies") != null);
    try fixtureLayers(a, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sample.zig", .data = "test {}\n" });
    const duplicate = try run(a, tmp.dir);
    try std.testing.expect(duplicate.term == .exited and duplicate.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, duplicate.stderr, "multiple layers") != null);
}

fn fixtureLayers(a: std.mem.Allocator, dir: std.Io.Dir) !void {
    const input = try std.fs.path.join(a, &.{ root, "sample/ci/layers.zig" });
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, input, a, .limited(1024 * 1024));
    const changed = try std.mem.replaceOwned(u8, a, text, "[_][]const u8{\"src/sample.zig\"}", "[_][]const u8{ \"src/sample.zig\", \"src/sample.zig\" }");
    try dir.writeFile(std.testing.io, .{ .sub_path = "ci/layers.zig", .data = changed });
}

test "portable replay records timings and still rejects failed tests and leaked memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sample.zig", .data = "test \"failure\" { return error.DeliberateFailure; }\ntest \"leak\" { _ = try @import(\"std\").testing.allocator.alloc(u8, 1); }\n" });
    const compiled = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci-build", "-Dci-timings=true" }, .cwd = .{ .dir = tmp.dir } });
    if (compiled.term != .exited or compiled.term.exited != 0) std.debug.print("{s}", .{compiled.stderr});
    try std.testing.expect(compiled.term == .exited and compiled.term.exited == 0);
    const executed = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci-run", "-Dci-timings=true" }, .cwd = .{ .dir = tmp.dir } });
    try std.testing.expect(executed.term == .exited and executed.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, executed.stderr, "DeliberateFailure") != null);
    try std.testing.expect(std.mem.indexOf(u8, executed.stderr, "leaked") != null);
    try tmp.dir.access(io, ".zig-cache/preflight-timings", .{});
}

test "hosted output appends to existing records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "output", .data = "kept=yes\n" });
    const output = try tmp.dir.realPathFileAlloc(io, "output", a);
    var env = try std.testing.environ.createMap(a);
    defer env.deinit();
    try env.put("GITHUB_OUTPUT", output);
    _ = env.swapRemove("GITHUB_STEP_SUMMARY");
    const result = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "setup" }, .cwd = .{ .path = root }, .environ_map = &env });
    if (result.term != .exited or result.term.exited != 0) std.debug.print("{s}", .{result.stderr});
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    const text = try tmp.dir.readFileAlloc(io, "output", a, .limited(1024 * 1024));
    try std.testing.expect(std.mem.startsWith(u8, text, "kept=yes\nglobal="));
}
