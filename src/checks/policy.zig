const std = @import("std");
const gantry = @import("gantry");
const src = @import("source.zig");
const assembly = @import("glint/assembly.zig");

/// The namespace layout of `sources`. A file the build roots a module at (`modules`, the build's
/// configured modules) is no namespace's member: it is reached by its module's name, never
/// through an entry file, so a directory of such roots (spectra's kernels, one module each for
/// the CPU features its instructions need) needs no entry, and roots sharing a name's prefix
/// belong in no directory of that name.
pub fn layout(c: *src.Context, sources: []const src.Source, config: src.Value, modules: []const src.BuildModule) !void {
    var globs: gantry.rules.Globs = .{ .arena = c.a };
    const tests = try globs.list(.path, try src.testPaths(c.a, config));
    var roots: std.StringHashMapUnmanaged(void) = .empty;
    for (modules) |module| {
        if (module.script) continue;
        try roots.put(c.a, try assembly.normalize(c.a, module.root orelse continue), {});
    }
    var grouped: std.ArrayList(src.Source) = .empty;
    for (sources) |s| {
        if (gantry.rules.anyOf(tests, s.path) or roots.contains(try assembly.normalize(c.a, s.path))) continue;
        try grouped.append(c.a, s);
    }
    var directories: std.StringHashMap(std.ArrayList([]const u8)) = .init(c.a);
    for (grouped.items) |s| {
        const directory = std.Io.Dir.path.dirname(s.path) orelse continue;
        const group = try directories.getOrPut(directory);
        if (!group.found_existing) group.value_ptr.* = .empty;
        try group.value_ptr.append(c.a, s.path);
    }
    var iterator = directories.iterator();
    while (iterator.next()) |entry| {
        const directory = entry.key_ptr.*;
        const members = entry.value_ptr.items;
        if (members.len < 2 or try rootDirectory(directory, config)) continue;
        const exception = src.get(src.get(config, "layout_exceptions"), directory);
        if (try layoutException(members, exception)) continue;
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
    try flatNamespaces(c, grouped.items, config);
}

/// `grouped`: the sources that belong to a namespace, tests and module roots left out.
fn flatNamespaces(c: *src.Context, grouped: []const src.Source, config: src.Value) !void {
    var groups = std.StringHashMap(std.ArrayList([]const u8)).init(c.a);
    for (grouped) |s| {
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
        if (try layoutException(members, src.get(src.get(config, "layout_exceptions"), entry.key_ptr.*))) continue;
        c.fail("layout: {s}: {d} namespace files belong in {s}/ beside its entry", .{ try std.mem.join(c.a, ", ", members), members.len, entry.key_ptr.* });
    }
}

fn rootDirectory(path: []const u8, config: src.Value) src.TypeError!bool {
    const roots = src.get(config, "sources");
    if (roots == .null) return std.mem.eql(u8, path, "src");
    for (try src.items(roots)) |root| if (std.mem.eql(u8, path, try src.string(root, ""))) return true;
    return false;
}

fn layoutException(members: []const []const u8, exception: src.Value) src.TypeError!bool {
    if (std.mem.trim(u8, try src.string(src.get(exception, "reason"), ""), " \t\r\n").len == 0) return false;
    const allowed = try src.items(src.get(exception, "files"));
    if (members.len != allowed.len) return false;
    for (members) |member| {
        var count: usize = 0;
        for (allowed) |item| if (std.mem.eql(u8, member, try src.string(item, ""))) {
            count += 1;
        };
        if (count != 1) return false;
    }
    return true;
}
