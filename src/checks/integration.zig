const std = @import("std");
const root = @import("test_options").root;

fn fixture(a: std.mem.Allocator, dir: std.Io.Dir) !void {
    const io = std.testing.io;
    for ([_][]const u8{ "src", "ci" }) |path| try dir.createDirPath(io, path);
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

test "format checks owned sources and ignores extracted dependency packages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    const formatted = try std.process.run(a, io, .{ .argv = &.{ "zig", "fmt", "build.zig", "build.zig.zon", "src", "ci" }, .cwd = .{ .dir = tmp.dir } });
    try std.testing.expect(formatted.term == .exited and formatted.term.exited == 0);
    try tmp.dir.createDirPath(io, "zig-pkg/third-party");
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-pkg/third-party/value.zig", .data = "const value=1;\n" });
    const valid = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "lint" }, .cwd = .{ .dir = tmp.dir } });
    if (valid.term != .exited or valid.term.exited != 0) std.debug.print("{s}", .{valid.stderr});
    try std.testing.expect(valid.term == .exited and valid.term.exited == 0);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sample.zig", .data = "test {}\nconst value=1;\n" });
    const invalid = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "lint" }, .cwd = .{ .dir = tmp.dir } });
    try std.testing.expect(invalid.term == .exited and invalid.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, invalid.stderr, "non-conforming formatting") != null);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sample.zig", .data = "test {}\n" });
    try tmp.dir.createDir(io, "examples", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "examples/value.zig", .data = "pub fn address(ptr: *const u8) usize {\n    return @intFromPtr(ptr);\n}\n" });
    const cast = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "lint" }, .cwd = .{ .dir = tmp.dir } });
    try std.testing.expect(cast.term == .exited and cast.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, cast.stderr, "examples/value.zig:2: @intFromPtr needs // safe:") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, executed.stderr, "seed") != null);
    try tmp.dir.access(io, ".zig-cache/preflight-timings", .{});
}

fn lintFixture(a: std.mem.Allocator, dir: std.Io.Dir) !std.process.RunResult {
    const format = try std.process.run(a, std.testing.io, .{ .argv = &.{ "zig", "fmt", "build.zig", "build.zig.zon", "src", "ci" }, .cwd = .{ .dir = dir } });
    if (!@import("ledger.zig").success(format)) return error.FixtureFormatFailed;
    var env = try std.testing.environ.createMap(a);
    defer env.deinit();
    for ([_][]const u8{ "GITHUB_HEAD_REF", "GITHUB_REF_NAME", "GITHUB_BASE_REF", "PREFLIGHT_LEDGER_BASE", "GITHUB_STEP_SUMMARY", "PREFLIGHT_ADOPT" }) |key| _ = env.swapRemove(key);
    return std.process.run(a, std.testing.io, .{ .argv = &.{ "zig", "build", "lint" }, .cwd = .{ .dir = dir }, .environ_map = &env });
}

fn recordedOrder(a: std.mem.Allocator, dir: std.Io.Dir) ![]const u8 {
    var timings = try dir.openDir(std.testing.io, ".zig-cache/preflight-timings", .{ .iterate = true });
    defer timings.close(std.testing.io);
    var iterator = timings.iterate();
    var names: std.ArrayList(u8) = .empty;
    while (try iterator.next(std.testing.io)) |entry| {
        const text = try timings.readFileAlloc(std.testing.io, entry.name, a, .limited(1024 * 1024));
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const row = (try std.json.parseFromSlice(@import("source.zig").Value, a, line, .{})).value;
            try names.appendSlice(a, @import("source.zig").string(@import("source.zig").get(row, "name"), ""));
            try names.append(a, '\n');
        }
    }
    return names.items;
}

test "sample test protocol and portable replay shuffle reproducibly with an explicit seed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    var text: std.Io.Writer.Allocating = .init(a);
    for (0..16) |i| try text.writer.print("test \"order-{d}\" {{}}\n", .{i});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/sample.zig", .data = text.written() });
    var env = try std.testing.environ.createMap(a);
    defer env.deinit();
    const commands = [_][]const []const u8{
        &.{ "zig", "build", "ci", "-Dci-lint=false", "-Dci-timings=true" },
        &.{ "zig", "build", "ci-build", "-Dci-timings=true" },
        &.{ "zig", "build", "ci-run", "-Dci-timings=true" },
    };
    try env.put("PREFLIGHT_TEST_SEED", "42");
    const native = try std.process.run(a, std.testing.io, .{ .argv = commands[0], .cwd = .{ .dir = tmp.dir }, .environ_map = &env });
    if (!@import("ledger.zig").success(native)) std.debug.print("{s}\n", .{native.stderr});
    try std.testing.expect(@import("ledger.zig").success(native));
    const first = try recordedOrder(a, tmp.dir);
    const compile = try std.process.run(a, std.testing.io, .{ .argv = commands[1], .cwd = .{ .dir = tmp.dir }, .environ_map = &env });
    try std.testing.expect(@import("ledger.zig").success(compile));
    const replay = try std.process.run(a, std.testing.io, .{ .argv = commands[2], .cwd = .{ .dir = tmp.dir }, .environ_map = &env });
    try std.testing.expect(@import("ledger.zig").success(replay));
    try std.testing.expectEqualStrings(first, try recordedOrder(a, tmp.dir));
    try env.put("PREFLIGHT_TEST_SEED", "43");
    const other = try std.process.run(a, std.testing.io, .{ .argv = commands[2], .cwd = .{ .dir = tmp.dir }, .environ_map = &env });
    try std.testing.expect(@import("ledger.zig").success(other));
    try std.testing.expect(!std.mem.eql(u8, first, try recordedOrder(a, tmp.dir)));
}

fn fixtureGit(a: std.mem.Allocator, dir: std.Io.Dir, args: []const []const u8) !void {
    const argv = try std.mem.concat(a, []const u8, &.{ &.{ "git", "-c", "user.name=Preflight", "-c", "user.email=preflight@example.invalid" }, args });
    const result = try std.process.run(a, std.testing.io, .{ .argv = argv, .cwd = .{ .dir = dir } });
    if (result.term != .exited or result.term.exited != 0) return error.FixtureGitFailed;
}

test "initial adoption requires exact base findings and cannot grow an existing ledger" {
    const src = @import("source.zig");
    const quality = @import("quality.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, "ci");
    const code = "const std = @import(\"std\");\nfn work() void {\n    std.debug.print(\"hi\", .{});\n}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "src/value.zig", .data = code });
    try fixtureGit(a, tmp.dir, &.{ "init", "-b", "main" });
    try fixtureGit(a, tmp.dir, &.{ "add", "src" });
    try fixtureGit(a, tmp.dir, &.{ "commit", "-m", "Existing source" });
    try fixtureGit(a, tmp.dir, &.{ "switch", "-c", "gate" });
    const debt = "[{\"rule\":\"debug-print\",\"path\":\"src/value.zig\",\"source\":\"std.debug.print(\\\"hi\\\", .{});\",\"detail\":\"std.debug.print outside tests and src/testing/\",\"reason\":\"existing at gate adoption; burned down in the cleanup pass\"}]";
    try tmp.dir.writeFile(io, .{ .sub_path = "ci/debug.json", .data = debt });
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"debug_print_exceptions\":\"ci/debug.json\"}", .{})).value;
    const s = try src.Source.parse(a, "src/value.zig", code);
    var c: src.Context = .{ .a = a, .io = io, .dir = tmp.dir, .ledger_base = "main", .adopt = true };
    try quality.check(&c, &.{s}, config);
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    const changed_code = try std.mem.replaceOwned(u8, a, code, "hi", "new debt");
    const changed_debt = try std.mem.replaceOwned(u8, a, debt, "hi", "new debt");
    try tmp.dir.writeFile(io, .{ .sub_path = "ci/debug.json", .data = changed_debt });
    const changed = try src.Source.parse(a, s.path, changed_code);
    try quality.check(&c, &.{changed}, config);
    try std.testing.expectEqual(@as(usize, 1), c.errors);
    try tmp.dir.writeFile(io, .{ .sub_path = "ci/debug.json", .data = "[]" });
    try fixtureGit(a, tmp.dir, &.{ "switch", "main" });
    try fixtureGit(a, tmp.dir, &.{ "add", "ci/debug.json" });
    try fixtureGit(a, tmp.dir, &.{ "commit", "-m", "Adopt empty ledger" });
    try fixtureGit(a, tmp.dir, &.{ "switch", "gate" });
    try tmp.dir.createDirPath(io, "ci");
    try tmp.dir.writeFile(io, .{ .sub_path = "ci/debug.json", .data = debt });
    try quality.check(&c, &.{s}, config);
    try std.testing.expectEqual(@as(usize, 2), c.errors);
    try tmp.dir.deleteFile(io, "ci/debug.json");
    try fixtureGit(a, tmp.dir, &.{ "switch", "main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ci/debug.json", .data = debt });
    try fixtureGit(a, tmp.dir, &.{ "add", "ci/debug.json" });
    try fixtureGit(a, tmp.dir, &.{ "commit", "-m", "Record existing finding" });
    try fixtureGit(a, tmp.dir, &.{ "switch", "-c", "move" });
    const remainder = try std.mem.replaceOwned(u8, a, code, "    std.debug.print(\"hi\", .{});\n", "");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/value.zig", .data = remainder });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/moved.zig", .data = code });
    const moved_debt = try std.mem.replaceOwned(u8, a, debt, "src/value.zig", "src/moved.zig");
    try tmp.dir.writeFile(io, .{ .sub_path = "ci/debug.json", .data = moved_debt });
    try fixtureGit(a, tmp.dir, &.{ "add", "src", "ci" });
    try fixtureGit(a, tmp.dir, &.{ "commit", "-m", "Move existing code" });
    c.adopt = false;
    const moved = try src.Source.parse(a, "src/moved.zig", code);
    const retained = try src.Source.parse(a, "src/value.zig", remainder);
    try quality.check(&c, &.{ retained, moved }, config);
    try std.testing.expectEqual(@as(usize, 2), c.errors);
}

test "sample rejects each new source rule and passes clean code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    const examples = [_][]const u8{
        "fn work() void {\n    foo() catch unreachable;\n}\ntest {}\n",
        "const std = @import(\"std\");\nfn work() void {\n    std.debug.print(\"hi\", .{});\n}\ntest {}\n",
        "field: u8,\ntest {}\n",
    };
    for (examples, @import("quality.zig").rules) |text, rule| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/sample.zig", .data = text });
        const result = try lintFixture(a, tmp.dir);
        if (std.mem.indexOf(u8, result.stderr, rule) == null) std.debug.print("{s}\n", .{result.stderr});
        try std.testing.expect(result.term == .exited and result.term.exited != 0);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, rule) != null);
    }
    try fixture(a, tmp.dir);
    const clean = try lintFixture(a, tmp.dir);
    try std.testing.expect(clean.term == .exited and clean.term.exited == 0);
}

test "sample branch rejects a newly added exact exception and main rejects stale debt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    try fixtureGit(a, tmp.dir, &.{ "init", "-b", "main" });
    try fixtureGit(a, tmp.dir, &.{ "add", "build.zig", "build.zig.zon", "src", "ci" });
    try fixtureGit(a, tmp.dir, &.{ "commit", "-m", "Clean sample" });
    try fixtureGit(a, tmp.dir, &.{ "switch", "-c", "gate" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ci/preflight.json", .data = "{\"sources\":[\"src\"],\"test_roots\":[\"src/sample.zig\"],\"debug_print_exceptions\":\"ci/debug.json\"}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sample.zig", .data = "const std = @import(\"std\");\nfn work() void {\n    std.debug.print(\"hi\", .{});\n}\ntest {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ci/debug.json", .data = "[{\"rule\":\"debug-print\",\"path\":\"src/sample.zig\",\"source\":\"std.debug.print(\\\"hi\\\", .{});\",\"detail\":\"std.debug.print outside tests and src/testing/\",\"reason\":\"seeded debt\"}]\n" });
    try fixtureGit(a, tmp.dir, &.{ "add", "src", "ci" });
    try fixtureGit(a, tmp.dir, &.{ "commit", "-m", "Add seeded debt" });
    const added = try lintFixture(a, tmp.dir);
    if (std.mem.indexOf(u8, added.stderr, "new exception:") == null) std.debug.print("{s}\n", .{added.stderr});
    try std.testing.expect(added.term == .exited and added.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, added.stderr, "new exception: ledger may only shrink") != null);
    try fixtureGit(a, tmp.dir, &.{ "branch", "-m", "main", "old-main" });
    try fixtureGit(a, tmp.dir, &.{ "branch", "-m", "main" });
    const accepted = try lintFixture(a, tmp.dir);
    try std.testing.expect(accepted.term == .exited and accepted.term.exited == 0);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sample.zig", .data = "test {}\n" });
    const stale = try lintFixture(a, tmp.dir);
    try std.testing.expect(stale.term == .exited and stale.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, stale.stderr, "stale exception: remove it") != null);
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

test "compiled caches never skip a second CI execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sample.zig", .data =
        \\test "runs each time" {
        \\    const std = @import("std");
        \\    const io = std.testing.io;
        \\    const file = try std.Io.Dir.cwd().createFile(io, "executions", .{ .truncate = false, .read = true });
        \\    defer file.close(io);
        \\    var buffer: [32]u8 = undefined;
        \\    var writer = file.writer(io, &buffer);
        \\    writer.pos = (try file.stat(io)).size;
        \\    try writer.interface.writeByte('x');
        \\    try writer.interface.flush();
        \\}
        \\
    });
    const format = try std.process.run(a, io, .{ .argv = &.{ "zig", "fmt", "build.zig", "build.zig.zon", "src", "ci" }, .cwd = .{ .dir = tmp.dir } });
    try std.testing.expect(format.term == .exited and format.term.exited == 0);
    for (0..2) |_| {
        const result = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci" }, .cwd = .{ .dir = tmp.dir } });
        if (result.term != .exited or result.term.exited != 0) std.debug.print("{s}", .{result.stderr});
        try std.testing.expect(result.term == .exited and result.term.exited == 0);
    }
    try std.testing.expectEqualStrings("xx", try tmp.dir.readFileAlloc(io, "executions", a, .limited(32)));
}

test "compile-only test graph builds foreign binaries without executing failing tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/sample.zig", .data = "test \"must not run\" { return error.ExecutedCompileOnlyTest; }\n" });
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "zig", "build", "ci-check", "-Dtarget=x86_64-windows-gnu" }, .cwd = .{ .dir = tmp.dir } });
    if (result.term != .exited or result.term.exited != 0) std.debug.print("{s}", .{result.stderr});
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
}
