const std = @import("std");
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

    pub fn directory(c: Context) std.Io.Dir {
        return c.dir orelse .cwd();
    }

    /// Where a child process runs: `dir`, or this process's own directory.
    pub fn childCwd(c: Context) std.process.Child.Cwd {
        return if (c.dir) |dir| .{ .dir = dir } else .inherit;
    }

    /// Writes to stderr, as a command-line tool reports; a failed write loses only the message.
    pub fn report(c: Context, comptime fmt: []const u8, args: anytype) void {
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
        return c.directory().readFileAlloc(c.io, path, c.a, .limited(64 * 1024 * 1024));
    }

    pub fn json(c: Context, path: []const u8) !Value {
        return (try std.json.parseFromSlice(Value, c.a, try c.read(path), .{ .allocate = .alloc_always })).value;
    }

    pub fn exists(c: Context, path: []const u8) bool {
        c.directory().access(c.io, path, .{}) catch return false;
        return true;
    }
};

pub fn get(v: Value, key: []const u8) Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}

pub fn string(v: Value, fallback: []const u8) []const u8 {
    return if (v == .string) v.string else fallback;
}

pub fn number(v: Value, fallback: usize) usize {
    return if (v == .integer and v.integer >= 0) @intCast(v.integer) else fallback;
}

pub fn items(v: Value) []const Value {
    return if (v == .array) v.array.items else &.{};
}

/// The strings of an array; anything else in it is refused.
pub fn strings(a: std.mem.Allocator, v: Value) ![]const []const u8 {
    const out = try a.alloc([]const u8, items(v).len);
    for (items(v), out) |item, *text| text.* = if (item == .string) item.string else return error.ExpectedStrings;
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
    if (patterns == .null) try out.appendSlice(a, &default_support) else for (items(patterns)) |pattern| {
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
    const out = try a.alloc([]const u8, items(named).len);
    for (items(named), out) |root, *path| path.* = string(root, "src");
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
