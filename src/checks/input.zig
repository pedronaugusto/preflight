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
    /// A program the held git's build made, read for what it links, or an installer the
    /// held git's store keeps: git's largest program is tens of MB, an installer under 100.
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

    fn bytes(kind: Document) aegis.units.Bytes(u64) {
        return .fromRaw(switch (kind) {
            .source, .list => 16 * 1024 * 1024,
            .whole => 64 * 1024 * 1024,
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

    fn limit(report: Report) std.Io.Limit {
        return .limited(switch (report) {
            .text => 16 * 1024 * 1024,
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
