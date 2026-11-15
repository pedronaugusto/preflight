//! The test machine's host side's one call past std's checked layer: the user this program
//! runs as, whom the machine runs its program as, as a build runs it on the host. std's
//! checked layer has no getuid or getgid, so they are the system's own, here and nowhere
//! else on the host side.
const std = @import("std");

/// A user's ids, as the machine's `user` file takes them.
pub const User = struct { uid: std.posix.uid_t, gid: std.posix.gid_t };

/// The real user and group ids of this process.
pub fn current() User {
    return .{ .uid = std.posix.system.getuid(), .gid = std.posix.system.getgid() };
}
