const std = @import("std");
const src = @import("source.zig");

const Import = struct { token: std.zig.Ast.TokenIndex, target: []const u8, alias: ?[]const u8 };

fn sourceImports(a: std.mem.Allocator, s: src.Source) ![]Import {
    var out: std.ArrayList(Import) = .empty;
    const tags = s.tree.tokens.items(.tag);
    for (tags, 0..) |tag, i| {
        if (tag != .builtin or !std.mem.eql(u8, s.tree.tokenSlice(@intCast(i)), "@import")) continue;
        if (i + 3 >= tags.len or tags[i + 1] != .l_paren or tags[i + 2] != .string_literal or tags[i + 3] != .r_paren) continue;
        const target = try std.zig.string_literal.parseAlloc(a, s.tree.tokenSlice(@intCast(i + 2)));
        if (!std.mem.endsWith(u8, target, ".zig")) continue;
        const alias = if (i >= 3 and tags[i - 3] == .keyword_const and tags[i - 2] == .identifier and tags[i - 1] == .equal)
            s.tree.tokenSlice(@intCast(i - 2))
        else
            null;
        try out.append(a, .{ .token = @intCast(i), .target = target, .alias = alias });
    }
    return out.items;
}

fn aliasUsed(s: src.Source, alias: []const u8) bool {
    for (s.tree.tokens.items(.tag), 0..) |tag, i| {
        if (tag != .identifier or !s.inTest(@intCast(i))) continue;
        const name = s.tree.tokenSlice(@intCast(i));
        if (std.mem.eql(u8, name, alias) or std.mem.eql(u8, name, "refAllDecls") or std.mem.eql(u8, name, "refAllDeclsRecursive")) return true;
    }
    return false;
}

fn resolve(a: std.mem.Allocator, path: []const u8, target: []const u8) ![]const u8 {
    // Resolve dot components lexically without depending on host separators.
    const joined = try std.fmt.allocPrint(a, "{s}/{s}", .{ std.fs.path.dirname(path) orelse ".", target });
    var parts: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.tokenizeAny(u8, joined, "/\\");
    while (iterator.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..") and parts.items.len != 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
            _ = parts.pop();
        } else try parts.append(a, part);
    }
    return std.mem.join(a, "/", parts.items);
}

pub fn check(c: *src.Context, sources: []const src.Source, config: src.Value) !void {
    const roots = src.items(src.get(config, "test_roots"));
    if (roots.len == 0) {
        c.fail("test imports: configure test_roots in ci/preflight.json", .{});
        return;
    }
    var reached = std.StringHashMap(void).init(c.a);
    var pending: std.ArrayList([]const u8) = .empty;
    for (roots) |root| try pending.append(c.a, src.string(root, ""));
    while (pending.pop()) |path| {
        const entry = try reached.getOrPut(path);
        if (entry.found_existing) continue;
        const s = find(sources, path) orelse {
            c.fail("{s}: configured or imported test root is missing", .{path});
            continue;
        };
        for (try sourceImports(c.a, s)) |item| {
            if (s.inTest(item.token) or (item.alias != null and aliasUsed(s, item.alias.?)))
                try pending.append(c.a, try resolve(c.a, path, item.target));
        }
    }
    for (sources) |s| {
        if (s.hasTests() and !reached.contains(s.path))
            c.fail("{s}: tests are unreachable; name the file in a test block reached by a configured root", .{s.path});
    }
}

fn find(sources: []const src.Source, path: []const u8) ?src.Source {
    for (sources) |s| if (std.mem.eql(u8, s.path, path)) return s;
    return null;
}

test "reachability follows imports and aliases only from named or unnamed test blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"test_roots\":[\"src/root.zig\"]}", .{})).value;
    const value = try src.Source.parse(a, "src/value.zig", "test \"covered\" {}\n");
    const root = try src.Source.parse(a, "src/root.zig", "const value = @import(\"value.zig\");\n\ntest \"root\" { _ = value; }\n");
    var c: src.Context = .{ .a = a, .io = std.testing.io };
    try check(&c, &.{ root, value }, config);
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    const unreached = try src.Source.parse(a, "src/root.zig", "pub const value = @import(\"value.zig\");\n");
    try check(&c, &.{ unreached, value }, config);
    try std.testing.expectEqual(@as(usize, 1), c.errors);
}

test "fixtures inside strings are not imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"test_roots\":[\"root.zig\"]}", .{})).value;
    var c: src.Context = .{ .a = a, .io = std.testing.io };
    const root = try src.Source.parse(a, "root.zig", "\n\ntest { const fixture = \"@import(\\\"fake.zig\\\")\"; }\n");
    try check(&c, &.{root}, config);
    try std.testing.expectEqual(@as(usize, 0), c.errors);
}
