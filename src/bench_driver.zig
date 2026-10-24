//! Interleaved A/B process orchestration; no timers or statistical algorithms.
const std = @import("std");
const builtin = @import("builtin");
const ensign = @import("ensign");
const bench = @import("shakedown").bench;
const Io = std.Io;
const limit: Io.Limit = .limited(64 * 1024 * 1024);

/// `zig build bench-ab -- …`: the build gives `--zig`, `--bay`, `--candidate` and
/// `--comparison`; the rest are the caller's.
pub const Arguments = struct {
    zig: []const u8,
    bay: ?[]const u8 = null,
    candidate: []const u8,
    comparison: []const u8,
    base: []const u8,
    program: []const u8,
    pairs: u8 = 5,
    row: []const u8 = "",
    output: ?[]const u8 = null,

    pub const spec: ensign.Spec(@This()) = .{
        .name = "bench-ab",
        .about = "Interleave a benchmark program built at an immutable base and at the clean candidate, and compare them through shakedown",
        .options = .{
            .zig = .{ .value_name = "PATH", .hint = .command, .help = "The Zig that builds both revisions (the build's)" },
            .bay = .{ .value_name = "PATH", .hint = .command, .help = "The bay that builds both revisions, when the package is built under bay (the build's)" },
            .candidate = .{ .value_name = "DIR", .hint = .directory, .help = "The package's checkout, which must be clean (the build's)" },
            .comparison = .{ .value_name = "PATH", .hint = .file, .help = "shakedown's comparison program (the build's)" },
            .base = .{ .value_name = "COMMIT", .help = "The revision to compare against" },
            .program = .{ .value_name = "NAME", .help = "The benchmark program, as zig-out/bench names it" },
            .pairs = .{ .value_name = "N", .help = "How many base and candidate runs, in alternating order; 1 to 100" },
            .row = .{ .value_name = "PREFIX", .help = "Only the rows whose names start with this" },
            .output = .{ .value_name = "DIR", .hint = .directory, .help = "Also keep each pair's rows and comparison here" },
        },
    };
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    // Help and mistakes are answered here, and the program exits.
    const args = ensign.parseOrExit(Arguments, init);
    const zig = args.zig;
    const candidate = try Io.Dir.cwd().realPathFileAlloc(init.io, args.candidate, a);
    const comparison = try Io.Dir.cwd().realPathFileAlloc(init.io, args.comparison, a);
    const status = try command(a, init.io, candidate, &.{ "git", "status", "--porcelain", "--untracked-files=normal" });
    if (status.stdout.len != 0) return error.DirtyCandidate;
    const candidate_revision = try command(a, init.io, candidate, &.{ "git", "rev-parse", "HEAD" });
    const candidate_sha = std.mem.trim(u8, candidate_revision.stdout, "\r\n");
    const base = args.base;
    const program = args.program;
    if (program.len == 0 or std.mem.findAny(u8, program, "/\\") != null) return error.InvalidProgram;
    const pairs = args.pairs;
    if (pairs == 0 or pairs > 100) return error.InvalidPairs;
    const prefix = args.row;
    const sha_result = try command(a, init.io, candidate, &.{ "git", "rev-parse", "--verify", "--end-of-options", try a.print("{s}^{{commit}}", .{base}) });
    const sha = std.mem.trim(u8, sha_result.stdout, "\r\n");
    if (sha.len != 40) return error.InvalidBaseCommit;
    var random: [8]u8 = undefined;
    init.io.random(&random);
    const scratch = try a.print(".zig-cache/preflight-ab/{s}-{x}", .{ sha, random });
    try Io.Dir.cwd().createDirPath(init.io, scratch);
    const absolute = try Io.Dir.cwd().realPathFileAlloc(init.io, scratch, a);
    // glint-ignore: Z026 -- scratch removal is best effort after the run; a leftover directory is in the cache
    defer Io.Dir.cwd().deleteTree(init.io, scratch) catch {};
    const checkout = try Io.Dir.path.join(a, &.{ absolute, "base" });
    _ = try command(a, init.io, candidate, &.{ "git", "clone", "--shared", "--no-checkout", "--", candidate, checkout });
    _ = try command(a, init.io, checkout, &.{ "git", "checkout", "--detach", sha });
    // Each revision configures itself. No guessed executable or graph reconstruction.
    // Under bay, `bay bench-build` finds the step in whichever build each revision has it.
    const build: []const []const u8 = if (args.bay) |bay| &.{ bay, "bench-build" } else &.{ zig, "build", "bench-build" };
    _ = try command(a, init.io, checkout, build);
    _ = try command(a, init.io, candidate, build);
    const suffix = if (builtin.target.os.tag == .windows) ".exe" else "";
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
        if (args.output) |destination| {
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
fn read(args: []const []const u8) ensign.Error!Arguments {
    const outcome = try ensign.parse(Arguments, std.testing.allocator, args, .{});
    return outcome.parsed;
}

test "benchmark driver reads its arguments and rejects unknown, missing and truncated inputs" {
    const given = try read(&.{ "--zig", "zig", "--candidate", ".", "--comparison", "compare", "--base", "HEAD~1", "--program", "workflow", "--pairs", "3", "--row", "caller " });
    try std.testing.expectEqualStrings("HEAD~1", given.base);
    try std.testing.expectEqual(@as(u8, 3), given.pairs);
    try std.testing.expectEqualStrings("caller ", given.row);
    try std.testing.expectEqual(@as(?[]const u8, null), given.bay);
    try std.testing.expectError(error.UnknownOption, read(&.{"--typo"}));
    try std.testing.expectError(error.MissingOption, read(&.{ "--zig", "zig", "--candidate", ".", "--comparison", "compare", "--program", "workflow" }));
    try std.testing.expectError(error.MissingValue, read(&.{ "--zig", "zig", "--base" }));
    try std.testing.expectError(error.InvalidValue, read(&.{ "--zig", "zig", "--candidate", ".", "--comparison", "compare", "--base", "b", "--program", "p", "--pairs", "many" }));
    try std.testing.expectError(error.TruncatedRun, validate(std.testing.allocator, "{}", null));
    try std.testing.expectError(error.InvalidRun, validate(std.testing.allocator, "{}\n", null));
    try std.testing.expectError(error.BenchmarkDriverFailed, successful(.{ .exited = 7 }));
    try std.testing.expectError(error.BenchmarkDriverFailed, successful(.{ .signal = .KILL }));
    var writer = Io.Writer.failing;
    try std.testing.expectError(error.WriteFailed, emit(&writer, "result\n"));
}

fn successful(term: std.process.Child.Term) !void {
    if (term != .exited or term.exited != 0) return error.BenchmarkDriverFailed;
}
fn emit(writer: *Io.Writer, bytes: []const u8) !void {
    try writer.writeAll(bytes);
    try writer.flush();
}
