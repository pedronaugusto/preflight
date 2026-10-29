//! The ISO 9660 image with Rock Ridge (RRIP 1.09 over SUSP 1.10) the FreeBSD
//! test machine mounts as its root (`cd9660`, which GENERIC builds in): written
//! from the members of FreeBSD's own root file system, kernel modules and the
//! machine's first process, as cpio.zig writes the riscv64 machine's.
//!
//! The ISO 9660 names are the writer's own (`A` and the member's number within its
//! directory, in hexadecimal), unique and in the order they are written; a reader
//! takes each member's name, mode, owner and link target from its Rock Ridge
//! entries (NM, PX, SL). A hard link is a second record of the same extent. Every
//! date is the epoch, so the same members give the same image.
const std = @import("std");

pub const block = 2048;

pub const Kind = enum { directory, file, symlink };

/// One member: `data` is a file's bytes or a link's target, borrowed until `finish`.
pub const Entry = struct {
    name: []const u8,
    kind: Kind,
    /// Permission bits.
    mode: u32,
    data: []const u8 = "",
    uid: u32 = 0,
    gid: u32 = 0,
};

pub const Error = error{ OutOfMemory, InvalidName, NotDirectory, LinkTarget, ImageTooLarge };

const Node = struct {
    name: []const u8,
    kind: Kind,
    mode: u32,
    uid: u32,
    gid: u32,
    data: []const u8,
    parent: u32,
    /// The node whose extent this one shares: a hard link's target, or itself.
    extent_of: u32,
    children: std.ArrayList(u32) = .empty,
    // Laid out by `finish`.
    id: []const u8 = "\x00",
    lba: u32 = 0,
    size: u32 = 0,
    links: u32 = 1,
    number: u16 = 0,
};

pub const Writer = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(Node) = .empty,
    paths: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn init(gpa: std.mem.Allocator) Error!Writer {
        var w: Writer = .{ .arena = .init(gpa) };
        try w.nodes.append(w.arena.allocator(), .{ .name = "", .kind = .directory, .mode = 0o755, .uid = 0, .gid = 0, .data = "", .parent = 0, .extent_of = 0 });
        try w.paths.put(w.arena.allocator(), "", 0);
        return w;
    }

    pub fn deinit(w: *Writer) void {
        w.arena.deinit();
    }

    /// Adds a member, its parents as directories (0755, root's) where none was added;
    /// a later member at the same path replaces an earlier one's attributes and data.
    pub fn add(w: *Writer, entry: Entry) Error!void {
        const path = try clean(entry.name);
        if (path.len == 0) {
            if (entry.kind != .directory) return error.NotDirectory;
            w.nodes.items[0].mode = entry.mode;
            w.nodes.items[0].uid = entry.uid;
            w.nodes.items[0].gid = entry.gid;
            return;
        }
        const index = try w.node(path, entry.kind);
        const n = &w.nodes.items[index];
        n.mode = entry.mode & 0o7777;
        n.extent_of = index;
        n.uid = entry.uid;
        n.gid = entry.gid;
        n.data = entry.data;
    }

    /// Adds `name` as a hard link to the file already added at `target`.
    pub fn link(w: *Writer, name: []const u8, target: []const u8) Error!void {
        const to = w.paths.get(try clean(target)) orelse return error.LinkTarget;
        if (w.nodes.items[to].kind != .file) return error.LinkTarget;
        const shared = w.nodes.items[to].extent_of;
        const index = try w.node(try clean(name), .file);
        const n = &w.nodes.items[index];
        const t = w.nodes.items[shared];
        n.* = .{ .name = n.name, .kind = .file, .mode = t.mode, .uid = t.uid, .gid = t.gid, .data = t.data, .parent = n.parent, .extent_of = shared, .children = n.children };
    }

    /// The node at `path`, made with its parents when missing.
    fn node(w: *Writer, path: []const u8, kind: Kind) Error!u32 {
        const a = w.arena.allocator();
        if (w.paths.get(path)) |found| {
            if (w.nodes.items[found].kind != kind) return error.NotDirectory;
            return found;
        }
        const slash = std.mem.findScalarLast(u8, path, '/');
        const parent_path = if (slash) |s| path[0..s] else "";
        const parent = if (w.paths.get(parent_path)) |p| p else try w.node(parent_path, .directory);
        if (w.nodes.items[parent].kind != .directory) return error.NotDirectory;
        const index: u32 = @intCast(w.nodes.items.len); // safe: an image holds far fewer than 2^32 members, refused at layout past its size
        const owned = try a.dupe(u8, path);
        try w.nodes.append(a, .{ .name = owned[if (slash) |s| s + 1 else 0..], .kind = kind, .mode = if (kind == .directory) 0o755 else 0o644, .uid = 0, .gid = 0, .data = "", .parent = parent, .extent_of = index });
        try w.nodes.items[parent].children.append(a, index);
        try w.paths.put(a, owned, index);
        return index;
    }

    /// Lays the image out and writes it whole.
    pub fn finish(w: *Writer, out: *std.Io.Writer) (Error || std.Io.Writer.Error)!void {
        const a = w.arena.allocator();
        const nodes = w.nodes.items;
        const layout = try w.lay(a);
        try writeDescriptors(out, nodes, layout);
        try writePathTables(out, nodes, layout);
        try writeDirectories(a, out, nodes, layout);
        for (layout.continuation.areas.items) |area| try out.writeAll(area);
        for (nodes, 0..) |n, i| if (n.kind == .file and n.extent_of == i and n.data.len > 0) {
            try out.writeAll(n.data);
            try out.splatByteAll(0, blocks(n.data.len) * block - n.data.len);
        };
    }

    /// Names, numbers, sizes and places every member: the system area, the volume
    /// descriptors, the path tables, the directories, the continuation areas, the
    /// files' data, in that order.
    fn lay(w: *Writer, a: std.mem.Allocator) Error!Layout {
        const nodes = w.nodes.items;
        for (nodes) |*n| std.mem.sortUnstable(u32, n.children.items, nodes, byName);
        for (nodes) |n| for (n.children.items, 0..) |child, i| {
            nodes[child].id = try childId(a, nodes[child].kind, i);
        };

        // Directories in path table order: by depth, then parent, then name.
        var dirs: std.ArrayList(u32) = .empty;
        try dirs.append(a, 0);
        var next: usize = 0;
        while (next < dirs.items.len) : (next += 1) {
            for (nodes[dirs.items[next]].children.items) |child| if (nodes[child].kind == .directory) try dirs.append(a, child);
        }
        if (dirs.items.len > std.math.maxInt(u16)) return error.ImageTooLarge;
        for (dirs.items, 1..) |d, number| nodes[d].number = @intCast(number); // safe: at most 2^16 - 1 directories, checked above
        for (nodes, 0..) |n, i| {
            if (n.kind == .directory) {
                var subdirs: u32 = 0;
                for (n.children.items) |c| subdirs += @intFromBool(nodes[c].kind == .directory);
                nodes[i].links = 2 + subdirs;
            } else if (n.extent_of != i) nodes[n.extent_of].links += 1;
        }
        for (nodes, 0..) |*n, i| if (n.kind == .file and n.extent_of != i) {
            n.links = nodes[n.extent_of].links;
        };

        // Each directory's records, sized now: only their extents change with the layout.
        var layout: Layout = .{ .dirs = dirs.items, .records = try a.alloc([]Record, nodes.len) };
        for (dirs.items) |d| {
            const list = try a.alloc(Record, 2 + nodes[d].children.items.len);
            list[0] = try w.record(a, d, d, .self, &layout.continuation);
            list[1] = try w.record(a, nodes[d].parent, d, .parent, &layout.continuation);
            for (nodes[d].children.items, 0..) |child, i| list[2 + i] = try w.record(a, child, d, .{ .child = i }, &layout.continuation);
            layout.records[d] = list;
            var at: usize = 0;
            for (list) |r| {
                if (at % block + r.len > block) at = std.mem.alignForward(usize, at, block);
                at += r.len;
            }
            nodes[d].size = std.math.cast(u32, std.mem.alignForward(usize, at, block)) orelse return error.ImageTooLarge;
        }

        for (dirs.items) |d| layout.table_len += 8 + nodes[d].id.len + nodes[d].id.len % 2;
        layout.table_blocks = blocks(layout.table_len);
        var lba: u64 = 18 + 2 * @as(u64, layout.table_blocks);
        for (dirs.items) |d| {
            nodes[d].lba = try lbaOf(lba);
            lba += nodes[d].size / block;
        }
        layout.continuation_lba = try lbaOf(lba);
        lba += layout.continuation.blocks;
        for (nodes, 0..) |*n, i| if (n.kind == .file and n.extent_of == i) {
            n.size = std.math.cast(u32, n.data.len) orelse return error.ImageTooLarge;
            n.lba = if (n.data.len == 0) 0 else try lbaOf(lba);
            lba += blocks(n.data.len);
        };
        for (nodes, 0..) |*n, i| if (n.kind == .file and n.extent_of != i) {
            n.lba = nodes[n.extent_of].lba;
            n.size = nodes[n.extent_of].size;
        };
        layout.total = try lbaOf(lba);
        return layout;
    }

    const Role = union(enum) { self, parent, child: usize };

    /// The record in directory `dir` for node `index`, its system use sized and
    /// split: what fits in the record, the rest in a continuation area.
    fn record(w: *Writer, a: std.mem.Allocator, index: u32, dir: u32, role: Role, continuation: *Continuation) Error!Record {
        const n = w.nodes.items[index];
        var su: std.ArrayList(u8) = .empty;
        var spill: std.ArrayList(u8) = .empty;
        const id: []const u8 = switch (role) {
            .self => "\x00",
            .parent => "\x01",
            .child => n.id,
        };
        if (role == .self and dir == 0) {
            // SUSP's indicator, first in the root's own record, and the Rock Ridge
            // extension it names, which is long: in the continuation area.
            try su.appendSlice(a, "SP\x07\x01\xbe\xef\x00");
            try spill.appendSlice(a, &extensionReference());
        }
        var entries: std.ArrayList(u8) = .empty;
        try px(a, &entries, n);
        if (role == .child) {
            try nm(a, &entries, n.name);
            if (n.kind == .symlink) try sl(a, &entries, n.data);
        }
        // All of it in the record when it fits; otherwise whole entries while they fit
        // beside the continuation entry, and the rest in the continuation area.
        const fixed = 33 + id.len + (1 - id.len % 2);
        if (spill.items.len == 0 and fixed + su.items.len + entries.items.len <= 255) {
            try su.appendSlice(a, entries.items);
        } else {
            var rest = entries.items;
            while (rest.len > 0 and fixed + su.items.len + rest[2] + 28 <= 255) {
                try su.appendSlice(a, rest[0..rest[2]]);
                rest = rest[rest[2]..];
            }
            try spill.appendSlice(a, rest);
        }
        const placed = if (spill.items.len > 0) try continuation.place(a, spill.items) else null;
        return .{ .node = index, .id = id, .inline_su = su.items, .spill = placed, .len = fixed + su.items.len + @as(usize, if (placed != null) 28 else 0) };
    }
};

const Record = struct {
    node: u32,
    id: []const u8,
    inline_su: []const u8,
    spill: ?Continuation.Placed,
    len: usize,
};

const Layout = struct {
    /// Directory nodes in path table order.
    dirs: []const u32,
    /// Each directory's records, by node.
    records: [][]Record,
    continuation: Continuation = .{},
    table_len: usize = 0,
    table_blocks: u32 = 0,
    continuation_lba: u32 = 0,
    total: u32 = 0,

    const l_table = 18;

    fn mTable(l: Layout) u32 {
        return l_table + l.table_blocks;
    }
};

/// The system area, the primary volume descriptor and the set's terminator.
fn writeDescriptors(out: *std.Io.Writer, nodes: []const Node, layout: Layout) std.Io.Writer.Error!void {
    try out.splatByteAll(0, 16 * block);
    var pvd: [block]u8 = @splat(0);
    pvd[0] = 1;
    @memcpy(pvd[1..6], "CD001");
    pvd[6] = 1;
    @memset(pvd[8..72], ' ');
    @memcpy(pvd[40..49], "PREFLIGHT");
    both32(pvd[80..88], layout.total);
    both16(pvd[120..124], 1);
    both16(pvd[124..128], 1);
    both16(pvd[128..132], block);
    both32(pvd[132..140], @intCast(layout.table_len)); // safe: at most 2^16 entries of at most 16 bytes
    std.mem.writeInt(u32, pvd[140..144], Layout.l_table, .little);
    std.mem.writeInt(u32, pvd[148..152], layout.mTable(), .big);
    _ = writeRecord(pvd[156..190], nodes[0].lba, nodes[0].size, .directory, "\x00", "");
    @memset(pvd[190..813], ' ');
    for ([_]usize{ 813, 830, 864 }) |at| {
        @memcpy(pvd[at..][0..16], "1970010100000000");
        pvd[at + 16] = 0;
    }
    @memcpy(pvd[847..][0..16], "0000000000000000");
    pvd[881] = 1;
    try out.writeAll(&pvd);
    var terminator: [block]u8 = @splat(0);
    terminator[0] = 255;
    @memcpy(terminator[1..6], "CD001");
    terminator[6] = 1;
    try out.writeAll(&terminator);
}

/// The path tables, little-endian then big-endian.
fn writePathTables(out: *std.Io.Writer, nodes: []const Node, layout: Layout) std.Io.Writer.Error!void {
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        var written: usize = 0;
        for (layout.dirs) |d| {
            const id = nodes[d].id;
            var entry: [8]u8 = undefined;
            entry[0] = @intCast(id.len); // safe: an identifier is at most ten bytes
            entry[1] = 0;
            std.mem.writeInt(u32, entry[2..6], nodes[d].lba, endian);
            std.mem.writeInt(u16, entry[6..8], nodes[nodes[d].parent].number, endian);
            try out.writeAll(&entry);
            try out.writeAll(id);
            if (id.len % 2 == 1) try out.writeByte(0);
            written += 8 + id.len + id.len % 2;
        }
        try out.splatByteAll(0, @as(usize, layout.table_blocks) * block - written);
    }
}

/// Each directory's records, none across a block.
fn writeDirectories(a: std.mem.Allocator, out: *std.Io.Writer, nodes: []const Node, layout: Layout) (Error || std.Io.Writer.Error)!void {
    var sector: [block]u8 = undefined;
    for (layout.dirs) |d| {
        var at: usize = 0;
        var written: u32 = 1;
        @memset(&sector, 0);
        for (layout.records[d]) |r| {
            if (at + r.len > block) {
                try out.writeAll(&sector);
                @memset(&sector, 0);
                at = 0;
                written += 1;
            }
            const target = &nodes[r.node];
            const flags: Flags = if (target.kind == .directory) .directory else .file;
            const su = if (r.spill) |spilled| blk: {
                var ce: [28]u8 = undefined;
                continuationEntry(&ce, layout.continuation_lba + spilled.block, spilled.offset, @intCast(spilled.bytes.len)); // safe: a continuation area fits in one block
                break :blk try std.mem.concat(a, u8, &.{ r.inline_su, &ce });
            } else r.inline_su;
            at += writeRecord(sector[at..], target.lba, target.size, flags, r.id, su);
        }
        try out.writeAll(&sector);
        std.debug.assert(written == nodes[d].size / block);
    }
}

/// The continuation areas, packed into whole blocks: an area never crosses one.
const Continuation = struct {
    areas: std.ArrayList([]u8) = .empty,
    used: usize = block,
    blocks: u32 = 0,

    const Placed = struct { block: u32, offset: u32, bytes: []const u8 };

    fn place(c: *Continuation, a: std.mem.Allocator, bytes: []const u8) Error!Placed {
        if (bytes.len > block) return error.InvalidName;
        if (c.used + bytes.len > block) {
            const area = try a.alloc(u8, block);
            @memset(area, 0);
            try c.areas.append(a, area);
            c.used = 0;
            c.blocks += 1;
        }
        const area = c.areas.items[c.areas.items.len - 1];
        @memcpy(area[c.used..][0..bytes.len], bytes);
        const placed: Placed = .{ .block = c.blocks - 1, .offset = @intCast(c.used), .bytes = area[c.used..][0..bytes.len] }; // safe: within one block
        c.used += bytes.len;
        return placed;
    }
};

fn byName(nodes: []Node, l: u32, r: u32) bool {
    return std.mem.order(u8, nodes[l].name, nodes[r].name) == .lt;
}

/// A member's path without a leading `./` or `/` and trailing `/`; refused when a
/// part is empty, `.` or `..`, or holds a NUL.
fn clean(name: []const u8) Error![]const u8 {
    var path = name;
    while (std.mem.startsWith(u8, path, "./")) path = path[2..];
    path = std.mem.trim(u8, path, "/");
    if (std.mem.eql(u8, path, ".")) return "";
    if (path.len == 0) return path;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 255 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.findScalar(u8, part, 0) != null) return error.InvalidName;
    }
    return path;
}

/// A child's ISO 9660 name: `A` and its number in hexadecimal, a file's with
/// the empty extension and version 1.
fn childId(a: std.mem.Allocator, kind: Kind, index: usize) Error![]const u8 {
    if (index >= 1 << 24) return error.ImageTooLarge;
    return if (kind == .directory) a.print("A{X:0>6}", .{index}) else a.print("A{X:0>6}.;1", .{index});
}

fn blocks(len: usize) u32 {
    return @intCast(std.mem.alignForward(usize, len, block) / block); // safe: lengths are checked against u32 extents first
}

fn lbaOf(value: u64) Error!u32 {
    return std.math.cast(u32, value) orelse error.ImageTooLarge;
}

const Flags = enum(u8) { file = 0, directory = 2 };

/// Writes one directory record at the start of `out` and returns its length.
fn writeRecord(out: []u8, lba: u32, size: u32, flags: Flags, id: []const u8, su: []const u8) usize {
    const len = 33 + id.len + (1 - id.len % 2) + su.len;
    std.debug.assert(len <= 255);
    std.debug.assert(len <= out.len);
    @memset(out[0..len], 0);
    out[0] = @intCast(len); // safe: at most 255, asserted
    both32(out[2..10], lba);
    both32(out[10..18], size);
    // 1970-01-01 00:00:00, offset 0.
    out[18] = 70;
    out[19] = 1;
    out[20] = 1;
    out[25] = @backingInt(flags);
    both16(out[28..32], 1);
    out[32] = @intCast(id.len); // safe: identifiers are at most ten bytes
    @memcpy(out[33..][0..id.len], id);
    @memcpy(out[len - su.len .. len], su);
    return len;
}

fn both16(out: *[4]u8, value: u16) void {
    std.mem.writeInt(u16, out[0..2], value, .little);
    std.mem.writeInt(u16, out[2..4], value, .big);
}

fn both32(out: *[8]u8, value: u32) void {
    std.mem.writeInt(u32, out[0..4], value, .little);
    std.mem.writeInt(u32, out[4..8], value, .big);
}

fn both32Bytes(value: u32) [8]u8 {
    var out: [8]u8 = undefined;
    both32(&out, value);
    return out;
}

/// PX: the member's type and permission bits, links, owner and group (RRIP 1.09's 36 bytes).
fn px(a: std.mem.Allocator, out: *std.ArrayList(u8), n: Node) Error!void {
    const type_bits: u32 = switch (n.kind) {
        .directory => 0o040000,
        .file => 0o100000,
        .symlink => 0o120000,
    };
    try out.appendSlice(a, "PX\x24\x01");
    for ([_]u32{ type_bits | (n.mode & 0o7777), n.links, n.uid, n.gid }) |v| try out.appendSlice(a, &both32Bytes(v));
}

/// NM: the member's name, in entries of at most 250 bytes, all but the last continued.
fn nm(a: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) Error!void {
    var rest = name;
    while (true) {
        const part = rest[0..@min(rest.len, 250)];
        rest = rest[part.len..];
        try out.appendSlice(a, &.{ 'N', 'M', @intCast(5 + part.len), 1, @intFromBool(rest.len > 0) }); // safe: at most 255
        try out.appendSlice(a, part);
        if (rest.len == 0) return;
    }
}

/// SL: a symbolic link's target as components (root, `.`, `..` or a name), in
/// entries of at most 255 bytes. An entry ends only inside a name, continued in
/// the next: readers differ on whether a `/` falls between entries (libarchive
/// starts each without one; FreeBSD follows the last component's flag), and
/// agree when the boundary is within a component. A target whose boundary would
/// fall between components (a `.`, `..` or the end of a name filling an entry to
/// its last two bytes) is refused.
fn sl(a: std.mem.Allocator, out: *std.ArrayList(u8), target: []const u8) Error!void {
    if (target.len == 0) return error.LinkTarget;
    var entry: std.ArrayList(u8) = .empty;
    const Component = struct { flags: u8, text: []const u8 };
    var components: std.ArrayList(Component) = .empty;
    if (target[0] == '/') try components.append(a, .{ .flags = 8, .text = "" });
    var parts = std.mem.tokenizeScalar(u8, target, '/');
    while (parts.next()) |part| try components.append(a, if (std.mem.eql(u8, part, "."))
        .{ .flags = 2, .text = "" }
    else if (std.mem.eql(u8, part, ".."))
        .{ .flags = 4, .text = "" }
    else
        .{ .flags = 0, .text = part });
    for (components.items) |c| {
        var text = c.text;
        while (true) {
            const room = 250 - entry.items.len;
            if (2 + text.len <= room) {
                try entry.appendSlice(a, &.{ c.flags, @intCast(text.len) }); // safe: at most 248, fitting the entry
                try entry.appendSlice(a, text);
                break;
            }
            if (c.flags != 0 or room < 3) return error.LinkTarget;
            const piece = text[0 .. room - 2];
            try entry.appendSlice(a, &.{ 1, @intCast(piece.len) }); // safe: at most 248
            try entry.appendSlice(a, piece);
            try out.appendSlice(a, &.{ 'S', 'L', @intCast(5 + entry.items.len), 1, 1 }); // safe: at most 255
            try out.appendSlice(a, entry.items);
            entry.clearRetainingCapacity();
            text = text[piece.len..];
        }
    }
    try out.appendSlice(a, &.{ 'S', 'L', @intCast(5 + entry.items.len), 1, 0 }); // safe: at most 255
    try out.appendSlice(a, entry.items);
}

const er_id = "RRIP_1991A";
const er_descriptor = "THE ROCK RIDGE INTERCHANGE PROTOCOL PROVIDES SUPPORT FOR POSIX FILE SYSTEM SEMANTICS";
const er_source = "PLEASE CONTACT DISC PUBLISHER FOR SPECIFICATION SOURCE.  SEE PUBLISHER IDENTIFIER IN PRIMARY VOLUME DESCRIPTOR FOR CONTACT INFORMATION.";

/// ER: the extension the image's system use follows, Rock Ridge 1.09.
fn extensionReference() [8 + er_id.len + er_descriptor.len + er_source.len]u8 {
    var out: [8 + er_id.len + er_descriptor.len + er_source.len]u8 = undefined;
    out[0..8].* = .{ 'E', 'R', out.len, 1, er_id.len, er_descriptor.len, er_source.len, 1 };
    @memcpy(out[8..][0..er_id.len], er_id);
    @memcpy(out[8 + er_id.len ..][0..er_descriptor.len], er_descriptor);
    @memcpy(out[8 + er_id.len + er_descriptor.len ..], er_source);
    return out;
}

fn continuationEntry(out: *[28]u8, lba: u32, offset: u32, len: u32) void {
    out[0..4].* = .{ 'C', 'E', 28, 1 };
    both32(out[4..12], lba);
    both32(out[12..20], offset);
    both32(out[20..28], len);
}

/// What a reader finds in an image: each member by its Rock Ridge path, for the tests.
const Read = struct {
    path: []const u8,
    kind: Kind,
    mode: u32,
    links: u32,
    lba: u32,
    data: []const u8,
};

fn readImage(a: std.mem.Allocator, image: []const u8) ![]Read {
    if (!std.mem.eql(u8, image[16 * block + 1 ..][0..5], "CD001")) return error.NotIso;
    const root = image[16 * block + 156 ..][0..34];
    var found: std.ArrayList(Read) = .empty;
    try readDir(a, image, "", std.mem.readInt(u32, root[2..6], .little), std.mem.readInt(u32, root[10..14], .little), &found);
    return found.items;
}

fn readDir(a: std.mem.Allocator, image: []const u8, prefix: []const u8, lba: u32, size: u32, found: *std.ArrayList(Read)) !void {
    const extent = image[@as(usize, lba) * block ..][0..size];
    var at: usize = 0;
    var index: usize = 0;
    while (at < extent.len) {
        const len = extent[at];
        if (len == 0) {
            at = std.mem.alignForward(usize, at + 1, block);
            continue;
        }
        const r = extent[at..][0..len];
        at += len;
        defer index += 1;
        if (index < 2) continue;
        const id_len = r[32];
        var su = r[33 + id_len + (1 - id_len % 2) ..];
        var name: std.ArrayList(u8) = .empty;
        var target: std.ArrayList(u8) = .empty;
        var mode: u32 = 0;
        var links: u32 = 0;
        var area: ?[]const u8 = null;
        var separate = true;
        while (true) {
            while (su.len >= 4 and su[2] >= 4 and su[2] <= su.len) {
                const e = su[0..su[2]];
                su = su[e.len..];
                if (std.mem.eql(u8, e[0..2], "PX")) {
                    mode = std.mem.readInt(u32, e[4..8], .little);
                    links = std.mem.readInt(u32, e[12..16], .little);
                } else if (std.mem.eql(u8, e[0..2], "NM")) {
                    try name.appendSlice(a, e[5..]);
                } else if (std.mem.eql(u8, e[0..2], "SL")) {
                    // Components joined by `/`, a continued one with the next.
                    var c = e[5..];
                    while (c.len >= 2) {
                        const flags = c[0];
                        const piece = c[2..][0..c[1]];
                        c = c[2 + piece.len ..];
                        if (separate and target.items.len > 0 and target.items[target.items.len - 1] != '/') try target.append(a, '/');
                        if (flags & 8 != 0) try target.append(a, '/') else if (flags & 2 != 0) try target.append(a, '.') else if (flags & 4 != 0) try target.appendSlice(a, "..") else try target.appendSlice(a, piece);
                        separate = flags & 1 == 0;
                    }
                } else if (std.mem.eql(u8, e[0..2], "CE")) {
                    const ce_lba = std.mem.readInt(u32, e[4..8], .little);
                    const off = std.mem.readInt(u32, e[12..16], .little);
                    const ce_len = std.mem.readInt(u32, e[20..24], .little);
                    area = image[@as(usize, ce_lba) * block + off ..][0..ce_len];
                }
            }
            su = area orelse break;
            area = null;
        }
        const path = if (prefix.len == 0) name.items else try a.print("{s}/{s}", .{ prefix, name.items });
        const file_lba = std.mem.readInt(u32, r[2..6], .little);
        const file_size = std.mem.readInt(u32, r[10..14], .little);
        const kind: Kind = switch (mode & 0o170000) {
            0o040000 => .directory,
            0o120000 => .symlink,
            else => .file,
        };
        const data: []const u8 = switch (kind) {
            .file => image[@as(usize, file_lba) * block ..][0..file_size],
            .symlink => target.items,
            .directory => "",
        };
        try found.append(a, .{ .path = path, .kind = kind, .mode = mode & 0o7777, .links = links, .lba = file_lba, .data = data });
        if (kind == .directory) try readDir(a, image, path, file_lba, file_size, found);
    }
}

fn findRead(all: []const Read, path: []const u8) ?Read {
    for (all) |r| if (std.mem.eql(u8, r.path, path)) return r;
    return null;
}

/// `text` `count` times over, for the tests.
fn repeat(comptime text: []const u8, comptime count: usize) *const [text.len * count]u8 {
    return comptime blk: {
        @setEvalBranchQuota(count * 4 + 100);
        var out: [text.len * count]u8 = undefined;
        for (0..count) |i| @memcpy(out[i * text.len ..][0..text.len], text);
        const final = out;
        break :blk &final;
    };
}

test "an image written is read back by its Rock Ridge names, modes, links and data" {
    var w: Writer = try .init(std.testing.allocator);
    defer w.deinit();
    try w.add(.{ .name = "./bin/", .kind = .directory, .mode = 0o755 });
    try w.add(.{ .name = "bin/sh", .kind = .file, .mode = 0o555, .data = "\x7fELF shell" });
    try w.link("bin/-sh", "bin/sh");
    try w.add(.{ .name = "usr/share/doc/empty", .kind = .file, .mode = 0o644 });
    try w.add(.{ .name = "etc/termcap", .kind = .symlink, .mode = 0o777, .data = "/usr/share/misc/termcap" });
    try w.add(.{ .name = "lib/libc.so", .kind = .symlink, .mode = 0o777, .data = "../lib/./libc.so.7" });
    try w.add(.{ .name = "sbin/setuid", .kind = .file, .mode = 0o4555, .data = repeat("x", 5000) });
    const long = repeat("n", 255);
    try w.add(.{ .name = "tmp/" ++ long, .kind = .file, .mode = 0o600, .data = "long" });
    const far = "/" ++ repeat("abcdefghij", 30) ++ "/" ++ repeat("k", 250);
    try w.add(.{ .name = "tmp/far", .kind = .symlink, .mode = 0o777, .data = far });
    var many: [300][8]u8 = undefined;
    for (&many, 0..) |*name, i| try w.add(.{ .name = try std.mem.print(name, "m/{d:0>6}", .{i}), .kind = .file, .mode = 0o644, .data = "m" });

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try w.finish(&out.writer);
    const image = out.written();
    try std.testing.expectEqual(@as(usize, 0), image.len % block);
    try std.testing.expectEqual(image.len / block, std.mem.readInt(u32, image[16 * block + 80 ..][0..4], .little));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const all = try readImage(arena.allocator(), image);
    const sh = findRead(all, "bin/sh").?;
    try std.testing.expectEqualStrings("\x7fELF shell", sh.data);
    try std.testing.expectEqual(@as(u32, 0o555), sh.mode);
    try std.testing.expectEqual(@as(u32, 2), sh.links);
    const dash = findRead(all, "bin/-sh").?;
    try std.testing.expectEqual(sh.lba, dash.lba);
    try std.testing.expectEqual(@as(u32, 2), dash.links);
    try std.testing.expectEqual(Kind.directory, findRead(all, "usr/share/doc").?.kind);
    try std.testing.expectEqualStrings("", findRead(all, "usr/share/doc/empty").?.data);
    try std.testing.expectEqualStrings("/usr/share/misc/termcap", findRead(all, "etc/termcap").?.data);
    try std.testing.expectEqualStrings("../lib/./libc.so.7", findRead(all, "lib/libc.so").?.data);
    try std.testing.expectEqual(@as(u32, 0o4555), findRead(all, "sbin/setuid").?.mode);
    try std.testing.expectEqualStrings(repeat("x", 5000), findRead(all, "sbin/setuid").?.data);
    try std.testing.expectEqualStrings("long", findRead(all, "tmp/" ++ long).?.data);
    try std.testing.expectEqualStrings(far, findRead(all, "tmp/far").?.data);
    try std.testing.expectEqualStrings("m", findRead(all, "m/000299").?.data);
    try std.testing.expectEqual(@as(usize, 300), blk: {
        var count: usize = 0;
        for (all) |r| count += @intFromBool(std.mem.startsWith(u8, r.path, "m/"));
        break :blk count;
    });
    // The root's own record starts with SUSP's indicator; Rock Ridge's reference follows it.
    const root_lba = std.mem.readInt(u32, image[16 * block + 158 ..][0..4], .little);
    try std.testing.expectEqualStrings("SP\x07\x01\xbe\xef", image[root_lba * block + 34 ..][0..6]);
    try std.testing.expect(std.mem.find(u8, image, "ERRRIP") == null);
    try std.testing.expect(std.mem.find(u8, image, er_id) != null);
}

test "the same members give the same image, and bad names are refused" {
    var images: [2][]u8 = undefined;
    for (&images) |*image| {
        var w: Writer = try .init(std.testing.allocator);
        defer w.deinit();
        try w.add(.{ .name = "b/z", .kind = .file, .mode = 0o644, .data = "z" });
        try w.add(.{ .name = "a", .kind = .file, .mode = 0o644, .data = "a" });
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        try w.finish(&out.writer);
        image.* = try out.toOwnedSlice();
    }
    defer for (images) |image| std.testing.allocator.free(image);
    try std.testing.expectEqualSlices(u8, images[0], images[1]);

    var w: Writer = try .init(std.testing.allocator);
    defer w.deinit();
    try std.testing.expectError(error.InvalidName, w.add(.{ .name = "a/../b", .kind = .file, .mode = 0o644 }));
    try std.testing.expectError(error.InvalidName, w.add(.{ .name = "a//b", .kind = .file, .mode = 0o644 }));
    try w.add(.{ .name = "f", .kind = .file, .mode = 0o644 });
    try std.testing.expectError(error.NotDirectory, w.add(.{ .name = "f/g", .kind = .file, .mode = 0o644 }));
    try std.testing.expectError(error.LinkTarget, w.link("h", "missing"));
}
