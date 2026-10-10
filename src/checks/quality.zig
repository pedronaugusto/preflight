//! The assertion-density report. Code rules that gate are glint's.
const std = @import("std");
const src = @import("source.zig");

pub const Density = struct { path: []const u8, function: []const u8, asserts: usize, lines: usize };

pub fn density(a: std.mem.Allocator, sources: []const src.Source) ![]Density {
    var result: std.ArrayList(Density) = .empty;
    for (sources) |s| {
        for (s.tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .fn_decl) continue;
            const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(i));
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
                    const inner: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(k));
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
