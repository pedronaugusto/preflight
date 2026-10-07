const std = @import("std");
const gantry = @import("gantry");
const family = @import("rules.zig");

const Item = struct { path: []const u8, text: []const u8 };
const Reader = struct {
    items: []const Item,
    fn read(r: Reader, _: std.mem.Allocator, _: std.Io, path: []const u8) error{}!?[]const u8 {
        for (r.items) |item| if (std.mem.eql(u8, item.path, path)) return item.text;
        return null;
    }
};

test "family policies gate calls and production imports, with one definition per policy" {
    const items = [_]Item{
        .{ .path = "src/app.zig", .text =
        \\pub const support = @import("shakedown");
        \\pub fn work() void {
        \\    file . // trivia between code tokens
        \\        sync (io);
        \\    createFileAtomic(io); fsync(fd); fdatasync(fd); FlushFileBuffers(handle);
        \\    file.syncFile(io); dir.syncDir(io); io.async(work);
        \\    file.@"sync"(io); @"io".@"async"(work);
        \\    otherio.async(work); file.resync(io);
        \\    const literal = "file.sync( io.async( createFileAtomic(";
        \\    // file.sync( io.async( createFileAtomic(
        \\}
        },
        .{ .path = "src/app_test.zig", .text = "const support = @import(\"shakedown\"); test { _ = support; }" },
        .{ .path = "src/fixtures/helper.zig", .text = "pub const support = @import(\"shakedown\");" },
        .{ .path = "src/inline.zig", .text = "const support = @import(\"shakedown\"); test { _ = support; }" },
    };
    const paths = [_][]const u8{ "src/app.zig", "src/app_test.zig", "src/fixtures/helper.zig", "src/inline.zig" };
    const owned = family.durability ++ family.no_async;
    var graph = try gantry.scan(std.testing.allocator, std.testing.io, &paths, Reader{ .items = &items }, Reader.read, .{
        .manifests = false,
        .tokens = &owned,
        .test_paths = &.{ "*_test.zig", "src/fixtures/**" },
    });
    defer graph.deinit();
    var findings = try graph.check(std.testing.allocator, .{ .references = &family.shakedown, .tokens = &owned });
    defer findings.deinit();
    try std.testing.expectEqual(@as(usize, 11), findings.items().len);
    var imports: usize = 0;
    var syncs: usize = 0;
    var asyncs: usize = 0;
    for (findings.items()) |finding| {
        if (std.mem.eql(u8, finding.rule, family.shakedown[0].name)) {
            imports += 1;
            try std.testing.expectEqualStrings("src/app.zig", finding.reference.?.from);
        } else if (std.mem.eql(u8, finding.rule, family.durability[0].name)) syncs += 1 else if (std.mem.eql(u8, finding.rule, family.no_async[0].name)) asyncs += 1 else return error.UnexpectedRule;
    }
    try std.testing.expectEqual(@as(usize, 1), imports);
    try std.testing.expectEqual(@as(usize, 8), syncs);
    try std.testing.expectEqual(@as(usize, 2), asyncs);
}
