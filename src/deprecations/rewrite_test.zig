const std = @import("std");
const builtin = @import("builtin");
const library = @import("library.zig");
const table = @import("table.zig");
const rewrite = @import("rewrite.zig");
const test_options = @import("test_options");

/// A std the size of these tests: each deprecation in the shape the real
/// one has.
const fixture = [_][2][]const u8{
    .{
        "std.zig",
        \\pub const mem = @import("mem.zig");
        \\pub const fmt = @import("fmt.zig");
        \\pub const fs = @import("fs.zig");
        \\pub const heap = @import("heap.zig");
        \\pub const Io = @import("Io.zig");
        \\pub const Build = @import("Build.zig");
        \\pub const lang = @import("lang.zig");
        \\pub const array_list = @import("array_list.zig");
        \\pub fn ArrayList(comptime T: type) type {
        \\    return array_list.Aligned(T, null);
        \\}
        \\pub const array_hash_map = @import("array_hash_map.zig");
        \\/// Deprecated; use `array_hash_map.Auto`.
        \\pub const AutoArrayHashMapUnmanaged = array_hash_map.Auto;
        \\
    },
    .{
        "mem.zig",
        \\const std = @import("std");
        \\pub const Allocator = @import("mem/Allocator.zig");
        \\pub const PrintError = error{NoSpaceLeft};
        \\pub fn find(comptime T: type, haystack: []const T, needle: []const T) ?usize {}
        \\/// Deprecated in favor of `find`.
        \\pub const indexOf = find;
        \\pub fn print(buffer: []u8, comptime format: []const u8, args: anytype) PrintError![]u8 {}
        \\pub fn printSentinel(buffer: []u8, comptime format: []const u8, args: anytype, comptime sentinel: u8) PrintError![:sentinel]u8 {}
        \\/// Copy all of source into dest at position 0.
        \\/// This function is deprecated; use @memmove instead.
        \\pub fn copyForwards(comptime T: type, dest: []T, source: []const T) void {}
        \\/// This function is deprecated; use @memmove instead.
        \\pub fn copyBackwards(comptime T: type, dest: []T, source: []const T) void {}
        \\
    },
    .{
        "mem/Allocator.zig",
        \\const Allocator = @This();
        \\pub const Error = error{OutOfMemory};
        \\pub fn print(a: Allocator, comptime format: []const u8, args: anytype) Error![]u8 {}
        \\pub fn printSentinel(a: Allocator, comptime format: []const u8, args: anytype, comptime sentinel: u8) Error![:sentinel]u8 {}
        \\
    },
    .{
        "fmt.zig",
        \\const std = @import("std");
        \\const mem = std.mem;
        \\const Allocator = mem.Allocator;
        \\/// Deprecated in favor of `mem.PrintError`.
        \\pub const BufPrintError = mem.PrintError;
        \\/// Deprecated in favor of `mem.print`.
        \\pub fn bufPrint(buf: []u8, comptime fmt: []const u8, args: anytype) BufPrintError![]u8 {}
        \\/// Deprecated in favor of `mem.printSentinel`.
        \\pub fn bufPrintSentinel(buf: []u8, comptime fmt: []const u8, args: anytype, comptime sentinel: u8) BufPrintError![:sentinel]u8 {}
        \\/// Deprecated in favor of `Allocator.print`.
        \\pub fn allocPrint(gpa: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error![]u8 {}
        \\/// Deprecated in favor of `Allocator.printSentinel`.
        \\pub fn allocPrintSentinel(gpa: Allocator, comptime fmt: []const u8, args: anytype, comptime sentinel: u8) Allocator.Error![:sentinel]u8 {}
        \\
    },
    .{
        "fs.zig",
        \\const std = @import("std.zig");
        \\/// Deprecated, use `std.Io.Dir.path`.
        \\pub const path = @import("fs/path.zig");
        \\/// Deprecated, use `std.Io.Dir.max_path_bytes`.
        \\pub const max_path_bytes = std.Io.Dir.max_path_bytes;
        \\
    },
    .{
        "fs/path.zig",
        \\const std = @import("std");
        \\pub fn resolveAlloc(gpa: std.mem.Allocator, paths: []const []const u8) std.mem.Allocator.Error![]u8 {}
        \\/// Deprecated in favor of `resolveAlloc`.
        \\pub const resolve = resolveAlloc;
        \\
    },
    .{
        "heap.zig",
        \\/// Deprecated; use `SafeAllocator`.
        \\pub const DebugAllocator = @import("heap/debug_allocator.zig").DebugAllocator;
        \\
    },
    .{ "Io.zig", "pub const Dir = @import(\"Io/Dir.zig\");\n" },
    .{ "Io/Dir.zig", "const std = @import(\"std\");\npub const path = std.fs.path;\npub const max_path_bytes = 4096;\n" },
    .{ "array_hash_map.zig", "pub fn Auto(comptime K: type, comptime V: type) type {}\n" },
    .{
        "array_list.zig",
        \\pub fn Aligned(comptime T: type, comptime alignment: ?u8) type {
        \\    if (alignment) |a| {
        \\        if (a == 1) return Aligned(T, null);
        \\    }
        \\    return struct {
        \\        const Self = @This();
        \\        /// Deprecated in favor of `last`
        \\        pub const getLastOrNull = last;
        \\        pub fn last(self: Self) ?T {}
        \\    };
        \\}
        \\
    },
    .{
        "lang.zig",
        \\pub const Optimize = enum {
        \\    debug,
        \\    fast,
        \\    /// Deprecated, to be removed after 0.18.0
        \\    pub const Debug: @This() = .debug;
        \\};
        \\
    },
    .{
        "Build/Step.zig",
        \\pub const Run = @import("Step/Run.zig");
        \\pub const Compile = struct {};
        \\
    },
    .{
        "Build/Step/Run.zig",
        \\const Run = @This();
        \\const Compile = @import("../Step.zig").Compile;
        \\pub const PathArgOptions = struct { prefix: []const u8 = "", suffix: []const u8 = "" };
        \\/// Deprecated, use `addArtifactArg2`.
        \\pub fn addArtifactArg(run: *Run, artifact: *Compile) void {
        \\    run.addArtifactArg2(artifact, .{});
        \\}
        \\/// Deprecated, use `addArtifactArg2`.
        \\pub fn addPrefixedArtifactArg(run: *Run, prefix: []const u8, artifact: *Compile) void {
        \\    run.addArtifactArg2(artifact, .{ .prefix = prefix });
        \\}
        \\pub fn addArtifactArg2(run: *Run, artifact: *Compile, options: PathArgOptions) void {}
        \\/// Deprecated, use `enableProtocolMode`.
        \\pub fn enableTestRunnerMode(run: *Run) void {
        \\    run.stdio = .zig_test;
        \\}
        \\
    },
    .{
        "Build.zig",
        \\const Build = @This();
        \\pub const Step = @import("Build/Step.zig");
        \\pub const Dependency = struct {};
        \\pub fn addRunArtifact(b: *Build, exe: *Step.Compile) *Step.Run {}
        \\/// Deprecated in favor of `dependencyLazy`.
        \\pub fn lazyDependency(b: *Build, name: []const u8, args: anytype) ?*Dependency {}
        \\pub fn dependencyLazy(b: *Build, name: []const u8, args: anytype) error{LazyDependencyNeeded}!*Dependency {}
        \\
    },
};

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    lib: library.Library,
    entries: []const table.Entry,

    /// The fixture std, with `replace` swapping one file's text.
    fn init(f: *Fixture, replace: ?[2][]const u8) !void {
        f.arena = .init(std.testing.allocator);
        f.tmp = std.testing.tmpDir(.{});
        const io = std.testing.io;
        for (fixture) |pair| {
            const text = if (replace) |r| (if (std.mem.eql(u8, r[0], pair[0])) r[1] else pair[1]) else pair[1];
            if (std.Io.Dir.path.dirname(pair[0])) |dir| try f.tmp.dir.createDirPath(io, try std.mem.concat(f.arena.allocator(), u8, &.{ "std/", dir }));
            try f.tmp.dir.createDirPath(io, "std");
            try f.tmp.dir.writeFile(io, .{ .sub_path = try std.mem.concat(f.arena.allocator(), u8, &.{ "std/", pair[0] }), .data = text });
        }
        f.lib = .{ .a = f.arena.allocator(), .io = io, .dir = try f.tmp.dir.openDir(io, "std", .{}) };
        f.entries = table.releases[0].entries;
        for (f.entries) |entry| switch (entry) {
            .rename => |r| try f.lib.addRename(r.old, r.new),
            .receiver => |r| try f.lib.addRename(r.old, r.new),
            else => {},
        };
    }

    fn deinit(f: *Fixture) void {
        f.lib.dir.close(std.testing.io);
        f.tmp.cleanup();
        f.arena.deinit();
        f.* = undefined;
    }

    fn expect(f: *Fixture, source: []const u8, expected: []const u8) !rewrite.Outcome {
        const outcome = try rewrite.file(f.arena.allocator(), &f.lib, f.entries, source);
        try std.testing.expectEqualStrings(expected, outcome.text);
        return outcome;
    }
};

test "aliases: std's and the file's own resolve to what they stand for" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    const outcome = try f.expect(
        \\const std = @import("std");
        \\const mem = std.mem;
        \\const indexOf = std.mem.indexOf;
        \\const path = std.fs.path;
        \\pub fn f(s: []const u8) ?usize {
        \\    _ = std.mem.indexOf(u8, s, "a");
        \\    _ = indexOf(u8, s, "b");
        \\    var map: std.AutoArrayHashMapUnmanaged(u8, u8) = .empty;
        \\    _ = &map;
        \\    _ = std.fs.path.resolve;
        \\    _ = path.resolve;
        \\    _ = @import("std").fmt.BufPrintError;
        \\    _ = std.fs.max_path_bytes;
        \\    return mem.indexOf(u8, s, "c");
        \\}
        \\
    ,
        \\const std = @import("std");
        \\const mem = std.mem;
        \\const indexOf = std.mem.find;
        \\const path = std.Io.Dir.path;
        \\pub fn f(s: []const u8) ?usize {
        \\    _ = std.mem.find(u8, s, "a");
        \\    _ = indexOf(u8, s, "b");
        \\    var map: std.array_hash_map.Auto(u8, u8) = .empty;
        \\    _ = &map;
        \\    _ = std.Io.Dir.path.resolveAlloc;
        \\    _ = path.resolveAlloc;
        \\    _ = @import("std").mem.PrintError;
        \\    _ = std.Io.Dir.max_path_bytes;
        \\    return mem.find(u8, s, "c");
        \\}
        \\
    );
    try std.testing.expectEqual(0, outcome.leftovers.len);
}

test "aliases: a bitwise or after a parenthesis is no capture" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    _ = try f.expect(
        \\const std = @import("std");
        \\fn join(high: u64, low: u64) u64 {
        \\    return (high << 32) | low;
        \\}
        \\test {
        \\    var buffer: [std.fs.max_path_bytes]u8 = undefined;
        \\    _ = &buffer;
        \\}
        \\
    ,
        \\const std = @import("std");
        \\fn join(high: u64, low: u64) u64 {
        \\    return (high << 32) | low;
        \\}
        \\test {
        \\    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        \\    _ = &buffer;
        \\}
        \\
    );
}

test "aliases: a name bound another way somewhere is left alone" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    const source =
        \\const std = @import("std");
        \\fn a() void {
        \\    const mem = std.mem;
        \\    _ = mem;
        \\}
        \\fn b(mem: anytype) void {
        \\    _ = mem.indexOf(u8, "a", "b");
        \\}
        \\
    ;
    _ = try f.expect(source, source);
}

test "argument moves: the allocator becomes the receiver" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    const outcome = try f.expect(
        \\const std = @import("std");
        \\const fmt = std.fmt;
        \\pub fn f(a: std.mem.Allocator, arena: *std.heap.ArenaAllocator, buffer: []u8) !void {
        \\    _ = try std.fmt.allocPrint(a, "{d}", .{1});
        \\    _ = try fmt.allocPrint(arena.allocator(), "{s}", .{try std.fmt.allocPrint(a, "{d}", .{2})});
        \\    _ = try std.fmt.allocPrint(
        \\        a,
        \\        "{d}",
        \\        .{3},
        \\    );
        \\    _ = try std.fmt.allocPrint(if (true) a else a, "{d}", .{4});
        \\    _ = try std.fmt.bufPrint(buffer, "{d}", .{5});
        \\    const print = std.fmt.allocPrint;
        \\    _ = print;
        \\}
        \\
    ,
        \\const std = @import("std");
        \\pub fn f(a: std.mem.Allocator, arena: *std.heap.ArenaAllocator, buffer: []u8) !void {
        \\    _ = try a.print("{d}", .{1});
        \\    _ = try arena.allocator().print("{s}", .{try a.print("{d}", .{2})});
        \\    _ = try a.print(
        \\        "{d}",
        \\        .{3},
        \\    );
        \\    _ = try std.mem.Allocator.print(if (true) a else a, "{d}", .{4});
        \\    _ = try std.mem.print(buffer, "{d}", .{5});
        \\    const print = std.mem.Allocator.print;
        \\    _ = print;
        \\}
        \\
    );
    // `const fmt = std.fmt;` served only the moved call.
    try std.testing.expectEqual(rewrite.Kind.unused, outcome.changes[0].kind);
    try std.testing.expectEqual(2, outcome.changes[0].line);
}

test "comments: a rewrite never deletes one" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    const outcome = try f.expect(
        \\const std = @import("std");
        \\pub fn f(a: std.mem.Allocator) !void {
        \\    _ = try std.fmt.allocPrint(a, // the arena
        \\        "{d}", .{1});
        \\    _ = std.mem // the slice
        \\        .indexOf(u8, "a", "b");
        \\}
        \\
    ,
        \\const std = @import("std");
        \\pub fn f(a: std.mem.Allocator) !void {
        \\    _ = try std.mem.Allocator.print(a, // the arena
        \\        "{d}", .{1});
        \\    _ = std.mem // the slice
        \\        .indexOf(u8, "a", "b");
        \\}
        \\
    );
    try std.testing.expectEqual(1, outcome.leftovers.len);
    try std.testing.expectEqualStrings("a comment sits inside the rewrite", outcome.leftovers[0].doc);
}

test "argument moves: copies become @memmove when the source reads twice the same" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    const outcome = try f.expect(
        \\const std = @import("std");
        \\pub fn f(dest: []u8, source: []const u8, s: struct { bytes: []const u8 }) void {
        \\    std.mem.copyForwards(u8, dest, source);
        \\    std.mem.copyForwards(u8, dest[1..], s.bytes);
        \\    std.mem.copyForwards(u8, dest, source[1..]);
        \\}
        \\
    ,
        \\const std = @import("std");
        \\pub fn f(dest: []u8, source: []const u8, s: struct { bytes: []const u8 }) void {
        \\    @memmove(dest[0..source.len], source);
        \\    @memmove(dest[1..][0..s.bytes.len], s.bytes);
        \\    std.mem.copyForwards(u8, dest, source[1..]);
        \\}
        \\
    );
    try std.testing.expectEqual(1, outcome.leftovers.len);
    try std.testing.expectEqual(5, outcome.leftovers[0].line);
}

test "sentinel variants keep their sentinel" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    _ = try f.expect(
        \\const std = @import("std");
        \\pub fn f(a: std.mem.Allocator, buffer: []u8) !void {
        \\    _ = try std.fmt.allocPrintSentinel(a, "{d}", .{1}, 0);
        \\    _ = try std.fmt.bufPrintSentinel(buffer, "{d}", .{2}, 0);
        \\}
        \\
    ,
        \\const std = @import("std");
        \\pub fn f(a: std.mem.Allocator, buffer: []u8) !void {
        \\    _ = try a.printSentinel("{d}", .{1}, 0);
        \\    _ = try std.mem.printSentinel(buffer, "{d}", .{2}, 0);
        \\}
        \\
    );
}

test "orelse becomes catch on a value of the declared type; the rest is listed" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    const outcome = try f.expect(
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const dep = b.lazyDependency("x", .{}) orelse return;
        \\    _ = dep;
        \\    if (b.lazyDependency("y", .{})) |d| _ = d;
        \\    var gpa: std.heap.DebugAllocator(.{}) = .init;
        \\    _ = &gpa;
        \\}
        \\
    ,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const dep = b.dependencyLazy("x", .{}) catch return;
        \\    _ = dep;
        \\    if (b.lazyDependency("y", .{})) |d| _ = d;
        \\    var gpa: std.heap.DebugAllocator(.{}) = .init;
        \\    _ = &gpa;
        \\}
        \\
    );
    try std.testing.expectEqual(2, outcome.leftovers.len);
    try std.testing.expectEqualStrings("std.Build.lazyDependency", outcome.leftovers[0].name);
    try std.testing.expectEqualStrings("std.heap.DebugAllocator", outcome.leftovers[1].name);
}

test "signature check: the table holds only where std agrees" {
    {
        var f: Fixture = undefined;
        try f.init(null);
        defer f.deinit();
        // The fixture leaves out most forwarding methods: absent, not wrong.
        for (table.releases[0].entries) |entry| try std.testing.expect(try table.check(&f.lib, entry) != .mismatch);
        try std.testing.expectEqual(.active, std.meta.activeTag(try table.check(&f.lib, .{ .forward = "std.Build.Step.Run.addPrefixedArtifactArg" })));
    }
    {
        var f: Fixture = undefined;
        try f.init(.{
            "mem/Allocator.zig",
            \\const Allocator = @This();
            \\pub const Error = error{OutOfMemory};
            \\pub fn print(a: Allocator, args: anytype, comptime format: []const u8) Error![]u8 {}
            \\pub fn printSentinel(a: Allocator, comptime format: []const u8, args: anytype, comptime sentinel: u8) Error![:sentinel]u8 {}
            \\
        });
        defer f.deinit();
        const status = try table.check(&f.lib, .{ .receiver = .{ .old = "std.fmt.allocPrint", .new = "std.mem.Allocator.print" } });
        try std.testing.expectEqualStrings("std.fmt.allocPrint and std.mem.Allocator.print take different parameters", status.mismatch);
    }
    {
        var f: Fixture = undefined;
        try f.init(.{ "fs.zig", "pub const path = @import(\"fs/path.zig\");\n" });
        defer f.deinit();
        const status = try table.check(&f.lib, .{ .rename = .{ .old = "std.fs.path", .new = "std.Io.Dir.path" } });
        try std.testing.expectEqualStrings("std.fs.path is not deprecated", status.mismatch);
        try std.testing.expectEqual(.absent, std.meta.activeTag(try table.check(&f.lib, .{ .memmove = "std.mem.copyEither" })));
    }
}

test "methods: a forwarding method becomes the call it makes, on a value a method returned" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    const outcome = try f.expect(
        \\const std = @import("std");
        \\pub fn build(b: *std.Build, exe: *std.Build.Step.Compile) void {
        \\    const run = b.addRunArtifact(exe);
        \\    run.addArtifactArg(exe);
        \\    run.addPrefixedArtifactArg("--tool=", tool(b));
        \\    run.addPrefixedArtifactArg(prefix(b), tool(b));
        \\    run.enableTestRunnerMode();
        \\}
        \\
    ,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build, exe: *std.Build.Step.Compile) void {
        \\    const run = b.addRunArtifact(exe);
        \\    run.addArtifactArg2(exe, .{});
        \\    run.addArtifactArg2(tool(b), .{ .prefix = "--tool=" });
        \\    run.addPrefixedArtifactArg(prefix(b), tool(b));
        \\    run.enableTestRunnerMode();
        \\}
        \\
    );
    // Two calls would swap; a deprecated method the table does not move is
    // listed.
    try std.testing.expectEqual(2, outcome.leftovers.len);
    try std.testing.expectEqualStrings("its arguments would run in another order", outcome.leftovers[0].doc);
    try std.testing.expectEqualStrings("std.Build.Step.Run.enableTestRunnerMode", outcome.leftovers[1].name);
}

test "methods: std's own method aliases rename, through generic types too" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    const outcome = try f.expect(
        \\const std = @import("std");
        \\pub fn f(list: *std.ArrayList(u8)) ?u8 {
        \\    var ops: std.ArrayList(u8) = .empty;
        \\    _ = ops.getLastOrNull();
        \\    return list.getLastOrNull();
        \\}
        \\
    ,
        \\const std = @import("std");
        \\pub fn f(list: *std.ArrayList(u8)) ?u8 {
        \\    var ops: std.ArrayList(u8) = .empty;
        \\    _ = ops.last();
        \\    return list.last();
        \\}
        \\
    );
    try std.testing.expectEqual(0, outcome.leftovers.len);
}

test "builtin: the compiler's deprecated fields move to the target" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    _ = try f.expect(
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\const native_os = builtin.os.tag;
        \\pub fn f() bool {
        \\    return builtin.mode == .debug and @import("builtin").cpu.arch == .x86_64 and
        \\        builtin.object_format == .elf and builtin.abi == .gnu and builtin.is_test and
        \\        builtin.target.os.tag == native_os and std.lang.Optimize.Debug == .debug;
        \\}
        \\
    ,
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\const native_os = builtin.target.os.tag;
        \\pub fn f() bool {
        \\    return builtin.optimize == .debug and @import("builtin").target.cpu.arch == .x86_64 and
        \\        builtin.target.ofmt == .elf and builtin.target.abi == .gnu and builtin.is_test and
        \\        builtin.target.os.tag == native_os and std.lang.Optimize.debug == .debug;
        \\}
        \\
    );
}

test "signature check: a forward or a builtin move holds only where the compiler agrees" {
    var f: Fixture = undefined;
    try f.init(.{
        "Build/Step/Run.zig",
        \\const Run = @This();
        \\/// Deprecated, use `addArtifactArg2`.
        \\pub fn addArtifactArg(run: *Run, artifact: anytype) void {
        \\    run.addArtifactArg2(artifact, .{});
        \\    run.count += 1;
        \\}
        \\pub fn addArtifactArg2(run: *Run, artifact: anytype, options: anytype) void {}
        \\
    });
    defer f.deinit();
    const forward = try table.check(&f.lib, .{ .forward = "std.Build.Step.Run.addArtifactArg" });
    try std.testing.expectEqualStrings("std.Build.Step.Run.addArtifactArg does more than call its replacement on its receiver", forward.mismatch);
    const moved = try table.check(&f.lib, .{ .builtin = .{ .old = "os", .new = "target.cpu" } });
    try std.testing.expect(std.mem.startsWith(u8, moved.mismatch, "builtin.os is Target.Os and builtin.target.cpu is"));
    try std.testing.expectEqual(.absent, std.meta.activeTag(try table.check(&f.lib, .{ .builtin = .{ .old = "removed", .new = "target" } })));
}

test "signature check: the Zig 0.17 table matches Zig 0.17's std" {
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 17) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, test_options.zig_std, .{});
    defer dir.close(io);
    var lib: library.Library = .{ .a = arena.allocator(), .io = io, .dir = dir };
    const release = table.find(.{ .major = 0, .minor = 17, .patch = 0 }).?;
    for (release.entries) |entry| {
        const status = try table.check(&lib, entry);
        if (status == .mismatch) std.debug.print("{s}\n", .{status.mismatch});
        try std.testing.expectEqual(.active, std.meta.activeTag(status));
        switch (entry) {
            .rename => |r| try lib.addRename(r.old, r.new),
            .receiver => |r| try lib.addRename(r.old, r.new),
            else => {},
        }
    }
    const normal = try lib.normalize(&.{ "std", "fs", "path", "resolve" });
    try std.testing.expectEqualStrings("std.Io.Dir.path.resolveAlloc", try std.mem.join(arena.allocator(), ".", normal.path));
    const builtin_type = try lib.normalize(&.{ "std", "builtin", "OptimizeMode" });
    try std.testing.expectEqualStrings("std.lang.Optimize", try std.mem.join(arena.allocator(), ".", builtin_type.path));
    // The shapes the 0.17 port left behind, against the real std.
    const outcome = try rewrite.file(arena.allocator(), &lib, release.entries,
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\pub fn build(b: *std.Build, exe: *std.Build.Step.Compile) void {
        \\    const run = b.addRunArtifact(exe);
        \\    run.addDirectoryArg(b.path("std"));
        \\    run.addArtifactArg(exe);
        \\    var ops: std.ArrayList(u8) = .empty;
        \\    _ = ops.getLastOrNull();
        \\    _ = @tagName(builtin.os.tag) ++ @tagName(builtin.mode);
        \\    _ = std.lang.Optimize.ReleaseFast;
        \\}
        \\
    );
    try std.testing.expectEqualStrings(
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\pub fn build(b: *std.Build, exe: *std.Build.Step.Compile) void {
        \\    const run = b.addRunArtifact(exe);
        \\    run.addDirectoryArg2(b.path("std"), .{});
        \\    run.addArtifactArg2(exe, .{});
        \\    var ops: std.ArrayList(u8) = .empty;
        \\    _ = ops.last();
        \\    _ = @tagName(builtin.target.os.tag) ++ @tagName(builtin.optimize);
        \\    _ = std.lang.Optimize.fast;
        \\}
        \\
    , outcome.text);
    try std.testing.expectEqual(0, outcome.leftovers.len);
}

test "builtin: a name bound to a deprecated field moves with its declaration and is left alone where it is used" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    _ = try f.expect(
        \\const builtin = @import("builtin");
        \\const os = builtin.os;
        \\pub fn f() bool {
        \\    return os.tag == .linux;
        \\}
        \\
    ,
        \\const builtin = @import("builtin");
        \\const os = builtin.target.os;
        \\pub fn f() bool {
        \\    return os.tag == .linux;
        \\}
        \\
    );
}
