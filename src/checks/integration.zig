const std = @import("std");
const builtin = @import("builtin");
const root = @import("test_options").root;
const ledger = @import("ledger.zig");
const quality = @import("quality.zig");
const src = @import("source.zig");

fn fixture(a: std.mem.Allocator, dir: std.Io.Dir) !void {
    const io = std.testing.io;
    for ([_][]const u8{ "src/testing", "ci" }) |path| try dir.createDirPath(io, path);
    for ([_][]const u8{ "build.zig", "src/sample.zig", "src/testing/cases.zig", "ci/layers.zig", "ci/preflight.json", "ci/consumer.zig" }) |path| {
        const input = try std.Io.Dir.path.join(a, &.{ root, "sample", path });
        defer a.free(input);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, input, a, .limited(1024 * 1024));
        defer a.free(text);
        try dir.writeFile(io, .{ .sub_path = path, .data = text });
    }
    const fixture_root = try dir.realPathFileAlloc(io, ".", a);
    defer a.free(fixture_root);
    // `root` is the build's path to preflight, relative to where the tests run.
    const package_root = try std.Io.Dir.cwd().realPathFileAlloc(io, root, a);
    defer a.free(package_root);
    const relative = try std.Io.Dir.path.relativeAlloc(a, package_root, null, fixture_root, package_root);
    defer a.free(relative);
    const manifest = try a.print(".{{ .name = .preflight_sample, .version = \"0.0.0\", .minimum_zig_version = \"0.17.0\", .fingerprint = 0x5460136369dcf618, .paths = .{{ \"\" }}, .dependencies = .{{ .preflight = .{{ .path = \"{f}\" }} }} }}", .{std.zig.fmtString(relative)});
    defer a.free(manifest);
    try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = manifest });
}

fn run(a: std.mem.Allocator, dir: std.Io.Dir) !std.process.RunResult {
    return std.process.run(a, std.testing.io, .{ .argv = &.{ "zig", "build", "check-imports" }, .cwd = .{ .dir = dir } });
}

test "structure runner rejects undeclared imports, production reaching tests and duplicate layer owners" {
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
    try std.testing.expect(std.mem.find(u8, unknown.stderr, "named dependencies") != null);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sample.zig", .data = "pub const cases = @import(\"testing/cases.zig\");\n" });
    const reaches = try run(a, tmp.dir);
    try std.testing.expect(reaches.term == .exited and reaches.term.exited != 0);
    try std.testing.expect(std.mem.find(u8, reaches.stderr, "production reaches tests: src/sample.zig -> src/testing/cases.zig") != null);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sample.zig", .data = "test {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ci/preflight.json", .data = "{\"sources\":[\"src\"],\"test_roots\":[\"src/sample.zig\"],\"test_support\":[\"src/other/**\"]}\n" });
    const configured = try run(a, tmp.dir);
    try std.testing.expect(configured.term == .exited and configured.term.exited != 0);
    try std.testing.expect(std.mem.find(u8, configured.stderr, "src/testing/cases.zig: source has no named layer") != null);
    try fixtureLayers(a, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sample.zig", .data = "test {}\n" });
    const duplicate = try run(a, tmp.dir);
    try std.testing.expect(duplicate.term == .exited and duplicate.term.exited != 0);
    try std.testing.expect(std.mem.find(u8, duplicate.stderr, "multiple layers") != null);
}

test "structure runner walks every configured source root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "ci/preflight.json", .data = "{\"sources\":[\"src\",\"lib\"],\"test_roots\":[\"src/sample.zig\"]}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/foo.zig", .data = "pub const helper = @import(\"foo_test.zig\");\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/foo_test.zig", .data = "test {}\n" });
    const input = try std.Io.Dir.path.join(a, &.{ root, "sample/ci/layers.zig" });
    const text = try std.Io.Dir.cwd().readFileAlloc(io, input, a, .limited(1024 * 1024));
    const layered = try std.mem.replaceOwned(u8, a, text, "&.{\"src/sample.zig\"}", "&.{ \"src/sample.zig\", \"lib/foo.zig\" }");
    try std.testing.expect(!std.mem.eql(u8, text, layered));
    try tmp.dir.writeFile(io, .{ .sub_path = "ci/layers.zig", .data = layered });
    const result = try run(a, tmp.dir);
    try std.testing.expect(result.term == .exited and result.term.exited != 0);
    if (std.mem.find(u8, result.stderr, "production reaches tests: lib/foo.zig -> lib/foo_test.zig") == null) std.debug.print("{s}", .{result.stderr});
    try std.testing.expect(std.mem.find(u8, result.stderr, "production reaches tests: lib/foo.zig -> lib/foo_test.zig") != null);
}

fn fixtureLayers(a: std.mem.Allocator, dir: std.Io.Dir) !void {
    const input = try std.Io.Dir.path.join(a, &.{ root, "sample/ci/layers.zig" });
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, input, a, .limited(1024 * 1024));
    const changed = try std.mem.replaceOwned(u8, a, text, ".{ .name = \"sample\", .patterns = &.{\"src/sample.zig\"} }", ".{ .name = \"sample\", .patterns = &.{\"src/sample.zig\"} }, .{ .name = \"again\", .patterns = &.{\"src/*.zig\"} }");
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
    try std.testing.expect(std.mem.find(u8, invalid.stderr, "non-conforming formatting") != null);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sample.zig", .data = "test {}\n" });
    try tmp.dir.createDir(io, "examples", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "examples/value.zig", .data = "pub fn address(ptr: *const u8) usize {\n    return @intFromPtr(ptr);\n}\n" });
    const cast = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "lint" }, .cwd = .{ .dir = tmp.dir } });
    try std.testing.expect(cast.term == .exited and cast.term.exited != 0);
    try std.testing.expect(std.mem.find(u8, cast.stderr, "examples/value.zig:2: @intFromPtr needs // safe:") != null);
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
    try std.testing.expect(std.mem.find(u8, executed.stderr, "DeliberateFailure") != null);
    try std.testing.expect(std.mem.find(u8, executed.stderr, "leaked") != null);
    try std.testing.expect(std.mem.find(u8, executed.stderr, "seed") != null);
    try tmp.dir.access(io, ".zig-cache/preflight-timings", .{});
}

fn lintFixture(a: std.mem.Allocator, dir: std.Io.Dir) !std.process.RunResult {
    const format = try std.process.run(a, std.testing.io, .{ .argv = &.{ "zig", "fmt", "build.zig", "build.zig.zon", "src", "ci" }, .cwd = .{ .dir = dir } });
    if (!ledger.success(format)) return error.FixtureFormatFailed;
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
            const row = (try std.json.parseFromSlice(src.Value, a, line, .{})).value;
            try names.appendSlice(a, src.string(src.get(row, "name"), ""));
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
    if (!ledger.success(native)) std.debug.print("{s}\n", .{native.stderr});
    try std.testing.expect(ledger.success(native));
    const first = try recordedOrder(a, tmp.dir);
    const compile = try std.process.run(a, std.testing.io, .{ .argv = commands[1], .cwd = .{ .dir = tmp.dir }, .environ_map = &env });
    try std.testing.expect(ledger.success(compile));
    try dropExecutable(tmp.dir);
    const replay = try std.process.run(a, std.testing.io, .{ .argv = commands[2], .cwd = .{ .dir = tmp.dir }, .environ_map = &env });
    try std.testing.expect(ledger.success(replay));
    try std.testing.expectEqualStrings(first, try recordedOrder(a, tmp.dir));
    try env.put("PREFLIGHT_TEST_SEED", "43");
    const other = try std.process.run(a, std.testing.io, .{ .argv = commands[2], .cwd = .{ .dir = tmp.dir }, .environ_map = &env });
    try std.testing.expect(ledger.success(other));
    try std.testing.expect(!std.mem.eql(u8, first, try recordedOrder(a, tmp.dir)));
}

/// Takes the permission to run from the compiled test executables, as an
/// artifact download does.
fn dropExecutable(dir: std.Io.Dir) !void {
    if (!std.Io.File.Permissions.has_executable_bit) return;
    const io = std.testing.io;
    var bin = try dir.openDir(io, "zig-out/preflight/bin", .{ .iterate = true });
    defer bin.close(io);
    var entries = bin.iterate();
    while (try entries.next(io)) |entry| {
        const file = try bin.openFile(io, entry.name, .{});
        defer file.close(io);
        try file.setPermissions(io, .fromMode(0o644));
    }
}

fn fixtureGit(a: std.mem.Allocator, dir: std.Io.Dir, args: []const []const u8) !void {
    const argv = try std.mem.concat(a, []const u8, &.{ &.{ "git", "-c", "user.name=Preflight", "-c", "user.email=preflight@example.invalid" }, args });
    const result = try std.process.run(a, std.testing.io, .{ .argv = argv, .cwd = .{ .dir = dir } });
    if (result.term != .exited or result.term.exited != 0) return error.FixtureGitFailed;
}

test "initial adoption requires exact base findings and cannot grow an existing ledger" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, "ci");
    const code = "const std = @import(\"std\");\npub fn work() void {\n    std.debug.print(\"hi\", .{});\n}\n";
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
        "const std = @import(\"std\");\npub fn work() void {\n    std.debug.print(\"hi\", .{});\n}\ntest {}\n",
        "field: u8,\ntest {}\n",
    };
    for (examples, quality.rules) |text, rule| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/sample.zig", .data = text });
        const result = try lintFixture(a, tmp.dir);
        if (std.mem.find(u8, result.stderr, rule) == null) std.debug.print("{s}\n", .{result.stderr});
        try std.testing.expect(result.term == .exited and result.term.exited != 0);
        try std.testing.expect(std.mem.find(u8, result.stderr, rule) != null);
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
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sample.zig", .data = "const std = @import(\"std\");\npub fn work() void {\n    std.debug.print(\"hi\", .{});\n}\ntest {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ci/debug.json", .data = "[{\"rule\":\"debug-print\",\"path\":\"src/sample.zig\",\"source\":\"std.debug.print(\\\"hi\\\", .{});\",\"detail\":\"std.debug.print outside tests and src/testing/\",\"reason\":\"seeded debt\"}]\n" });
    try fixtureGit(a, tmp.dir, &.{ "add", "src", "ci" });
    try fixtureGit(a, tmp.dir, &.{ "commit", "-m", "Add seeded debt" });
    const added = try lintFixture(a, tmp.dir);
    if (std.mem.find(u8, added.stderr, "new exception:") == null) std.debug.print("{s}\n", .{added.stderr});
    try std.testing.expect(added.term == .exited and added.term.exited != 0);
    try std.testing.expect(std.mem.find(u8, added.stderr, "new exception: ledger may only shrink") != null);
    try fixtureGit(a, tmp.dir, &.{ "branch", "-m", "main", "old-main" });
    try fixtureGit(a, tmp.dir, &.{ "branch", "-m", "main" });
    const accepted = try lintFixture(a, tmp.dir);
    try std.testing.expect(accepted.term == .exited and accepted.term.exited == 0);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sample.zig", .data = "test {}\n" });
    const stale = try lintFixture(a, tmp.dir);
    try std.testing.expect(stale.term == .exited and stale.term.exited != 0);
    try std.testing.expect(std.mem.find(u8, stale.stderr, "stale exception: remove it") != null);
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

/// Test names recorded in timing files whose names end with `suffix`.
fn recordedNames(a: std.mem.Allocator, dir: std.Io.Dir, suffix: []const u8) ![]const []const u8 {
    var timings = try dir.openDir(std.testing.io, ".zig-cache/preflight-timings", .{ .iterate = true });
    defer timings.close(std.testing.io);
    var iterator = timings.iterate();
    var names: std.ArrayList([]const u8) = .empty;
    while (try iterator.next(std.testing.io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        const text = try timings.readFileAlloc(std.testing.io, entry.name, a, .limited(1024 * 1024));
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const row = (try std.json.parseFromSlice(src.Value, a, line, .{})).value;
            try names.append(a, try a.dupe(u8, src.string(src.get(row, "name"), "")));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return names.items;
}

test "shards split the tests once between them by recorded duration, natively and in portable replay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    var text: std.Io.Writer.Allocating = .init(a);
    for (0..12) |i| try text.writer.print("test \"case-{d}\" {{}}\n", .{i});
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sample.zig", .data = text.written() });
    var env = try std.testing.environ.createMap(a);
    defer env.deinit();
    _ = env.swapRemove("PREFLIGHT_SHARD");
    const whole = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci", "-Dci-lint=false", "-Dci-timings=true" }, .cwd = .{ .dir = tmp.dir }, .environ_map = &env });
    if (!ledger.success(whole)) std.debug.print("{s}\n", .{whole.stderr});
    try std.testing.expect(ledger.success(whole));
    const all = try recordedNames(a, tmp.dir, "-all.ndjson");
    try std.testing.expectEqual(@as(usize, 12), all.len);
    // One test outweighs the rest together, so its shard runs it alone.
    var heavy: []const u8 = "";
    var durations: std.Io.Writer.Allocating = .init(a);
    try durations.writer.print("{{\"keys\":[\"{s}-debug\"],\"tests\":{{", .{@tagName(builtin.os.tag)});
    for (all, 0..) |name, i| {
        if (std.mem.endsWith(u8, name, "case-0")) heavy = name;
        try durations.writer.print("{s}{f}:[{d}]", .{ if (i == 0) "" else ",", std.json.fmt(name, .{}), @as(u32, if (std.mem.endsWith(u8, name, "case-0")) 100 else 1) });
    }
    try durations.writer.writeAll("}}");
    try tmp.dir.writeFile(io, .{ .sub_path = "ci/durations.json", .data = durations.written() });
    var seen: std.ArrayList([]const u8) = .empty;
    var native: [3][]const []const u8 = undefined;
    for (&native, 1..) |*names, shard| {
        try env.put("PREFLIGHT_SHARD", try a.print("{d}/3", .{shard}));
        const result = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci", "-Dci-lint=false", "-Dci-timings=true" }, .cwd = .{ .dir = tmp.dir }, .environ_map = &env });
        if (!ledger.success(result)) std.debug.print("{s}\n", .{result.stderr});
        try std.testing.expect(ledger.success(result));
        names.* = try recordedNames(a, tmp.dir, try a.print("-{d}of3.ndjson", .{shard}));
        try seen.appendSlice(a, names.*);
        for (names.*) |name| if (std.mem.eql(u8, name, heavy)) try std.testing.expectEqual(@as(usize, 1), names.len);
    }
    std.mem.sort([]const u8, seen.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    try std.testing.expectEqual(all.len, seen.items.len);
    for (all, seen.items) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    _ = env.swapRemove("PREFLIGHT_SHARD");
    const compiled = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci-build", "-Dci-timings=true" }, .cwd = .{ .dir = tmp.dir }, .environ_map = &env });
    try std.testing.expect(ledger.success(compiled));
    try env.put("PREFLIGHT_SHARD", "2/3");
    const replay = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci-run", "-Dci-timings=true" }, .cwd = .{ .dir = tmp.dir }, .environ_map = &env });
    if (!ledger.success(replay)) std.debug.print("{s}\n", .{replay.stderr});
    try std.testing.expect(ledger.success(replay));
    const replayed = try recordedNames(a, tmp.dir, "-2of3.ndjson");
    try std.testing.expectEqual(native[1].len, replayed.len);
    for (native[1], replayed) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
}

test "the watchdog fails a stalled test by name and phase" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    const script = try tmp.dir.readFileAlloc(io, "build.zig", a, .limited(1024 * 1024));
    const bounded = try std.mem.replaceOwned(u8, a, script, ".portable_tests = true", ".portable_tests = true, .test_timeout = .{ .bound = .{ .limit = .fromMilliseconds(300), .reason = \"a stall test\" } }");
    try std.testing.expect(!std.mem.eql(u8, script, bounded));
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = bounded });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sample.zig", .data = "const std = @import(\"std\");\ntest \"stalls\" {\n    try std.Io.sleep(std.testing.io, .fromSeconds(30), .awake);\n}\n" });
    const stalled = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci", "-Dci-lint=false" }, .cwd = .{ .dir = tmp.dir } });
    try std.testing.expect(!ledger.success(stalled));
    try std.testing.expect(std.mem.find(u8, stalled.stderr, "preflight: watchdog: ") != null);
    try std.testing.expect(std.mem.find(u8, stalled.stderr, "stalls exceeded 300 ms; phase body") != null);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sample.zig", .data = "test \"quick\" {}\n" });
    const quick = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci", "-Dci-lint=false" }, .cwd = .{ .dir = tmp.dir } });
    if (!ledger.success(quick)) std.debug.print("{s}\n", .{quick.stderr});
    try std.testing.expect(ledger.success(quick));
}

test "the consumer check builds the package as a dependency with nothing fetched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    const built = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "check-consumer" }, .cwd = .{ .dir = tmp.dir } });
    if (!ledger.success(built)) std.debug.print("{s}\n", .{built.stderr});
    try std.testing.expect(ledger.success(built));
    try tmp.dir.writeFile(io, .{ .sub_path = "ci/consumer.zig", .data = "const sample = @import(\"preflight_sample\");\npub fn main() void {\n    _ = sample.missing;\n}\n" });
    const broken = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "check-consumer" }, .cwd = .{ .dir = tmp.dir } });
    try std.testing.expect(!ledger.success(broken));
    try std.testing.expect(std.mem.find(u8, broken.stderr, "no member named 'missing'") != null);
}

fn edit(a: std.mem.Allocator, dir: std.Io.Dir, path: []const u8, from: []const u8, to: []const u8) !void {
    const io = std.testing.io;
    const text = try dir.readFileAlloc(io, path, a, .limited(1024 * 1024));
    const changed = try std.mem.replaceOwned(u8, a, text, from, to);
    try std.testing.expect(!std.mem.eql(u8, text, changed));
    try dir.writeFile(io, .{ .sub_path = path, .data = changed });
}

fn gate(a: std.mem.Allocator, dir: std.Io.Dir, extra: []const []const u8) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "zig", "build", "ci", "-Dci-lint=false" });
    try argv.appendSlice(a, extra);
    return std.process.run(a, std.testing.io, .{ .argv = argv.items, .cwd = .{ .dir = dir } });
}

test "a test runner of its own fails by name while the watchdog is on or the tests are sharded, a single-threaded build while the watchdog is on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    const tests = "const tests = b.addTest(.{ .root_module = module });\n";
    try edit(a, tmp.dir, "build.zig", tests, tests ++ "    tests.test_runner = .{ .path = b.graph.path(.zig_lib, \"compiler/test_runner.zig\"), .mode = .server };\n");
    const own = try gate(a, tmp.dir, &.{});
    try std.testing.expect(!ledger.success(own));
    try std.testing.expect(std.mem.find(u8, own.stderr, "test: a test runner of its own arms no watchdog") != null);
    try edit(a, tmp.dir, "build.zig", ".portable_tests = true", ".portable_tests = true, .test_timeout = .{ .off = \"the upstream runner\" }");
    const off = try gate(a, tmp.dir, &.{});
    if (!ledger.success(off)) std.debug.print("{s}\n", .{off.stderr});
    try std.testing.expect(ledger.success(off));
    // The shard is read when the tests run, so the same configuration refuses it.
    var env = try std.testing.environ.createMap(a);
    defer env.deinit();
    try env.put("PREFLIGHT_SHARD", "1/2");
    const sharded = try std.process.run(a, std.testing.io, .{ .argv = &.{ "zig", "build", "ci", "-Dci-lint=false" }, .cwd = .{ .dir = tmp.dir }, .environ_map = &env });
    try std.testing.expect(!ledger.success(sharded));
    try std.testing.expect(std.mem.find(u8, sharded.stderr, "test: a test runner of its own runs every shard's tests") != null);
    try fixture(a, tmp.dir);
    try edit(a, tmp.dir, "build.zig", ".optimize = optimize,\n    });", ".optimize = optimize,\n        .single_threaded = true,\n    });");
    const single = try gate(a, tmp.dir, &.{});
    try std.testing.expect(!ledger.success(single));
    try std.testing.expect(std.mem.find(u8, single.stderr, "test: a single-threaded build has no watchdog") != null);
}

test "the test log level is a preflight option" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/sample.zig", .data = "const std = @import(\"std\");\ntest \"logs\" {\n    std.log.info(\"preflight-log-marker\", .{});\n}\n" });
    const quiet = try gate(a, tmp.dir, &.{});
    try std.testing.expect(ledger.success(quiet));
    try std.testing.expect(std.mem.find(u8, quiet.stderr, "preflight-log-marker") == null);
    try edit(a, tmp.dir, "build.zig", ".portable_tests = true", ".portable_tests = true, .test_log_level = .info");
    const loud = try gate(a, tmp.dir, &.{});
    try std.testing.expect(ledger.success(loud));
    try std.testing.expect(std.mem.find(u8, loud.stderr, "preflight-log-marker") != null);
}

test "timing records of two test runs with one name stay apart" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    const run_line = "step.dependOn(&b.addRunArtifact(tests).step);\n";
    // A second module whose test artifact takes the same default name, and a
    // run that shares the first module and so its record.
    const second = "    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(\"src/sample.zig\"), .target = target, .optimize = optimize }) })).step);\n";
    const shared = "    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);\n";
    try edit(a, tmp.dir, "build.zig", run_line, run_line ++ second ++ shared);
    const result = try gate(a, tmp.dir, &.{"-Dci-timings=true"});
    if (!ledger.success(result)) std.debug.print("{s}\n", .{result.stderr});
    try std.testing.expect(ledger.success(result));
    var dir = try tmp.dir.openDir(io, ".zig-cache/preflight-timings", .{ .iterate = true });
    defer dir.close(io);
    var files: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".ndjson")) files += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), files);
}
