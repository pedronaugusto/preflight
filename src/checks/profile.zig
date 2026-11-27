//! A run's records refresh what the next plan is sized by: each test's seconds, by which the
//! shards balance, and each job's (`legs`), by which the plan deals a tier's work into its jobs.
const std = @import("std");
const src = @import("source.zig");
const seam = @import("input.zig");
const Memory = @import("phases.zig").Memory;

/// Seconds per test name, per target column (`windows-Debug`).
pub const Durations = struct {
    tests: std.array_hash_map.String(std.array_hash_map.String(f64)) = .empty,
    keys: std.array_hash_map.String(void) = .empty,
    /// The columns a finished run measured last: each holds every test that job runs, so a
    /// test one lacks is not run there (an end-to-end suite the emulated build leaves out),
    /// where a column only cut runs measured may lack a test they never reached.
    complete: std.array_hash_map.String(void) = .empty,
    /// What each job spent, by its record name (`matrix.recordName`): what the plan sizes it by.
    legs: std.array_hash_map.String(Leg) = .empty,
    records: usize = 0,

    fn put(d: *Durations, a: std.mem.Allocator, name: []const u8, column: []const u8, seconds: f64) !void {
        try d.keys.put(a, column, {});
        const row = try d.tests.getOrPut(a, name);
        if (!row.found_existing) row.value_ptr.* = .empty;
        const cell = try row.value_ptr.getOrPut(a, column);
        cell.value_ptr.* = if (cell.found_existing) @max(cell.value_ptr.*, seconds) else seconds;
    }
};

/// What a job's shards spent, together: the most any spent besides its tests (its setup,
/// configuring and building), the seconds of tests they ran, scaled to every shard where the
/// run recorded only some, how many shards it ran in, and whether each recorded shard finished
/// within its job's minutes.
pub const Leg = struct { overhead: f64, tests: f64, shards: usize, finished: bool };

/// One shard's record of a job (`legRecord`): `leg` is its record name, `seconds` its whole run,
/// `tests` the seconds of the tests it ran.
const LegShard = struct { shard: []const u8, seconds: f64, tests: f64, finished: bool };

/// The record a job's run writes of itself, one line, beside its tests' and phases' records:
/// `ran` is how many tests it ran, which a profile refuses with no seconds recorded of them.
pub fn legRecord(a: std.mem.Allocator, name: []const u8, shard: []const u8, seconds: f64, tests: f64, ran: usize, finished: bool) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{ .leg = name, .shard = shard, .seconds = seconds, .tests = tests, .ran = ran, .finished = finished }, .{});
}

/// The seconds of tests the records under `root` hold: what a job's tests took, beside the rest
/// of its run.
pub fn testSeconds(c: src.Context, root: []const u8) !f64 {
    var dir = c.directory().openDir(c.io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(c.io);
    var walker = try dir.walk(c.a);
    defer walker.deinit();
    var total: f64 = 0;
    while (try walker.next(c.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".ndjson")) continue;
        var records = try Records.open(c, dir, root, entry.path);
        while (try records.next()) |value| {
            if (src.get(value, "key") == .null or src.get(value, "name") == .null) continue;
            total += try records.seconds(value);
        }
    }
    return total;
}

pub fn reset(c: src.Context, root: []const u8) !void {
    try c.directory().deleteTree(c.io, root);
}

/// Reads every `.ndjson` record under `root`. A column this run measured
/// replaces the one in `previous`; columns it did not measure are kept. With
/// `partial`, the records are of a run that did not finish (a job that failed
/// or ran out of time), and every test they do not record keeps its earlier
/// cell, so the tests a killed job never reached keep what an earlier run
/// measured of them. A test that two shards of one column both ran fails: the
/// split is broken. A column a finished run measured is complete (`Durations.complete`), and
/// stays so through a cut run, which records a share of the same tests.
pub fn summarize(c: src.Context, root: []const u8, previous: src.Value, partial: bool) !Durations {
    var result: Durations = .{};
    // The shard that recorded each test, by name and column.
    var shards: std.StringHashMapUnmanaged([]const u8) = .empty;
    var split = true;
    var legs: std.array_hash_map.String(std.ArrayList(LegShard)) = .empty;
    var dir = try c.directory().openDir(c.io, root, .{ .iterate = true });
    defer dir.close(c.io);
    var walker = try dir.walk(c.a);
    defer walker.deinit();
    while (try walker.next(c.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".ndjson")) continue;
        var records = try Records.open(c, dir, root, entry.path);
        while (try records.next()) |value| {
            // A phase of a job is not a test.
            if (src.get(value, "phase") != .null) continue;
            const seconds = try records.seconds(value);
            if (src.get(value, "leg") != .null) {
                const finished = src.get(value, "finished");
                const ran = src.get(value, "ran");
                if (finished != .bool or ran != .integer or ran.integer < 0) return error.InvalidLegRecord;
                const leg_name = try src.string(src.get(value, "leg"), "");
                const tested = try number(src.get(value, "tests"));
                // Tests that ran and recorded no second of themselves are a recording that
                // failed, not a measurement: sized by it, the next plan would read the shard's
                // whole run as its setup.
                if (tested == 0 and ran.integer > 0) {
                    c.report("profile: {s}/{s}:{d}: {s} (shard {s}) ran {d} tests and recorded no seconds of them: a recording error, not a measurement\n", .{ records.root, records.path, records.line, leg_name, try src.string(src.get(value, "shard"), ""), ran.integer });
                    return error.LegTestsUnrecorded;
                }
                const held = try legs.getOrPut(c.a, try c.a.dupe(u8, leg_name));
                if (!held.found_existing) held.value_ptr.* = .empty;
                try held.value_ptr.append(c.a, .{
                    .shard = try c.a.dupe(u8, try src.string(src.get(value, "shard"), "")),
                    .seconds = seconds,
                    .tests = tested,
                    .finished = finished.bool,
                });
                continue;
            }
            result.records += 1;
            const column = try src.string(src.get(value, "key"), "");
            if (column.len == 0) continue;
            const name = try src.string(src.get(value, "name"), "");
            const shard = try src.string(src.get(value, "shard"), "");
            const seen = try shards.getOrPut(c.a, try c.a.print("{s}\x00{s}", .{ name, column }));
            if (!seen.found_existing) {
                seen.value_ptr.* = try c.a.dupe(u8, shard);
            } else if (!std.mem.eql(u8, seen.value_ptr.*, shard)) {
                c.report("profile: {s} ran on shards {s} and {s} of {s}\n", .{ name, seen.value_ptr.*, shard, column });
                split = false;
            }
            try result.put(c.a, try c.a.dupe(u8, try src.string(src.get(value, "name"), "")), try c.a.dupe(u8, column), seconds);
        }
    }
    if (!split) return error.TestOnTwoShards;
    for (legs.keys(), legs.values()) |name, recorded| try result.legs.put(c.a, name, try foldLeg(recorded.items));
    const kept = src.get(previous, "legs");
    if (kept == .object) {
        for (kept.object.keys(), kept.object.values()) |name, entry| {
            if (result.legs.contains(name)) continue;
            const finished = src.get(entry, "finished");
            const count = src.get(entry, "shards");
            if (finished != .bool or count != .integer or count.integer < 1) return error.InvalidDurations;
            try result.legs.put(c.a, name, .{
                .overhead = try number(src.get(entry, "overhead")),
                .tests = try number(src.get(entry, "tests")),
                .shards = std.math.cast(usize, count.integer) orelse return error.InvalidDurations,
                .finished = finished.bool,
            });
        }
    } else if (kept != .null) return error.InvalidDurations;
    const measured = try result.keys.clone(c.a);
    for (try src.items(src.get(previous, "complete"))) |column| {
        if (column != .string) return error.InvalidDurations;
        try result.complete.put(c.a, column.string, {});
    }
    if (!partial) for (measured.keys()) |column| try result.complete.put(c.a, column, {});
    const keys = try src.items(src.get(previous, "keys"));
    const tests = src.get(previous, "tests");
    if (tests == .object) {
        var rows = tests.object.iterator();
        while (rows.next()) |row| {
            const cells = try src.items(row.value_ptr.*);
            if (cells.len != keys.len) return error.InvalidDurations;
            for (keys, cells) |column, cell| {
                if (column != .string or cell == .null) continue;
                const replaced = if (partial) shards.contains(try c.a.print("{s}\x00{s}", .{ row.key_ptr.*, column.string })) else measured.contains(column.string);
                if (replaced) continue;
                try result.put(c.a, row.key_ptr.*, column.string, try number(cell));
            }
        }
    }
    return result;
}

/// The records of one `.ndjson` file under the root, a JSON object a line. A
/// line that is not one, or a record without its seconds, stops the profile
/// with the file and line named: a job's records can arrive cut short or
/// interleaved with another's, and the error alone names neither.
const Records = struct {
    c: src.Context,
    root: []const u8,
    path: []const u8,
    lines: std.mem.SplitIterator(u8, .scalar),
    line: usize = 0,

    fn open(c: src.Context, dir: std.Io.Dir, root: []const u8, path: []const u8) !Records {
        const text = try seam.document(c.io, dir, path, c.a, .whole);
        return .{ .c = c, .root = root, .path = try c.a.dupe(u8, path), .lines = std.mem.splitScalar(u8, text, '\n') };
    }

    fn next(r: *Records) !?src.Value {
        while (r.lines.next()) |text| {
            r.line += 1;
            if (std.mem.trim(u8, text, " \t\r").len == 0) continue;
            const parsed = std.json.parseFromSlice(src.Value, r.c.a, text, .{}) catch |err| {
                if (err != error.OutOfMemory) r.c.report("profile: {s}/{s}:{d}: not a JSON record ({s})\n", .{ r.root, r.path, r.line, @errorName(err) });
                return err;
            };
            return parsed.value;
        }
        return null;
    }

    /// The most memory the phase's tree and any one process of it held, and the jobs it ran at
    /// once, where the record says.
    fn memory(r: *Records, value: src.Value) !?Memory {
        const bytes = src.get(value, "peak_bytes");
        if (bytes == .null) return null;
        return memoryOf(bytes, src.get(value, "single_bytes"), src.get(value, "jobs")) orelse {
            r.c.report("profile: {s}/{s}:{d}: a peak that is not counts of bytes, the tree's and one process's, beside a count of jobs, at least 1\n", .{ r.root, r.path, r.line });
            return error.InvalidPeak;
        };
    }

    fn seconds(r: *Records, value: src.Value) !f64 {
        return number(src.get(value, "seconds")) catch |err| {
            r.c.report("profile: {s}/{s}:{d}: a record without a duration in seconds\n", .{ r.root, r.path, r.line });
            return err;
        };
    }
};

fn memoryOf(bytes: src.Value, single: src.Value, jobs: src.Value) ?Memory {
    if (bytes != .integer or single != .integer or jobs != .integer) return null;
    const held = std.math.cast(u64, bytes.integer) orelse return null;
    const one = std.math.cast(u64, single.integer) orelse return null;
    const count = std.math.cast(u32, jobs.integer) orelse return null;
    if (count == 0) return null;
    // The tree held its one process: a record whose one process's peak passes its tree's
    // (Linux's high-water mark against samples of the group's sum) held at least that.
    return .sampled(held, one, count);
}

fn number(value: src.Value) !f64 {
    const seconds: f64 = switch (value) {
        .float => value.float,
        .integer => @floatFromInt(value.integer),
        else => return error.InvalidTestDuration,
    };
    if (!(seconds >= 0)) return error.InvalidTestDuration;
    return seconds;
}

/// A job's shards' records as one: `i/n` names the count, and the tests of the shards the run
/// did not record are those it did, scaled.
fn foldLeg(shards: []const LegShard) !Leg {
    var count: usize = 1;
    if (std.mem.findScalar(u8, shards[0].shard, '/')) |slash| count = std.fmt.parseUnsigned(usize, shards[0].shard[slash + 1 ..], 10) catch return error.InvalidLegRecord;
    if (count == 0) return error.InvalidLegRecord;
    var leg: Leg = .{ .overhead = 0, .tests = 0, .shards = count, .finished = true };
    for (shards) |shard| {
        leg.overhead = @max(leg.overhead, shard.seconds - @min(shard.tests, shard.seconds));
        leg.tests += shard.tests;
        leg.finished = leg.finished and shard.finished;
    }
    leg.tests *= @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(@min(shards.len, count)));
    return leg;
}

/// One line per test, names and columns sorted, so a refresh diffs by test.
pub fn render(a: std.mem.Allocator, d: Durations) ![]const u8 {
    const columns = try a.dupe([]const u8, d.keys.keys());
    std.mem.sort([]const u8, columns, {}, lessThan);
    const names = try a.dupe([]const u8, d.tests.keys());
    std.mem.sort([]const u8, names, {}, lessThan);
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll("{\n  \"keys\": ");
    try std.json.Stringify.value(columns, .{}, w);
    // Only columns the record still holds: one whose every test went is no column.
    var complete: std.ArrayList([]const u8) = .empty;
    for (columns) |column| if (d.complete.contains(column)) try complete.append(a, column);
    if (complete.items.len != 0) {
        try w.writeAll(",\n  \"complete\": ");
        try std.json.Stringify.value(complete.items, .{}, w);
    }
    try w.writeAll(",\n  \"tests\": {");
    for (names, 0..) |name, i| {
        try w.writeAll(if (i == 0) "\n    " else ",\n    ");
        try std.json.Stringify.value(name, .{}, w);
        try w.writeAll(": [");
        const row = d.tests.get(name).?;
        for (columns, 0..) |column, j| {
            if (j > 0) try w.writeAll(", ");
            if (row.get(column)) |seconds| try w.print("{d:.2}", .{seconds}) else try w.writeAll("null");
        }
        try w.writeByte(']');
    }
    try w.writeAll("\n  }");
    if (d.legs.count() != 0) {
        const jobs = try a.dupe([]const u8, d.legs.keys());
        std.mem.sort([]const u8, jobs, {}, lessThan);
        try w.writeAll(",\n  \"legs\": {");
        for (jobs, 0..) |name, i| {
            const leg = d.legs.get(name).?;
            try w.writeAll(if (i == 0) "\n    " else ",\n    ");
            try std.json.Stringify.value(name, .{}, w);
            try w.print(": {{\"overhead\": {d:.2}, \"tests\": {d:.2}, \"shards\": {d}, \"finished\": {}}}", .{ leg.overhead, leg.tests, leg.shards, leg.finished });
        }
        try w.writeAll("\n  }");
    }
    try w.writeAll("\n}\n");
    return out.written();
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

test "each job's record folds its shards into what the next plan sizes it by, and keeps the jobs the run did not run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const c: src.Context = .{ .a = a, .io = std.testing.io, .dir = .of(tmp.dir) };
    // Two of a suite's three shards recorded themselves: 100 s and 140 s of runs, 60 s and 80 s of
    // tests. The most either spent on the rest is 60 s; the three shards' tests are 210 s.
    try tmp.dir.writeFile(c.io, .{ .sub_path = "leg-a.ndjson", .data = try legRecord(a, "test (ubuntu-latest, Debug)", "1/3", 100, 60, 4, true) });
    try tmp.dir.writeFile(c.io, .{ .sub_path = "leg-b.ndjson", .data = try legRecord(a, "test (ubuntu-latest, Debug)", "2/3", 140, 80, 5, true) });
    try tmp.dir.writeFile(c.io, .{ .sub_path = "leg-c.ndjson", .data = try legRecord(a, "source checks", "", 30, 0, 0, false) });
    // A job's record of itself is no test, and its tests' seconds are what the tests recorded.
    try tmp.dir.writeFile(c.io, .{ .sub_path = "tests-linux-debug-1of3.ndjson", .data = "{\"name\":\"first\",\"seconds\":60,\"key\":\"linux-debug\",\"shard\":\"1/3\"}\n" });
    try std.testing.expectEqual(@as(f64, 60), try testSeconds(c, "."));
    const previous = (try std.json.parseFromSlice(src.Value, a,
        \\{"keys":[],"tests":{},"legs":{"source checks":{"overhead":10,"tests":0,"shards":1,"finished":true},"hardened":{"overhead":50,"tests":200,"shards":2,"finished":true}}}
    , .{})).value;
    const durations = try summarize(c, ".", previous, false);
    try std.testing.expectEqual(@as(usize, 1), durations.records);
    const suite = durations.legs.get("test (ubuntu-latest, Debug)").?;
    try std.testing.expectEqual(@as(f64, 60), suite.overhead);
    try std.testing.expectEqual(@as(f64, 210), suite.tests);
    try std.testing.expectEqual(@as(usize, 3), suite.shards);
    try std.testing.expect(suite.finished);
    // What the run measured replaces the record; what it did not run keeps its own.
    try std.testing.expect(!durations.legs.get("source checks").?.finished);
    try std.testing.expectEqual(@as(f64, 200), durations.legs.get("hardened").?.tests);
    const rendered = try render(a, durations);
    try std.testing.expect(std.mem.find(u8, rendered, "\"test (ubuntu-latest, Debug)\": {\"overhead\": 60.00, \"tests\": 210.00, \"shards\": 3, \"finished\": true}") != null);
    // What renders reads back as it was: a run that measured nothing keeps every job's record.
    try tmp.dir.createDir(c.io, "none", .default_dir);
    const again = try summarize(c, "none", (try std.json.parseFromSlice(src.Value, a, rendered, .{})).value, false);
    try std.testing.expectEqual(@as(usize, 3), again.legs.count());
    try std.testing.expectEqualStrings(rendered, try render(a, again));
    // A shard whose tests ran and recorded no second of them is refused, named.
    try tmp.dir.createDir(c.io, "unrecorded", .default_dir);
    try tmp.dir.writeFile(c.io, .{ .sub_path = "unrecorded/leg-d.ndjson", .data = try legRecord(a, "preflight's own suite (ubuntu-latest)", "4/4", 557, 0, 104, true) });
    var held: std.Io.Writer.Allocating = .init(a);
    var reporting = c;
    reporting.held = &held;
    try std.testing.expectError(error.LegTestsUnrecorded, summarize(reporting, "unrecorded", previous, false));
    try std.testing.expect(std.mem.find(u8, held.written(), "preflight's own suite (ubuntu-latest) (shard 4/4) ran 104 tests and recorded no seconds of them: a recording error") != null);
}

test "a refresh replaces the columns it measured, keeps the rest, and takes the longest record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const c: src.Context = .{ .a = a, .io = std.testing.io, .dir = .of(tmp.dir) };
    // Fixed fixture weights exercise arithmetic, not a machine's timing.
    try tmp.dir.writeFile(c.io, .{ .sub_path = "tests-windows-Debug-1of2.ndjson", .data = "{\"name\":\"first\",\"seconds\":3,\"status\":\"pass\",\"key\":\"windows-Debug\"}\n{\"name\":\"first\",\"seconds\":4.5,\"status\":\"pass\",\"key\":\"windows-Debug\"}\n" });
    try tmp.dir.writeFile(c.io, .{ .sub_path = "tests-linux-Debug-all.ndjson", .data = "{\"name\":\"second\",\"seconds\":0.25,\"status\":\"skip\",\"key\":\"linux-Debug\"}\n{\"name\":\"untargeted\",\"seconds\":1,\"status\":\"pass\"}\n" });
    const previous = (try std.json.parseFromSlice(src.Value, a,
        \\{"keys":["macos-Debug","windows-Debug"],"tests":{"first":[2,9],"gone":[1,1],"kept":[3,null]}}
    , .{})).value;
    const durations = try summarize(c, ".", previous, false);
    try std.testing.expectEqual(@as(usize, 4), durations.records);
    try std.testing.expectEqualStrings(
        \\{
        \\  "keys": ["linux-Debug","macos-Debug","windows-Debug"],
        \\  "complete": ["linux-Debug","windows-Debug"],
        \\  "tests": {
        \\    "first": [null, 2.00, 4.50],
        \\    "gone": [null, 1.00, null],
        \\    "kept": [null, 3.00, null],
        \\    "second": [0.25, null, null]
        \\  }
        \\}
        \\
    , try render(a, durations));
    try tmp.dir.writeFile(c.io, .{ .sub_path = "bad.ndjson", .data = "{\"name\":\"x\",\"seconds\":-1,\"key\":\"k\"}\n" });
    try std.testing.expectError(error.InvalidTestDuration, summarize(c, ".", .null, false));
}

test "a run that did not finish refreshes what it recorded and keeps every test it never reached" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const c: src.Context = .{ .a = a, .io = std.testing.io, .dir = .of(tmp.dir) };
    // The emulated job ran `first` before its time ran out; `reached` never started.
    try tmp.dir.writeFile(c.io, .{ .sub_path = "tests-linux-riscv64-debug-all.ndjson", .data = "{\"name\":\"first\",\"seconds\":30,\"status\":\"pass\",\"key\":\"linux-riscv64-debug\"}\n" });
    const previous = (try std.json.parseFromSlice(src.Value, a,
        \\{"keys":["linux-debug","linux-riscv64-debug"],"tests":{"first":[3,20],"reached":[4,40],"gone":[1,null]}}
    , .{})).value;
    try std.testing.expectEqualStrings(
        \\{
        \\  "keys": ["linux-debug","linux-riscv64-debug"],
        \\  "tests": {
        \\    "first": [3.00, 30.00],
        \\    "gone": [1.00, null],
        \\    "reached": [4.00, 40.00]
        \\  }
        \\}
        \\
    , try render(a, try summarize(c, ".", previous, true)));
    // A finished run's column is the run's alone: `reached`, unrecorded, is gone from it, and
    // the column is complete: what it lacks does not run there.
    try std.testing.expectEqualStrings(
        \\{
        \\  "keys": ["linux-debug","linux-riscv64-debug"],
        \\  "complete": ["linux-riscv64-debug"],
        \\  "tests": {
        \\    "first": [3.00, 30.00],
        \\    "gone": [1.00, null],
        \\    "reached": [4.00, null]
        \\  }
        \\}
        \\
    , try render(a, try summarize(c, ".", previous, false)));
    // A cut run neither makes a column complete nor unmakes one: it ran a share of its tests.
    try std.testing.expect(!(try summarize(c, ".", previous, true)).complete.contains("linux-riscv64-debug"));
    const finished = (try std.json.parseFromSlice(src.Value, a,
        \\{"keys":["linux-debug","linux-riscv64-debug"],"complete":["linux-riscv64-debug"],"tests":{"first":[3,20],"gone":[1,null]}}
    , .{})).value;
    try std.testing.expect((try summarize(c, ".", finished, true)).complete.contains("linux-riscv64-debug"));
}

test "restored timings are discarded before a gate records this run" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const c: src.Context = .{ .a = std.testing.allocator, .io = std.testing.io, .dir = .of(tmp.dir) };
    try tmp.dir.createDirPath(c.io, "cache/preflight-timings");
    try tmp.dir.writeFile(c.io, .{ .sub_path = "cache/preflight-timings/previous.ndjson", .data = "old run" });
    try tmp.dir.writeFile(c.io, .{ .sub_path = "cache/compiled", .data = "keep" });
    try reset(c, "cache/preflight-timings");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(c.io, "cache/preflight-timings", .{}));
    try tmp.dir.access(c.io, "cache/compiled", .{});
    try reset(c, "cache/preflight-timings");
}

test "a test recorded on two shards of one column fails the refresh" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const c: src.Context = .{ .a = a, .io = std.testing.io, .dir = .of(tmp.dir) };
    try tmp.dir.writeFile(c.io, .{ .sub_path = "tests-windows-Debug-1of2.ndjson", .data = "{\"name\":\"first\",\"seconds\":3,\"status\":\"pass\",\"key\":\"windows-Debug\",\"shard\":\"1/2\"}\n" });
    try tmp.dir.writeFile(c.io, .{ .sub_path = "tests-macos-Debug-2of2.ndjson", .data = "{\"name\":\"first\",\"seconds\":3,\"status\":\"pass\",\"key\":\"macos-Debug\",\"shard\":\"2/2\"}\n" });
    _ = try summarize(c, ".", .null, false);
    try tmp.dir.writeFile(c.io, .{ .sub_path = "tests-windows-Debug-2of2.ndjson", .data = "{\"name\":\"first\",\"seconds\":2,\"status\":\"pass\",\"key\":\"windows-Debug\",\"shard\":\"2/2\"}\n" });
    try std.testing.expectError(error.TestOnTwoShards, summarize(c, ".", .null, false));
}

test "a record that is not JSON, or has no seconds, fails the refresh naming its file and line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var held: std.Io.Writer.Allocating = .init(a);
    const c: src.Context = .{ .a = a, .io = std.testing.io, .dir = .of(tmp.dir), .held = &held };
    // Two downloads writing one file at once leave a record cut into by another.
    try tmp.dir.writeFile(c.io, .{ .sub_path = "tests-linux-debug-all.ndjson", .data = "{\"name\":\"first\",\"seconds\":3,\"key\":\"linux-debug\"}\n\n{\"name\":\"sec{\"name\":\"first\",\"seconds\":3}\n" });
    try std.testing.expectError(error.SyntaxError, summarize(c, ".", .null, false));
    try std.testing.expectError(error.SyntaxError, measure(c, ".", .null));
    const cut = "profile: ./tests-linux-debug-all.ndjson:3: not a JSON record (SyntaxError)\n";
    try std.testing.expectEqualStrings(cut ++ cut, held.written());
    held.clearRetainingCapacity();
    try tmp.dir.writeFile(c.io, .{ .sub_path = "tests-linux-debug-all.ndjson", .data = "{\"phase\":\"compile\",\"seconds\":\"long\"}\n" });
    try std.testing.expectError(error.InvalidTestDuration, measure(c, ".", .null));
    try std.testing.expectEqualStrings("profile: ./tests-linux-debug-all.ndjson:1: a record without a duration in seconds\n", held.written());
}

/// Seconds per phase of a hosted job (`compile aarch64-macos`), as a run
/// measured them. A plan balances its jobs by these.
pub const Costs = struct {
    phases: std.array_hash_map.String(f64) = .empty,
    /// The most memory each phase's tree and any one process of it held, beside the jobs its
    /// build ran at once: what a plan sizes a cross job's `-j` by (the one process's). A phase no
    /// run measured has none.
    peaks: std.array_hash_map.String(Memory) = .empty,
};

/// Reads the phase records under `root`. A phase this run measured replaces
/// the one in `previous`; the others are kept, since a tier does not run them
/// all. Several records of one phase keep the longest.
pub fn measure(c: src.Context, root: []const u8, previous: src.Value) !Costs {
    var result: Costs = .{};
    var dir = try c.directory().openDir(c.io, root, .{ .iterate = true });
    defer dir.close(c.io);
    var walker = try dir.walk(c.a);
    defer walker.deinit();
    while (try walker.next(c.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".ndjson")) continue;
        var records = try Records.open(c, dir, root, entry.path);
        while (try records.next()) |value| {
            const label = src.get(value, "phase");
            if (label != .string) continue;
            const seconds = try records.seconds(value);
            const name = try c.a.dupe(u8, label.string);
            const cell = try result.phases.getOrPut(c.a, name);
            cell.value_ptr.* = if (cell.found_existing) @max(cell.value_ptr.*, seconds) else seconds;
            // Several records of one phase keep the one whose single process held the most.
            if (try records.memory(value)) |m| {
                const held = try result.peaks.getOrPut(c.a, cell.key_ptr.*);
                if (!held.found_existing or m.single > held.value_ptr.single) held.value_ptr.* = m;
            }
        }
    }
    const kept = src.get(previous, "phases");
    if (kept == .object) {
        var rows = kept.object.iterator();
        while (rows.next()) |row| {
            if (result.phases.contains(row.key_ptr.*)) continue;
            try result.phases.put(c.a, row.key_ptr.*, try number(row.value_ptr.*));
        }
    }
    // A peak this run did not record is kept: a job on a system whose memory is not read
    // (macOS) records none.
    const kept_peaks = src.get(previous, "peaks");
    if (kept_peaks == .object) {
        var rows = kept_peaks.object.iterator();
        while (rows.next()) |row| {
            if (result.peaks.contains(row.key_ptr.*)) continue;
            const m = memoryOf(src.get(row.value_ptr.*, "bytes"), src.get(row.value_ptr.*, "single"), src.get(row.value_ptr.*, "jobs")) orelse return error.InvalidPeak;
            try result.peaks.put(c.a, row.key_ptr.*, m);
        }
    }
    return result;
}

/// One line per phase, sorted, so a refresh diffs by phase.
pub fn renderCosts(a: std.mem.Allocator, costs: Costs) ![]const u8 {
    const labels = try a.dupe([]const u8, costs.phases.keys());
    std.mem.sort([]const u8, labels, {}, lessThan);
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll("{\n  \"phases\": {");
    for (labels, 0..) |label, i| {
        try w.writeAll(if (i == 0) "\n    " else ",\n    ");
        try std.json.Stringify.value(label, .{}, w);
        try w.print(": {d:.2}", .{costs.phases.get(label).?});
    }
    try w.writeAll("\n  }");
    if (costs.peaks.count() != 0) {
        const named = try a.dupe([]const u8, costs.peaks.keys());
        std.mem.sort([]const u8, named, {}, lessThan);
        try w.writeAll(",\n  \"peaks\": {");
        for (named, 0..) |label, i| {
            try w.writeAll(if (i == 0) "\n    " else ",\n    ");
            try std.json.Stringify.value(label, .{}, w);
            const m = costs.peaks.get(label).?;
            try w.print(": {{ \"bytes\": {d}, \"single\": {d}, \"jobs\": {d} }}", .{ m.bytes, m.single, m.jobs });
        }
        try w.writeAll("\n  }");
    }
    try w.writeAll("\n}\n");
    return out.written();
}

test "a phase record whose one process's peak passes its tree's reads as the tree holding at least that" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const c: src.Context = .{ .a = a, .io = std.testing.io, .dir = .of(tmp.dir) };
    // As a Linux cross job's bound wrote it: samples of the group's sum saw 2.1 GB, VmHWM 3.4 GB.
    try tmp.dir.writeFile(c.io, .{ .sub_path = "phases-cross.ndjson", .data = "{\"phase\":\"configure the build\",\"seconds\":0.2}\n{\"phase\":\"compile x86_64-windows\",\"seconds\":88.5,\"peak_bytes\":2100000000,\"single_bytes\":3400000000,\"jobs\":4}\n" });
    const costs = try measure(c, ".", .null);
    const peak = costs.peaks.get("compile x86_64-windows").?;
    try std.testing.expectEqual(Memory{ .bytes = 3_400_000_000, .single = 3_400_000_000, .jobs = 4 }, peak);
    try std.testing.expectEqual(@as(?Memory, null), memoryOf(.{ .integer = 1 }, .{ .integer = 1 }, .{ .integer = 0 }));
}

test "a refresh of the phase costs takes the longest record and keeps the phases it did not measure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const c: src.Context = .{ .a = a, .io = std.testing.io, .dir = .of(tmp.dir) };
    try tmp.dir.writeFile(c.io, .{ .sub_path = "phases-cross-objects-0.ndjson", .data = "{\"phase\":\"compile x86_64-macos\",\"seconds\":61.5,\"peak_bytes\":8000000000,\"single_bytes\":8000000000,\"jobs\":1}\n{\"phase\":\"compile x86_64-macos\",\"seconds\":70,\"peak_bytes\":16000000000,\"single_bytes\":9200000000,\"jobs\":4}\n{\"phase\":\"compile aarch64-macos\",\"seconds\":3}\n" });
    try tmp.dir.writeFile(c.io, .{ .sub_path = "tests-linux-debug-all.ndjson", .data = "{\"name\":\"second\",\"seconds\":0.25,\"status\":\"skip\",\"key\":\"linux-debug\"}\n" });
    const previous = (try std.json.parseFromSlice(src.Value, a,
        \\{"phases":{"compile aarch64-macos":99,"benchmarks aarch64-macos":40.25},"peaks":{"benchmarks aarch64-macos":{"bytes":3000000000,"single":2000000000,"jobs":2}}}
    , .{})).value;
    const costs = try measure(c, ".", previous);
    try std.testing.expectEqualStrings(
        \\{
        \\  "phases": {
        \\    "benchmarks aarch64-macos": 40.25,
        \\    "compile aarch64-macos": 3.00,
        \\    "compile x86_64-macos": 70.00
        \\  },
        \\  "peaks": {
        \\    "benchmarks aarch64-macos": { "bytes": 3000000000, "single": 2000000000, "jobs": 2 },
        \\    "compile x86_64-macos": { "bytes": 16000000000, "single": 9200000000, "jobs": 4 }
        \\  }
        \\}
        \\
    , try renderCosts(a, costs));
    // The durations refresh passes the phase records over.
    const durations = try summarize(c, ".", .null, false);
    try std.testing.expectEqual(@as(usize, 1), durations.records);
}
