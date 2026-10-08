const std = @import("std");
const src = @import("source.zig");
const ledger = @import("ledger.zig");

pub fn check(c: *src.Context, executable: []const u8, config: src.Value) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.a, &.{ executable, "--ignore", "Z013", "--ignore", "Z024" });
    const paths = src.get(config, "ziglint_paths");
    if (paths == .null) {
        for ([_][]const u8{ "src", "examples", "ci", "build.zig" }) |path|
            if (c.exists(path)) try argv.append(c.a, path);
    } else for (src.items(paths)) |value| {
        const path = src.string(value, "");
        if (c.exists(path)) try argv.append(c.a, path);
    }
    const result = try capture(c, argv.items, .limited(64 * 1024 * 1024));
    const output = try std.mem.concat(c.a, u8, &.{ result.stdout, result.stderr });
    var allowed = try ledger.Ledger.load(c, config, "ziglint_exceptions");
    try parseFindings(c, output, &allowed);
    try allowed.finish();
    // Termination is independent of exception acceptance. The pinned CLI
    // returns 1 for findings AND invalid arguments, 0 for some input errors,
    // swallows directory-walk errors, and ignores its final flush failure.
    // It cannot certify either complete outcome: never infer one from text.
    if (result.term != .exited) {
        c.fail("ziglint: analysis terminated abnormally ({t})", .{result.term});
    } else {
        c.fail("ziglint: completion unavailable in pinned 924b6b5 contract (exit {d}); a completion-aware tool is required", .{result.term.exited});
    }
}

fn capture(c: *src.Context, argv: []const []const u8, limit: std.Io.Limit) std.process.RunError!std.process.RunResult {
    return std.process.run(c.a, c.io, .{ .argv = argv, .cwd = c.childCwd(), .environ_map = c.environ_map, .stdout_limit = limit, .stderr_limit = limit });
}

pub fn findings(c: *src.Context, output: []const u8, exceptions: src.Value) !void {
    var allowed = try ledger.Ledger.init(c, exceptions);
    try parseFindings(c, output, &allowed);
    try allowed.finish();
}

fn parseFindings(c: *src.Context, output: []const u8, allowed: *ledger.Ledger) !void {
    var remaining = std.mem.trim(u8, output, " \t\r\n");
    while (remaining.len > 0) {
        const rule_end = std.mem.find(u8, remaining, ": ") orelse {
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
        const header_end = std.mem.find(u8, rest, ": ") orelse return error.InvalidZiglintDiagnostic;
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

test "owner allowed finding followed by signal must fail independently" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "value.zig", .data = "code\n" });
    // Test-only fake process: flush one complete, allowed diagnostic, then die.
    try tmp.dir.writeFile(io, .{ .sub_path = "fake.zig", .data =
        \\const std = @import("std");
        \\pub fn main(init: std.process.Init) !void {
        \\    var buffer: [128]u8 = undefined;
        \\    var writer = std.Io.File.stderr().writerStreaming(init.io, &buffer);
        \\    try writer.interface.writeAll("Z028: value.zig:1: inline import\n");
        \\    try writer.interface.flush();
        \\    try std.posix.raise(.KILL);
        \\}
        \\
    });
    const compiled = try std.process.run(a, io, .{ .argv = &.{ "zig", "build-exe", "fake.zig", "-femit-bin=fake" }, .cwd = .{ .dir = tmp.dir } });
    try std.testing.expect(compiled.term == .exited and compiled.term.exited == 0);
    const config = (try std.json.parseFromSlice(src.Value, a,
        \\{"ziglint_paths":["value.zig"],"ziglint_exceptions":"exceptions.json"}
    , .{})).value;
    try tmp.dir.writeFile(io, .{ .sub_path = "exceptions.json", .data = "[{\"rule\":\"Z028\",\"path\":\"value.zig\",\"source\":\"code\",\"detail\":\"inline import\",\"reason\":\"existing declaration\"}]" });
    var c: src.Context = .{ .a = a, .io = io, .dir = tmp.dir };
    const executable = try tmp.dir.realPathFileAlloc(io, "fake", a);
    try check(&c, executable, config);
    try std.testing.expect(c.errors != 0);
}

test "owner complete-looking findings and no findings fail closed without a completion contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "value.zig", .data = "code\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "exceptions.json", .data = "[{\"rule\":\"Z028\",\"path\":\"value.zig\",\"source\":\"code\",\"detail\":\"inline import\",\"reason\":\"existing declaration\"}]" });
    try tmp.dir.writeFile(io, .{ .sub_path = "fake.zig", .data =
        \\const std = @import("std");
        \\pub fn main(init: std.process.Init) !u8 {
        \\    const mode = init.environ_map.get("LINT_MODE") orelse "findings";
        \\    var buffer: [128]u8 = undefined;
        \\    var writer = std.Io.File.stderr().writerStreaming(init.io, &buffer);
        \\    if (!std.mem.eql(u8, mode, "empty")) try writer.interface.writeAll("Z028: value.zig:1: inline import\n");
        \\    if (std.mem.eql(u8, mode, "input")) try writer.interface.writeAll("error: cannot access 'missing.zig': error.FileNotFound\n");
        \\    if (std.mem.eql(u8, mode, "json")) try writer.interface.writeAll("{\"diagnostics\":[");
        \\    if (std.mem.eql(u8, mode, "partial")) try writer.interface.writeAll("Z028: value.zig:");
        \\    try writer.interface.flush();
        \\    return if (std.mem.eql(u8, mode, "empty")) 0 else 1;
        \\}
        \\
    });
    const compiled = try std.process.run(a, io, .{ .argv = &.{ "zig", "build-exe", "fake.zig", "-femit-bin=fake" }, .cwd = .{ .dir = tmp.dir } });
    try std.testing.expect(compiled.term == .exited and compiled.term.exited == 0);
    const executable = try tmp.dir.realPathFileAlloc(io, "fake", a);
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"ziglint_paths\":[\"value.zig\"],\"ziglint_exceptions\":\"exceptions.json\"}", .{})).value;
    var env = try std.testing.environ.createMap(a);
    defer env.deinit();
    const no_ledger = (try std.json.parseFromSlice(src.Value, a, "{}", .{})).value;
    for ([_][]const u8{ "findings", "empty", "input", "json", "partial" }) |mode| {
        try env.put("LINT_MODE", mode);
        var c: src.Context = .{ .a = a, .io = io, .dir = tmp.dir, .environ_map = &env };
        check(&c, executable, if (std.mem.eql(u8, mode, "empty")) no_ledger else config) catch |err| {
            try std.testing.expect(std.mem.eql(u8, mode, "partial"));
            try std.testing.expect(err == error.InvalidZiglintDiagnostic);
            continue;
        };
        try std.testing.expect(c.errors != 0);
        if (std.mem.eql(u8, mode, "empty") or std.mem.eql(u8, mode, "findings")) try std.testing.expectEqual(@as(usize, 1), c.errors);
    }
    const FaultIo = @import("shakedown").FaultIo;
    const faults = try FaultIo.init(std.testing.allocator, io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .processSpawn, .n = 1 } }, .fault = .{ .fail = error.Canceled } }} });
    defer faults.deinit();
    var cancelled: src.Context = .{ .a = a, .io = faults.io(), .dir = tmp.dir };
    try std.testing.expectError(error.Canceled, capture(&cancelled, &.{executable}, .unlimited));
    try std.testing.expectEqual(@as(u64, 1), faults.count(.processSpawn));
    // The limit fails the actual output collector; no partial diagnostic slice
    // is returned for the exception parser to turn into a successful gate.
    try env.put("LINT_MODE", "findings");
    var bounded: src.Context = .{ .a = a, .io = io, .dir = tmp.dir, .environ_map = &env };
    try std.testing.expectError(error.StreamTooLong, capture(&bounded, &.{executable}, .limited(8)));
    const capture_fault = try FaultIo.init(std.testing.allocator, io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .file_read_streaming, .n = 1 } }, .fault = .{ .fail = error.InputOutput } }} });
    defer capture_fault.deinit();
    var failed_capture: src.Context = .{ .a = a, .io = capture_fault.io(), .dir = tmp.dir };
    try std.testing.expectError(error.InputOutput, capture(&failed_capture, &.{executable}, .unlimited));
}

test "owner pinned tool input failure exits zero and has no completion protocol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const options = @import("test_options");
    var c: src.Context = .{ .a = a, .io = std.testing.io, .dir = tmp.dir };
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(c.io, options.ziglint, a);
    const result = try capture(&c, &.{ executable, "missing.zig" }, .unlimited);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expect(std.mem.find(u8, result.stderr, "error: cannot access 'missing.zig'") != null);
}

test "owner explicit lint inputs cannot be silently omitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "record.zig", .data =
        \\const std = @import("std");
        \\pub fn main(init: std.process.Init) !void {
        \\    const a = init.arena.allocator();
        \\    const args = try init.minimal.args.toSlice(a);
        \\    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "invocation.txt", .data = try std.mem.join(a, "\n", args) });
        \\}
        \\
    });
    const compiled = try std.process.run(a, io, .{ .argv = &.{ "zig", "build-exe", "record.zig", "-femit-bin=record" }, .cwd = .{ .dir = tmp.dir } });
    try std.testing.expect(compiled.term == .exited and compiled.term.exited == 0);
    const executable = try tmp.dir.realPathFileAlloc(io, "record", a);
    var c: src.Context = .{ .a = a, .io = io, .dir = tmp.dir };
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"ziglint_paths\":[\"missing.zig\"]}", .{})).value;
    try check(&c, executable, config);
    try std.testing.expect(std.mem.find(u8, try c.read("invocation.txt"), "\nmissing.zig") != null);
    for ([_][]const u8{ "{\"ziglint_paths\":true}", "{\"ziglint_paths\":[1]}", "{\"ziglint_paths\":[\"\"]}" }) |invalid| {
        const malformed = (try std.json.parseFromSlice(src.Value, a, invalid, .{})).value;
        try std.testing.expectError(error.InvalidZiglintPaths, check(&c, executable, malformed));
    }
}
