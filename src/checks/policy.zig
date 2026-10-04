const std = @import("std");
const src = @import("source.zig");

pub fn casts(c: *src.Context, sources: []const src.Source, config: src.Value) void {
    const vendored = src.get(config, "vendored");
    if (vendored == .object) {
        var reasons = vendored.object.iterator();
        while (reasons.next()) |entry| {
            if (std.mem.trim(u8, src.string(entry.value_ptr.*, ""), " \t\r\n").len == 0)
                c.fail("vendored: {s} needs provenance and verification", .{entry.key_ptr.*});
        }
    }
    for (sources) |s| {
        if (src.testFile(s.path) or src.get(vendored, s.path) != .null) continue;
        for (s.tree.tokens.items(.tag), 0..) |tag, i| {
            if (tag != .builtin) continue;
            const token: std.zig.Ast.TokenIndex = @intCast(i);
            const name = s.tree.tokenSlice(token);
            if (!isCast(name) or s.inTest(token)) continue;
            if (!safeReason(s.lineText(token)))
                c.fail("{s}:{d}: {s} needs // safe: <reason> on its line", .{ s.path, s.line(token), name });
        }
    }
}

fn isCast(name: []const u8) bool {
    for ([_][]const u8{ "@constCast", "@ptrCast", "@alignCast", "@intFromPtr" }) |cast|
        if (std.mem.eql(u8, cast, name)) return true;
    return false;
}

pub fn safeReason(line: []const u8) bool {
    var quote: ?u8 = null;
    var escaped = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const char = line[i];
        if (quote) |q| {
            if (escaped) escaped = false else if (char == '\\') escaped = true else if (char == q) quote = null;
        } else if (char == '"' or char == '\'') {
            quote = char;
        } else if (char == '/' and i + 1 < line.len and line[i + 1] == '/') {
            const comment = std.mem.trim(u8, line[i + 2 ..], " \t\r");
            return std.mem.startsWith(u8, comment, "safe:") and std.mem.trim(u8, comment[5..], " \t\r").len > 0;
        }
    }
    return false;
}

pub fn lengths(c: *src.Context, sources: []const src.Source, config: src.Value) !void {
    for (sources) |s| {
        if (src.get(src.get(config, "vendored"), s.path) != .null) continue;
        for (s.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .fn_decl) continue;
            const node: std.zig.Ast.Node.Index = @enumFromInt(i);
            var buffer: [1]std.zig.Ast.Node.Index = undefined;
            const proto = s.tree.fullFnProto(&buffer, node).?;
            const name = s.tree.tokenSlice(proto.name_token orelse continue);
            const line = s.line(s.tree.firstToken(node));
            const count = s.line(s.tree.lastToken(node)) - line + 1;
            var limit = src.number(src.get(config, "function_limit"), 120);
            const limits = src.get(config, "function_limits");
            if (limits == .object) {
                var iterator = limits.object.iterator();
                while (iterator.next()) |entry| {
                    if (src.glob(entry.key_ptr.*, s.path)) limit = @min(limit, src.number(entry.value_ptr.*, limit));
                }
            }
            const label = try std.fmt.allocPrint(c.a, "{s}:{s}", .{ s.path, name });
            const exception = src.get(src.get(config, "function_exceptions"), label);
            if (exception != .null) {
                if (std.mem.trim(u8, src.string(src.get(exception, "reason"), ""), " \t\r\n").len == 0 or count > src.number(src.get(exception, "lines"), 0))
                    c.fail("{s}: exception has no reason or grew to {d} lines", .{ label, count });
            } else if (count > limit) c.fail("{s}:{d}: {s} is {d} lines (limit {d})", .{ s.path, line, name, count, limit });
        }
    }
}

pub fn layout(c: *src.Context, sources: []const src.Source, config: src.Value) !void {
    var directories: std.StringHashMap(std.ArrayList([]const u8)) = .init(c.a);
    for (sources) |s| {
        if (src.testFile(s.path) or src.support(s.path, config)) continue;
        const directory = std.fs.path.dirname(s.path) orelse continue;
        const group = try directories.getOrPut(directory);
        if (!group.found_existing) group.value_ptr.* = .empty;
        try group.value_ptr.append(c.a, s.path);
    }
    var iterator = directories.iterator();
    while (iterator.next()) |entry| {
        const directory = entry.key_ptr.*;
        const members = entry.value_ptr.items;
        if (members.len < 2 or rootDirectory(directory, config)) continue;
        const exception = src.get(src.get(config, "layout_exceptions"), directory);
        if (layoutException(members, exception)) continue;
        const parent = std.fs.path.dirname(directory) orelse ".";
        const name = std.fs.path.basename(directory);
        var count: usize = 0;
        for (sources) |s| {
            if (!std.mem.eql(u8, std.fs.path.dirname(s.path) orelse ".", parent)) continue;
            const base = std.fs.path.basename(s.path);
            if (std.ascii.eqlIgnoreCase(base[0 .. base.len - 4], name)) count += 1;
        }
        if (count != 1) c.fail("{s}: namespace has {d} files; give it one adjacent {s}.zig entry", .{ directory, members.len, name });
    }
}

fn rootDirectory(path: []const u8, config: src.Value) bool {
    const roots = src.get(config, "sources");
    if (roots == .null) return std.mem.eql(u8, path, "src");
    for (src.items(roots)) |root| if (std.mem.eql(u8, path, src.string(root, ""))) return true;
    return false;
}

fn layoutException(members: []const []const u8, exception: src.Value) bool {
    if (std.mem.trim(u8, src.string(src.get(exception, "reason"), ""), " \t\r\n").len == 0) return false;
    const allowed = src.items(src.get(exception, "files"));
    if (members.len != allowed.len) return false;
    for (members) |member| {
        var count: usize = 0;
        for (allowed) |item| if (std.mem.eql(u8, member, src.string(item, ""))) {
            count += 1;
        };
        if (count != 1) return false;
    }
    return true;
}

test "cast reasons must be nonempty real comments on the cast line" {
    try std.testing.expect(!safeReason("const p = @ptrCast(\"// safe: hidden\");"));
    try std.testing.expect(!safeReason("const p = @ptrCast(x); // safe: "));
    try std.testing.expect(safeReason("const p = @ptrCast(x); // safe: same representation"));
}

test "casts ignore literals, comments and named or unnamed tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: src.Context = .{ .a = a, .io = std.testing.io };
    const s = try src.Source.parse(a, "src/value.zig", "const x = \"@ptrCast(x)\";\n// @ptrCast(x)\ntest \"cast\" { const p = @ptrCast(x); }\ntest { const p = @alignCast(x); }\n");
    casts(&c, &.{s}, .null);
    try std.testing.expectEqual(@as(usize, 0), c.errors);
}

test "function spans ignore literal braces and exact exceptions cannot grow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: src.Context = .{ .a = a, .io = std.testing.io };
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"function_limit\":3,\"function_exceptions\":{\"src/a.zig:value\":{\"lines\":4,\"reason\":\"dispatch\"}}}", .{})).value;
    const s = try src.Source.parse(a, "src/a.zig", "pub fn value() void {\n const x = \"{\";\n // }\n}\n");
    try lengths(&c, &.{s}, config);
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    const grown = try src.Source.parse(a, "src/a.zig", "fn value() void {\n\n\n\n}\n");
    try lengths(&c, &.{grown}, config);
    try std.testing.expectEqual(@as(usize, 1), c.errors);
}

test "namespace entry is case insensitive, tests and support are excluded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c: src.Context = .{ .a = a, .io = std.testing.io };
    const paths = [_][]const u8{ "src/Namespace/a.zig", "src/Namespace/b.zig", "src/namespace.zig", "src/Other/one.zig", "src/Other/other_test.zig", "src/testing/a.zig", "src/testing/b.zig" };
    var sources: std.ArrayList(src.Source) = .empty;
    for (paths) |path| try sources.append(a, try src.Source.parse(a, path, ""));
    try layout(&c, sources.items, .null);
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    try layout(&c, sources.items[0..2], .null);
    try std.testing.expectEqual(@as(usize, 1), c.errors);
}
