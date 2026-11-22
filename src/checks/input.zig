//! The checks' input seam: where bytes from outside enter them, each read held to a limit
//! named here. A file's contents and a program's output are read here and nowhere else in
//! the checks (and the commands above them); what reads the bytes these hand back parses them
//! as the input they are.
const std = @import("std");
const aegis = @import("aegis");

/// How much of a file a read takes: each read names the kind of file it is.
pub const Limit = enum {
    /// A record a tool of the family wrote (a fuzz finding, a lint list): small text.
    record,
    /// A program the held git's build made, read for what it links, or a portable build the
    /// held git's store keeps: git's largest program is tens of MB, a portable build under 100.
    program,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return .fromRaw(switch (limit) {
            .record => 1024 * 1024,
            .program => 512 * 1024 * 1024,
        });
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the caller.
pub fn file(io: std.Io, dir: std.Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}

/// How much of a program's output a run takes.
pub const Output = enum {
    /// A line or a few (`git --version`, `xcrun --show-sdk-path`).
    line,

    fn limit(output: Output) std.Io.Limit {
        return .limited(switch (output) {
            .line => 64 * 1024,
        });
    }
};

/// `options`' program run to its end, its output and error output held to `output`'s
/// limit; a program that writes more fails the run (`error.StreamTooLong`).
pub fn run(gpa: std.mem.Allocator, io: std.Io, options: std.process.RunOptions, output: Output) std.process.RunError!std.process.RunResult {
    var held = options;
    held.stdout_limit = output.limit();
    held.stderr_limit = output.limit();
    return std.process.run(gpa, io, held);
}

test "a read past its limit fails, and one within it is the file's bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "small", .data = "finding\n" });
    const bytes = try file(std.testing.io, tmp.dir, "small", std.testing.allocator, .record);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("finding\n", bytes);
    const big = try std.testing.allocator.alloc(u8, 1024 * 1024 + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big", .data = big });
    try std.testing.expectError(error.StreamTooLong, file(std.testing.io, tmp.dir, "big", std.testing.allocator, .record));
}

// The package's own files, a header a program here wrote, and what a build prints: the checks'
// context reads the package it runs on through `packageFile`, the fuzz campaign reads its
// coverage files' headers through `header`, and the integration suite runs its fixtures'
// builds through `build`.

/// The most of a package's own file a read takes: its manifest, its configuration, a source or a
/// document a check reads whole, a sample file a fixture copies. A package's largest is a
/// generated source, well under this.
pub const package_file_limit: aegis.units.Bytes(u64) = .fromRaw(64 * 1024 * 1024);

/// The file at `path` under `dir`, one of the package's own, at most `package_file_limit`'s
/// bytes, owned by the caller.
pub fn packageFile(io: std.Io, dir: std.Io.Dir, path: []const u8, gpa: std.mem.Allocator) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, package_file_limit);
}

/// The first `@sizeOf(T)` bytes of the file `path` under `dir`, as the `T` a program on this
/// machine laid out there (a fuzzer's coverage header); null when the file holds fewer bytes,
/// as one its writer is still creating does. Only those bytes are read.
pub fn header(comptime T: type, io: std.Io, dir: std.Io.Dir, path: []const u8) (std.Io.File.OpenError || std.Io.File.Reader.Error)!?T {
    const opened = try dir.openFile(io, path, .{});
    defer opened.close(io);
    var buffer: [@sizeOf(T)]u8 = undefined;
    var reader = opened.reader(io, &buffer);
    const taken = reader.interface.takeStructPointer(T) catch |err| switch (err) {
        error.EndOfStream => return null,
        error.ReadFailed => return reader.err.?,
    };
    return taken.*;
}

/// The most of a build's output, and of its error output, a run takes: `zig build` of a step,
/// `zig fmt`, `git` in a fixture. What the compiler, the tests and the checks print is a few MB
/// at the most.
pub const build_output_limit: std.Io.Limit = .limited(16 * 1024 * 1024);

/// `options`' program, a build or a tool run on a package, run to its end, its output and error
/// output held to `build_output_limit`; one that writes more fails the run
/// (`error.StreamTooLong`).
pub fn build(gpa: std.mem.Allocator, io: std.Io, options: std.process.RunOptions) std.process.RunError!std.process.RunResult {
    var held = options;
    held.stdout_limit = build_output_limit;
    held.stderr_limit = build_output_limit;
    return std.process.run(gpa, io, held);
}

test "a header is the file's first bytes, and a file shorter than one has none" {
    const Pair = extern struct { a: u32, b: u32 };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const pair: Pair = .{ .a = 7, .b = 35 };
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "whole", .data = std.mem.asBytes(&pair) });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "partial", .data = "x" });
    try std.testing.expectEqual(pair, (try header(Pair, std.testing.io, tmp.dir, "whole")).?);
    try std.testing.expectEqual(@as(?Pair, null), try header(Pair, std.testing.io, tmp.dir, "partial"));
}

// The lint's and the gate's reads, and those of the layers above the checks that read through
// this seam too (the configured build's facts, the deprecation codemod, the commands): the
// sources and workflows they read, the lists a run kept for the next, the pipes a build talks
// on, and the programs whose output is more than a line.

/// What a file read whole is, and so how much of it a read takes.
pub const Document = enum {
    /// A source the lint or the gate reads (a Zig file and its package's manifest, a
    /// workflow's YAML, glint.json): 16 MiB, the lint's bound for one file.
    source,
    /// A list a run kept for the next (the escapes a lint reported) or a person wrote (the
    /// build scripts the lint maps): 16 MiB.
    list,
    /// A file taken whole for its bytes: a Zig source the codemod rewrites and std's own it
    /// follows, a vendored copy whose digest is checked, a run's profile, the configuration a
    /// build wrote: 64 MiB.
    whole,
    /// glint's report of one lint, every finding with its message and span: 256 MiB.
    report,

    fn bytes(kind: Document) aegis.units.Bytes(u64) {
        return .fromRaw(switch (kind) {
            .source, .list => 16 * 1024 * 1024,
            .whole => 64 * 1024 * 1024,
            .report => 256 * 1024 * 1024,
        });
    }
};

/// The file at `path` under `dir`, at most `kind`'s bytes, owned by the caller.
pub fn document(io: std.Io, dir: std.Io.Dir, path: []const u8, gpa: std.mem.Allocator, kind: Document) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, kind.bytes());
}

/// How much of a program's output a run takes, where it is more than a line.
pub const Report = enum {
    /// What a program lists or writes out: git's tags, paths and trees, a docs generator's
    /// text, `zig env`'s settings: 16 MiB.
    text,
    /// A revision's Zig sources, archived (`git archive`), for glint to read its surface:
    /// 256 MiB.
    tree,

    fn limit(report: Report) std.Io.Limit {
        return .limited(switch (report) {
            .text => 16 * 1024 * 1024,
            .tree => 256 * 1024 * 1024,
        });
    }
};

/// `options`' program run to its end, its output and error output held to `report`'s limit;
/// a program that writes more fails the run (`error.StreamTooLong`).
pub fn runReport(gpa: std.mem.Allocator, io: std.Io, options: std.process.RunOptions, report: Report) std.process.RunError!std.process.RunResult {
    var held = options;
    held.stdout_limit = report.limit();
    held.stderr_limit = report.limit();
    return std.process.run(gpa, io, held);
}

/// Readers over `files`, a child's pipes, made into `multi` over `streams`: what they take is
/// the child's output. Who reads them bounds what it buffers.
pub fn pipes(multi: *std.Io.File.MultiReader, gpa: std.mem.Allocator, io: std.Io, streams: *std.Io.File.MultiReader.Streams, files: []const std.Io.File) void {
    multi.init(gpa, io, streams, files);
}
