//! A build function that calls `lazyImport` raises the branch quota first. std's `lazyImport` compares
//! every package of the dependency tree at comptime, so a large tree passes the default 1000 branches
//! and the build fails to compile, in whichever function happens to call it.
const std = @import("std");
const src = @import("source.zig");

/// Reports each function of `build.zig` that calls `lazyImport` without an earlier `@setEvalBranchQuota`
/// in its body.
pub fn check(c: *src.Context) !void {
    if (!c.exists("build.zig")) return;
    const text = try c.a.dupeSentinel(u8, try c.read("build.zig"), 0);
    for (try unguarded(c.a, text)) |line| c.fail("build.zig:{d}: lazyImport compares every package of the tree at comptime: call @setEvalBranchQuota earlier in this function", .{line});
}

/// The line of each `lazyImport` call that no `@setEvalBranchQuota` precedes in its function.
pub fn unguarded(a: std.mem.Allocator, text: [:0]const u8) ![]const usize {
    const ast = try std.zig.Ast.parse(a, text, .{});
    var found: std.ArrayList(usize) = .empty;
    const tags = ast.tokens.items(.tag);
    for (ast.rootDecls()) |decl| {
        if (ast.nodeTag(decl) != .fn_decl) continue;
        _, const body = ast.nodeData(decl).node_and_node;
        var quota = false;
        var token = ast.firstToken(body);
        const last = ast.lastToken(body);
        while (token <= last) : (token += 1) {
            if (tags[token] == .builtin and std.mem.eql(u8, ast.tokenSlice(token), "@setEvalBranchQuota")) quota = true;
            if (tags[token] != .identifier or !std.mem.eql(u8, ast.tokenSlice(token), "lazyImport")) continue;
            if (token + 1 > last or tags[token + 1] != .l_paren or quota) continue;
            try found.append(a, ast.tokenLocation(0, token).line + 1);
        }
    }
    return found.items;
}

test "lazyImport needs a branch quota before it in the same function" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const guarded = try unguarded(a,
        \\pub fn build(b: *std.Build) void {
        \\    @setEvalBranchQuota(10_000);
        \\    if (b.lazyImport(@This(), "preflight")) |p| p.addCi(b, .{});
        \\}
    );
    try std.testing.expectEqual(@as(usize, 0), guarded.len);
    const late = try unguarded(a,
        \\pub fn build(b: *std.Build) void {
        \\    const ci = b.lazyImport(@This(), "preflight");
        \\    @setEvalBranchQuota(10_000);
        \\    _ = b.lazyImport(@This(), "other");
        \\    _ = ci;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), late.len);
    try std.testing.expectEqual(@as(usize, 2), late[0]);
    // Another function's quota does not count, and a function that never calls it needs none.
    const other = try unguarded(a,
        \\fn raise() void {
        \\    @setEvalBranchQuota(10_000);
        \\}
        \\fn ci(b: *std.Build) void {
        \\    _ = b.lazyImport(@This(), "preflight");
        \\}
        \\fn plain() void {}
    );
    try std.testing.expectEqual(@as(usize, 1), other.len);
    try std.testing.expectEqual(@as(usize, 5), other[0]);
}
