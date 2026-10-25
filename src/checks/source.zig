const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const gantry = @import("gantry");
const configure = @import("../configure.zig");

pub const Value = std.json.Value;
pub const Context = struct {
    a: std.mem.Allocator,
    io: std.Io,
    dir: ?std.Io.Dir = null,
    errors: usize = 0,
    summary_path: ?[]const u8 = null,
    /// The Zig that runs the configured commands: the one running the build, else the first on PATH.
    zig: []const u8 = "zig",
    /// The environment a child process gets; null passes this process's own.
    environ_map: ?*const std.process.Environ.Map = null,
    /// bay, when the package is developed with it (its manifest has `.dev_dependencies`):
    /// its steps then run as `bay <step>`, and its whole configured build is `bay dev`'s.
    /// Null runs `zig build`.
    bay: ?[]const u8 = null,
    /// Where the reports go instead of stderr until the command knows its outcome:
    /// a passing check writes nothing, since Zig 0.17 shows any stderr of a passing
    /// build step under a "failed command:" line.
    held: ?*std.Io.Writer.Allocating = null,
    /// Findings a check reports without failing: a run with any shows what it held.
    notes: usize = 0,

    /// The command that runs the package's steps: under bay, `bay dev`, the
    /// development build that holds the package and the gate. Never bare `bay
    /// <step>`, where bay's own commands (`install`, `build`, ...) win over a step
    /// of the same name. Without bay, `zig build`.
    pub fn buildCommand(c: Context) []const []const u8 {
        if (c.bay) |bay| return c.a.dupe([]const u8, &.{ bay, "dev" }) catch @panic("OOM");
        return c.a.dupe([]const u8, &.{ c.zig, "build" }) catch @panic("OOM");
    }

    /// bay, when the manifest here declares `.dev_dependencies`: `BAY`, which bay
    /// sets for what it runs; else the one beside this program, as the hosted
    /// toolchain puts it; else the bay on PATH. Null without the field.
    pub fn bayFor(c: Context, environ: *const std.process.Environ.Map) ?[]const u8 {
        if (!c.developedWithBay()) return null;
        if (environ.get("BAY")) |bay| return bay;
        const self = std.process.executableDirPathAlloc(c.io, c.a) catch return "bay";
        const beside = std.Io.Dir.path.join(c.a, &.{ self, if (@import("builtin").target.os.tag == .windows) "bay.exe" else "bay" }) catch @panic("OOM");
        std.Io.Dir.cwd().access(c.io, beside, .{}) catch return "bay";
        return beside;
    }

    /// Whether the manifest here declares `.dev_dependencies`.
    pub fn developedWithBay(c: Context) bool {
        const text = c.read("build.zig.zon") catch return false;
        const source = c.a.dupeSentinel(u8, text, 0) catch @panic("OOM");
        const tree = std.zig.Ast.parse(c.a, source, .{ .mode = .zon }) catch @panic("OOM");
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const fields = (tree.fullStructInit(&buffer, tree.nodeData(.root).node) orelse return false).ast.fields;
        for (fields) |field| {
            if (std.mem.eql(u8, tree.tokenSlice(tree.firstToken(field) - 2), "dev_dependencies")) return true;
        }
        return false;
    }

    // aegis: no-danger: lends the context's directory; the command that opened it closes it
    pub fn directory(c: Context) std.Io.Dir {
        return c.dir orelse .cwd();
    }

    /// Where a child process runs: `dir`, or this process's own directory.
    pub fn childCwd(c: Context) std.process.Child.Cwd {
        return if (c.dir) |dir| .{ .dir = dir } else .inherit;
    }

    /// Writes to stderr, as a command-line tool reports; a failed write loses only the message.
    pub fn report(c: Context, comptime fmt: []const u8, args: anytype) void {
        if (c.held) |held| {
            held.writer.print(fmt, args) catch return;
            return;
        }
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.File.stderr().writerStreaming(c.io, &buffer);
        writer.interface.print(fmt, args) catch return;
        writer.interface.flush() catch return;
    }

    pub fn fail(c: *Context, comptime fmt: []const u8, args: anytype) void {
        c.report(fmt ++ "\n", args);
        c.errors += 1;
    }

    pub fn read(c: Context, path: []const u8) ![]const u8 {
        return aegis.own.readFile(c.io, c.directory(), path, c.a, .fromRaw(64 * 1024 * 1024));
    }

    /// The configuration at `path`, or an empty one when the file does not exist:
    /// every option has a default, so a package needs no file to start.
    pub fn options(c: Context, path: []const u8) !Value {
        if (!try c.exists(path)) return .{ .object = .empty };
        return c.json(path);
    }

    /// The JSON in the file at `path`; a file that holds none is named.
    pub fn json(c: Context, path: []const u8) !Value {
        const parsed = std.json.parseFromSlice(Value, c.a, try c.read(path), .{ .allocate = .alloc_always }) catch |err| {
            if (err != error.OutOfMemory) c.report("{s}: not JSON ({s})\n", .{ path, @errorName(err) });
            return err;
        };
        return parsed.value;
    }

    /// Whether `path` is there. Only its absence is false: a file that is
    /// there and cannot be reached is the error, never "no file", which
    /// would read an unreadable configuration as every default.
    pub fn exists(c: Context, path: []const u8) Io.Dir.AccessError!bool {
        c.directory().access(c.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => |e| return e,
        };
        return true;
    }
};

pub fn get(v: Value, key: []const u8) Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}

/// A value of the wrong type where a configuration names one: refused,
/// never read as the default an absent one gets.
pub const TypeError = error{InvalidConfiguration};

/// The string `v`, or `fallback` when it is absent (`null`).
pub fn string(v: Value, fallback: []const u8) TypeError![]const u8 {
    return switch (v) {
        .string => |text| text,
        .null => fallback,
        else => error.InvalidConfiguration,
    };
}

/// The count `v`, or `fallback` when it is absent (`null`).
pub fn number(v: Value, fallback: usize) TypeError!usize {
    return switch (v) {
        .integer => |n| std.math.cast(usize, n) orelse error.InvalidConfiguration,
        .null => fallback,
        else => error.InvalidConfiguration,
    };
}

/// The array `v`, or none when it is absent (`null`).
pub fn items(v: Value) TypeError![]const Value {
    return switch (v) {
        .array => |list| list.items,
        .null => &.{},
        else => error.InvalidConfiguration,
    };
}

/// The strings of an array; anything else in it is refused.
pub fn strings(a: std.mem.Allocator, v: Value) ![]const []const u8 {
    const listed = try items(v);
    const out = try a.alloc([]const u8, listed.len);
    for (listed, out) |item, *text| text.* = if (item == .string) item.string else return error.ExpectedStrings;
    return out;
}

/// A module of the configured build: where its root file is, and which module
/// each name its code imports leads to (an index into the same list).
pub const BuildModule = struct {
    /// The root file, relative to the repository or absolute; null when the
    /// build generates it.
    root: ?[]const u8,
    imports: []const Binding,
    pub const Binding = struct { name: []const u8, module: usize };
};

/// Test files by name, wherever they sit.
pub const test_files = [_][]const u8{ "*_test.zig", "test_*.zig", "tests.zig" };
/// Test support when `test_support` is not configured.
pub const default_support = [_][]const u8{"src/testing/**"};

/// Test file names are fixed package data; malformed caller patterns are
/// compiled separately by `testCode`.
pub fn testFile(path: []const u8) bool {
    for (test_files) |pattern| if (gantry.rules.matches(pattern, path) catch unreachable) return true; // unreachable: the fixed test file patterns are valid
    return false;
}

/// The shared compiled definition of test code. Every pattern compiles before
/// matching, so an invalid later pattern fails even if an earlier one matches.
pub fn testCode(a: std.mem.Allocator, path: []const u8, config: Value) !bool {
    var globs: gantry.rules.Globs = .{ .arena = a };
    return gantry.rules.anyOf(try globs.list(.path, try testPaths(a, config)), path);
}

/// The patterns `testCode` matches, for gantry's `Options.test_paths`.
pub fn testPaths(a: std.mem.Allocator, config: Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(a, &test_files);
    const patterns = get(config, "test_support");
    if (patterns == .null) try out.appendSlice(a, &default_support) else for (try items(patterns)) |pattern| {
        if (pattern != .string) return error.InvalidTestSupport;
        try out.append(a, pattern.string);
    }
    return out.items;
}

pub const Source = struct {
    path: []const u8,
    text: [:0]const u8,
    tree: std.zig.Ast,

    pub fn parse(a: std.mem.Allocator, path: []const u8, text: []const u8) !Source {
        const z = try a.dupeSentinel(u8, text, 0);
        return .{ .path = path, .text = z, .tree = try std.zig.Ast.parse(a, z, .{ .mode = .zig }) };
    }

    pub fn inTest(s: Source, token: std.zig.Ast.TokenIndex) bool {
        for (s.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .test_decl) continue;
            const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (token >= s.tree.firstToken(node) and token <= s.tree.lastToken(node)) return true;
        }
        return false;
    }

    pub fn hasTests(s: Source) bool {
        for (s.tree.nodes.items(.tag)) |tag| if (tag == .test_decl) return true;
        return false;
    }

    pub fn line(s: Source, token: std.zig.Ast.TokenIndex) usize {
        const offset = s.tree.tokens.items(.start)[token];
        return 1 + std.mem.count(u8, s.text[0..offset], "\n");
    }

    pub fn lineText(s: Source, token: std.zig.Ast.TokenIndex) []const u8 {
        const offset = s.tree.tokens.items(.start)[token];
        const begin = if (std.mem.findScalarLast(u8, s.text[0..offset], '\n')) |n| n + 1 else 0;
        const end = if (std.mem.findScalarPos(u8, s.text, offset, '\n')) |n| n else s.text.len;
        return s.text[begin..end];
    }
};

/// The source directories `sources` names, `src` when it names none: what
/// lint and the structure check both walk.
pub fn roots(a: std.mem.Allocator, config: Value) ![]const []const u8 {
    const named = get(config, "sources");
    if (named == .null) return &.{"src"};
    const out = try a.alloc([]const u8, (try items(named)).len);
    for (try items(named), out) |root, *path| path.* = try string(root, "src");
    return out;
}

pub fn collect(c: Context, config: Value) ![]Source {
    var out: std.ArrayList(Source) = .empty;
    for (try roots(c.a, config)) |root| try collectRoot(c, root, &out);
    std.mem.sort(Source, out.items, {}, struct {
        fn less(_: void, a: Source, b: Source) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less);
    return out.items;
}

/// The directories a repository keeps code in beside what it ships: linted, and followed
/// from the test roots under them, but never part of `sources`, the shipped roots
/// `.paths` must list.
pub const code_directories = [_][]const u8{ "examples", "ci", "conformance", "bench" };

/// Every Zig file under each of `code_directories` that is there, is not a package of its
/// own (a nested build with its own `build.zig.zon`) and is not a source root already.
pub fn collectCode(c: Context, config: Value) ![]Source {
    const shipped = try roots(c.a, config);
    var out: std.ArrayList(Source) = .empty;
    for (code_directories) |directory| {
        if (!try c.exists(directory)) continue;
        if (try c.exists(try std.Io.Dir.path.join(c.a, &.{ directory, "build.zig.zon" }))) continue;
        const listed = for (shipped) |root| {
            if (samePath(root, directory)) break true;
        } else false;
        if (listed) continue;
        try collectRoot(c, directory, &out);
    }
    return out.items;
}

/// Every Zig file under `root`, passing over the directories a build makes.
pub fn collectRoot(c: Context, root: []const u8, out: *std.ArrayList(Source)) !void {
    var dir = try c.directory().openDir(c.io, root, .{ .iterate = true });
    defer dir.close(c.io);
    var walker = try dir.walkSelectively(c.a);
    defer walker.deinit();
    while (try walker.next(c.io)) |entry| {
        if (entry.kind == .directory) {
            if (!configure.generated(entry.basename)) try walker.enter(c.io, entry);
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.Io.Dir.path.join(c.a, &.{ root, entry.path });
        const normalized = try c.a.dupe(u8, path);
        std.mem.replaceScalar(u8, normalized, '\\', '/');
        try out.append(c.a, try Source.parse(c.a, normalized, try c.read(path)));
    }
}

test "parser ignores imports and braces in literals, finds named test blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try Source.parse(arena.allocator(), "fixture.zig", "const x = \"@import(\\\"fake.zig\\\") {\";\n\ntest \"named\" { _ = @ptrCast(x); }\n");
    try std.testing.expect(s.hasTests());
    for (s.tree.tokens.items(.tag), 0..) |tag, i| {
        if (tag == .builtin) try std.testing.expect(s.inTest(@intCast(i)));
    }
    try std.testing.expect(!try gantry.rules.matches("src/*.zig", "ci/a.zig"));
}

test "one dialect: a component star stays in its directory, test code has one definition" {
    try std.testing.expect(!try gantry.rules.matches("src/*", "src/a/b.zig"));
    try std.testing.expect(try gantry.rules.matches("src/**", "src/a/b.zig"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const defaults: Value = .null;
    try std.testing.expect(try testCode(a, "src/deep/x_test.zig", defaults));
    try std.testing.expect(try testCode(a, "src/test_x.zig", defaults));
    try std.testing.expect(try testCode(a, "src/tests.zig", defaults));
    try std.testing.expect(try testCode(a, "src/testing/lfs/transfer.zig", defaults));
    try std.testing.expect(!try testCode(a, "src/testing.zig", defaults));
    try std.testing.expect(!try testCode(a, "src/contest.zig", defaults));
    const flat = (try std.json.parseFromSlice(Value, a, "{\"test_support\":[\"src/testing/*\"]}", .{})).value;
    try std.testing.expect(try testCode(a, "src/testing/clock.zig", flat));
    try std.testing.expect(!try testCode(a, "src/testing/lfs/transfer.zig", flat));
    const patterns = try testPaths(a, flat);
    try std.testing.expectEqual(@as(usize, test_files.len + 1), patterns.len);
    for ([_][]const u8{ "src/a_test.zig", "src/testing/clock.zig", "src/testing/lfs/transfer.zig", "src/a.zig" }) |path| {
        var matched = false;
        for (patterns) |pattern| matched = matched or try gantry.rules.matches(pattern, path);
        try std.testing.expectEqual(try testCode(a, path, flat), matched);
    }
}

test "malformed test support fails even after a matching pattern or with no sources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(Value, a, "{\"test_support\":[\"**\",\"[\"]}", .{})).value;
    try std.testing.expectError(error.InvalidPattern, testCode(a, "src/a.zig", config));
}

/// Two relative paths naming the same file, whichever separator each was written with:
/// the build graph gives Windows paths with `\`, the source walk may give `/`.
pub fn samePath(x: []const u8, y: []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (p != q and !(isSeparator(p) and isSeparator(q))) return false;
    return true;
}

fn isSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

test "a test root matches its source whichever separator either path uses" {
    try std.testing.expect(samePath("src\\zero.zig", "src/zero.zig"));
    try std.testing.expect(samePath("src/zero.zig", "src/zero.zig"));
    try std.testing.expect(!samePath("src/zero.zig", "src/zeros.zig"));
    try std.testing.expect(!samePath("src/a.zig", "src_a.zig"));
}

test "a configuration value of the wrong type is refused; only an absent one takes the default" {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator,
        \\{"compile_step": 3, "name": "x", "count": -1, "list": "a", "none": null}
    , .{});
    defer parsed.deinit();
    const config = parsed.value;
    // Before, `3` ran the default step, `check`.
    try std.testing.expectError(error.InvalidConfiguration, string(get(config, "compile_step"), "check"));
    try std.testing.expectEqualStrings("x", try string(get(config, "name"), ""));
    try std.testing.expectEqualStrings("check", try string(get(config, "absent"), "check"));
    try std.testing.expectEqualStrings("check", try string(get(config, "none"), "check"));
    try std.testing.expectError(error.InvalidConfiguration, number(get(config, "count"), 1));
    try std.testing.expectEqual(@as(usize, 1), try number(get(config, "absent"), 1));
    try std.testing.expectError(error.InvalidConfiguration, items(get(config, "list")));
    try std.testing.expectEqual(@as(usize, 0), (try items(get(config, "absent"))).len);
}

test "a configuration that is there and cannot be read is the error, not every default" {
    const shakedown = @import("shakedown");
    const fio = try shakedown.FaultIo.init(std.testing.allocator, std.testing.io, .{});
    defer fio.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "preflight.json", .data = "{\"compile_step\": \"build\"}" });
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const c: Context = .{ .a = arena.allocator(), .io = fio.io(), .dir = tmp.dir };
    try std.testing.expect(!try c.exists("absent.json"));
    try std.testing.expectEqual(@as(usize, 0), (try c.options("absent.json")).object.count());
    try fio.setPlan(&.{.{ .at = .{ .nth = .{ .call = .dirAccess, .n = 1 } }, .fault = .{ .fail = error.AccessDenied } }});
    // Before, this was an empty configuration: every option at its default.
    try std.testing.expectError(error.AccessDenied, c.options("preflight.json"));
}
