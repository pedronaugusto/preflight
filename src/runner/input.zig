//! The test runner's input seam: where bytes from outside enter the runner, each read held to
//! a limit named here. The build's protocol, a claim another run wrote, the lifeline, the
//! tests' output the supervisor forwards and what Linux says of a process are read here and
//! nowhere else in the runner; what reads the bytes these hand back parses them as the input
//! they are. Compiled into every package's test binaries: std alone, as the runner.
//!
//! The limit of each read is the buffer its caller hands it: none reads past it, and none
//! allocates.
const std = @import("std");

/// A reader of the build's protocol on `from`, through `buffer`: the build's messages, which
/// `std.zig.Server` reads by their stated lengths.
pub fn protocol(io: std.Io, from: std.Io.File, buffer: []u8) std.Io.File.Reader {
    return from.readerStreaming(io, buffer);
}

/// The file at `path` under `dir`, at most `buffer`'s length of it.
pub fn file(io: std.Io, dir: std.Io.Dir, path: []const u8, buffer: []u8) std.Io.Dir.ReadFileError![]u8 {
    return dir.readFile(io, path, buffer);
}

/// The target of the symbolic link at `path` under `dir`, in `buffer`.
pub fn link(io: std.Io, dir: std.Io.Dir, path: []const u8, buffer: []u8) std.Io.Dir.ReadLinkError![]u8 {
    return buffer[0..try dir.readLink(io, path, buffer)];
}

/// What `from` holds next, at most `buffer`'s length.
pub fn chunk(io: std.Io, from: std.Io.File, buffer: []u8) std.Io.File.ReadStreamingError!usize {
    return from.readStreaming(io, &.{buffer});
}

/// The read of what `from` holds next into `data`, at most its length, as an operation for a
/// batch to run: one a cancel can stop with what it read kept.
pub fn streaming(from: std.Io.File, data: []const []u8) std.Io.Operation {
    return .{ .file_read_streaming = .{ .file = from, .data = data } };
}
