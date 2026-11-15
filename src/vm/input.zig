//! The test machine's input seam: where bytes from outside enter the machine's host side
//! (host.zig, freebsd.zig) and the riscv64 machine's first process (guest.zig), each read held
//! to a limit named here. A file's contents, a link's target and the host's input forwarded to
//! the machine are read here and nowhere else in them; what reads the bytes these hand back
//! parses them as the input they are. The FreeBSD machine's first process, whose module is
//! rooted in freebsd/, reads through its own (freebsd/input.zig).
const std = @import("std");
const aegis = @import("aegis");

/// How much of a file a read takes: each read names the kind of file it is.
pub const Limit = enum {
    /// A part of a machine's boot image (a kernel, Alpine's initramfs, a kernel module, the
    /// guest's init) or a file of a tree added under it (the held git's programs), or the
    /// kernel's module index (`modules.dep`) the first process loads modules by.
    part,
    /// A boot image the build made, its parts and a tree together, or a layer of FreeBSD's
    /// runtime image: at most 1 GiB.
    image,
    /// A record of FreeBSD's runtime image: its OCI index, at most 1 MiB.
    record,
    /// A list the host writes to describe a run to the first process (its arguments,
    /// environment, binds and scratch directories): at most 16 MiB.
    description,
    /// A line or a few a release or a machine writes (a signing key, a repository list, the
    /// program's status, the run's directory and user, a port's name).
    text,
    /// The machine's console, kept for a run that ended without its program's status.
    console,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return .fromRaw(switch (limit) {
            .part => 512 * 1024 * 1024,
            .image => 1024 * 1024 * 1024,
            .record => 1024 * 1024,
            .description => 16 * 1024 * 1024,
            .text => 64 * 1024,
            .console => 16 * 1024 * 1024,
        });
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the caller.
pub fn file(io: std.Io, dir: std.Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}

/// The start of the file at `path` under `dir`, at most `buffer`'s length, in `buffer`: for
/// a file another process is still writing, read again until it says what is awaited.
pub fn head(io: std.Io, dir: std.Io.Dir, path: []const u8, buffer: []u8) std.Io.Dir.ReadFileError![]u8 {
    return dir.readFile(io, path, buffer);
}

/// The target of the symbolic link at `path` under `dir`, in `buffer`.
pub fn link(io: std.Io, dir: std.Io.Dir, path: []const u8, buffer: []u8) std.Io.Dir.ReadLinkError![]const u8 {
    return buffer[0..try dir.readLink(io, path, buffer)];
}

/// What the host's standard input holds next, at most `buffer`'s length: none at its end.
pub fn chunk(io: std.Io, buffer: []u8) std.Io.File.ReadStreamingError!usize {
    return std.Io.File.stdin().readStreaming(io, &.{buffer});
}
