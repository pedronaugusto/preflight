const std = @import("std");
const src = @import("source.zig");
const ledger = @import("ledger.zig");

pub fn check(c: *src.Context, executable: []const u8, config: src.Value) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.a, &.{ executable, "--ignore", "Z024" });
    const paths = src.get(config, "ziglint_paths");
    if (paths == .null) {
        for ([_][]const u8{ "src", "examples", "ci", "build.zig" }) |path|
            if (c.exists(path)) try argv.append(c.a, path);
    } else for (src.items(paths)) |value| {
        const path = src.string(value, "");
        if (c.exists(path)) try argv.append(c.a, path);
    }
    const result = try std.process.run(c.a, c.io, .{ .argv = argv.items });
    const output = try std.mem.concat(c.a, u8, &.{ result.stdout, result.stderr });
    var allowed = try ledger.Ledger.load(c, config, "ziglint_exceptions");
    try parseFindings(c, output, &allowed);
    try allowed.finish();
    if ((result.term != .exited or result.term.exited != 0) and std.mem.trim(u8, output, " \t\r\n").len == 0)
        c.fail("ziglint: command failed without diagnostics", .{});
}

pub fn findings(c: *src.Context, output: []const u8, exceptions: src.Value) !void {
    var allowed = try ledger.Ledger.init(c, exceptions);
    try parseFindings(c, output, &allowed);
    try allowed.finish();
}

fn parseFindings(c: *src.Context, output: []const u8, allowed: *ledger.Ledger) !void {
    var remaining = std.mem.trim(u8, output, " \t\r\n");
    while (remaining.len > 0) {
        const rule_end = std.mem.indexOf(u8, remaining, ": ") orelse {
            c.fail("ziglint: {s}", .{remaining});
            return;
        };
        const rule = remaining[0..rule_end];
        if (rule.len < 2 or rule[0] != 'Z') {
            c.fail("ziglint: {s}", .{remaining});
            return;
        }
        _ = std.fmt.parseInt(u32, rule[1..], 10) catch {
            c.fail("ziglint: {s}", .{remaining});
            return;
        };
        const rest = remaining[rule_end + 2 ..];
        const header_end = std.mem.indexOf(u8, rest, ": ") orelse return error.InvalidZiglintDiagnostic;
        const header = rest[0..header_end];
        const line_separator = std.mem.findScalarLast(u8, header, ':') orelse return error.InvalidZiglintDiagnostic;
        const path = try c.a.dupe(u8, header[0..line_separator]);
        std.mem.replaceScalar(u8, path, '\\', '/');
        const line = try std.fmt.parseInt(usize, header[line_separator + 1 ..], 10);
        const detail_start = rule_end + 2 + header_end + 2;
        const next = nextDiagnostic(remaining, detail_start);
        const detail = std.mem.trim(u8, remaining[detail_start..next], " \t\r\n");
        const text = c.read(path) catch "";
        const source = sourceLine(text, line);
        if (!allowed.consume(rule, path, source, detail)) c.fail("{s}: {s}:{d}: {s}", .{ rule, path, line, detail });
        remaining = std.mem.trimStart(u8, remaining[next..], "\r\n");
    }
}

fn nextDiagnostic(text: []const u8, start: usize) usize {
    var cursor = start;
    while (std.mem.findPos(u8, text, cursor, "\nZ")) |index| {
        var end = index + 2;
        while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
        if (end > index + 2 and std.mem.startsWith(u8, text[end..], ": ")) return index + 1;
        cursor = index + 2;
    }
    return text.len;
}

fn sourceLine(text: []const u8, wanted: usize) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line: usize = 1;
    while (lines.next()) |value| : (line += 1) {
        if (line == wanted) return std.mem.trim(u8, value, " \t\r");
    }
    return "";
}

test "unknown failures and missing reasons cannot be hidden" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io };
    try findings(&c, "internal error\n", .null);
    try std.testing.expectEqual(@as(usize, 1), c.errors);
    const exceptions = (try std.json.parseFromSlice(src.Value, c.a, "[{\"rule\":\"Z001\",\"path\":\"x.zig\",\"source\":\"code\",\"detail\":\"detail\",\"reason\":\"\"}]", .{})).value;
    try findings(&c, "", exceptions);
    try std.testing.expectEqual(@as(usize, 3), c.errors);
}

test "exact exceptions are consumed once and cannot admit source changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    try tmp.dir.writeFile(c.io, .{ .sub_path = "value.zig", .data = "const existing = @import(\"other.zig\").value;\n" });
    const allowed = (try std.json.parseFromSlice(src.Value, c.a, "[{\"rule\":\"Z028\",\"path\":\"value.zig\",\"source\":\"const existing = @import(\\\"other.zig\\\").value;\",\"detail\":\"inline import\",\"reason\":\"existing declaration\"}]", .{})).value;
    const output = "Z028: value.zig:1: inline import\n";
    try findings(&c, output, allowed);
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    try findings(&c, output ++ output, allowed);
    try std.testing.expectEqual(@as(usize, 1), c.errors);
    try tmp.dir.writeFile(c.io, .{ .sub_path = "value.zig", .data = "const changed = @import(\"other.zig\").value;\n" });
    try findings(&c, output, allowed);
    try std.testing.expectEqual(@as(usize, 3), c.errors);
}
