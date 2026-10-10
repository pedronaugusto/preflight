const std = @import("std");
const builtin = @import("builtin");
const C = std.Build.Configuration;
const shakedown = @import("shakedown");
const configuration = @import("facts/configuration.zig");
const facts = @import("facts.zig");

pub fn seed(a: std.mem.Allocator) ![]const u8 {
    var wip: C.Wip = .init(a);
    defer wip.deinit();
    const name = try wip.addString("test");
    const deps = try wip.addExtra(C.Deps, .{ .steps = .{ .slice = &.{} } });
    const extended = try wip.addExtraErased(C.Step.TopLevel, .{ .description = name });
    try wip.steps.append(a, .{ .name = name, .owner = .root, .deps = deps, .max_rss = .none, .extended = @fromBackingInt(extended) });
    var writer: std.Io.Writer.Allocating = .init(a);
    defer writer.deinit();
    wip.write(&writer.writer, .{ .default_step = @fromBackingInt(0), .generated_files_len = 0, .poisoned = false }) catch return error.OutOfMemory;
    return a.dupe(u8, writer.written());
}

fn allocate(gpa: std.mem.Allocator) !void {
    var no_resize = shakedown.alloc.NoResize.init(gpa);
    var arena = std.heap.ArenaAllocator.init(no_resize.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try seed(a);
    const c = try configuration.load(a, bytes);
    try std.testing.expectEqualStrings("test", c.steps[0].name.slice(&c));
}

test "build configuration bounds reserved bits and every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocate, .{});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try seed(a);
    for (0..bytes.len) |length| try std.testing.expectError(error.MalformedConfiguration, configuration.load(a, bytes[0..length]));
    var bad = try a.dupe(u8, bytes);
    const string_bytes_len = std.mem.bytesToValue(C.Header, bytes[0..@sizeOf(C.Header)]).string_bytes_len;
    const step = @sizeOf(C.Header) + string_bytes_len;
    // A compiler-produced string index cannot point outside the string table.
    @memset(bad[step..][0..4], 0xff);
    try std.testing.expectError(error.MalformedConfiguration, configuration.load(a, bad));
    @memcpy(bad, bytes);
    // TopLevel reserved flag bits must remain zero.
    bad[bad.len - 5] |= 0x80;
    try std.testing.expectError(error.MalformedConfiguration, configuration.load(a, bad));
}

test "the exported facts name the Zig that produced them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loaded = try configuration.load(a, try seed(a));
    var out: std.Io.Writer.Allocating = .init(a);
    try facts.write(a, .{ .config = loaded, .path = "path" }, &out.writer);
    const parsed = try std.json.parseFromSliceLeaky(struct { protocol: u32, zig: []const u8 }, a, out.written(), .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(u32, 1), parsed.protocol);
    try std.testing.expectEqualStrings(builtin.zig_version_string, parsed.zig);
}
