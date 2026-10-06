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
        try unused(c, s);
    }
}

/// An import in a container-level declaration that nothing reaches: no
/// `pub`, `export` or `comptime` member, field, `main` or test leads to it,
/// so Zig never analyses it. An identifier naming a member is a use (after a
/// period only as `reference` reads it), so a doubtful case stays quiet.
fn unused(c: *src.Context, s: src.Source) !void {
    const t = s.tree;
    const decls = t.rootDecls();
    const live = try c.a.alloc(bool, decls.len);
    var pending: std.ArrayList(usize) = .empty;
    var names = std.StringHashMap(usize).init(c.a);
    for (decls, 0..) |node, i| {
        live[i] = false;
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        var name: ?std.zig.Ast.TokenIndex = null;
        switch (t.nodeTag(node)) {
            .test_decl, .@"comptime", .container_field, .container_field_init, .container_field_align => live[i] = true,
            else => if (t.fullVarDecl(node)) |v| {
                name = v.ast.mut_token + 1;
                live[i] = v.visib_token != null or exported(t, v.extern_export_token);
            } else if (t.fullFnProto(&buffer, node)) |f| {
                name = f.name_token;
                live[i] = f.visib_token != null or exported(t, f.extern_export_inline_token);
            },
        }
        if (name) |token| {
            const text = t.tokenSlice(token);
            if (std.mem.eql(u8, text, "main")) live[i] = true;
            try names.put(text, i);
        }
        if (live[i]) try pending.append(c.a, i);
    }
    const selves = try thisAliases(c.a, t);
    while (pending.pop()) |i| {
        var token = t.firstToken(decls[i]);
        while (token <= t.lastToken(decls[i])) : (token += 1) {
            if (t.tokenTag(token) != .identifier or !reference(t, selves, token)) continue;
            const j = names.get(t.tokenSlice(token)) orelse continue;
            if (live[j]) continue;
            live[j] = true;
            try pending.append(c.a, j);
        }
    }
    for (decls, live) |node, reached| {
        if (reached) continue;
        var token = t.firstToken(node);
        while (token + 2 <= t.lastToken(node)) : (token += 1) {
            if (t.tokenTag(token) != .builtin or !std.mem.eql(u8, t.tokenSlice(token), "@import")) continue;
            if (t.tokenTag(token + 2) != .string_literal) continue;
            c.fail("{s}:{d}: unused import {s}: nothing reaches its declaration", .{ s.path, s.line(token), t.tokenSlice(token + 2) });
        }
    }
}

fn exported(t: std.zig.Ast, token: ?std.zig.Ast.TokenIndex) bool {
    return if (token) |index| t.tokenTag(index) == .keyword_export else false;
}

/// A name after a period is a member: it names one of this file's
/// declarations only as a call (`x.name(`) or through `@This()`. A name
/// that opens a field (`{ name: T`) declares that field.
fn reference(t: std.zig.Ast, selves: []const []const u8, token: std.zig.Ast.TokenIndex) bool {
    if (token + 1 < t.tokens.len and t.tokenTag(token + 1) == .colon and token > 0) switch (t.tokenTag(token - 1)) {
        .l_brace, .comma, .doc_comment => return false,
        else => {},
    };
    if (token == 0 or t.tokenTag(token - 1) != .period) return true;
    if (token + 1 < t.tokens.len and t.tokenTag(token + 1) == .l_paren) return true;
    if (token < 2) return false;
    const owner = token - 2;
    if (t.tokenTag(owner) == .identifier) {
        for (selves) |name| if (std.mem.eql(u8, name, t.tokenSlice(owner))) return true;
        return false;
    }
    return owner >= 2 and t.tokenTag(owner) == .r_paren and t.tokenTag(owner - 1) == .l_paren and
        std.mem.eql(u8, t.tokenSlice(owner - 2), "@This");
}

/// Names bound as `const Name = @This();` anywhere in the file.
fn thisAliases(a: std.mem.Allocator, t: std.zig.Ast) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var token: std.zig.Ast.TokenIndex = 0;
    while (token + 5 < t.tokens.len) : (token += 1) {
        if (t.tokenTag(token) != .keyword_const or t.tokenTag(token + 1) != .identifier or t.tokenTag(token + 2) != .equal) continue;
        if (!std.mem.eql(u8, t.tokenSlice(token + 3), "@This") or t.tokenTag(token + 4) != .l_paren or t.tokenTag(token + 5) != .r_paren) continue;
        try out.append(a, t.tokenSlice(token + 1));
    }
    return out.items;
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

fn unusedCount(text: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io };
    try unused(&c, try src.Source.parse(c.a, "src/value.zig", text));
    return c.errors;
}

test "an import nothing reaches is unused" {
    try std.testing.expectEqual(@as(usize, 1), try unusedCount("const a = @import(\"a.zig\");\npub fn f() void {}\n"));
    try std.testing.expectEqual(@as(usize, 1), try unusedCount("const std = @import(\"std\");\npub fn f() void {}\n"));
    // A chain from a dead declaration stays dead.
    try std.testing.expectEqual(@as(usize, 1), try unusedCount("const a = @import(\"a.zig\");\nfn helper() void { _ = a; }\npub fn f() void {}\n"));
    try std.testing.expectEqual(@as(usize, 2), try unusedCount("const a = @import(\"a.zig\");\nconst S = struct { const b = @import(\"b.zig\"); };\n"));
    // A member of another value with the same name is not a use.
    try std.testing.expectEqual(@as(usize, 1), try unusedCount("const object = @import(\"object.zig\");\npub const U = union(enum) { none, object: struct { x: u8 }, };\n"));
    try std.testing.expectEqual(@as(usize, 1), try unusedCount("const fs = @import(\"repo/fs.zig\");\nconst std = @import(\"std\");\npub const sep = std.fs.path.sep;\n"));
}

test "a root, a test, a field or a method call keeps an import" {
    for ([_][]const u8{
        "pub const a = @import(\"a.zig\");\n",
        "const a = @import(\"a.zig\");\npub fn f() void { _ = a; }\n",
        "const a = @import(\"a.zig\");\nfn helper() void { _ = a; }\npub fn f() void { helper(); }\n",
        "const a = @import(\"a.zig\");\ntest { _ = a; }\n",
        "const a = @import(\"a.zig\");\ntest a {}\n",
        "const a = @import(\"a.zig\");\ncomptime { _ = a; }\n",
        "const len = @import(\"a.zig\").len;\npub const B = [len:0]u8;\n",
        "const n = @import(\"a.zig\").n;\npub fn f(b: [:0]const u8) [:0]const u8 { return b[0..n :0]; }\n",
        "const a = @import(\"a.zig\");\nfield: a.T,\n",
        "const a = @import(\"a.zig\");\nexport fn f() void { _ = a; }\n",
        "const a = @import(\"a.zig\");\nfn main() void { _ = a; }\n",
        "const a = @import(\"a.zig\");\nfn helper(self: @This()) void { _ = self; _ = a; }\npub fn f(self: @This()) void { self.helper(); }\n",
        "const Self = @This();\nconst a = @import(\"a.zig\");\nconst helper = a.x;\npub const y = Self.helper;\n",
        "const a = @import(\"a.zig\");\nconst helper = a.x;\npub const y = @This().helper;\n",
        "const builtin = @import(\"builtin\");\nconst a = @import(\"a.zig\");\npub fn f() void { if (builtin.is_test) _ = a; }\n",
    }) |text| try std.testing.expectEqual(@as(usize, 0), try unusedCount(text));
}
