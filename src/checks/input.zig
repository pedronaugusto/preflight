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
