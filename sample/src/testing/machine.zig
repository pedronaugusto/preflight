//! The FreeBSD machine's directories as a test on it reaches them, with the host's side in
//! ci/machine.zig: what a test makes beside its scratch reaches the host (`check` reads it
//! after the run), and its scratch holds while the host changes the share's directory under
//! it (`change`, during the run). Both run only in the sample's FreeBSD run, whose build makes
//! the channel first (`prepare`).
const std = @import("std");
const builtin = @import("builtin");

/// Where the tests and the host's side answer each other: a directory of the share, made
/// before the machine boots, so that the machine binds it and each side sees the other's files.
pub const channel = ".zig-cache/preflight-sample-channel";
/// A test's word that its scratch file is made, and the host's that it changed the share's
/// directory under the scratch.
pub const ready = "ready";
pub const changed = "changed";
/// The scratch of `std.testing.tmpDir`, which the machine mounts in its memory.
pub const scratch = ".zig-cache/tmp";
/// What a test makes beside the scratch, in a directory the machine makes its own.
pub const made_file = ".zig-cache/preflight-sample-made";
pub const made_dir = ".zig-cache/preflight-sample-made-dir";
pub const made_inner = made_dir ++ "/inner";
pub const made_link = ".zig-cache/preflight-sample-made-link";
pub const made_text = "made by a test on the FreeBSD machine\n";
/// How long the test waits for the host's change, in tenths of a second.
const change_wait = 1200;

/// Whether this is the sample's FreeBSD run: its build made the channel.
fn onMachine() bool {
    if (builtin.os.tag != .freebsd) return false;
    std.Io.Dir.cwd().access(std.testing.io, channel, .{}) catch return false;
    return true;
}

test "what a test makes beside the FreeBSD machine's scratch reaches the host" {
    if (!onMachine()) return error.SkipZigTest;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = made_file, .data = made_text });
    try cwd.createDirPath(io, made_dir);
    try cwd.writeFile(io, .{ .sub_path = made_inner, .data = made_text });
    cwd.deleteFile(io, made_link) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    try cwd.symLink(io, std.fs.path.basename(made_file), made_link, .{});
}

test "the FreeBSD machine's scratch holds while the host changes the share's directory under it" {
    if (!onMachine()) return error.SkipZigTest;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "before", .data = made_text });
    var answers = try cwd.openDir(io, channel, .{ .iterate = true });
    defer answers.close(io);
    try answers.writeFile(io, .{ .sub_path = ready, .data = "" });
    try waitFor(io, answers, changed);
    // By its path, which a lookup after the change resolves: the directory held open keeps
    // the vnode it was opened on. A scratch mounted on the share's directory is passed by
    // this lookup once the host has changed that directory, and its file is not there.
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.print(&buffer, "{s}/{s}/before", .{ scratch, &tmp.sub_path });
    var text: [made_text.len]u8 = undefined;
    try std.testing.expectEqualStrings(made_text, try cwd.readFile(io, path, &text));
}

/// Waits until `name` is in `dir`, read by listing it: a lookup of a name not there yet may
/// be answered from the machine's cache of names that were not.
fn waitFor(io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    for (0..change_wait) |_| {
        var entries = dir.iterate();
        while (try entries.next(io)) |found| if (std.mem.eql(u8, found.name, name)) return;
        try io.sleep(.fromMilliseconds(100), .awake);
    }
    return error.HostNeverChanged;
}
