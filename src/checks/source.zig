const std = @import("std");
const gantry = @import("gantry");

pub const Value = std.json.Value;
pub const Context = struct {
    a: std.mem.Allocator,
    io: std.Io,
    dir: ?std.Io.Dir = null,
    errors: usize = 0,
    ledger_base: ?[]const u8 = null,
    summary_path: ?[]const u8 = null,
    adopt: bool = false,

    pub fn directory(c: Context) std.Io.Dir {
        return c.dir orelse .cwd();
    }

    pub fn fail(c: *Context, comptime fmt: []const u8, args: anytype) void {
        std.debug.print(fmt ++ "\n", args);
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

/// Path patterns in gantry's dialect: `*` and `?` stay within one component,
/// `**` spans components, and a pattern without `/` matches the basename.
pub fn glob(pattern: []const u8, path: []const u8) bool {
    return gantry.rules.matches(pattern, path);
}

pub fn excluded(path: []const u8, patterns: Value) bool {
    for (items(patterns)) |pattern| if (glob(string(pattern, ""), path)) return true;
    return false;
}

/// Test files by name, wherever they sit.
pub const test_files = [_][]const u8{ "*_test.zig", "test_*.zig", "tests.zig" };
/// Test support when `test_support` is not configured.
pub const default_support = [_][]const u8{"src/testing/**"};

pub fn testFile(path: []const u8) bool {
    for (test_files) |pattern| if (glob(pattern, path)) return true;
    return false;
}

pub fn support(path: []const u8, config: Value) bool {
    const patterns = get(config, "test_support");
    if (patterns != .null) return excluded(path, patterns);
    for (default_support) |pattern| if (glob(pattern, path)) return true;
    return false;
}

/// The one definition of test code, shared by lint and the structure check:
/// a test file by name or a `test_support` file.
pub fn testCode(path: []const u8, config: Value) bool {
    return testFile(path) or support(path, config);
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

pub fn outsideTests(s: Source, config: Value, token: std.zig.Ast.TokenIndex) bool {
    return !testCode(s.path, config) and !s.inTest(token);
}

pub const Source = struct {
    path: []const u8,
    text: [:0]const u8,
    tree: std.zig.Ast,

    pub fn parse(a: std.mem.Allocator, path: []const u8, text: []const u8) !Source {
        const z = try a.dupeZ(u8, text);
        return .{ .path = path, .text = z, .tree = try std.zig.Ast.parse(a, z, .zig) };
    }

    pub fn inTest(s: Source, token: std.zig.Ast.TokenIndex) bool {
        for (s.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .test_decl) continue;
            const node: std.zig.Ast.Node.Index = @enumFromInt(i);
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
        const begin = if (std.mem.lastIndexOfScalar(u8, s.text[0..offset], '\n')) |n| n + 1 else 0;
        const end = if (std.mem.indexOfScalarPos(u8, s.text, offset, '\n')) |n| n else s.text.len;
        return s.text[begin..end];
    }
};

pub fn collect(c: Context, config: Value) ![]Source {
    var out: std.ArrayList(Source) = .empty;
    const roots = get(config, "sources");
    if (roots == .null) try collectRoot(c, "src", &out) else {
        for (items(roots)) |root| try collectRoot(c, string(root, "src"), &out);
    }
    std.mem.sort(Source, out.items, {}, struct {
        fn less(_: void, a: Source, b: Source) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less);
    return out.items;
}

pub fn collectRoot(c: Context, root: []const u8, out: *std.ArrayList(Source)) !void {
    var dir = try c.directory().openDir(c.io, root, .{ .iterate = true });
    defer dir.close(c.io);
    var walker = try dir.walk(c.a);
    defer walker.deinit();
    while (try walker.next(c.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fs.path.join(c.a, &.{ root, entry.path });
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
    try std.testing.expect(!glob("src/*.zig", "ci/a.zig"));
}

test "one dialect: a component star stays in its directory, test code has one definition" {
    try std.testing.expect(!glob("src/*", "src/a/b.zig"));
    try std.testing.expect(glob("src/**", "src/a/b.zig"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const defaults: Value = .null;
    try std.testing.expect(testCode("src/deep/x_test.zig", defaults));
    try std.testing.expect(testCode("src/test_x.zig", defaults));
    try std.testing.expect(testCode("src/tests.zig", defaults));
    try std.testing.expect(testCode("src/testing/lfs/transfer.zig", defaults));
    try std.testing.expect(!testCode("src/testing.zig", defaults));
    try std.testing.expect(!testCode("src/contest.zig", defaults));
    const flat = (try std.json.parseFromSlice(Value, a, "{\"test_support\":[\"src/testing/*\"]}", .{})).value;
    try std.testing.expect(testCode("src/testing/clock.zig", flat));
    try std.testing.expect(!testCode("src/testing/lfs/transfer.zig", flat));
    const patterns = try testPaths(a, flat);
    try std.testing.expectEqual(@as(usize, test_files.len + 1), patterns.len);
    for ([_][]const u8{ "src/a_test.zig", "src/testing/clock.zig", "src/testing/lfs/transfer.zig", "src/a.zig" }) |path| {
        var matched = false;
        for (patterns) |pattern| matched = matched or glob(pattern, path);
        try std.testing.expectEqual(testCode(path, flat), matched);
    }
}
