const std = @import("std");
const gantry = @import("gantry");
const src = @import("source.zig");

pub fn layout(c: *src.Context, sources: []const src.Source, config: src.Value) !void {
    var globs: gantry.rules.Globs = .{ .arena = c.a };
    const tests = try globs.list(.path, try src.testPaths(c.a, config));
    var directories: std.StringHashMap(std.ArrayList([]const u8)) = .init(c.a);
    for (sources) |s| {
        if (gantry.rules.anyOf(tests, s.path)) continue;
        const directory = std.Io.Dir.path.dirname(s.path) orelse continue;
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
        const parent = std.Io.Dir.path.dirname(directory) orelse ".";
        const name = std.Io.Dir.path.basename(directory);
        var count: usize = 0;
        for (sources) |s| {
            if (!std.mem.eql(u8, std.Io.Dir.path.dirname(s.path) orelse ".", parent)) continue;
            const base = std.Io.Dir.path.basename(s.path);
            if (std.ascii.eqlIgnoreCase(base[0 .. base.len - 4], name)) count += 1;
        }
        if (count != 1) c.fail("{s}: namespace has {d} files; give it one adjacent {s}.zig entry", .{ directory, members.len, name });
    }
    try flatNamespaces(c, sources, config, tests);
}

fn flatNamespaces(c: *src.Context, sources: []const src.Source, config: src.Value, tests: []const *const gantry.rules.Pattern) !void {
    var groups = std.StringHashMap(std.ArrayList([]const u8)).init(c.a);
    for (sources) |s| {
        if (gantry.rules.anyOf(tests, s.path)) continue;
        const parent = std.Io.Dir.path.dirname(s.path) orelse ".";
        const base = std.Io.Dir.path.basename(s.path);
        const stem = base[0 .. base.len - 4];
        const prefix = stem[0..(std.mem.findScalar(u8, stem, '_') orelse stem.len)];
        // Members already inside their namespace may retain descriptive prefixes.
        if (std.ascii.eqlIgnoreCase(std.Io.Dir.path.basename(parent), prefix)) continue;
        const lower = try std.ascii.allocLowerString(c.a, prefix);
        const namespace = try c.a.print("{s}/{s}", .{ parent, lower });
        const group = try groups.getOrPut(namespace);
        if (!group.found_existing) group.value_ptr.* = .empty;
        try group.value_ptr.append(c.a, s.path);
    }
    var iterator = groups.iterator();
    while (iterator.next()) |entry| {
        const members = entry.value_ptr.items;
        if (members.len < 2) continue;
        if (layoutException(members, src.get(src.get(config, "layout_exceptions"), entry.key_ptr.*))) continue;
        c.fail("layout: {s}: {d} namespace files belong in {s}/ beside its entry", .{ try std.mem.join(c.a, ", ", members), members.len, entry.key_ptr.* });
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
