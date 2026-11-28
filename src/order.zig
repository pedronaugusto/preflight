//! One seed orders the tests and seeds std.testing on every runner. A shard runs its share of
//! the tests, chosen by their names.
const std = @import("std");
// Compiled into every package's test binaries, so it links std alone: any
// package it imported could be a second copy beside the tested package's own.

pub const Shard = struct {
    /// Zero-based, below `count`.
    index: usize,
    /// At least one.
    count: usize,

    pub const all: Shard = .{ .index = 0, .count = 1 };

    pub const ParseError = error{InvalidShard};

    /// Validate the index/count relation before any shard arithmetic.
    /// Zig permits direct field construction; assign rechecks this boundary.
    pub fn init(index: usize, count: usize) ParseError!Shard {
        if (count == 0 or index >= count) return error.InvalidShard;
        return .{ .index = index, .count = count };
    }

    /// Reads `i/n`, one-based, as the hosted matrix writes it. Empty is all.
    pub fn parse(text: []const u8) ParseError!Shard {
        if (text.len == 0) return all;
        const slash = std.mem.findScalar(u8, text, '/') orelse return error.InvalidShard;
        // The parser imports raw decimal values once, then constructs the checked
        // shard identity and count.
        const number = std.fmt.parseUnsigned(usize, text[0..slash], 10) catch return error.InvalidShard;
        const count = std.fmt.parseUnsigned(usize, text[slash + 1 ..], 10) catch return error.InvalidShard;
        if (number == 0 or number > count) return error.InvalidShard;
        return .{ .index = number - 1, .count = count };
    }
};

/// What `init` fails with: a seed that is no `u32` (`--seed=` or
/// `PREFLIGHT_TEST_SEED`), a shard that is not `i/n`, reading the environment, writing the seed
/// line, or memory. `Unexpected` is reading the environment on WASI.
pub const InitError = error{ InvalidSeed, InvalidShard, WriteFailed, Unexpected, OutOfMemory };

/// Seeds std.testing and returns the indices of this shard's tests in seeded
/// order. `PREFLIGHT_SHARD` (`i/n`) selects the shard (`assign`). With
/// `announce`, the seed and the shard's share go to stderr. A runner serving
/// the build runner passes false: Zig 0.17 shows any stderr of a passing run
/// step under a "failed command:" line, and each failure names its seed. An
/// `unsharded` binary (`Config.unsharded`) runs whole on shard 1/n and not at all
/// on the others: its tests answer each other or the host, and a split leaves one
/// side waiting on the other.
pub fn init(io: std.Io, process: std.process.Init.Minimal, args: []const []const u8, tests: []const std.lang.TestFn, announce: bool, unsharded: bool) InitError![]usize {
    const gpa = std.heap.page_allocator;
    var bytes: [4]u8 = undefined;
    std.Io.random(io, &bytes);
    var seed = std.mem.readInt(u32, &bytes, .little);
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--seed=")) seed = std.fmt.parseUnsigned(u32, arg[7..], 0) catch return error.InvalidSeed;
    }
    var env = try process.environ.createMap(gpa);
    defer env.deinit();
    if (env.get("PREFLIGHT_TEST_SEED")) |value| seed = std.fmt.parseUnsigned(u32, value, 0) catch return error.InvalidSeed;
    std.testing.random_seed = seed;
    const shard = share(try Shard.parse(env.get("PREFLIGHT_SHARD") orelse ""), unsharded) orelse return gpa.alloc(usize, 0);
    const names = try gpa.alloc([]const u8, tests.len);
    defer gpa.free(names);
    for (tests, names) |test_fn, *name| name.* = test_fn.name;
    const selected = try assign(gpa, names, shard);
    var random = std.Random.DefaultPrng.init(seed);
    random.random().shuffle(usize, selected);
    if (!announce) return selected;
    var buffer: [256]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
    try stderr.interface.print("preflight: test seed {d} (reproduce with PREFLIGHT_TEST_SEED={d})\n", .{ seed, seed });
    if (shard.count > 1) {
        try stderr.interface.print("preflight: shard {d}/{d} runs {d} of {d} tests\n", .{ shard.index + 1, shard.count, selected.len, tests.len });
    }
    try stderr.interface.flush();
    return selected;
}

/// The share of a binary's tests the job's shard `parsed` runs: an unsharded binary's are all of
/// them on shard 1/n, and none (null) on the others.
pub fn share(parsed: Shard, unsharded: bool) ?Shard {
    if (!unsharded) return parsed;
    return if (parsed.index == 0) .all else null;
}

pub const AssignError = std.mem.Allocator.Error || error{InvalidShard};

/// The tests `shard` runs, in index order: each test's fully-qualified name, hashed, modulo the
/// shard count. Every shard computes the same split from the same names, and a test keeps its
/// shard as others are added or go.
pub fn assign(gpa: std.mem.Allocator, names: []const []const u8, shard: Shard) AssignError![]usize {
    _ = try Shard.init(shard.index, shard.count);
    var selected: std.ArrayList(usize) = .empty;
    errdefer selected.deinit(gpa);
    for (names, 0..) |name, index| {
        if (std.hash.Wyhash.hash(0, name) % shard.count == shard.index) try selected.append(gpa, index);
    }
    return selected.toOwnedSlice(gpa);
}

comptime {
    if (@sizeOf(Shard) != 2 * @sizeOf(usize)) @compileError("shard domains must retain scalar storage");
}
