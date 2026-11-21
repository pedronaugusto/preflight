//! glint's answer to a project file, as preflight reads it: the JSON report (version 1, with a
//! project file's additions) and the run's record, which says the report is this run's, whole,
//! and what the run's exit status means. Fields glint adds later are read past: the contract
//! grows additively within a version.
const std = @import("std");

pub const Report = struct {
    version: u32,
    analysis_complete: bool,
    suppressed: usize,
    stale_suppressions: usize,
    stale: []const Stale,
    malformed: []const Malformed,
    diagnostics: []const Diagnostic,
    errors: []const RunError,
    notes: []const []const u8 = &.{},
    fixed: ?Fixed = null,
    metrics: ?Metrics = null,
};
pub const Span = struct { line: u32, column: u32 };
pub const Diagnostic = struct {
    rule: []const u8,
    source: []const u8,
    span: Span,
    message: []const u8,
    /// The verdicts a project file's run gives every diagnostic: absent, the run was not one.
    fails: bool,
    shipped_ban: bool,
    carried: bool,
};
pub const RunError = struct { source: ?[]const u8, why: []const u8 };
pub const Malformed = struct { source: []const u8, line: u32, column: u32, why: []const u8 };
pub const Stale = struct { source: []const u8, rule: []const u8, line: u32, column: u32 };
pub const Fixed = struct { sites: usize, files: usize };
pub const Metrics = struct {
    functions: usize,
    asserted: usize,
    assertions: std.json.ArrayHashMap(usize),
    files: []const FileCounts,

    pub const FileCounts = struct {
        source: []const u8,
        functions: usize,
        asserted: usize,
        assertions: std.json.ArrayHashMap(usize),
    };
};

/// Every assertion call `counts` holds, of whichever kind.
pub fn total(counts: std.json.ArrayHashMap(usize)) usize {
    var sum: usize = 0;
    for (counts.map.values()) |n| sum += n;
    return sum;
}

pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Report {
    const report = try std.json.parseFromSliceLeaky(Report, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    if (report.version != 1) return error.UnsupportedReport;
    return report;
}

/// The record glint writes for a run named by its id (`--result FILE --run-id ID`).
pub const Record = struct {
    version: u32,
    run_id: []const u8,
    completed: bool,
    outcome: []const u8,
    output_bytes: usize,
    output_sha256: []const u8,
};

/// What a run's record and exit status say of it.
pub const Verdict = union(enum) {
    /// The report is the run's own and whole: its findings, none failing (0), some failing (1),
    /// or an analysis glint did not finish (2), which its report says where.
    report: u8,
    /// glint ended without a report: its outcome (an argument or input it refused, a file it
    /// could not write), which glint said on its error output.
    failed: []const u8,
    /// The record and the run disagree, or the record is not this run's: why.
    mismatch: []const u8,
};

/// Reads a run's record against what the run left: its id, its exit status (null where it did
/// not exit of itself) and the output read back.
pub fn verdict(a: std.mem.Allocator, record_bytes: []const u8, run_id: []const u8, status: ?u8, output: []const u8) std.mem.Allocator.Error!Verdict {
    const record = std.json.parseFromSliceLeaky(Record, a, record_bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .mismatch = try a.print("its record is not one glint writes ({t})", .{err}) },
    };
    if (record.version != 1) return .{ .mismatch = try a.print("its record is version {d}, not 1", .{record.version}) };
    if (!std.mem.eql(u8, record.run_id, run_id)) return .{ .mismatch = try a.print("its record is another run's ({s}, not {s})", .{ record.run_id, run_id }) };
    const expected: ?u8 = if (std.mem.eql(u8, record.outcome, "clean")) 0 else if (std.mem.eql(u8, record.outcome, "findings")) 1 else if (std.mem.eql(u8, record.outcome, "analysis_incomplete")) 2 else null;
    const code = expected orelse return if (std.mem.eql(u8, record.outcome, "running"))
        .{ .mismatch = try a.print("its record says it is still running: it ended before it finished (exit status {?d})", .{status}) }
    else
        .{ .failed = record.outcome };
    if (status != code) return .{ .mismatch = try a.print("its record's outcome is {s}, and it exited {?d}, not {d}", .{ record.outcome, status, code }) };
    if (record.completed != (code != 2)) return .{ .mismatch = try a.print("its record's outcome is {s} and says the run {s}", .{ record.outcome, if (record.completed) "completed" else "did not complete" }) };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output, &digest, .{});
    const hex = std.fmt.bytesToHex(&digest, .lower);
    if (record.output_bytes != output.len or !std.mem.eql(u8, record.output_sha256, &hex)) return .{ .mismatch = try a.print("the report read ({d} bytes) is not the one its record names ({d} bytes, SHA-256 {s})", .{ output.len, record.output_bytes, record.output_sha256 }) };
    return .{ .report = code };
}

fn recordFor(a: std.mem.Allocator, run_id: []const u8, outcome: []const u8, completed: bool, output: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output, &digest, .{});
    return std.json.Stringify.valueAlloc(a, .{ .version = 1, .run_id = run_id, .completed = completed, .outcome = outcome, .sources = 1, .findings = 0, .suppressed = 0, .output_bytes = output.len, .output_sha256 = &std.fmt.bytesToHex(&digest, .lower) }, .{});
}

test "a run's record vouches for its report only when it is this run's, finished, its status and its bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const output = "{\"version\":1}\n";
    try std.testing.expectEqual(Verdict{ .report = 0 }, try verdict(a, try recordFor(a, "lint-1", "clean", true, output), "lint-1", 0, output));
    try std.testing.expectEqual(Verdict{ .report = 1 }, try verdict(a, try recordFor(a, "lint-1", "findings", true, output), "lint-1", 1, output));
    try std.testing.expectEqual(Verdict{ .report = 2 }, try verdict(a, try recordFor(a, "lint-1", "analysis_incomplete", false, output), "lint-1", 2, output));
    try std.testing.expectEqualStrings("argument_failure", (try verdict(a, try recordFor(a, "lint-1", "argument_failure", false, ""), "lint-1", 2, "")).failed);
    for ([_]Verdict{
        // Another run's record, one left by a run that never finished, and a status the record denies.
        try verdict(a, try recordFor(a, "lint-0", "clean", true, output), "lint-1", 0, output),
        try verdict(a, try recordFor(a, "lint-1", "running", false, ""), "lint-1", null, output),
        try verdict(a, try recordFor(a, "lint-1", "clean", true, output), "lint-1", 1, output),
        try verdict(a, try recordFor(a, "lint-1", "findings", true, output), "lint-1", null, output),
        try verdict(a, try recordFor(a, "lint-1", "analysis_incomplete", true, output), "lint-1", 2, output),
        // A report cut short, or another one's bytes.
        try verdict(a, try recordFor(a, "lint-1", "clean", true, output), "lint-1", 0, output[0..5]),
        try verdict(a, try recordFor(a, "lint-1", "clean", true, "{\"version\":2}\n"), "lint-1", 0, output),
        try verdict(a, "{\"version\":1", "lint-1", 0, output),
        try verdict(a, "{\"version\":2,\"run_id\":\"lint-1\",\"completed\":true,\"outcome\":\"clean\",\"output_bytes\":0,\"output_sha256\":\"\"}", "lint-1", 0, output),
    }) |answer| try std.testing.expect(answer == .mismatch);
}

test "a report is read past the fields it does not name, and its verdicts are required" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\{"version":1,"analysis_complete":true,"suppressed":2,"stale_suppressions":0,"stale":[],"malformed":[],
        \\"diagnostics":[{"rule":"P007","rule_version":1,"class":"danger","severity":"error","source":"src/a.zig","span":{"file":0,"start":3,"end":9,"line":2,"column":12},"level":"report","message":"m","bug_class":"b","related":[],"fails":true,"shipped_ban":true,"carried":false}],
        \\"errors":[],"seams":[],"test_inputs":[],"notes":["Z026 is set to report"],"fixed":{"sites":1,"files":1},
        \\"metrics":{"functions":3,"asserted":1,"assertions":{"std":1,"own":0},"files":[{"source":"src/a.zig","functions":3,"asserted":1,"assertions":{"std":1,"own":0}}]}}
    ;
    const report = try parse(a, text);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try std.testing.expect(report.diagnostics[0].fails and report.diagnostics[0].shipped_ban);
    try std.testing.expectEqual(@as(u32, 12), report.diagnostics[0].span.column);
    try std.testing.expectEqualStrings("Z026 is set to report", report.notes[0]);
    try std.testing.expectEqual(@as(usize, 1), total(report.metrics.?.assertions));
    // A run that gave no verdicts was not a project file's, and is no answer to one.
    try std.testing.expectError(error.MissingField, parse(a, "{\"version\":1,\"analysis_complete\":true,\"suppressed\":0,\"stale_suppressions\":0,\"stale\":[],\"malformed\":[],\"diagnostics\":[{\"rule\":\"P007\",\"source\":\"a\",\"span\":{\"line\":1,\"column\":1},\"message\":\"m\"}],\"errors\":[]}"));
    try std.testing.expectError(error.UnsupportedReport, parse(a, "{\"version\":2,\"analysis_complete\":true,\"suppressed\":0,\"stale_suppressions\":0,\"stale\":[],\"malformed\":[],\"diagnostics\":[],\"errors\":[]}"));
}
