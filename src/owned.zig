//! What this process opens, owned where it is opened and closed once there: a context or an
//! options struct is lent it (`borrow`), and never closes what it is lent.
const std = @import("std");
const aegis = @import("aegis");

/// A directory this process opened.
pub const OwnedDir = aegis.own.OwnedIo(std.Io.Dir, closeDir);
/// A file this process opened.
pub const OwnedFile = aegis.own.OwnedIo(std.Io.File, closeFile);

fn closeDir(dir: *std.Io.Dir, io: std.Io) void {
    dir.close(io);
}

fn closeFile(file: *std.Io.File, io: std.Io) void {
    file.close(io);
}
