const std = @import("std");
const builtin = @import("builtin");
const root = @import("test_options").root;
const ledger = @import("ledger.zig");
const quality = @import("quality.zig");
const src = @import("source.zig");
const paths = @import("paths.zig");

fn fixture(a: std.mem.Allocator, dir: std.Io.Dir) !void {
    const io = std.testing.io;
    for ([_][]const u8{ "src/testing", "ci" }) |path| try dir.createDirPath(io, path);
    for ([_][]const u8{ "build.zig", "src/sample.zig", "src/testing/cases.zig", "src/testing/hardened.zig", "ci/layers.zig", "ci/preflight.json", "ci/consumer.zig", "LICENSE", "README.md", "CHANGELOG.md" }) |path| {
        const input = try std.Io.Dir.path.join(a, &.{ root, "sample", path });
        defer a.free(input);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, input, a, .limited(1024 * 1024));
        defer a.free(text);
        const copied = if (std.mem.eql(u8, path, "build.zig")) try std.mem.replaceOwned(u8, a, text, ".bench = sampleBench(target, optimize),", "") else text;
        try dir.writeFile(io, .{ .sub_path = path, .data = copied });
    }
    const fixture_root = try dir.realPathFileAlloc(io, ".", a);
    defer a.free(fixture_root);
    // `root` is the build's path to preflight, relative to where the tests run.
    const package_root = try std.Io.Dir.cwd().realPathFileAlloc(io, root, a);
    defer a.free(package_root);
    const relative = try std.Io.Dir.path.relativeAlloc(a, package_root, null, fixture_root, package_root);
    defer a.free(relative);
    const manifest = try a.print(".{{ .name = .preflight_sample, .version = \"0.0.0\", .minimum_zig_version = \"0.17.0\", .fingerprint = 0x5460136369dcf618, .paths = .{{ \"build.zig\", \"build.zig.zon\", \"src\", \"LICENSE\", \"README.md\", \"CHANGELOG.md\" }}, .dependencies = .{{ .preflight = .{{ .path = \"{f}\" }} }} }}", .{std.zig.fmtString(relative)});
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
    // A build of its own under a checked directory, such as a conformance
    // build with a manifest of its own, keeps its packages and outputs beside
    // it: neither is the repository's source, to format or to read for casts.
    const foreign = "pub fn address(ptr: *const u8) usize {\nreturn @intFromPtr(ptr);\n}\n";
    for ([_][]const u8{ "conformance/zig-pkg/third-party", "conformance/zig-out/generated", "conformance/.zig-cache/o" }) |path| {
        try tmp.dir.createDirPath(io, path);
        try tmp.dir.writeFile(io, .{ .sub_path = try std.Io.Dir.path.join(a, &.{ path, "value.zig" }), .data = foreign });
    }
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
    try withoutUserGit(&env);
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

/// Keeps the user's and the system's git configuration out of a test's
/// git: no hook, signing key or alias of theirs runs on a fixture.
fn withoutUserGit(env: *std.process.Environ.Map) !void {
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
}

fn fixtureGit(a: std.mem.Allocator, dir: std.Io.Dir, args: []const []const u8) !void {
    const argv = try std.mem.concat(a, []const u8, &.{ &.{ "git", "-c", "user.name=Preflight", "-c", "user.email=preflight@example.invalid" }, args });
    var env = try std.testing.environ.createMap(a);
    defer env.deinit();
    try withoutUserGit(&env);
    const result = try std.process.run(a, std.testing.io, .{ .argv = argv, .cwd = .{ .dir = dir }, .environ_map = &env });
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
    var env = try std.testing.environ.createMap(a);
    try withoutUserGit(&env);
    var c: src.Context = .{ .a = a, .io = io, .dir = tmp.dir, .ledger_base = "main", .adopt = true, .environ_map = &env };
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
        "const std = @import(\"std\");\npub fn old() ?usize { return std.mem.indexOfScalar(u8, \"x\", 'x'); }\ntest {}\n",
    };
    for (examples, quality.rules ++ [_][]const u8{ "Z009", "Z011" }) |text, rule| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/sample.zig", .data = text });
        const result = try lintFixture(a, tmp.dir);
        if (std.mem.find(u8, result.stderr, rule) == null) std.debug.print("{s}\n", .{result.stderr});
        try std.testing.expect(result.term == .exited and result.term.exited != 0);
        try std.testing.expect(std.mem.find(u8, result.stderr, rule) != null);
        try std.testing.expect(std.mem.find(u8, result.stderr, "file-name-case") == null);
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
    try durations.writer.print("{{\"keys\":[\"{s}-debug\"],\"tests\":{{", .{@tagName(builtin.target.os.tag)});
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

test "a test run with an environment of the build's fails by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    // Zig 0.17 bakes the whole environment into the run's cached
    // configuration, where a later shard or another tool path finds it stale.
    try edit(a, tmp.dir, "build.zig", "step.dependOn(&b.addRunArtifact(tests).step);", "const run_tests = b.addRunArtifact(tests);\n    run_tests.setEnvironmentVariable(\"SAMPLE_TOOL\", \"1\");\n    step.dependOn(&run_tests.step);");
    const result = try gate(a, tmp.dir, &.{});
    try std.testing.expect(!ledger.success(result));
    try std.testing.expect(std.mem.find(u8, result.stderr, "test: a test run carries no environment of the build's") != null);
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

test "a dispatched run compares the branch with main, so a docs-only last commit keeps the gate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "upstream/src");
    var upstream = try tmp.dir.openDir(io, "upstream", .{});
    defer upstream.close(io);
    try upstream.writeFile(io, .{ .sub_path = "src/value.zig", .data = "pub const x = 1;\n" });
    try fixtureGit(a, upstream, &.{ "init", "-b", "main" });
    try fixtureGit(a, upstream, &.{ "add", "src" });
    try fixtureGit(a, upstream, &.{ "commit", "-m", "Main" });
    try fixtureGit(a, tmp.dir, &.{ "clone", "-q", "upstream", "work" });
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try fixtureGit(a, work, &.{ "switch", "-c", "wave" });
    try work.writeFile(io, .{ .sub_path = "src/value.zig", .data = "pub const x = 2;\n" });
    try fixtureGit(a, work, &.{ "commit", "-am", "Code" });
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "# value\n" });
    try fixtureGit(a, work, &.{ "add", "README.md" });
    try fixtureGit(a, work, &.{ "commit", "-m", "Docs" });
    var env = try std.testing.environ.createMap(a);
    try withoutUserGit(&env);
    const c: src.Context = .{ .a = a, .io = io, .dir = work, .environ_map = &env };
    // The last commit alone is documentation; the branch is not.
    try std.testing.expect(try paths.run(c, "HEAD^"));
    try std.testing.expect(!try paths.run(c, null));
    try fixtureGit(a, work, &.{ "switch", "-c", "notes", "origin/main" });
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "# notes\n" });
    try fixtureGit(a, work, &.{ "add", "README.md" });
    try fixtureGit(a, work, &.{ "commit", "-m", "Notes" });
    try std.testing.expect(try paths.run(c, null));
    try std.testing.expect(!try paths.run(c, "no-such-base"));
}

test "structure runner reads the namespaces' re-exports from ci/layers.zig" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    const layers = try tmp.dir.readFileAlloc(io, "ci/layers.zig", a, .limited(1024 * 1024));
    const declared = try std.mem.concat(a, u8, &.{ layers, "pub const reexports = .{.{ .from = \"src/sample.zig\", .to = \"src/sample/part.zig\" }};\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ci/layers.zig", .data = declared });
    const stale = try run(a, tmp.dir);
    try std.testing.expect(stale.term == .exited and stale.term.exited != 0);
    try std.testing.expect(std.mem.find(u8, stale.stderr, "imports: reexports: src/sample.zig -> src/sample/part.zig: no such import") != null);
}

const bench_build =
    \\const std = @import("std");
    \\const preflight = @import("preflight");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\    const module = b.addModule("preflight_sample", .{ .root_source_file = b.path("src/sample.zig"), .target = target, .optimize = optimize });
    \\    const step = b.step("test", "Run the sample tests");
    \\    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    \\    preflight.addCi(b, .{ .tests = step, .portable_tests = true, .bench = BENCH });
    \\}
    \\
    \\fn imports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    \\    const module = b.createModule(.{ .root_source_file = b.path("src/sample.zig"), .target = target, .optimize = optimize });
    \\    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "preflight_sample", .module = module }}) catch @panic("OOM");
    \\}
    \\
;

test "the bench contract: ReleaseFast under zig-out/bench, and each program run once by the tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    try tmp.dir.createDirPath(io, "bench");
    const program = "const std = @import(\"std\");\nconst sample = @import(\"preflight_sample\");\npub fn main(init: std.process.Init) !void {\n    const args = try init.minimal.args.toSlice(init.arena.allocator());\n    if (args.len > 1 and !std.mem.eql(u8, args[1], \"--smoke\")) return error.UnknownArgument;\n    _ = sample;\n}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "bench/tick.zig", .data = program });
    // A bench/ directory the build gives no programs fails the tests by name.
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = try std.mem.replaceOwned(u8, a, bench_build, "BENCH", "null") });
    const missing = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "test", "-Dci-lint=false" }, .cwd = .{ .dir = tmp.dir } });
    try std.testing.expect(!ledger.success(missing));
    try std.testing.expect(std.mem.find(u8, missing.stderr, "bench/: give addCi its .bench") != null);
    const given = ".{ .programs = &.{.{ .name = \"tick\", .source = \"bench/tick.zig\" }}, .imports = imports, .target = target, .optimize = optimize }";
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = try std.mem.replaceOwned(u8, a, bench_build, "BENCH", given) });
    const tested = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "test", "-Dci-lint=false" }, .cwd = .{ .dir = tmp.dir } });
    if (!ledger.success(tested)) std.debug.print("{s}\n", .{tested.stderr});
    try std.testing.expect(ledger.success(tested));
    const timed = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "bench" }, .cwd = .{ .dir = tmp.dir } });
    if (!ledger.success(timed)) std.debug.print("{s}\n", .{timed.stderr});
    try std.testing.expect(ledger.success(timed));
    try tmp.dir.access(io, if (builtin.os.tag == .windows) "zig-out/bench/tick.exe" else "zig-out/bench/tick", .{});
    // Compiled once and run elsewhere, the smoke run gets a fresh directory there too.
    const built = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci-build", "-Dci-lint=false" }, .cwd = .{ .dir = tmp.dir } });
    if (!ledger.success(built)) std.debug.print("{s}\n", .{built.stderr});
    try std.testing.expect(ledger.success(built));
    const manifest = try tmp.dir.readFileAlloc(io, "zig-out/preflight/tests.json", a, .limited(1 << 20));
    try std.testing.expect(std.mem.find(u8, manifest, "\"scratch\":true") != null);
    const replayed = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci-run", "-Dci-lint=false" }, .cwd = .{ .dir = tmp.dir } });
    if (!ledger.success(replayed)) std.debug.print("{s}\n", .{replayed.stderr});
    try std.testing.expect(ledger.success(replayed));
    // The tests run the program: one that fails fails them.
    try tmp.dir.writeFile(io, .{ .sub_path = "bench/tick.zig", .data = "pub fn main() !void {\n    return error.Broken;\n}\n" });
    const broken = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "test", "-Dci-lint=false" }, .cwd = .{ .dir = tmp.dir } });
    try std.testing.expect(!ledger.success(broken));
}

test "owner cross objects retain SDK declarations and validate every artifact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    try tmp.dir.createDir(io, "bench", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data =
        \\const std = @import("std");
        \\const preflight = @import("preflight");
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\    const broken = b.option([]const u8, "broken", "artifact to break") orelse "";
        \\    const options = b.addOptions();
        \\    options.addOption([]const u8, "broken", broken);
        \\    const native = b.addLibrary(.{ .name = "native", .linkage = .static, .root_module = b.createModule(.{ .root_source_file = b.path("src/native.zig"), .target = target, .optimize = optimize }) });
        \\    native.root_module.addOptions("options", options);
        \\    const module = b.addModule("preflight_sample", .{ .root_source_file = b.path("src/sample.zig"), .target = target, .optimize = optimize });
        \\    module.addOptions("options", options);
        \\    module.linkLibrary(native);
        \\    if (target.result.os.tag == .macos) {
        \\        module.linkFramework("Security", .{});
        \\        module.linkFramework("CoreFoundation", .{});
        \\    }
        \\    const tests = b.addTest(.{ .root_module = module });
        \\    const helper = b.addExecutable(.{ .name = "helper", .root_module = b.createModule(.{ .root_source_file = b.path("src/helper.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "sample", .module = module }} }) });
        \\    const test_step = b.step("test", "tests and helpers");
        \\    test_step.dependOn(&b.addRunArtifact(tests).step);
        \\    test_step.dependOn(&b.addRunArtifact(helper).step);
        \\    b.step("check", "root").dependOn(&tests.step);
        \\    preflight.addCi(b, .{ .tests = test_step, .bench = .{ .programs = &.{.{ .name = "bench", .source = "bench/main.zig" }}, .imports = imports, .target = target, .optimize = optimize } });
        \\}
        \\fn imports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
        \\    _ = target;
        \\    _ = optimize;
        \\    return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "sample", .module = b.modules.get("preflight_sample").? }}) catch @panic("OOM");
        \\}
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/native.zig", .data = "const std = @import(\"std\");\nconst options = @import(\"options\");\nexport fn nativeValue() u32 { if (comptime std.mem.eql(u8, options.broken, \"native\")) @compileError(\"broken artifact\"); return 7; }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sample.zig", .data =
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\const options = @import("options");
        \\extern fn nativeValue() u32;
        \\extern "c" fn SecCopyErrorMessageString(i32, ?*anyopaque) ?*anyopaque;
        \\extern "c" fn CFRelease(*anyopaque) void;
        \\pub fn value(comptime kind: []const u8) u32 {
        \\    if (comptime std.mem.eql(u8, kind, options.broken)) @compileError("broken artifact");
        \\    if (builtin.os.tag == .macos) {
        \\        if (SecCopyErrorMessageString(0, null)) |message| CFRelease(message);
        \\    }
        \\    return nativeValue();
        \\}
        \\test "SDK link and execution" { try std.testing.expectEqual(@as(u32, 7), value("test")); }
        \\
    });
    for ([_][]const u8{ "src/helper.zig", "bench/main.zig" }, [_][]const u8{ "helper", "bench" }) |path, kind| {
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = try a.print("const sample = @import(\"sample\");\npub fn main() void {{ _ = sample.value(\"{s}\"); }}\n", .{kind}) });
    }
    for ([_][]const u8{ "x86_64-macos", "aarch64-macos", "x86_64-windows-gnu" }) |target| {
        const result = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci-check", try a.print("-Dtarget={s}", .{target}), "-Dcpu=baseline", "-Dci-lint=false" }, .cwd = .{ .dir = tmp.dir } });
        if (result.term != .exited or result.term.exited != 0) std.debug.print("{s}", .{result.stderr});
        try std.testing.expect(result.term == .exited and result.term.exited == 0);
    }
    for ([_][]const u8{ "test", "helper", "bench", "native" }) |kind| {
        const result = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci-check", "-Dtarget=x86_64-macos", "-Dci-lint=false", try a.print("-Dbroken={s}", .{kind}) }, .cwd = .{ .dir = tmp.dir } });
        try std.testing.expect(result.term == .exited and result.term.exited != 0);
        try std.testing.expect(std.mem.find(u8, result.stderr, "broken artifact") != null);
    }
    // The timed ReleaseFast program is a distinct artifact from Debug smoke.
    // A successful smoke compile must not hide an error in that artifact.
    const good_bench = try tmp.dir.readFileAlloc(io, "bench/main.zig", a, .limited(4096));
    try tmp.dir.writeFile(io, .{ .sub_path = "bench/main.zig", .data = "const sample = @import(\"sample\");\nconst builtin = @import(\"builtin\");\npub fn main() void { if (builtin.mode == .fast) @compileError(\"broken fast benchmark\"); _ = sample.value(\"bench\"); }\n" });
    const fast_bench = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci-check", "-Dtarget=x86_64-macos", "-Dci-lint=false" }, .cwd = .{ .dir = tmp.dir } });
    try std.testing.expect(fast_bench.term == .exited and fast_bench.term.exited != 0);
    try std.testing.expect(std.mem.find(u8, fast_bench.stderr, "broken fast benchmark") != null);
    try tmp.dir.writeFile(io, .{ .sub_path = "bench/main.zig", .data = good_bench });
    const native = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci-link", "test", "-Dci-lint=false" }, .cwd = .{ .dir = tmp.dir } });
    if (native.term != .exited or native.term.exited != 0) std.debug.print("{s}", .{native.stderr});
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    var env = try std.testing.environ.createMap(a);
    defer env.deinit();
    if (builtin.os.tag == .macos) {
        if (env.get("SDKROOT")) |sdk| {
            const timed = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "bench", try a.print("-Dci-sdk={s}", .{sdk}), "-Dci-lint=false" }, .cwd = .{ .dir = tmp.dir } });
            if (timed.term != .exited or timed.term.exited != 0) std.debug.print("{s}", .{timed.stderr});
            try std.testing.expect(timed.term == .exited and timed.term.exited == 0);
            const explicit = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci-link", "-Dtarget=x86_64-macos", "-Dcpu=baseline", try a.print("-Dci-sdk={s}", .{sdk}), "-Dci-lint=false" }, .cwd = .{ .dir = tmp.dir } });
            if (explicit.term != .exited or explicit.term.exited != 0) std.debug.print("{s}", .{explicit.stderr});
            try std.testing.expect(explicit.term == .exited and explicit.term.exited == 0);
        }
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "src/native.zig", .data = "export fn wrongNativeSymbol() u32 { return 7; }\n" });
    const unlinked = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci-link", "-Dci-lint=false" }, .cwd = .{ .dir = tmp.dir } });
    try std.testing.expect(unlinked.term == .exited and unlinked.term.exited != 0);
    try std.testing.expect(std.mem.find(u8, unlinked.stderr, "nativeValue") != null);
}

test "owner caller regeneration replaces stale pin without a consumer planner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    try tmp.dir.createDirPath(io, ".github/workflows");
    try tmp.dir.writeFile(io, .{ .sub_path = "ci/workflow.json", .data = "{\"compile_once\":true,\"shards\":{\"macos\":2},\"targets\":[{\"target\":\"x86_64-macos\",\"cpu\":\"baseline\"}]}" });
    const pin = "9af905ed85cab6dbb19d9431c65ee3f41fbaa74d";
    // The fixture's build uses the local dependency. The generator independently
    // reads the declared publication pin, as it does after a consumer's repin.
    try tmp.dir.writeFile(io, .{ .sub_path = "pin.zon", .data = ".{ .dependencies = .{ .preflight = .{ .url = \"git+https://github.com/pedronaugusto/preflight#" ++ pin ++ "\" } } }" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".github/workflows/ci.yml", .data = "old stale pin\n" });
    for (0..2) |index| {
        const result = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "plan", "--", "--workflow", ".github/workflows/ci.yml", "--manifest", "pin.zon" }, .cwd = .{ .dir = tmp.dir } });
        if (result.term != .exited or result.term.exited != 0) std.debug.print("{s}", .{result.stderr});
        try std.testing.expect(result.term == .exited and result.term.exited == 0);
        const text = try tmp.dir.readFileAlloc(io, ".github/workflows/ci.yml", a, .limited(1024 * 1024));
        try std.testing.expect(std.mem.find(u8, text, "uses: pedronaugusto/preflight/.github/workflows/zig.yml@" ++ pin) != null);
        if (index == 0) try tmp.dir.writeFile(io, .{ .sub_path = "first.yml", .data = text }) else try std.testing.expectEqualStrings(try tmp.dir.readFileAlloc(io, "first.yml", a, .limited(1024 * 1024)), text);
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "ci/plan.py", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "ci/plan.zig", .{}));
}

test "toolchain measuring builds without executing and injects shakedown for a consumer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    try tmp.dir.createDir(std.testing.io, "bench", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bench/probe.zig", .data =
        \\const std = @import("std");
        \\const measuring = @import("shakedown").bench;
        \\pub fn main(init: std.process.Init) !void {
        \\    const args = try init.minimal.args.toSlice(init.arena.allocator());
        \\    if (args.len != 2 or !std.mem.eql(u8, args[1], "--smoke")) return error.FullMeasurementMustNotRunInCi;
        \\    _ = measuring.Row(void);
        \\    _ = @import("preflight_bench_options").commit;
        \\}
    });
    const build = try tmp.dir.readFileAlloc(std.testing.io, "build.zig", a, .limited(1024 * 1024));
    const changed = try std.mem.replaceOwned(u8, a, build, ".portable_tests = true", ".portable_tests = true, .bench = .{ .programs = &.{.{ .name = \"probe\", .source = \"bench/probe.zig\" }}, .target = target, .optimize = optimize, .imports = probeImports }");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data = try std.mem.concat(a, u8, &.{
        changed,
        \\fn probeImports(_: *std.Build, _: std.Build.ResolvedTarget, _: std.lang.Optimize) []const std.Build.Module.Import { return &.{}; }
    }) });
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "zig", "build", "bench-build" }, .cwd = .{ .dir = tmp.dir } });
    if (!ledger.success(result)) std.debug.print("{s}", .{result.stderr});
    try std.testing.expect(ledger.success(result));
    const smoke = try std.process.run(a, std.testing.io, .{ .argv = &.{ "zig", "build", "test", "-Dci-lint=false" }, .cwd = .{ .dir = tmp.dir } });
    if (!ledger.success(smoke)) std.debug.print("{s}", .{smoke.stderr});
    try std.testing.expect(ledger.success(smoke));
}

test "toolchain hardened preserves test allocator ownership and detects write after free" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    const build = try tmp.dir.readFileAlloc(std.testing.io, "build.zig", a, .limited(1024 * 1024));
    const changed = try std.mem.replaceOwned(u8, a, build, ".portable_tests = true", ".portable_tests = true");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data = changed });
    const good = try std.process.run(a, std.testing.io, .{ .argv = &.{ "zig", "build", "hardened" }, .cwd = .{ .dir = tmp.dir } });
    if (!ledger.success(good)) std.debug.print("{s}", .{good.stderr});
    try std.testing.expect(ledger.success(good));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/sample.zig", .data =
        \\test "write after free" {
        \\    const a = @import("std").testing.allocator;
        \\    const bytes = try a.alloc(u8, 128);
        \\    a.free(bytes);
        \\    const ptr: *volatile u8 = &bytes[0];
        \\    ptr.* = 42;
        \\}
    });
    const bad = try std.process.run(a, std.testing.io, .{ .argv = &.{ "zig", "build", "hardened" }, .cwd = .{ .dir = tmp.dir } });
    try std.testing.expect(!ledger.success(bad));
    try std.testing.expect(std.mem.find(u8, bad.stderr, "write after free") != null or std.mem.find(u8, bad.stderr, "use after free") != null);
}

test "toolchain facts come from the configured build including options and generated test roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    const build = try tmp.dir.readFileAlloc(std.testing.io, "build.zig", a, .limited(1024 * 1024));
    const generated = try std.mem.replaceOwned(u8, a, build, "const tests = b.addTest(.{ .root_module = module });",
        \\const files = b.addWriteFiles();
        \\const generated_module = b.createModule(.{ .root_source_file = files.add("generated.zig", "test { _ = @import(\"configured_sample\"); }\n"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "configured_sample", .module = module }} });
        \\const tests = b.addTest(.{ .root_module = generated_module });
    );
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data = generated });
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "zig", "build", "facts", "--", "-Doptimize=safe" }, .cwd = .{ .dir = tmp.dir } });
    if (!ledger.success(result)) std.debug.print("{s}", .{result.stderr});
    try std.testing.expect(ledger.success(result));
    try std.testing.expect(std.mem.find(u8, result.stdout, "src/sample.zig") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "safe") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "ci-check") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "configured_sample") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "\"kind\":\"generated\"") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "\"test_roots\"") != null);
}

test "toolchain TSan executes a native consumer and detects an intentional race" {
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    const good = try std.process.run(a, std.testing.io, .{ .argv = &.{ "zig", "build", "hardened-tsan" }, .cwd = .{ .dir = tmp.dir } });
    if (!ledger.success(good)) std.debug.print("{s}", .{good.stderr});
    try std.testing.expect(ledger.success(good));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/testing/hardened.zig", .data =
        \\const std = @import("std");
        \\var go: std.atomic.Value(bool) = .init(false);
        \\var shared: u32 = 0;
        \\fn race() void {
        \\    while (!go.load(.acquire)) std.atomic.spinLoopHint();
        \\    for (0..10000) |_| {
        \\        shared += 1;
        \\        std.mem.doNotOptimizeAway(shared);
        \\    }
        \\}
        \\test "intentional race" {
        \\    const first = try std.Thread.spawn(.{}, race, .{});
        \\    const second = try std.Thread.spawn(.{}, race, .{});
        \\    go.store(true, .release);
        \\    first.join();
        \\    second.join();
        \\}
    });
    const bad = try std.process.run(a, std.testing.io, .{ .argv = &.{ "zig", "build", "hardened-tsan" }, .cwd = .{ .dir = tmp.dir } });
    try std.testing.expect(!ledger.success(bad));
    try std.testing.expect(std.mem.find(u8, bad.stderr, "data race") != null);
}

test "toolchain hosted runner forwards its benchmark control exactly once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ci/workflow.json", .data = "{}" });
    const fixture_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const owner = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, root, a);
    const build = try std.Io.Dir.path.join(a, &.{ owner, "build.zig" });
    var env = try std.testing.environ.createMap(a);
    defer env.deinit();
    try env.put("STEP", "hardened");
    try env.put("BUILD_ARGS", "-Dci-lint=false -Dci-bench-smoke=false");
    try env.put("PREFLIGHT_SETUP", "false");
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "zig", "build", "--build-file", build, try a.print("-Drepo-root={s}", .{fixture_root}), "run" }, .cwd = .{ .dir = tmp.dir }, .environ_map = &env });
    if (!ledger.success(result)) std.debug.print("{s}", .{result.stderr});
    try std.testing.expect(ledger.success(result));
}

test "toolchain canonical sample declares its benchmark artifacts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sample = try std.Io.Dir.path.join(a, &.{ root, "sample" });
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "zig", "build", "bench-build" }, .cwd = .{ .path = sample } });
    if (!ledger.success(result)) std.debug.print("{s}", .{result.stderr});
    try std.testing.expect(ledger.success(result));
}

test "toolchain hardened selects LLVM for the native fuzz rebuild" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    const build = try tmp.dir.readFileAlloc(std.testing.io, "build.zig", a, .limited(1024 * 1024));
    const replacement =
        \\const backend = b.step("backend-proof", "Require LLVM instrumentation for the native fuzz rebuild");
        \\if (tests.use_llvm != true) backend.dependOn(&b.addFail("hardened tests must select LLVM before fuzz instrumentation").step);
        \\preflight.addConsumerCheck(b,
    ;
    const modified = try std.mem.replaceOwned(u8, a, build, "preflight.addConsumerCheck(b,", replacement);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data = modified });
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "zig", "build", "backend-proof", "-Dci-hardened=true" }, .cwd = .{ .dir = tmp.dir } });
    if (!ledger.success(result)) std.debug.print("{s}", .{result.stderr});
    try std.testing.expect(ledger.success(result));
}

test "toolchain cold root declares CI controls before lazy discovery returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var owner = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer owner.close(io);
    for ([_][]const u8{ "build.zig", "build.zig.zon" }) |name| {
        const text = try owner.readFileAlloc(io, name, a, .limited(1024 * 1024));
        const copied = if (std.mem.eql(u8, name, "build.zig.zon"))
            try std.mem.replaceOwned(u8, a, text, "git+https://github.com/pedronaugusto/gantry#3677ee001a89b07060decc817e95b87b9cb29ce9", "file:///preflight-deliberately-missing-lazy-package")
        else
            text;
        const uncached = if (std.mem.eql(u8, name, "build.zig.zon"))
            try std.mem.replaceOwned(u8, a, copied, "gantry-0.1.0-1iNrkTwCDAAGb-z9PfKY87xoFPNpMfdvguhnsUlqngxF", "gantry-0.1.0-1iNrkTxCDAAGb-z9PfKY87xoFPNpMfdvguhnsUlqngxF")
        else
            copied;
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = uncached });
    }
    var sources = try owner.openDir(io, "src", .{ .iterate = true });
    defer sources.close(io);
    var walk = try sources.walk(a);
    defer walk.deinit();
    while (try walk.next(io)) |entry| {
        const dest = try a.print("src/{s}", .{entry.path});
        if (entry.kind == .directory) {
            try tmp.dir.createDirPath(io, dest);
        } else if (entry.kind == .file) {
            try tmp.dir.createDirPath(io, std.Io.Dir.path.dirname(dest).?);
            try tmp.dir.writeFile(io, .{ .sub_path = dest, .data = try sources.readFileAlloc(io, entry.path, a, .limited(1024 * 1024)) });
        }
    }
    // The actual first configurer pass must accept controls before returning
    // for the missing lazy dependency; its subsequent local fetch must fail.
    const result = try std.process.run(a, io, .{
        .argv = &.{ "zig", "build", "-Dci-bench-smoke=false", "-Dci-hardened=false", "-Dci-tsan=false", "-Dci-lint=false" },
        .cwd = .{ .dir = tmp.dir },
    });
    try std.testing.expect(!ledger.success(result));
    if (std.mem.find(u8, result.stderr, "invalid option:") != null) std.debug.print("{s}", .{result.stderr});
    try std.testing.expect(std.mem.find(u8, result.stderr, "invalid option:") == null);
    try std.testing.expect(std.mem.find(u8, result.stderr, "fetching lazy dependency gantry-") != null);
}

test "toolchain caller-owned timing option retains its config override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try fixture(a, tmp.dir);
    const build = try tmp.dir.readFileAlloc(io, "build.zig", a, .limited(1024 * 1024));
    const declared = try std.mem.replaceOwned(u8, a, build, "preflight.addCi(b, .{", "const timing = b.option(bool, \"ci-timings\", \"Caller-owned recording\") orelse false;\n    preflight.addCi(b, .{ .timings_enabled = timing,");
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = declared });
    for ([_][]const u8{ "false", "true" }) |enabled| {
        const result = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "--list-steps", try a.print("-Dci-timings={s}", .{enabled}) }, .cwd = .{ .dir = tmp.dir } });
        if (!ledger.success(result)) std.debug.print("{s}", .{result.stderr});
        try std.testing.expect(ledger.success(result));
    }
}

test "owner cross objects preserve expected compile failure diagnostics without an emitted binary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(a, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data =
        \\const std = @import("std");
        \\const preflight = @import("preflight");
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const accept = b.option(bool, "accept", "unexpectedly accept the rejected input") orelse false;
        \\    const wrong = b.option(bool, "wrong", "emit the wrong diagnostic") orelse false;
        \\    const options = b.addOptions();
        \\    options.addOption(bool, "accept", accept);
        \\    options.addOption([]const u8, "message", if (wrong) "wrong projection diagnostic" else "expected projection diagnostic");
        \\    const step = b.step("test", "expected semantic failures and positive compilation");
        \\    const positives = b.addObject(.{ .name = "positive", .root_module = b.createModule(.{ .root_source_file = b.path("src/positive.zig"), .target = target }) });
        \\    step.dependOn(&positives.step);
        \\    for ([_]std.Build.Step.Compile.Kind{ .obj, .exe, .@"test" }) |kind| {
        \\        const rejected = std.Build.Step.Compile.create(b, .{
        \\            .name = b.fmt("rejected-{t}", .{kind}), .kind = kind,
        \\            .root_module = b.createModule(.{ .root_source_file = b.path("src/rejected.zig"), .target = target }),
        \\        });
        \\        rejected.root_module.addOptions("rejection_options", options);
        \\        rejected.expect_errors = .{ .contains = "expected projection diagnostic" };
        \\        // A semantic failure produces no file for the object/link graph.
        \\        step.dependOn(&rejected.step);
        \\    }
        \\    preflight.addCi(b, .{ .tests = step });
        \\    const projected = b.top_level_steps.get("ci-check").?;
        \\    for (projected.step.dependencies.items) |dependency| {
        \\        const artifact = dependency.cast(std.Build.Step.Compile) orelse continue;
        \\        if (!std.mem.startsWith(u8, artifact.name, "rejected-")) continue;
        \\        if (artifact.expect_errors == null) @panic("projection lost expected diagnostics");
        \\        if (artifact.generated_bin.unwrap() != null) @panic("projection requests a nonexistent failure binary");
        \\    }
        \\}
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/rejected.zig", .data = "const options = @import(\"rejection_options\");\ncomptime { if (!options.accept) @compileError(options.message); }\npub fn main() void {}\ntest {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/positive.zig", .data = "export fn positive() u32 { return 7; }\n" });
    for ([_][]const u8{ "aarch64-linux-musl", "x86_64-macos", "aarch64-macos", "x86_64-windows-gnu", "aarch64-windows-gnu" }) |target| {
        const target_arg = try a.print("-Dtarget={s}", .{target});
        const good = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci-check", target_arg, "-Dcpu=baseline", "-Dci-lint=false" }, .cwd = .{ .dir = tmp.dir } });
        if (!ledger.success(good)) std.debug.print("{s}", .{good.stderr});
        try std.testing.expect(ledger.success(good));
        const wrong = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci-check", target_arg, "-Dcpu=baseline", "-Dci-lint=false", "-Dwrong=true" }, .cwd = .{ .dir = tmp.dir } });
        try std.testing.expect(!ledger.success(wrong));
        try std.testing.expect(std.mem.find(u8, wrong.stderr, "wrong projection diagnostic") != null);
        try std.testing.expect(std.mem.find(u8, wrong.stderr, "should contain") != null);
        const accepted = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci-check", target_arg, "-Dcpu=baseline", "-Dci-lint=false", "-Daccept=true" }, .cwd = .{ .dir = tmp.dir } });
        try std.testing.expect(!ledger.success(accepted));
        try std.testing.expect(std.mem.find(u8, accepted.stderr, "should contain") != null);
    }
    const native = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "ci-link", "-Dci-lint=false" }, .cwd = .{ .dir = tmp.dir } });
    if (!ledger.success(native)) std.debug.print("{s}", .{native.stderr});
    try std.testing.expect(ledger.success(native));
}
