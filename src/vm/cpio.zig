//! The "newc" cpio archive Linux unpacks as its first file system: written for
//! the test machine's boot image, and read to take the modules out of a
//! distribution's own initramfs.
const std = @import("std");

const magic = "070701";
const header_len = 110;
const trailer = "TRAILER!!!";

pub const Kind = enum { directory, file, symlink };

/// One archive member: `data` is a file's bytes or a link's target.
pub const Entry = struct {
    name: []const u8,
    kind: Kind,
    /// Permission bits.
    mode: u32,
    data: []const u8 = "",
};

pub const Writer = struct {
    out: *std.Io.Writer,
    /// The next inode number: Linux links members that share one.
    inode: u32 = 1,

    pub fn add(w: *Writer, entry: Entry) std.Io.Writer.Error!void {
        const type_bits: u32 = switch (entry.kind) {
            .directory => 0o040000,
            .file => 0o100000,
            .symlink => 0o120000,
        };
        const fields = [_]u64{
            w.inode,
            type_bits | (entry.mode & 0o7777),
            0, // uid
            0, // gid
            if (entry.kind == .directory) 2 else 1,
            0, // mtime
            entry.data.len,
            0, 0, // device
            0,                  0, // rdev
            entry.name.len + 1,
            0, // check
        };
        w.inode += 1;
        try w.out.writeAll(magic);
        for (fields) |value| try w.out.print("{x:0>8}", .{value});
        try w.out.writeAll(entry.name);
        try w.out.writeByte(0);
        try pad(w.out, header_len + entry.name.len + 1);
        try w.out.writeAll(entry.data);
        try pad(w.out, entry.data.len);
    }

    pub fn finish(w: *Writer) std.Io.Writer.Error!void {
        try w.add(.{ .name = trailer, .kind = .file, .mode = 0 });
    }
};

fn pad(out: *std.Io.Writer, len: usize) std.Io.Writer.Error!void {
    const rest = (4 - len % 4) % 4;
    try out.splatByteAll(0, rest);
}

pub const ReadError = error{ NotCpio, Truncated, UnknownKind };

/// The members of a whole archive in memory, in order; `next` returns null at its trailer.
pub const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    pub fn next(r: *Reader) ReadError!?Entry {
        // A member padded past the end of an archive cut short leaves `at` beyond it.
        if (r.at > r.bytes.len or r.bytes.len - r.at < header_len) return error.Truncated;
        const header = r.bytes[r.at..][0..header_len];
        if (!std.mem.eql(u8, header[0..6], magic)) return error.NotCpio;
        const mode = try field(header, 1);
        const size = try field(header, 6);
        const name_len = try field(header, 11);
        if (name_len == 0) return error.NotCpio;
        // Each length is checked against what is left before it is added to a position.
        const name_start = r.at + header_len;
        if (name_len > r.bytes.len - name_start) return error.Truncated;
        const name_end = name_start + name_len;
        const data_start = std.mem.alignForward(usize, name_end, 4);
        if (data_start > r.bytes.len or size > r.bytes.len - data_start) return error.Truncated;
        const data_end = data_start + size;
        // aegis: no-danger: name_len is not zero and at most what is left after name_start, checked above
        const name = r.bytes[name_start .. name_end - 1];
        r.at = std.mem.alignForward(usize, data_end, 4);
        if (std.mem.eql(u8, name, trailer)) return null;
        const kind: Kind = switch (mode & 0o170000) {
            0o040000 => .directory,
            0o100000 => .file,
            0o120000 => .symlink,
            else => return error.UnknownKind,
        };
        return .{ .name = name, .kind = kind, .mode = @intCast(mode & 0o7777), .data = r.bytes[data_start..data_end] }; // aegis: no-danger: masked to twelve bits
    }
};

fn field(header: *const [header_len]u8, index: usize) ReadError!usize {
    const start = 6 + index * 8;
    return std.fmt.parseInt(usize, header[start..][0..8], 16) catch error.NotCpio;
}

test "an archive written is read back member by member" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var w: Writer = .{ .out = &buffer.writer };
    try w.add(.{ .name = "bin", .kind = .directory, .mode = 0o755 });
    try w.add(.{ .name = "bin/busybox", .kind = .file, .mode = 0o755, .data = "\x7fELF..." });
    try w.add(.{ .name = "bin/sh", .kind = .symlink, .mode = 0o777, .data = "/bin/busybox" });
    try w.finish();
    const bytes = buffer.written();
    try std.testing.expectEqual(@as(usize, 0), bytes.len % 4);
    var r: Reader = .{ .bytes = bytes };
    const dir = (try r.next()).?;
    try std.testing.expectEqualStrings("bin", dir.name);
    try std.testing.expectEqual(Kind.directory, dir.kind);
    const file = (try r.next()).?;
    try std.testing.expectEqualStrings("bin/busybox", file.name);
    try std.testing.expectEqualStrings("\x7fELF...", file.data);
    try std.testing.expectEqual(@as(u32, 0o755), file.mode);
    const link = (try r.next()).?;
    try std.testing.expectEqual(Kind.symlink, link.kind);
    try std.testing.expectEqualStrings("/bin/busybox", link.data);
    try std.testing.expectEqual(@as(?Entry, null), try r.next());
}

test "a damaged archive is refused, not read past its end" {
    var r: Reader = .{ .bytes = "070701" ++ @as([40]u8, @splat('0')) };
    try std.testing.expectError(error.Truncated, r.next());
    var wrong: Reader = .{ .bytes = "070707" ++ @as([104]u8, @splat('0')) };
    try std.testing.expectError(error.NotCpio, wrong.next());
    // A last member whose data ends the archive unaligned, with no trailer after it: its padding
    // runs past the end, and the next read is refused, not taken from past it.
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var w: Writer = .{ .out = &buffer.writer };
    try w.add(.{ .name = "a", .kind = .file, .mode = 0o644, .data = "x" });
    var cut: Reader = .{ .bytes = buffer.written()[0 .. buffer.written().len - 3] };
    try std.testing.expectEqualStrings("x", (try cut.next()).?.data);
    try std.testing.expectError(error.Truncated, cut.next());
    // A name longer than what is left.
    const long = "070701" ++ @as([8 * 11]u8, @splat('0')) ++ "FFFFFFF0" ++ "00000000";
    var named: Reader = .{ .bytes = long };
    try std.testing.expectError(error.Truncated, named.next());
}
