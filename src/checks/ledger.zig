//! Exact, single-use exceptions. Git is the authority for the shrinking budget.
const std = @import("std");
const src = @import("source.zig");

pub const Ledger = struct {
    c: *src.Context,
    allowed: []const src.Value,
    used: []bool,

    pub fn init(c: *src.Context, value: src.Value) !Ledger {
        if (value != .null and value != .array) return error.InvalidExceptionLedger;
        const allowed = src.items(value);
        const used = try c.a.alloc(bool, allowed.len);
        @memset(used, false);
        for (allowed) |item| {
            for ([_][]const u8{ "rule", "path", "source", "detail", "reason" }) |key| {
                if (src.get(item, key) != .string or (std.mem.trim(u8, src.string(src.get(item, key), ""), " \t\r\n").len == 0 and !std.mem.eql(u8, key, "source")))
                    c.fail("exception needs {s}: {s}", .{ key, try std.json.Stringify.valueAlloc(c.a, item, .{}) });
            }
        }
        return .{ .c = c, .allowed = allowed, .used = used };
    }

    pub fn load(c: *src.Context, config: src.Value, key: []const u8) !Ledger {
        return loadWithBaseline(c, config, key, .null);
    }

    pub fn loadWithBaseline(c: *src.Context, config: src.Value, key: []const u8, baseline: src.Value) !Ledger {
        const file = src.get(config, key);
        const value = if (file == .string) try c.json(file.string) else .null;
        var ledger = try init(c, value);
        if (file == .string) try ledger.compareFile(file.string, baseline);
        return ledger;
    }

    pub fn consume(l: *Ledger, rule: []const u8, path: []const u8, source: []const u8, detail: []const u8) bool {
        for (l.allowed, 0..) |item, i| {
            if (!l.used[i] and equals(item, "rule", rule) and equals(item, "path", path) and equals(item, "source", source) and equals(item, "detail", detail)) {
                l.used[i] = true;
                return true;
            }
        }
        return false;
    }

    pub fn finish(l: Ledger) !void {
        for (l.allowed, l.used) |item, used| {
            if (!used) l.c.fail("stale exception: remove it: {s}", .{try std.json.Stringify.valueAlloc(l.c.a, item, .{})});
        }
    }

    fn compareFile(l: *Ledger, file: []const u8, baseline: src.Value) !void {
        const base = l.c.ledger_base orelse return;
        if (l.allowed.len == 0) return;
        const prefix = try git(l.c, &.{ "rev-parse", "--show-prefix" });
        const path = try std.mem.concat(l.c.a, u8, &.{ std.mem.trim(u8, prefix.stdout, "\r\n"), file });
        const spec = try l.c.a.print("{s}:{s}", .{ base, path });
        const shown = try git(l.c, &.{ "show", spec });
        const base_exists = try git(l.c, &.{ "rev-parse", "--verify", base });
        if (!success(base_exists)) return error.MissingLedgerBase;
        const previous = if (success(shown)) (try std.json.parseFromSlice(src.Value, l.c.a, shown.stdout, .{})).value else .null;
        if (!success(shown) and l.c.adopt and baseline == .array) {
            for (l.allowed) |item| {
                if (!equals(item, "reason", "existing at gate adoption; burned down in the cleanup pass"))
                    l.c.fail("initial ledger needs the gate adoption reason: {s}", .{try std.json.Stringify.valueAlloc(l.c.a, item, .{})});
            }
            try l.compare(baseline, "", "");
            return;
        }
        const changes = try git(l.c, &.{ "diff", "--name-status", "-z", "--find-renames", base, "HEAD", "--" });
        if (!success(changes)) return error.LedgerDiffFailed;
        try l.compare(previous, changes.stdout, std.mem.trim(u8, prefix.stdout, "\r\n"));
    }

    pub fn compare(l: Ledger, previous: src.Value, changes: []const u8, prefix: []const u8) !void {
        const old = src.items(previous);
        const used = try l.c.a.alloc(bool, old.len);
        @memset(used, false);
        for (l.allowed) |item| {
            const path = src.string(src.get(item, "path"), "");
            const old_path = renamedFrom(changes, prefix, path) orelse path;
            var found = false;
            for (old, 0..) |entry, i| {
                if (used[i]) continue;
                if (!equals(entry, "rule", src.string(src.get(item, "rule"), "")) or
                    !equals(entry, "source", src.string(src.get(item, "source"), "")) or
                    !equals(entry, "detail", src.string(src.get(item, "detail"), ""))) continue;
                if (!equals(entry, "path", old_path) and !try movedCode(l.c, prefix, entry)) continue;
                used[i] = true;
                found = true;
                break;
            }
            if (!found) l.c.fail("new exception: ledger may only shrink: {s}", .{try std.json.Stringify.valueAlloc(l.c.a, item, .{})});
        }
    }
};

fn movedCode(c: *src.Context, prefix: []const u8, entry: src.Value) !bool {
    const base = c.ledger_base orelse return false;
    const source = src.string(src.get(entry, "source"), "");
    if (source.len == 0) return false;
    const path = try std.mem.concat(c.a, u8, &.{ ":(top)", prefix, src.string(src.get(entry, "path"), "") });
    const diff = try git(c, &.{ "diff", "--unified=0", "--no-renames", base, "HEAD", "--", path });
    if (!success(diff)) return error.LedgerDiffFailed;
    var lines = std.mem.splitScalar(u8, diff.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] != '-' or std.mem.startsWith(u8, line, "---")) continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[1..], " \t\r"), source)) return true;
    }
    return false;
}

pub fn git(c: *src.Context, args: []const []const u8) !std.process.RunResult {
    const argv = try std.mem.concat(c.a, []const u8, &.{ &.{"git"}, args });
    return std.process.run(c.a, c.io, .{ .argv = argv, .cwd = c.childCwd() });
}

pub fn success(result: std.process.RunResult) bool {
    return result.term == .exited and result.term.exited == 0;
}

fn equals(item: src.Value, key: []const u8, wanted: []const u8) bool {
    return std.mem.eql(u8, src.string(src.get(item, key), ""), wanted);
}

fn renamedFrom(changes: []const u8, prefix: []const u8, path: []const u8) ?[]const u8 {
    var entries = std.mem.splitScalar(u8, changes, 0);
    while (entries.next()) |status| {
        if (status.len == 0) continue;
        const from = entries.next() orelse return null;
        if (status[0] != 'R' and status[0] != 'C') continue;
        const to = entries.next() orelse return null;
        if (status[0] != 'R') continue;
        if (!std.mem.startsWith(u8, from, prefix) or !std.mem.startsWith(u8, to, prefix)) continue;
        if (std.mem.eql(u8, to[prefix.len..], path)) return from[prefix.len..];
    }
    return null;
}

test "ledger rejects additions, duplicates and stale exceptions; exact renames survive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io };
    const old = (try std.json.parseFromSlice(src.Value, c.a, "[{\"rule\":\"R\",\"path\":\"old.zig\",\"source\":\"code\",\"detail\":\"why\",\"reason\":\"existing\"}]", .{})).value;
    const moved = (try std.json.parseFromSlice(src.Value, c.a, "[{\"rule\":\"R\",\"path\":\"new.zig\",\"source\":\"code\",\"detail\":\"why\",\"reason\":\"existing\"}]", .{})).value;
    var l = try Ledger.init(&c, moved);
    try l.compare(old, "R100\x00old.zig\x00new.zig\x00", "");
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    try l.compare(old, "", "");
    try std.testing.expectEqual(@as(usize, 1), c.errors);
    try l.finish();
    try std.testing.expectEqual(@as(usize, 2), c.errors);
    try std.testing.expect(l.consume("R", "new.zig", "code", "why"));
    try std.testing.expect(!l.consume("R", "new.zig", "code", "why"));
    try l.finish();
    try std.testing.expectEqual(@as(usize, 2), c.errors);
    try l.compare(.null, "", "");
    try std.testing.expectEqual(@as(usize, 3), c.errors);
}
