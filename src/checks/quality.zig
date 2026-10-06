//! Zig source checks share exact ledgers, with independent budgets per rule.
const std = @import("std");
const src = @import("source.zig");
const ledger = @import("ledger.zig");

pub const Finding = struct { rule: []const u8, path: []const u8, source: []const u8, detail: []const u8, line: usize };
pub const Density = struct { path: []const u8, function: []const u8, asserts: usize, lines: usize };
pub const rules = [_][]const u8{ "catch-unreachable", "debug-print", "file-name-case" };
pub const keys = [_][]const u8{ "unreachable_exceptions", "debug_print_exceptions", "file_name_exceptions" };

pub fn check(c: *src.Context, sources: []const src.Source, config: src.Value) !void {
    const found = try findings(c.a, sources, config);
    const baseline = if (c.adopt and c.ledger_base != null) try baseFindings(c, sources, config) else src.Value.null;
    for (rules, keys) |rule, key| {
        var allowed = try ledger.Ledger.loadWithBaseline(c, config, key, baseline);
        for (found) |f| {
            if (!std.mem.eql(u8, f.rule, rule)) continue;
            if (!allowed.consume(f.rule, f.path, f.source, f.detail)) c.fail("{s}: {s}:{d}: {s}", .{ f.rule, f.path, f.line, f.detail });
        }
        try allowed.finish();
    }
}

fn baseFindings(c: *src.Context, sources: []const src.Source, config: src.Value) !src.Value {
    const prefix = try ledger.git(c, &.{ "rev-parse", "--show-prefix" });
    if (!ledger.success(prefix)) return error.MissingRepository;
    var old_sources: std.ArrayList(src.Source) = .empty;
    for (sources) |s| {
        const spec = try std.fmt.allocPrint(c.a, "{s}:{s}{s}", .{ c.ledger_base.?, std.mem.trim(u8, prefix.stdout, "\r\n"), s.path });
        const shown = try ledger.git(c, &.{ "show", spec });
        if (!ledger.success(shown)) continue;
        try old_sources.append(c.a, try src.Source.parse(c.a, s.path, shown.stdout));
    }
    const json = try std.json.Stringify.valueAlloc(c.a, try findings(c.a, old_sources.items, config), .{});
    return (try std.json.parseFromSlice(src.Value, c.a, json, .{})).value;
}

pub fn findings(a: std.mem.Allocator, sources: []const src.Source, config: src.Value) ![]Finding {
    var result: std.ArrayList(Finding) = .empty;
    for (sources) |s| {
        if (s.tree.errors.len != 0) return error.InvalidZigSource;
        for (s.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .@"catch") continue;
            const node: std.zig.Ast.Node.Index = @enumFromInt(i);
            const token = s.tree.nodeMainToken(node);
            var rhs = s.tree.nodeData(node).node_and_node[1];
            while (s.tree.nodeTag(rhs) == .grouped_expression) rhs = s.tree.nodeData(rhs).node_and_token[0];
            if (s.tree.nodeTag(rhs) == .unreachable_literal and src.outsideTests(s, config, token) and !unreachableReason(s, token))
                try add(a, &result, s, token, rules[0], "catch unreachable needs // unreachable: <why> on the same or previous line");
        }
        const tags = s.tree.tokens.items(.tag);
        for (tags, 0..) |tag, i| {
            const token: std.zig.Ast.TokenIndex = @intCast(i);
            if (!src.outsideTests(s, config, token)) continue;
            if (tag == .identifier and debugPrint(s, token))
                try add(a, &result, s, token, rules[1], "std.debug.print outside tests and src/testing/");
        }
        var fields = false;
        for (s.tree.rootDecls()) |node| switch (s.tree.nodeTag(node)) {
            .container_field, .container_field_init, .container_field_align => fields = true,
            else => {},
        };
        const base = std.fs.path.basename(s.path);
        const stem = base[0 .. base.len - 4];
        if (!fileCase(stem, fields)) try result.append(a, .{
            .rule = rules[2],
            .path = s.path,
            .source = if (fields) "top-level fields" else "no top-level fields",
            .detail = if (fields) "struct file must use TitleCase" else "namespace file must use snake_case/lowercase",
            .line = 1,
        });
    }
    return result.items;
}

fn add(a: std.mem.Allocator, list: *std.ArrayList(Finding), s: src.Source, token: std.zig.Ast.TokenIndex, rule: []const u8, detail: []const u8) !void {
    try list.append(a, .{ .rule = rule, .path = s.path, .source = std.mem.trim(u8, s.lineText(token), " \t\r"), .detail = detail, .line = s.line(token) });
}

fn debugPrint(s: src.Source, token: std.zig.Ast.TokenIndex) bool {
    const parts = [_][]const u8{ "std", ".", "debug", ".", "print", "(" };
    if (token + parts.len > s.tree.tokens.len) return false;
    for (parts, 0..) |part, j| {
        if (!std.mem.eql(u8, s.tree.tokenSlice(token + @as(u32, @intCast(j))), part)) return false;
    }
    return true;
}

fn fileCase(stem: []const u8, fields: bool) bool {
    if (stem.len == 0 or !(if (fields) std.ascii.isUpper(stem[0]) else std.ascii.isLower(stem[0]))) return false;
    for (stem) |char| {
        if (std.ascii.isDigit(char) or std.ascii.isLower(char)) continue;
        if (fields and std.ascii.isUpper(char)) continue;
        if (!fields and char == '_') continue;
        return false;
    }
    return true;
}

fn unreachableReason(s: src.Source, token: std.zig.Ast.TokenIndex) bool {
    if (commentReason(s.lineText(token))) return true;
    const offset = s.tree.tokens.items(.start)[token];
    const end = std.mem.findScalarLast(u8, s.text[0..offset], '\n') orelse return false;
    const start = if (std.mem.findScalarLast(u8, s.text[0..end], '\n')) |n| n + 1 else 0;
    return commentReason(s.text[start..end]);
}

fn commentReason(line: []const u8) bool {
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "\\\\")) return false;
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
            return std.mem.startsWith(u8, comment, "unreachable:") and std.mem.trim(u8, comment[12..], " \t\r").len > 0;
        }
    }
    return false;
}

pub fn density(a: std.mem.Allocator, sources: []const src.Source) ![]Density {
    var result: std.ArrayList(Density) = .empty;
    for (sources) |s| {
        for (s.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .fn_decl) continue;
            const node: std.zig.Ast.Node.Index = @enumFromInt(i);
            var buffer: [1]std.zig.Ast.Node.Index = undefined;
            const proto = s.tree.fullFnProto(&buffer, node).?;
            const name = s.tree.tokenSlice(proto.name_token orelse continue);
            const first = s.tree.firstToken(node);
            const last = s.tree.lastToken(node);
            var count: usize = 0;
            const body_first = s.tree.firstToken(s.tree.nodeData(node).node_and_node[1]);
            for (body_first..last) |j| {
                const token: std.zig.Ast.TokenIndex = @intCast(j);
                if (s.tree.tokens.items(.tag)[token] != .identifier or !std.mem.eql(u8, s.tree.tokenSlice(token), "assert") or
                    s.tree.tokens.items(.tag)[token + 1] != .l_paren) continue;
                var nested = false;
                for (s.tree.nodes.items(.tag), 0..) |inner_tag, k| {
                    if (inner_tag != .fn_decl or k == i) continue;
                    const inner: std.zig.Ast.Node.Index = @enumFromInt(k);
                    if (s.tree.firstToken(inner) > first and token >= s.tree.firstToken(inner) and token <= s.tree.lastToken(inner)) nested = true;
                }
                if (!nested) count += 1;
            }
            try result.append(a, .{ .path = s.path, .function = name, .asserts = count, .lines = s.line(last) - s.line(first) + 1 });
        }
    }
    return result.items;
}

pub fn summary(c: *src.Context, sources: []const src.Source, output: ?[]const u8) !void {
    const records = try density(c.a, sources);
    var total: usize = 0;
    var text: std.Io.Writer.Allocating = .init(c.a);
    try text.writer.writeAll("\nAssertion density (report only)\n\n| Function | Asserts | Lines |\n|---|---:|---:|\n");
    for (records) |row| {
        total += row.asserts;
        try text.writer.print("| `{s}:{s}` | {d} | {d} |\n", .{ row.path, row.function, row.asserts, row.lines });
    }
    try text.writer.print("\nPackage: {d} assertions in {d} functions.\n", .{ total, records.len });
    c.report("preflight: assertion density: {d} assertions in {d} functions\n", .{ total, records.len });
    if (output) |path| {
        const file = try c.directory().createFile(c.io, path, .{ .truncate = false, .read = true });
        defer file.close(c.io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(c.io, &buffer);
        writer.pos = (try file.stat(c.io)).size;
        try writer.interface.writeAll(text.written());
        try writer.interface.flush();
    }
}

test "each source policy finds code and ignores literals, tests and justified unreachable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = try src.Source.parse(a, "src/value.zig", "field: u8,\nfn work() void { foo() catch unreachable; std.debug.print(\"hi\", .{}); }\n");
    try std.testing.expectEqual(@as(usize, 3), (try findings(a, &.{bad}, .null)).len);
    const clean = try src.Source.parse(a, "src/Value.zig", "field: u8,\nfn work() void {\n // unreachable: checked earlier\n foo() catch unreachable;\n foo() catch unreachable; // unreachable: invariant\n const literal = \"std.debug.print catch unreachable // unreachable: fake\";\n}\ntest { foo() catch unreachable; std.debug.print(\"hi\", .{}); }\n");
    try std.testing.expectEqual(@as(usize, 0), (try findings(a, &.{clean}, .null)).len);
    for ([_][]const u8{ "src/work_test.zig", "src/test_work.zig", "src/tests.zig", "src/testing/helper.zig" }) |path| {
        const ignored = try src.Source.parse(a, path, "fn work() void { foo() catch unreachable; std.debug.print(\"hi\", .{}); }\n");
        try std.testing.expectEqual(@as(usize, 0), (try findings(a, &.{ignored}, .null)).len);
    }
    const plural = try src.Source.parse(a, "src/work_tests.zig", "fn work() void { foo() catch unreachable; std.debug.print(\"hi\", .{}); }\n");
    try std.testing.expectEqual(@as(usize, 2), (try findings(a, &.{plural}, .null)).len);
    try std.testing.expect(!commentReason("foo(\"// unreachable: fake\") catch unreachable;"));
    try std.testing.expect(!commentReason("foo() catch unreachable; // unreachable: "));
    try std.testing.expect(!commentReason("\\\\ // unreachable: fake"));
    const grouped = try src.Source.parse(a, "src/value.zig", "fn work() void { foo() catch |err| (unreachable); }\n");
    try std.testing.expectEqual(@as(usize, 1), (try findings(a, &.{grouped}, .null)).len);
    const namespace = try src.Source.parse(a, "src/Namespace.zig", "const S = struct { field: u8 };\n");
    try std.testing.expectEqual(@as(usize, 1), (try findings(a, &.{namespace}, .null)).len);
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"test_support\":[\"src/fixtures/**\"]}", .{})).value;
    const configured = try src.Source.parse(a, "src/fixtures/deep/helper.zig", "fn work() void { foo() catch unreachable; std.debug.print(\"hi\", .{}); }\n");
    try std.testing.expectEqual(@as(usize, 0), (try findings(a, &.{configured}, config)).len);
    const unconfigured = try src.Source.parse(a, "src/testing/helper.zig", "fn work() void { foo() catch unreachable; std.debug.print(\"hi\", .{}); }\n");
    try std.testing.expectEqual(@as(usize, 2), (try findings(a, &.{unconfigured}, config)).len);
}

test "assertion density counts per function without comments or nested double counting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try src.Source.parse(a, "src/value.zig", "fn outer() void { assert(true); const S = struct { fn inner() void { std.debug.assert(true); } }; }\nfn empty() void { const text = \"assert(false)\"; }\nfn assert(condition: bool) void {}\n");
    const rows = try density(a, &.{s});
    try std.testing.expectEqual(@as(usize, 4), rows.len);
    try std.testing.expectEqual(@as(usize, 1), rows[0].asserts);
    try std.testing.expectEqual(@as(usize, 1), rows[1].asserts);
    try std.testing.expectEqual(@as(usize, 0), rows[2].asserts);
    try std.testing.expectEqual(@as(usize, 0), rows[3].asserts);
}
