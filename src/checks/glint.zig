//! Completion is checked before findings policy. No code predicates live here.
const std = @import("std");
const engine = @import("glint");
const builtin = @import("builtin");
const test_options = @import("test_options");
const src = @import("source.zig");
const ledger = @import("ledger.zig");

/// Arguments contain explicit files and caller-selected code configuration.
/// Selection, module context and path policy belong to the repository caller.
pub fn check(c: *src.Context, executable: []const u8, arguments: []const []const u8, config: src.Value, source_count: usize) !void {
    var random: [16]u8 = undefined;
    c.io.random(&random);
    const nonce = std.fmt.bytesToHex(&random, .lower);
    const scratch = try c.a.print(".zig-cache/preflight-glint-{s}", .{nonce});
    try c.directory().createDirPath(c.io, scratch);
    defer c.directory().deleteTree(c.io, scratch) catch {}; // glint-ignore: Z026 -- scratch removal is best effort after verified receipt consumption
    const result_path = try std.Io.Dir.path.join(c.a, &.{ scratch, "completion.json" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(c.a, executable);
    try argv.appendSlice(c.a, arguments);
    try argv.appendSlice(c.a, &.{ "--format", "json", "--result", result_path, "--run-id", &nonce });
    const result = try capture(c, argv.items, .limited(64 * 1024 * 1024));
    if (result.term != .exited) {
        c.fail("glint: analysis terminated abnormally ({t})", .{result.term});
        return;
    }
    const receipt = c.read(result_path) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        c.fail("glint: missing completion receipt ({t})", .{err});
        return;
    };
    try accept(c, receipt, &nonce, result.term.exited, result.stdout, result.stderr, config, source_count);
}

fn capture(c: *src.Context, argv: []const []const u8, limit: std.Io.Limit) std.process.RunError!std.process.RunResult {
    return std.process.run(c.a, c.io, .{ .argv = argv, .cwd = c.childCwd(), .environ_map = c.environ_map, .stdout_limit = limit, .stderr_limit = limit });
}

/// An allowed-only finding list cannot certify execution or required coverage.
pub fn accept(c: *src.Context, receipt: []const u8, nonce: []const u8, status: u8, output: []const u8, stderr: []const u8, config: src.Value, source_count: usize) !void {
    const completed = engine.Completion.verify(c.a, receipt, nonce, status, output) catch |err| {
        if (err == error.OutOfMemory) return err;
        c.fail("glint: invalid completion receipt", .{});
        return;
    };
    if (!completed or stderr.len != 0) {
        c.fail("glint: analysis did not complete successfully (exit {d})", .{status});
        return;
    }
    const record = try std.json.parseFromSliceLeaky(engine.Completion.Record, c.a, receipt, .{});
    if (source_count == 0 or record.sources != source_count) return error.GlintSourceCountMismatch;
    const document = try std.json.parseFromSliceLeaky(src.Value, c.a, output, .{});
    const version = src.get(document, "version");
    const complete = src.get(document, "analysis_complete");
    const diagnostics = src.get(document, "diagnostics");
    const coverage = src.get(document, "coverage");
    if (version != .integer or version.integer != 1 or complete != .bool or !complete.bool or diagnostics != .array or coverage != .array or diagnostics.array.items.len != record.findings)
        return error.InvalidGlintReport;
    // Load exceptions only after the run, receipt and required coverage pass.
    var allowed = try ledger.Ledger.load(c, config, "glint_exceptions");
    for (diagnostics.array.items) |diagnostic| {
        const name = src.get(diagnostic, "rule");
        const path = src.get(diagnostic, "source");
        const detail = src.get(diagnostic, "message");
        const level = src.get(diagnostic, "level");
        const line = src.get(src.get(diagnostic, "span"), "line");
        if (name != .string or path != .string or detail != .string or level != .string or line != .integer or line.integer <= 0 or engine.parseRule(name.string, &packDefinitions()) == null)
            return error.InvalidGlintReport;
        if (!std.mem.eql(u8, level.string, "gate") and !std.mem.eql(u8, level.string, "report")) return error.InvalidGlintReport;
        const line_number = std.math.cast(usize, line.integer) orelse return error.InvalidGlintReport;
        const source = try sourceLine(try c.read(path.string), line_number);
        const excepted = allowed.consume(name.string, path.string, source, detail.string);
        if (std.mem.eql(u8, level.string, "gate") and !excepted) {
            c.fail("{s}: {s}:{d}: {s}", .{ name.string, path.string, line.integer, detail.string });
        } else c.report("glint report: {s}: {s}:{d}: {s}\n", .{ name.string, path.string, line.integer, detail.string });
    }
    for (coverage.array.items) |item| {
        const reason = src.get(item, "reason");
        if (reason != .string) return error.InvalidGlintReport;
        if (!std.mem.eql(u8, reason.string, "parsed")) c.report("glint coverage: {s}\n", .{try std.json.Stringify.valueAlloc(c.a, item, .{})});
    }
    try allowed.finish();
}

fn packDefinitions() [engine.AegisPack.rules.len]engine.RuleDefinition {
    var definitions: [engine.AegisPack.rules.len]engine.RuleDefinition = undefined;
    for (engine.AegisPack.rules, &definitions) |rule, *definition| definition.* = rule.definition;
    return definitions;
}

fn sourceLine(text: []const u8, wanted: usize) ![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line: usize = 1;
    while (lines.next()) |value| : (line += 1) {
        if (line == wanted) return std.mem.trim(u8, value, " \t\r");
    }
    return error.InvalidGlintSpan;
}

test "F04 allowed findings require nonce exit source count complete analysis and exact output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    try tmp.dir.writeFile(c.io, .{ .sub_path = "value.zig", .data = "code\n" });
    try tmp.dir.writeFile(c.io, .{ .sub_path = "exceptions.json", .data = "[{\"rule\":\"Z013\",\"path\":\"value.zig\",\"source\":\"code\",\"detail\":\"unused import\",\"reason\":\"site reviewed\"}]" });
    const config = (try std.json.parseFromSlice(src.Value, c.a, "{\"glint_exceptions\":\"exceptions.json\"}", .{})).value;
    const output = "{\"version\":1,\"analysis_complete\":true,\"diagnostics\":[{\"rule\":\"Z013\",\"source\":\"value.zig\",\"span\":{\"line\":1},\"level\":\"gate\",\"message\":\"unused import\"}],\"coverage\":[]}";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output, &digest, .{});
    const hex = std.fmt.bytesToHex(&digest, .lower);
    const good: engine.Completion.Record = .{ .version = 1, .run_id = "fresh", .completed = true, .outcome = .findings, .sources = 1, .findings = 1, .suppressed = 0, .output_bytes = output.len, .output_sha256 = &hex };
    const receipt = try std.json.Stringify.valueAlloc(c.a, good, .{});
    try accept(&c, receipt, "fresh", 1, output, "", config, 1);
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    for ([_]engine.Completion.Outcome{ .canceled, .input_failure, .output_failure, .analysis_incomplete, .tool_failure }) |outcome| {
        var bad = good;
        bad.outcome = outcome;
        bad.completed = false;
        try accept(&c, try std.json.Stringify.valueAlloc(c.a, bad, .{}), "fresh", 2, output, "", config, 1);
    }
    try accept(&c, receipt, "stale", 1, output, "", config, 1);
    try accept(&c, receipt, "fresh", 2, output, "", config, 1);
    try accept(&c, receipt, "fresh", 1, output[0 .. output.len - 1], "", config, 1);
    try accept(&c, receipt[0 .. receipt.len - 1], "fresh", 1, output, "", config, 1);
    try accept(&c, receipt, "fresh", 1, output, "input failure", config, 1);
    try std.testing.expectEqual(@as(usize, 10), c.errors);
    try std.testing.expectError(error.GlintSourceCountMismatch, accept(&c, receipt, "fresh", 1, output, "", config, 2));
}

test "F04 real process rejects incomplete allowed-only findings signals input cancellation and truncation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "value.zig", .data = "code\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "exceptions.json", .data = "[{\"rule\":\"Z013\",\"path\":\"value.zig\",\"source\":\"code\",\"detail\":\"unused import\",\"reason\":\"site reviewed\"}]" });
    try tmp.dir.writeFile(io, .{ .sub_path = "fake.zig", .data = fake });
    const compiled = try std.process.run(a, io, .{ .argv = &.{ "zig", "build-exe", "fake.zig", "-femit-bin=fake" }, .cwd = .{ .dir = tmp.dir } });
    try std.testing.expect(compiled.term == .exited and compiled.term.exited == 0);
    const executable = try tmp.dir.realPathFileAlloc(io, if (builtin.os.tag == .windows) "fake.exe" else "fake", a);
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"glint_exceptions\":\"exceptions.json\"}", .{})).value;
    var env = try std.testing.environ.createMap(a);
    defer env.deinit();
    for ([_][]const u8{ "findings", "clean", "incomplete", "canceled", "input", "truncated", "missing", "stderr", "signal" }) |mode| {
        if (std.mem.eql(u8, mode, "signal") and builtin.os.tag == .windows) continue;
        try env.put("LINT_MODE", mode);
        var c: src.Context = .{ .a = a, .io = io, .dir = tmp.dir, .environ_map = &env };
        try check(&c, executable, &.{"value.zig"}, if (std.mem.eql(u8, mode, "clean")) .null else config, 1);
        try std.testing.expectEqual(!std.mem.eql(u8, mode, "findings") and !std.mem.eql(u8, mode, "clean"), c.errors != 0);
    }
    const FaultIo = @import("shakedown").FaultIo;
    const canceled = try FaultIo.init(std.testing.allocator, io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .processSpawn, .n = 1 } }, .fault = .{ .fail = error.Canceled } }} });
    defer canceled.deinit();
    var cancel_context: src.Context = .{ .a = a, .io = canceled.io(), .dir = tmp.dir };
    try std.testing.expectError(error.Canceled, capture(&cancel_context, &.{executable}, .unlimited));
    try std.testing.expectEqual(@as(u64, 1), canceled.count(.processSpawn));
    try env.put("LINT_MODE", "findings");
    var bounded: src.Context = .{ .a = a, .io = io, .dir = tmp.dir, .environ_map = &env };
    try std.testing.expectError(error.StreamTooLong, capture(&bounded, &.{executable}, .limited(8)));
    const failed = try FaultIo.init(std.testing.allocator, io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .file_read_streaming, .n = 1 } }, .fault = .{ .fail = error.InputOutput } }} });
    defer failed.deinit();
    var failed_context: src.Context = .{ .a = a, .io = failed.io(), .dir = tmp.dir };
    try std.testing.expectError(error.InputOutput, capture(&failed_context, &.{executable}, .unlimited));
}

const fake =
    \\const std = @import("std");
    \\const builtin = @import("builtin");
    \\pub fn main(init: std.process.Init) !u8 {
    \\    const a = init.arena.allocator();
    \\    const args = try init.minimal.args.toSlice(a);
    \\    const mode = init.environ_map.get("LINT_MODE") orelse "findings";
    \\    var path: ?[]const u8 = null;
    \\    var nonce: []const u8 = "legacy";
    \\    for (args, 0..) |arg, i| {
    \\        if (std.mem.eql(u8, arg, "--result")) path = args[i + 1];
    \\        if (std.mem.eql(u8, arg, "--run-id")) nonce = args[i + 1];
    \\    }
    \\    const incomplete = std.mem.eql(u8, mode, "incomplete") or std.mem.eql(u8, mode, "canceled") or std.mem.eql(u8, mode, "input");
    \\    const clean = std.mem.eql(u8, mode, "clean");
    \\    const output = if (clean) "{\"version\":1,\"analysis_complete\":true,\"diagnostics\":[],\"coverage\":[]}" else "{\"version\":1,\"analysis_complete\":true,\"diagnostics\":[{\"rule\":\"Z013\",\"source\":\"value.zig\",\"span\":{\"line\":1},\"level\":\"gate\",\"message\":\"unused import\"}],\"coverage\":[]}";
    \\    var buffer: [512]u8 = undefined;
    \\    var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    \\    try writer.interface.writeAll(if (path == null) "Z013: value.zig:1: unused import\n" else if (std.mem.eql(u8, mode, "truncated")) output[0 .. output.len - 1] else output);
    \\    try writer.interface.flush();
    \\    if (std.mem.eql(u8, mode, "signal")) {
    \\        if (builtin.os.tag != .windows) try std.posix.raise(.KILL);
    \\    }
    \\    if (std.mem.eql(u8, mode, "stderr")) try std.Io.File.stderr().writeStreamingAll(init.io, "input failure\n");
    \\    if (path != null and !std.mem.eql(u8, mode, "missing")) {
    \\        var digest: [32]u8 = undefined;
    \\        std.crypto.hash.sha2.Sha256.hash(output, &digest, .{});
    \\        const receipt = try std.json.Stringify.valueAlloc(a, .{ .version = 1, .run_id = nonce, .completed = !incomplete, .outcome = if (incomplete) "analysis_incomplete" else if (clean) "clean" else "findings", .sources = 1, .findings = if (clean) @as(usize, 0) else @as(usize, 1), .suppressed = 0, .output_bytes = output.len, .output_sha256 = std.fmt.bytesToHex(&digest, .lower) }, .{});
    \\        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path.?, .data = receipt });
    \\    }
    \\    return if (incomplete) 2 else if (clean) 0 else 1;
    \\}
;

test "F04 published Glint reports required coverage and input failures independently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const executable = try std.Io.Dir.cwd().realPathFileAlloc(io, test_options.glint, a);
    var c: src.Context = .{ .a = a, .io = io, .dir = tmp.dir };
    try check(&c, executable, &.{ "--only", "Z003", "missing.zig" }, .null, 1);
    try std.testing.expect(c.errors != 0);
    // Even with no findings, a required unknown call is incomplete. Suppression
    // and an empty ledger cannot make symbolic/generic coverage a safe verdict.
    try tmp.dir.writeFile(io, .{ .sub_path = "unknown.zig", .data = "pub fn call(receiver: anytype) void { receiver.work(); }\n" });
    c.errors = 0;
    try check(&c, executable, &.{ "--only", "Z011", "--gate", "Z011", "unknown.zig" }, .null, 1);
    try std.testing.expect(c.errors != 0);
}
