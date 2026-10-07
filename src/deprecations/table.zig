//! What each Zig release deprecated that std's own aliases do not say how to
//! follow. A deprecated `pub const old = new;` needs no entry: the library
//! resolves it to `new`. Each entry is checked against the std it runs on.
const std = @import("std");
const builtin = @import("builtin");
const library = @import("library.zig");

pub const Entry = union(enum) {
    /// Every reference to `old` becomes `new`: the same declaration, or a
    /// function with the same parameters.
    rename: struct { old: []const u8, new: []const u8 },
    /// A call's first argument becomes the receiver: `old(a, b)` becomes
    /// `a.print(b)` for `new` ending in `print`. Any other reference becomes `new`.
    receiver: struct { old: []const u8, new: []const u8 },
    /// `old(T, dest, source)` becomes `@memmove(dest[0..source.len], source)`.
    memmove: []const u8,
    /// `value.old(args) orelse x` becomes `value.new(args) catch x`, where
    /// `value` is declared as `type`: `old` returns `?T`, `new` returns `E!T`.
    orelse_to_catch: struct { type: []const u8, old: []const u8, new: []const u8 },
    /// `value.old(args)`, for a deprecated method whose body only calls its
    /// replacement, becomes that call with the caller's arguments in place:
    /// `run.addPrefixedArtifactArg(p, a)` becomes `run.addArtifactArg2(a, .{ .prefix = p })`.
    forward: []const u8,
    /// `builtin.old` becomes `builtin.new` for `@import("builtin")`. The
    /// compiler writes that module, so the check reads the compiler's own.
    builtin: struct { old: []const u8, new: []const u8 },
};

pub const Release = struct { version: std.SemanticVersion, entries: []const Entry };

pub const releases = [_]Release{.{ .version = .{ .major = 0, .minor = 17, .patch = 0 }, .entries = &.{
    .{ .rename = .{ .old = "std.fs.path", .new = "std.Io.Dir.path" } },
    .{ .rename = .{ .old = "std.fmt.bufPrint", .new = "std.mem.print" } },
    .{ .rename = .{ .old = "std.fmt.bufPrintSentinel", .new = "std.mem.printSentinel" } },
    .{ .receiver = .{ .old = "std.fmt.allocPrint", .new = "std.mem.Allocator.print" } },
    .{ .receiver = .{ .old = "std.fmt.allocPrintSentinel", .new = "std.mem.Allocator.printSentinel" } },
    .{ .memmove = "std.mem.copyForwards" },
    .{ .memmove = "std.mem.copyBackwards" },
    .{ .orelse_to_catch = .{ .type = "std.Build", .old = "lazyDependency", .new = "dependencyLazy" } },
    .{ .forward = "std.Build.Step.Run.addArtifactArg" },
    .{ .forward = "std.Build.Step.Run.addPrefixedArtifactArg" },
    .{ .forward = "std.Build.Step.Run.addOutputFileArg" },
    .{ .forward = "std.Build.Step.Run.addPrefixedOutputFileArg" },
    .{ .forward = "std.Build.Step.Run.addFileContentArg" },
    .{ .forward = "std.Build.Step.Run.addPrefixedFileContentArg" },
    .{ .forward = "std.Build.Step.Run.addOutputDirectoryArg" },
    .{ .forward = "std.Build.Step.Run.addPrefixedOutputDirectoryArg" },
    .{ .forward = "std.Build.Step.Run.addDirectoryArg" },
    .{ .forward = "std.Build.Step.Run.addPrefixedDirectoryArg" },
    .{ .forward = "std.Build.Step.Run.addDecoratedDirectoryArg" },
    .{ .forward = "std.Build.Step.Run.addDepFileOutputArg" },
    .{ .forward = "std.Build.Step.Run.addPrefixedDepFileOutputArg" },
    .{ .builtin = .{ .old = "os", .new = "target.os" } },
    .{ .builtin = .{ .old = "cpu", .new = "target.cpu" } },
    .{ .builtin = .{ .old = "abi", .new = "target.abi" } },
    .{ .builtin = .{ .old = "object_format", .new = "target.ofmt" } },
    .{ .builtin = .{ .old = "mode", .new = "optimize" } },
} }};

/// The table for the release `version` belongs to: patch releases share it.
pub fn find(version: std.SemanticVersion) ?Release {
    for (releases) |release| {
        if (release.version.major == version.major and release.version.minor == version.minor) return release;
    }
    return null;
}

pub const Status = union(enum) {
    /// The entry matches this std.
    active,
    /// This std has no `old`: nothing can call it.
    absent,
    mismatch: []const u8,
};

/// Whether `entry` says what this std says: `old` exists and is deprecated,
/// `new` exists and is not, and the move keeps every argument's meaning.
pub fn check(lib: *library.Library, entry: Entry) !Status {
    const a = lib.a;
    switch (entry) {
        .rename => |r| {
            const old = try lib.lookup(try library.split(a, r.old)) orelse return .absent;
            const new = try fresh(lib, r.new) orelse return mismatch("{s}: {s} is missing or deprecated", a, .{ r.old, r.new });
            if (library.deprecation(a, old) == null) return mismatch("{s} is not deprecated", a, .{r.old});
            const old_target = try lib.targetOf(old, 0);
            const new_target = try lib.targetOf(new, 0);
            if (old_target != null and new_target != null and old_target.?.same(new_target.?)) return .active;
            return sameParams(lib, old, new, r.old, r.new);
        },
        .receiver => |r| {
            const old = try lib.lookup(try library.split(a, r.old)) orelse return .absent;
            const new = try fresh(lib, r.new) orelse return mismatch("{s}: {s} is missing or deprecated", a, .{ r.old, r.new });
            if (library.deprecation(a, old) == null) return mismatch("{s} is not deprecated", a, .{r.old});
            return sameParams(lib, old, new, r.old, r.new);
        },
        .memmove => |name| {
            const old = try lib.lookup(try library.split(a, name)) orelse return .absent;
            if (library.deprecation(a, old) == null) return mismatch("{s} is not deprecated", a, .{name});
            const params = try lib.params(old) orelse return mismatch("{s} is not a function", a, .{name});
            const expected = [_]library.Param{ .{ .comptime_param = true, .type = "type" }, .{ .comptime_param = false, .type = "[]T" }, .{ .comptime_param = false, .type = "[]const T" } };
            if (!equalParams(params, &expected)) return mismatch("{s} does not take (comptime T: type, dest: []T, source: []const T)", a, .{name});
            return .active;
        },
        .orelse_to_catch => |r| {
            const old_path = try std.mem.join(a, ".", &.{ r.type, r.old });
            const new_path = try std.mem.join(a, ".", &.{ r.type, r.new });
            const old = try lib.lookup(try library.split(a, old_path)) orelse return .absent;
            const new = try fresh(lib, new_path) orelse return mismatch("{s}: {s} is missing or deprecated", a, .{ old_path, new_path });
            if (library.deprecation(a, old) == null) return mismatch("{s} is not deprecated", a, .{old_path});
            const status = try sameParams(lib, old, new, old_path, new_path);
            if (status != .active) return status;
            const old_return = library.Library.returnType(old) orelse "";
            const new_return = library.Library.returnType(new) orelse "";
            const bang = std.mem.findScalar(u8, new_return, '!');
            if (old_return.len < 2 or old_return[0] != '?' or bang == null or !std.mem.eql(u8, old_return[1..], new_return[bang.? + 1 ..]))
                return mismatch("{s} returns {s} and {s} returns {s}; orelse becomes catch only for ?T and E!T", a, .{ old_path, old_return, new_path, new_return });
            return .active;
        },
        .forward => |name| {
            const old = try lib.lookup(try library.split(a, name)) orelse return .absent;
            if (library.deprecation(a, old) == null) return mismatch("{s} is not deprecated", a, .{name});
            if (try lib.forward(old) == null) return mismatch("{s} does more than call its replacement on its receiver", a, .{name});
            return .active;
        },
        .builtin => |r| {
            const old = builtinType(r.old) orelse return .absent;
            const new = builtinType(r.new) orelse return mismatch("builtin.{s}: builtin.{s} is missing", a, .{ r.old, r.new });
            if (!std.mem.eql(u8, old, new)) return mismatch("builtin.{s} is {s} and builtin.{s} is {s}", a, .{ r.old, old, r.new, new });
            return .active;
        },
    }
}

/// The type of `path` in this compiler's `@import("builtin")`: a
/// declaration, or a field of one. Its doc comments are not in std's
/// source, so whether it is deprecated is the table's word.
pub fn builtinType(path: []const u8) ?[]const u8 {
    const dot = std.mem.findScalar(u8, path, '.');
    const head = path[0 .. dot orelse path.len];
    inline for (comptime std.meta.declarations(builtin)) |name| {
        if (std.mem.eql(u8, name, head)) {
            const T = @TypeOf(@field(builtin, name));
            const field = path[(dot orelse return @typeName(T)) + 1 ..];
            if (@typeInfo(T) != .@"struct") return null;
            const info = @typeInfo(T).@"struct";
            inline for (info.field_names, info.field_types) |field_name, field_type| {
                if (std.mem.eql(u8, field_name, field)) return @typeName(field_type);
            }
            return null;
        }
    }
    return null;
}

/// `path` as a declaration that exists and is not deprecated.
fn fresh(lib: *library.Library, path: []const u8) !?library.Member {
    const found = try lib.lookup(try library.split(lib.a, path)) orelse return null;
    return if (library.deprecation(lib.a, found) == null) found else null;
}

fn sameParams(lib: *library.Library, old: library.Member, new: library.Member, old_name: []const u8, new_name: []const u8) !Status {
    const old_params = try lib.params(old) orelse return mismatch("{s} is not a function", lib.a, .{old_name});
    const new_params = try lib.params(new) orelse return mismatch("{s} is not a function", lib.a, .{new_name});
    if (!equalParams(old_params, new_params))
        return mismatch("{s} and {s} take different parameters", lib.a, .{ old_name, new_name });
    return .active;
}

fn equalParams(x: []const library.Param, y: []const library.Param) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| {
        if (p.comptime_param != q.comptime_param or !std.mem.eql(u8, p.type, q.type)) return false;
    }
    return true;
}

fn mismatch(comptime format: []const u8, a: std.mem.Allocator, args: anytype) !Status {
    return .{ .mismatch = try a.print(format, args) };
}
