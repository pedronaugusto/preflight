//! The build helper's input seam: where bytes from outside enter the build script and the
//! programs it runs (the consumer check's and the nested build's), each read held to a limit
//! named here. A file's contents and a program's output are read here and nowhere else in the
//! build helper; what reads the bytes these hand back parses them as the input they are.
//! Imported by a build script, where `aegis` is aegis's build.zig, and by those programs, where
//! it is aegis's module: both give `aegis.own`, and nothing else of aegis is named here.
const std = @import("std");
const aegis = @import("aegis");

/// How much of a file a read takes: each read names the kind of file it is.
pub const Limit = union(enum) {
    /// A package's manifest, build.zig.zon, its own or a dependency's as published.
    manifest,
    /// A consumer's program, the source the consumer check builds.
    program,
    /// A git directory's HEAD: a commit or the ref it names.
    head,
    /// A file of the build root the build script reads as it configures (`configure.read`): a
    /// manifest, a workflow or a configuration, its bound stated where it is read.
    configured: u64,

    fn bytes(limit: Limit) u64 {
        return switch (limit) {
            .manifest => 1024 * 1024,
            .program => 16 * 1024 * 1024,
            .head => 32 * 1024,
            .configured => |stated| stated,
        };
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the caller.
pub fn file(io: std.Io, dir: std.Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, .fromRaw(limit.bytes()));
}

/// How much of a program's output a run takes.
pub const Output = enum {
    /// A line or a few (`git rev-parse`).
    line,
    /// What a fetch says (`zig fetch`): its hash, or why it failed.
    report,

    fn limit(output: Output) std.Io.Limit {
        return .limited(switch (output) {
            .line => 32 * 1024,
            .report => 1024 * 1024,
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
