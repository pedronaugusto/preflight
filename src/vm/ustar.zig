//! The POSIX tar archive a FreeBSD OCI image's layer is (ustar, with pax and GNU
//! long-name headers), read whole from memory, hard links included: the FreeBSD
//! test machine's root is the layer's members as they are. std.tar's iterator
//! leaves hard links out (Zig 0.17: it reports a type '1' member as unsupported,
//! without its target, and Zig's package fetch fails on one), and FreeBSD's
//! userland is full of them (`/bin/[` is `/bin/test`).
const std = @import("std");

const header_len = 512;

pub const Kind = enum { directory, file, symlink, hard_link };

/// One member: `data` is a file's bytes, `link` a link's target (for a hard link,
/// the path of the member it names), both borrowed from the archive.
pub const Entry = struct {
    name: []const u8,
    kind: Kind,
    /// Permission bits.
    mode: u32,
    uid: u32,
    gid: u32,
    data: []const u8 = "",
    link: []const u8 = "",
};

pub const ReadError = error{ NotTar, Truncated, BadChecksum, BadNumber, UnsupportedMember };

/// The members of a whole archive in memory, in order; `next` returns null at its end.
pub const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    /// Holds a name or target that a ustar header splits in two.
    joined: [256]u8 = undefined,

    pub fn next(r: *Reader) ReadError!?Entry {
        // What extended headers (pax `x`, GNU `L` and `K`) set for the member after them.
        var path: ?[]const u8 = null;
        var link: ?[]const u8 = null;
        var size_override: ?u64 = null;
        var uid_override: ?u32 = null;
        var gid_override: ?u32 = null;
        while (true) {
            if (r.bytes.len - r.at < header_len) {
                if (r.at == r.bytes.len) return null;
                return error.Truncated;
            }
            const header = r.bytes[r.at..][0..header_len];
            if (std.mem.allEqual(u8, header, 0)) return null;
            try checksum(header);
            const size = size_override orelse try octal(u64, header[124..136]);
            const start = r.at + header_len;
            if (size > r.bytes.len - start) return error.Truncated;
            const body = r.bytes[start..][0..@intCast(size)]; // safe: at most the archive's length, checked above
            r.at = start + std.mem.alignForward(usize, body.len, header_len);
            if (r.at > r.bytes.len) r.at = r.bytes.len;
            switch (header[156]) {
                'x' => {
                    var records = Pax{ .bytes = body };
                    while (try records.next()) |record| {
                        if (std.mem.eql(u8, record.key, "path")) path = record.value;
                        if (std.mem.eql(u8, record.key, "linkpath")) link = record.value;
                        if (std.mem.eql(u8, record.key, "size")) size_override = std.fmt.parseInt(u64, record.value, 10) catch return error.BadNumber;
                        if (std.mem.eql(u8, record.key, "uid")) uid_override = std.fmt.parseInt(u32, record.value, 10) catch return error.BadNumber;
                        if (std.mem.eql(u8, record.key, "gid")) gid_override = std.fmt.parseInt(u32, record.value, 10) catch return error.BadNumber;
                    }
                    continue;
                },
                'g' => continue,
                'L' => {
                    path = std.mem.sliceTo(body, 0);
                    continue;
                },
                'K' => {
                    link = std.mem.sliceTo(body, 0);
                    continue;
                },
                else => {},
            }
            const kind: Kind = switch (header[156]) {
                0, '0', '7' => .file,
                '1' => .hard_link,
                '2' => .symlink,
                '5' => .directory,
                else => return error.UnsupportedMember,
            };
            return .{
                .name = path orelse r.ustarName(header),
                .kind = kind,
                .mode = try octal(u32, header[100..108]) & 0o7777,
                .uid = uid_override orelse try octal(u32, header[108..116]),
                .gid = gid_override orelse try octal(u32, header[116..124]),
                .data = if (kind == .file) body else "",
                .link = link orelse std.mem.sliceTo(header[157..257], 0),
            };
        }
    }

    /// A ustar header's name: its prefix, a `/`, and its name field.
    fn ustarName(r: *Reader, header: *const [header_len]u8) []const u8 {
        const name = std.mem.sliceTo(header[0..100], 0);
        if (!std.mem.eql(u8, header[257..262], "ustar")) return name;
        const prefix = std.mem.sliceTo(header[345..500], 0);
        if (prefix.len == 0) return name;
        @memcpy(r.joined[0..prefix.len], prefix);
        r.joined[prefix.len] = '/';
        @memcpy(r.joined[prefix.len + 1 ..][0..name.len], name);
        return r.joined[0 .. prefix.len + 1 + name.len];
    }
};

/// A header's checksum: its bytes summed with the checksum field as spaces.
fn checksum(header: *const [header_len]u8) ReadError!void {
    const stated = octal(u64, header[148..156]) catch return error.NotTar;
    var sum: u64 = 0;
    for (header, 0..) |byte, i| sum += if (i >= 148 and i < 156) ' ' else byte;
    if (sum != stated) return error.BadChecksum;
}

/// A NUL- or space-terminated octal field.
fn octal(comptime T: type, field: []const u8) ReadError!T {
    const digits = std.mem.trim(u8, std.mem.sliceTo(field, 0), " ");
    if (digits.len == 0) return 0;
    return std.fmt.parseInt(T, digits, 8) catch error.BadNumber;
}

/// pax records: `<length> <key>=<value>\n`, the length counting the whole record.
const Pax = struct {
    bytes: []const u8,

    const Record = struct { key: []const u8, value: []const u8 };

    fn next(p: *Pax) ReadError!?Record {
        if (p.bytes.len == 0) return null;
        const space = std.mem.findScalar(u8, p.bytes, ' ') orelse return error.NotTar;
        const len = std.fmt.parseInt(usize, p.bytes[0..space], 10) catch return error.BadNumber;
        if (len <= space + 1 or len > p.bytes.len or p.bytes[len - 1] != '\n') return error.NotTar;
        const record = p.bytes[space + 1 .. len - 1];
        p.bytes = p.bytes[len..];
        const eq = std.mem.findScalar(u8, record, '=') orelse return error.NotTar;
        return .{ .key = record[0..eq], .value = record[eq + 1 ..] };
    }
};

/// A ustar header for the tests, its checksum filled in.
fn testHeader(name: []const u8, kind: u8, size: usize, link: []const u8) [header_len]u8 {
    var h: [header_len]u8 = @splat(0);
    @memcpy(h[0..name.len], name);
    _ = std.mem.print(h[100..107], "{o:0>7}", .{@as(u32, 0o755)}) catch unreachable; // unreachable: seven digits fit
    _ = std.mem.print(h[108..115], "{o:0>7}", .{@as(u32, 0)}) catch unreachable; // unreachable: seven digits fit
    _ = std.mem.print(h[116..123], "{o:0>7}", .{@as(u32, 5)}) catch unreachable; // unreachable: seven digits fit
    _ = std.mem.print(h[124..135], "{o:0>11}", .{size}) catch unreachable; // unreachable: eleven digits fit a test's sizes
    h[156] = kind;
    @memcpy(h[157..][0..link.len], link);
    @memcpy(h[257..263], "ustar\x00");
    @memcpy(h[263..265], "00");
    @memset(h[148..156], ' ');
    var sum: u32 = 0;
    for (h) |b| sum += b;
    _ = std.mem.print(h[148..155], "{o:0>6}\x00", .{sum}) catch unreachable; // unreachable: six digits fit
    return h;
}

test "an archive's files, links and directories are read, a hard link with its target" {
    var archive: std.ArrayList(u8) = .empty;
    defer archive.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try archive.appendSlice(a, &testHeader("bin/", '5', 0, ""));
    try archive.appendSlice(a, &testHeader("bin/test", '0', 5, ""));
    try archive.appendSlice(a, "test\n" ++ @as([507]u8, @splat(0)));
    try archive.appendSlice(a, &testHeader("bin/[", '1', 0, "bin/test"));
    try archive.appendSlice(a, &testHeader("lib/libc.so", '2', 0, "libc.so.7"));
    const pax = "30 path=usr/share/a-long-name\n";
    try archive.appendSlice(a, &testHeader("PaxHeader", 'x', pax.len, ""));
    try archive.appendSlice(a, pax ++ @as([512 - pax.len]u8, @splat(0)));
    try archive.appendSlice(a, &testHeader("short", '0', 0, ""));
    try archive.appendSlice(a, &@as([1024]u8, @splat(0)));

    var r: Reader = .{ .bytes = archive.items };
    const dir = (try r.next()).?;
    try std.testing.expectEqual(Kind.directory, dir.kind);
    try std.testing.expectEqualStrings("bin/", dir.name);
    const file = (try r.next()).?;
    try std.testing.expectEqualStrings("test\n", file.data);
    try std.testing.expectEqual(@as(u32, 0o755), file.mode);
    try std.testing.expectEqual(@as(u32, 5), file.gid);
    const hard = (try r.next()).?;
    try std.testing.expectEqual(Kind.hard_link, hard.kind);
    try std.testing.expectEqualStrings("bin/[", hard.name);
    try std.testing.expectEqualStrings("bin/test", hard.link);
    const sym = (try r.next()).?;
    try std.testing.expectEqual(Kind.symlink, sym.kind);
    try std.testing.expectEqualStrings("libc.so.7", sym.link);
    try std.testing.expectEqualStrings("usr/share/a-long-name", (try r.next()).?.name);
    try std.testing.expectEqual(@as(?Entry, null), try r.next());
}

test "a damaged archive is refused, not read past its end" {
    var bad = testHeader("f", '0', 100, "");
    var r: Reader = .{ .bytes = &bad };
    try std.testing.expectError(error.Truncated, r.next());
    bad[0] = 'g';
    r = .{ .bytes = &bad };
    try std.testing.expectError(error.BadChecksum, r.next());
    var device = testHeader("dev/null", '3', 0, "");
    r = .{ .bytes = &device };
    try std.testing.expectError(error.UnsupportedMember, r.next());
    r = .{ .bytes = (&bad)[0..100] };
    try std.testing.expectError(error.Truncated, r.next());
}
