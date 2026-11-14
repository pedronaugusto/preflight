//! The test machine's input seam: where bytes from outside enter the machine's host side,
//! each read held to a limit named here. A file's contents, a link's target and the host's
//! input forwarded to the machine are read here and nowhere else on the host side; what reads
//! the bytes these hand back parses them as the input they are.
const std = @import("std");
const aegis = @import("aegis");

/// How much of a file a read takes: each read names the kind of file it is.
pub const Limit = enum {
    /// A part of the machine's boot image (Alpine's kernel, initramfs and modules, the
    /// guest's init) or a file of a tree added under it (the held git's programs).
    part,
    /// A boot image the build made, its parts and a tree together: at most 1 GiB.
    image,
    /// A line or a few a release or a machine writes (a signing key, a repository list, the
    /// program's status).
    text,
    /// The machine's console, kept for a run that ended without its program's status.
    console,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return .fromRaw(switch (limit) {
            .part => 512 * 1024 * 1024,
            .image => 1024 * 1024 * 1024,
            .text => 64 * 1024,
            .console => 16 * 1024 * 1024,
        });
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the caller.
pub fn file(io: std.Io, dir: std.Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}

/// The target of the symbolic link at `path` under `dir`, in `buffer`.
pub fn link(io: std.Io, dir: std.Io.Dir, path: []const u8, buffer: []u8) std.Io.Dir.ReadLinkError![]const u8 {
    return buffer[0..try dir.readLink(io, path, buffer)];
}

/// What the host's standard input holds next, at most `buffer`'s length: none at its end.
pub fn chunk(io: std.Io, buffer: []u8) std.Io.File.ReadStreamingError!usize {
    return std.Io.File.stdin().readStreaming(io, &.{buffer});
}
