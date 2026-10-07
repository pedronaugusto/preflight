//! Follows std's deprecations: rewrites every reference to what this Zig
//! release deprecated, by std's own aliases and the release's table, and
//! lists what needs a person.
const std = @import("std");
const builtin = @import("builtin");
const library = @import("deprecations/library.zig");
const table = @import("deprecations/table.zig");
const rewrite = @import("deprecations/rewrite.zig");

pub const Options = struct {
    /// The `std` directory of the Zig that builds the package.
    std_dir: std.Io.Dir,
    /// The release whose table applies: the Zig that built preflight.
    version: std.SemanticVersion = builtin.zig_version,
    write: bool = false,
    /// Files and directories under `root` to read; all of it when empty.
    paths: []const []const u8 = &.{},
};

pub const Summary = struct {
    files: usize = 0,
    changes: [std.enums.values(rewrite.Kind).len]usize = @splat(0),
    leftovers: usize = 0,
    unparsed: usize = 0,
};

/// Rewrites, or with `write` off only reports, every Zig file under `root`
/// outside caches and hidden directories.
pub fn run(a: std.mem.Allocator, io: std.Io, root: std.Io.Dir, options: Options, out: *std.Io.Writer) !Summary {
    const release = table.find(options.version) orelse {
        try out.print("deprecations: no rewrite table for Zig {d}.{d}\n", .{ options.version.major, options.version.minor });
        return error.NoRewriteTable;
    };
    var lib: library.Library = .{ .a = a, .io = io, .dir = options.std_dir };
    const entries = try prepare(&lib, release, out);
    var summary: Summary = .{};
    for (try files(a, io, root, options.paths)) |path| {
        const source = try root.readFileAlloc(io, path, a, .limited(64 * 1024 * 1024));
        const outcome = rewrite.file(a, &lib, entries, source) catch |err| switch (err) {
            error.Unparsable => {
                try out.print("{s}: does not parse; skipped\n", .{path});
                summary.unparsed += 1;
                continue;
            },
            else => |e| {
                try out.print("{s}: {s}\n", .{ path, @errorName(e) });
                return e;
            },
        };
        for (outcome.changes) |change| {
            try out.print("{s}:{d}: {s} -> {s}\n", .{ path, change.line, change.old, change.new });
            summary.changes[@backingInt(change.kind)] += 1;
        }
        for (outcome.leftovers) |left| try out.print("{s}:{d}: by hand: {s}: {s}\n", .{ path, left.line, left.name, left.doc });
        summary.leftovers += outcome.leftovers.len;
        if (outcome.changes.len == 0) continue;
        summary.files += 1;
        if (options.write) try root.writeFile(io, .{ .sub_path = path, .data = outcome.text });
    }
    const count = summary.changes;
    try out.print("deprecations: {d} changes in {d} files ({d} paths, {d} receivers, {d} memmoves, {d} orelse to catch, {d} forwards, {d} unused aliases removed); {d} by hand; {d} files do not parse{s}\n", .{
        total(summary),                                                          summary.files,
        count[@backingInt(rewrite.Kind.path)],                                   count[@backingInt(rewrite.Kind.receiver)],
        count[@backingInt(rewrite.Kind.memmove)],                                count[@backingInt(rewrite.Kind.orelse_to_catch)],
        count[@backingInt(rewrite.Kind.forward)],                                count[@backingInt(rewrite.Kind.unused)],
        summary.leftovers,                                                       summary.unparsed,
        if (options.write) "" else "; nothing written: -- --write applies them",
    });
    return summary;
}

pub fn total(summary: Summary) usize {
    var sum: usize = 0;
    for (summary.changes) |count| sum += count;
    return sum;
}

/// The entries this std confirms; a table that disagrees with it stops the run.
fn prepare(lib: *library.Library, release: table.Release, out: *std.Io.Writer) ![]const table.Entry {
    var active: std.ArrayList(table.Entry) = .empty;
    var mismatches: usize = 0;
    for (release.entries) |entry| switch (try table.check(lib, entry)) {
        .active => {
            try active.append(lib.a, entry);
            switch (entry) {
                .rename => |r| try lib.addRename(r.old, r.new),
                .receiver => |r| try lib.addRename(r.old, r.new),
                else => {},
            }
        },
        .absent => {},
        .mismatch => |why| {
            try out.print("deprecations: the Zig {d}.{d} table does not match this std: {s}\n", .{ release.version.major, release.version.minor, why });
            mismatches += 1;
        },
    };
    if (mismatches > 0) return error.TableMismatch;
    return active.items;
}

/// Zig files under the named paths, sorted; build output, fetched packages
/// and hidden directories are not the package's source.
fn files(a: std.mem.Allocator, io: std.Io, root: std.Io.Dir, paths: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (if (paths.len == 0) &[_][]const u8{"."} else paths) |path| {
        if (std.mem.endsWith(u8, path, ".zig")) {
            try out.append(a, path);
            continue;
        }
        var dir = try root.openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walkSelectively(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory) {
                if (!skipped(entry.basename)) try walker.enter(io, entry);
                continue;
            }
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            const joined = if (std.mem.eql(u8, path, ".")) try a.dupe(u8, entry.path) else try std.Io.Dir.path.join(a, &.{ path, entry.path });
            std.mem.replaceScalar(u8, joined, '\\', '/');
            try out.append(a, joined);
        }
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return out.items;
}

fn skipped(name: []const u8) bool {
    return name[0] == '.' or std.mem.eql(u8, name, "zig-out") or std.mem.eql(u8, name, "zig-pkg");
}

test {
    _ = library;
    _ = @import("deprecations/rewrite_test.zig");
}
