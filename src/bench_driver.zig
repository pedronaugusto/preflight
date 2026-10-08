//! Interleaved A/B process orchestration; no timers or statistical algorithms.
const std = @import("std");
const builtin = @import("builtin");
const bench = @import("shakedown").bench;
const Io = std.Io;
const limit: Io.Limit = .limited(64 * 1024 * 1024);

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    try arguments(args);
    const zig = try option(args, "--zig");
    const candidate = try Io.Dir.cwd().realPathFileAlloc(init.io, try option(args, "--candidate"), a);
    const comparison = try Io.Dir.cwd().realPathFileAlloc(init.io, try option(args, "--comparison"), a);
    const status = try command(a, init.io, candidate, &.{ "git", "status", "--porcelain", "--untracked-files=normal" });
    if (status.stdout.len != 0) return error.DirtyCandidate;
    const candidate_revision = try command(a, init.io, candidate, &.{ "git", "rev-parse", "HEAD" });
    const candidate_sha = std.mem.trim(u8, candidate_revision.stdout, "\r\n");
    const base = try option(args, "--base");
    const program = try option(args, "--program");
    if (program.len == 0 or std.mem.findAny(u8, program, "/\\") != null) return error.InvalidProgram;
    const pairs = try std.fmt.parseInt(usize, optional(args, "--pairs") orelse "5", 10);
    if (pairs == 0 or pairs > 100) return error.InvalidPairs;
    const prefix = optional(args, "--row") orelse "";
    const sha_result = try command(a, init.io, candidate, &.{ "git", "rev-parse", "--verify", "--end-of-options", try a.print("{s}^{{commit}}", .{base}) });
    const sha = std.mem.trim(u8, sha_result.stdout, "\r\n");
    if (sha.len != 40) return error.InvalidBaseCommit;
    var random: [8]u8 = undefined;
    init.io.random(&random);
    const scratch = try a.print(".zig-cache/preflight-ab/{s}-{x}", .{ sha, random });
    try Io.Dir.cwd().createDirPath(init.io, scratch);
    const absolute = try Io.Dir.cwd().realPathFileAlloc(init.io, scratch, a);
    defer Io.Dir.cwd().deleteTree(init.io, scratch) catch {};
    const checkout = try Io.Dir.path.join(a, &.{ absolute, "base" });
    _ = try command(a, init.io, candidate, &.{ "git", "clone", "--shared", "--no-checkout", "--", candidate, checkout });
    _ = try command(a, init.io, checkout, &.{ "git", "checkout", "--detach", sha });
    // Each revision configures itself. No guessed executable or graph reconstruction.
    _ = try command(a, init.io, checkout, &.{ zig, "build", "bench-build" });
    _ = try command(a, init.io, candidate, &.{ zig, "build", "bench-build" });
    const suffix = if (builtin.os.tag == .windows) ".exe" else "";
    const executable = try a.print("{s}{s}", .{ program, suffix });
    const base_bin = try Io.Dir.path.join(a, &.{ checkout, "zig-out", "bench", executable });
    const candidate_bin = try Io.Dir.path.join(a, &.{ candidate, "zig-out", "bench", executable });
    var output_buffer: [4096]u8 = undefined;
    var output = Io.File.stdout().writerStreaming(init.io, &output_buffer);
    for (0..pairs) |pair| {
        var texts: [2][]const u8 = undefined;
        // Reverse order on alternate pairs to reduce order bias.
        for (0..2) |turn| {
            const index = (turn + pair % 2) % 2;
            const cwd = try a.print("{s}/run-{d}-{d}", .{ absolute, pair, index });
            try Io.Dir.cwd().createDirPath(init.io, cwd);
            const result = try command(a, init.io, cwd, &.{ if (index == 0) base_bin else candidate_bin, "--row", prefix });
            try validate(init.gpa, result.stdout, if (index == 0) sha else candidate_sha);
            texts[index] = result.stdout;
        }
        const before = try a.print("{s}/before-{d}.jsonl", .{ absolute, pair });
        const after = try a.print("{s}/after-{d}.jsonl", .{ absolute, pair });
        try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = before, .data = texts[0] });
        try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = after, .data = texts[1] });
        const result = try command(a, init.io, candidate, &.{ comparison, before, after });
        try emit(&output.interface, result.stdout);
        if (optional(args, "--output")) |destination| {
            try Io.Dir.cwd().createDirPath(init.io, destination);
            for ([_][]const u8{ "base", "candidate", "comparison" }, [_][]const u8{ texts[0], texts[1], result.stdout }) |name, text| {
                try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try a.print("{s}/{d}-{s}.jsonl", .{ destination, pair, name }), .data = text });
            }
        }
    }
    try output.interface.flush();
}

fn validate(gpa: std.mem.Allocator, text: []const u8, commit: ?[]const u8) !void {
    // A capture cut in the middle of a line is an infrastructure failure.
    if (text.len == 0 or text[text.len - 1] != '\n') return error.TruncatedRun;
    var parsed = try bench.parse(gpa, text);
    defer parsed.deinit();
    for (parsed.rows.items) |row| {
        if (row.value.smoke) return error.SmokeRun;
        if (!std.mem.eql(u8, row.value.zig, builtin.zig_version_string)) return error.WrongCompiler;
        if (commit) |expected| if (!std.mem.eql(u8, row.value.commit, expected)) return error.WrongCommit;
    }
}

fn command(a: std.mem.Allocator, io: Io, cwd: []const u8, argv: []const []const u8) !std.process.RunResult {
    const result = try std.process.run(a, io, .{ .argv = argv, .cwd = .{ .path = cwd }, .stdout_limit = limit, .stderr_limit = limit, .timeout = .{ .duration = .{ .raw = .fromSeconds(600), .clock = .awake } } });
    if (successful(result.term)) |_| {} else |err| {
        var buffer: [4096]u8 = undefined;
        var stderr = Io.File.stderr().writerStreaming(io, &buffer);
        try stderr.interface.writeAll(result.stderr);
        try stderr.interface.flush();
        return err;
    }
    return result;
}
fn optional(args: []const []const u8, key: []const u8) ?[]const u8 {
    for (args, 0..) |arg, i| if (std.mem.eql(u8, arg, key) and i + 1 < args.len) return args[i + 1];
    return null;
}
fn option(args: []const []const u8, key: []const u8) ![]const u8 {
    return optional(args, key) orelse error.MissingBenchmarkOption;
}

test "benchmark driver rejects unknown missing duplicate and truncated inputs" {
    try std.testing.expectError(error.UnknownBenchmarkOption, arguments(&.{ "driver", "--typo", "value" }));
    try std.testing.expectError(error.MissingBenchmarkOption, arguments(&.{ "driver", "--base" }));
    try std.testing.expectError(error.DuplicateBenchmarkOption, arguments(&.{ "driver", "--base", "a", "--base", "b" }));
    try std.testing.expectError(error.TruncatedRun, validate(std.testing.allocator, "{}", null));
    try std.testing.expectError(error.InvalidRun, validate(std.testing.allocator, "{}\n", null));
    try std.testing.expectError(error.BenchmarkDriverFailed, successful(.{ .exited = 7 }));
    try std.testing.expectError(error.BenchmarkDriverFailed, successful(.{ .signal = .KILL }));
    var writer = Io.Writer.failing;
    try std.testing.expectError(error.WriteFailed, emit(&writer, "result\n"));
}

fn arguments(args: []const []const u8) !void {
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        const flag = args[i];
        var known = false;
        for ([_][]const u8{ "--zig", "--candidate", "--comparison", "--base", "--program", "--pairs", "--row", "--output" }) |name| if (std.mem.eql(u8, flag, name)) {
            known = true;
        };
        if (!known) return error.UnknownBenchmarkOption;
        if (i + 1 == args.len or std.mem.startsWith(u8, args[i + 1], "--")) return error.MissingBenchmarkOption;
        var previous: usize = 1;
        while (previous < i) : (previous += 2) if (std.mem.eql(u8, args[previous], flag)) return error.DuplicateBenchmarkOption;
    }
}
fn successful(term: std.process.Child.Term) !void {
    if (term != .exited or term.exited != 0) return error.BenchmarkDriverFailed;
}
fn emit(writer: *Io.Writer, bytes: []const u8) !void {
    try writer.writeAll(bytes);
    try writer.flush();
}
