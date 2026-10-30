//! One seed orders the tests and seeds std.testing on every runner. A shard
//! runs its share of the tests, balanced by the durations the package records.
const std = @import("std");
const builtin = @import("builtin");
// Compiled into every package's test binaries, so it links std alone: any
// package it imported could be a second copy beside the tested package's own.

/// The column of `ci/durations.json` this test binary reads: its system and mode, and
/// its architecture where the hosted runners of one system have two (Linux and Windows
/// on ARM beside x86_64), so the two never share a column. A ThreadSanitizer build
/// has a column of its own, `-tsan`: it runs some tests many times slower than the
/// same mode without it, and others hardly so.
pub const key = @tagName(builtin.target.os.tag) ++ arch ++ "-" ++ @tagName(builtin.optimize) ++ if (builtin.sanitize_thread) "-tsan" else "";
const arch = switch (builtin.target.cpu.arch) {
    .x86_64 => "",
    .aarch64 => if (builtin.target.os.tag == .macos) "" else "-aarch64",
    else => |other| "-" ++ @tagName(other),
};

/// A test that records no time still costs its process a little.
pub const floor_seconds = 0.001;

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
/// `PREFLIGHT_TEST_SEED`), a shard that is not `i/n`, durations that are not
/// `ci/durations.json`'s shape, reading the environment, writing the seed
/// line, or memory. `Unexpected` is reading the environment on WASI.
pub const InitError = error{ InvalidSeed, InvalidShard, InvalidWeights, InvalidDurations, WriteFailed, Unexpected, OutOfMemory };
/// What `weigh` fails with: durations that are not `ci/durations.json`'s
/// shape, or memory.
pub const WeighError = error{ InvalidDurations, OutOfMemory };

/// Seeds std.testing and returns the indices of this shard's tests in seeded
/// order. `PREFLIGHT_SHARD` (`i/n`) selects the shard; `durations`, the text of
/// the package's `ci/durations.json` or empty, balances the split. With
/// `announce`, the seed and the shard's share go to stderr. A runner serving
/// the build runner passes false: Zig 0.17 shows any stderr of a passing run
/// step under a "failed command:" line, and each failure names its seed.
pub fn init(io: std.Io, process: std.process.Init.Minimal, args: []const []const u8, tests: []const std.lang.TestFn, durations: []const u8, announce: bool) InitError![]usize {
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
    const shard: Shard = try Shard.parse(env.get("PREFLIGHT_SHARD") orelse "");
    const names = try gpa.alloc([]const u8, tests.len);
    defer gpa.free(names);
    for (tests, names) |test_fn, *name| name.* = test_fn.name;
    const weights = try weigh(gpa, if (shard.count > 1 and durations.len > 0) durations else "{}", names, key);
    defer gpa.free(weights);
    const selected = try assign(gpa, names, weights, shard);
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

/// Each test's seconds in `column`, as `estimate` reads them from the text
/// of `ci/durations.json`.
pub fn weigh(gpa: std.mem.Allocator, json: []const u8, names: []const []const u8, column: []const u8) WeighError![]f64 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidDurations,
    };
    return (try estimate(gpa, value, names, column)).weights;
}

/// The column a test with no record in its own is weighed by: Linux Debug on
/// x86_64, which every tier records.
pub const reference_column = "linux-debug";

/// What `estimate` makes of a column: each test's seconds, the caller's to
/// free, and how many of them came from a record rather than the mean.
pub const Estimate = struct { weights: []f64, recorded: usize };

/// Each test's seconds in `column` of `durations`, a parsed `ci/durations.json`.
/// A test that column has no record of weighs its `reference_column` record
/// times the ratio of the two columns over the tests both recorded, so a
/// suite measured on Linux is weighed under emulation before its first full
/// run there. A test with neither record, or no ratio to scale by, weighs
/// the mean of the others; with no records every test weighs the same, so
/// the shards split by count.
pub fn estimate(gpa: std.mem.Allocator, durations: std.json.Value, names: []const []const u8, column: []const u8) WeighError!Estimate {
    if (durations != .object) return error.InvalidDurations;
    const own = try position(durations, column);
    const reference = if (std.mem.eql(u8, column, reference_column)) null else try position(durations, reference_column);
    const tests = durations.object.get("tests");
    if (tests != null and tests.? != .object) return error.InvalidDurations;
    const weights = try gpa.alloc(f64, names.len);
    errdefer gpa.free(weights);
    const referenced = try gpa.alloc(f64, names.len);
    defer gpa.free(referenced);
    // The ratio of `column` to the reference, over the tests both recorded.
    var both_own: f64 = 0;
    var both_reference: f64 = 0;
    for (names, weights, referenced) |name, *weight, *other| {
        weight.* = -1;
        other.* = -1;
        const row = (tests orelse continue).object.get(name) orelse continue;
        if (row != .array) return error.InvalidDurations;
        if (own) |i| if (try cell(row, i)) |seconds| {
            weight.* = @max(seconds, floor_seconds);
        };
        if (reference) |i| if (try cell(row, i)) |seconds| {
            other.* = @max(seconds, floor_seconds);
        };
        if (weight.* >= 0 and other.* >= 0) {
            both_own += weight.*;
            both_reference += other.*;
        }
    }
    const ratio: ?f64 = if (both_reference > 0) both_own / both_reference else null;
    var known: f64 = 0;
    var recorded: usize = 0;
    for (weights, referenced) |*weight, other| {
        if (weight.* < 0 and other >= 0) if (ratio) |r| {
            weight.* = other * r;
        };
        if (weight.* < 0) continue;
        known += weight.*;
        recorded += 1;
    }
    // `recorded` counts tests and cannot exceed names.len; floating-point
    // seconds stay one domain.
    const mean = if (recorded == 0) 1 else known / @as(f64, @floatFromInt(recorded));
    for (weights) |*weight| if (weight.* < 0) {
        weight.* = mean;
    };
    return .{ .weights = weights, .recorded = recorded };
}

/// Where `column` is among `durations`' keys, or null when it has none.
fn position(durations: std.json.Value, column: []const u8) WeighError!?usize {
    const keys = durations.object.get("keys") orelse return null;
    if (keys != .array) return error.InvalidDurations;
    for (keys.array.items, 0..) |item, i| if (item == .string and std.mem.eql(u8, item.string, column)) return i;
    return null;
}

/// A row's seconds in column `index`, or null where it has none.
fn cell(row: std.json.Value, index: usize) WeighError!?f64 {
    if (row.array.items.len <= index) return error.InvalidDurations;
    const seconds: f64 = switch (row.array.items[index]) {
        .null => return null,
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return error.InvalidDurations,
    };
    if (!(seconds >= 0)) return error.InvalidDurations;
    return seconds;
}

pub const AssignError = std.mem.Allocator.Error || error{ InvalidShard, InvalidWeights };

/// The tests `shard` runs, in index order: longest first onto the least
/// loaded shard. Every shard computes the same split from the same names
/// and weights; the names choose where ties start, so a package's small
/// test binaries do not all land on the first shard.
pub fn assign(gpa: std.mem.Allocator, names: []const []const u8, weights: []const f64, shard: Shard) AssignError![]usize {
    if (names.len != weights.len) return error.InvalidWeights;
    _ = try Shard.init(shard.index, shard.count);
    _ = std.math.mul(usize, shard.count, @sizeOf(f64)) catch return error.InvalidShard;
    // One shard index domain, a nonzero count with count*sizeof(f64) fitting usize, and
    // equal name/weight lengths: start+step < 2*count cannot overflow.
    const count = shard.count;
    const order = try gpa.alloc(usize, weights.len);
    defer gpa.free(order);
    for (order, 0..) |*index, i| index.* = i;
    std.mem.sort(usize, order, weights, struct {
        fn longer(w: []const f64, x: usize, y: usize) bool {
            return w[x] > w[y] or (w[x] == w[y] and x < y);
        }
    }.longer);
    const loads = try gpa.alloc(f64, count);
    defer gpa.free(loads);
    @memset(loads, 0);
    var hash: std.hash.Wyhash = .init(0);
    for (names) |name| {
        hash.update(name);
        hash.update(&.{0});
    }
    const start: usize = @intCast(hash.final() % count); // safe: modulo is below the validated usize shard count
    var selected: std.ArrayList(usize) = .empty;
    errdefer selected.deinit(gpa);
    for (order) |test_index| {
        var least = start;
        for (1..count) |step| {
            const candidate = (start + step) % count;
            if (loads[candidate] < loads[least]) least = candidate;
        }
        loads[least] += weights[test_index];
        if (least == shard.index) try selected.append(gpa, test_index);
    }
    std.mem.sort(usize, selected.items, {}, std.sort.asc(usize));
    return selected.toOwnedSlice(gpa);
}

comptime {
    if (@sizeOf(Shard) != 2 * @sizeOf(usize)) @compileError("shard domains must retain scalar storage");
}
