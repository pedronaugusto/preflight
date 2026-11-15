//! The FreeBSD machine's first process's input seam: where bytes from outside enter it, each
//! read held to a limit named here. The run's description the host writes on the `run` share
//! is read here and nowhere else in it; what reads the bytes these hand back parses them as
//! the input they are. Its module is rooted in this directory, so it cannot reach the
//! machines' seam beside its parent (vm/input.zig); the limits are that seam's for the same
//! files.
const std = @import("std");
const aegis = @import("aegis");

/// How much of a file a read takes: each read names the kind of file it is.
pub const Limit = enum {
    /// A list the host writes to describe a run (its arguments, environment, binds and
    /// scratch directories): at most 16 MiB.
    description,
    /// A line the host writes (the run's directory, its user).
    text,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return .fromRaw(switch (limit) {
            .description => 16 * 1024 * 1024,
            .text => 64 * 1024,
        });
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the caller.
pub fn file(io: std.Io, dir: std.Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}
