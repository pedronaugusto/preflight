//! Evidence the test runner records, never asserted by a test: the count of the tests a run's
//! binary holds.
const std = @import("std");

/// The shard a run's tests are, `PREFLIGHT_SHARD`: its name, `2/5` or empty for all of the
/// tests, and the part of a record's name it gives, `2of5` or `all`.
pub const Shard = struct {
    name: []const u8,
    part: []const u8,

    pub fn read(a: std.mem.Allocator, environ: std.process.Environ) (std.process.Environ.CreateMapError || std.mem.Allocator.Error)!Shard {
        var env = try environ.createMap(a);
        defer env.deinit();
        return of(a, env.get("PREFLIGHT_SHARD") orelse "");
    }

    pub fn of(a: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!Shard {
        return .{ .name = try a.dupe(u8, name), .part = if (name.len == 0) "all" else try std.mem.replaceOwned(u8, a, name, "/", "of") };
    }
};

/// What a run's binary holds, as the runner tells it to the build: its root, the artifact
/// that compiles it, whether the compiler kept only the tests a filter names, how many tests
/// the binary holds, and how many of them the run's shard selects.
pub const Count = struct {
    root: []const u8,
    artifact: []const u8,
    filtered: bool,
    tests: usize,
    selected: usize,
    shard: []const u8 = "",
};

/// What `count` fails with: reading the environment, the records' directory or file, or memory.
pub const CountError = std.process.Environ.CreateMapError || std.Io.Dir.CreateDirPathError || std.Io.Dir.WriteFileError || std.Io.Writer.Error || std.mem.Allocator.Error;

/// Writes `record` to `<stem>-<shard part>.json`, in place of an earlier run's: the build's
/// count of the run's tests reads it after the run.
pub fn count(io: std.Io, environ: std.process.Environ, stem: []const u8, record: Count) CountError!void {
    const a = std.heap.page_allocator;
    const shard = try Shard.read(a, environ);
    const path = try a.print("{s}-{s}.json", .{ stem, shard.part });
    if (std.Io.Dir.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    var with_shard = record;
    with_shard.shard = shard.name;
    const json = try std.json.Stringify.valueAlloc(a, with_shard, .{});
    defer a.free(json);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
}

/// The directory a hosted job's test runners write their progress into, one file per process:
/// a line for each test slower than `slow_ns` as it ends, and one for the binary as the build
/// ends it. `preflight run` prints each line as it lands, so a job its deadline ends still shows
/// where its time went, where the build's summary of its steps comes only at its end.
pub const progress_variable = "PREFLIGHT_PROGRESS";
/// A test that runs longer than this gets a line of its own.
pub const slow_ns = std.time.ns_per_s;

/// One process's progress file, or none outside a hosted job. A line lost is evidence lost and
/// no test's failure, so a write that fails ends the file and nothing else.
pub const Progress = struct {
    file: ?std.Io.File = null,
    artifact: []const u8 = "",

    /// The progress file of the binary `artifact`, in the directory `environ` names, if any.
    pub fn open(io: std.Io, environ: std.process.Environ, artifact: []const u8) Progress {
        const a = std.heap.page_allocator;
        var env = environ.createMap(a) catch return .{};
        defer env.deinit();
        const directory = env.get(progress_variable) orelse return .{};
        if (directory.len == 0) return .{};
        var dir = std.Io.Dir.cwd().openDir(io, directory, .{}) catch return .{};
        defer dir.close(io);
        var name: [256]u8 = undefined;
        // Several processes of one binary run at once, each shard's and each build's: the
        // first name free is this one's.
        for (0..1000) |n| {
            const sub_path = std.mem.print(&name, "{s}-{d}.txt", .{ artifact, n }) catch return .{};
            if (dir.createFile(io, sub_path, .{ .exclusive = true })) |file| {
                return .{ .file = file, .artifact = artifact };
            } else |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return .{},
            }
        }
        return .{};
    }

    /// Writes one line, `<artifact>: ` and `format` with `args`.
    pub fn line(progress: *Progress, io: std.Io, comptime format: []const u8, args: anytype) void {
        const file = progress.file orelse return;
        var buffer: [1024]u8 = undefined;
        const text = std.mem.print(&buffer, "{s}: " ++ format ++ "\n", .{progress.artifact} ++ args) catch |err| switch (err) {
            // A name longer than the buffer: the line is cut, ended all the same.
            error.NoSpaceLeft => cut: {
                buffer[buffer.len - 1] = '\n';
                break :cut &buffer;
            },
        };
        file.writeStreamingAll(io, text) catch |err| switch (err) {
            // Whatever ended the write, a full disk or a file gone, the rest of this process's
            // lines go with it: they are evidence, and no test's result.
            else => {
                file.close(io);
                progress.file = null;
            },
        };
    }

    pub fn close(progress: *Progress, io: std.Io) void {
        if (progress.file) |file| file.close(io);
        progress.file = null;
    }
};
