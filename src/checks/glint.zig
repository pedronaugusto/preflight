//! The code rules are glint's. This is the linter that runs them for a
//! repository: the default policy, amended, over the repository's files, in one
//! project glint holds in memory, so that nothing stands between a finding
//! and the gate, and a run that did not finish is not a run that passed.
const std = @import("std");
const glint = @import("glint");
const src = @import("source.zig");
pub const policy = @import("glint/policy.zig");
pub const assembly = @import("glint/assembly.zig");

test {
    _ = policy;
    _ = assembly;
}

pub const Inputs = struct {
    gpa: std.mem.Allocator,
    /// `ci/preflight.json`.
    config: src.Value,
    build: assembly.Build = .{},
};

/// How many lines of one kind a run prints before it counts the rest.
const printed = 25;

/// Fails the run on a finding the policy gates and on any analysis glint
/// did not finish: a file it could not parse or lower, work it ran out of
/// budget for, a site a gating rule could not decide, a suppression that
/// suppresses nothing.
pub fn check(c: *src.Context, inputs: Inputs) !void {
    const chosen = (try policy.parse(c, inputs.config)) orelse return;
    const paths = (try assembly.select(c, chosen, inputs.config)) orelse return;
    var assembled = (try assembly.assemble(c, inputs.gpa, chosen, paths, inputs.build)) orelse return;
    defer assembled.deinit();
    var files: std.ArrayList(glint.FileConfig) = .empty;
    for (assembled.selected, 0..) |file, index| {
        try files.append(c.a, .{ .file = .fromRaw(@intCast(index)), .config = try chosen.forFile(c.a, file.path) });
    }
    var report = glint.runConfigured(inputs.gpa, &assembled.project, chosen.base, .{
        .project_rules = &policy.project_rules,
        .files = files.items,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            c.fail("glint: the run did not finish ({t})", .{err});
            return;
        },
    };
    defer report.deinit();
    judge(c, chosen, &assembled.project, &report);
}

fn judge(c: *src.Context, chosen: policy.Policy, project: *const glint.Project, report: *const glint.Report) void {
    var failing: usize = 0;
    var warned: usize = 0;
    var shown: std.AutoHashMapUnmanaged(glint.Rule, usize) = .empty;
    for (report.diagnostics) |d| {
        const file = project.inputs[d.span.file.raw()].name;
        const fails = d.level == .gate or chosen.fails(d.rule);
        const seen = shown.getOrPutValue(c.a, d.rule, 0) catch null;
        if (seen) |count| {
            count.value_ptr.* += 1;
            if (count.value_ptr.* == printed + 1) c.report("glint: more {s} follow\n", .{d.name});
        }
        const quiet = if (seen) |count| count.value_ptr.* > printed else false;
        if (fails) {
            if (quiet) c.errors += 1 else c.fail("{s}: {s}:{d}:{d}: {s}", .{ d.name, file, d.span.line, d.span.column, d.message });
            failing += 1;
        } else {
            if (!quiet) {
                c.report("glint: {s}: {s}:{d}:{d}: {s}\n", .{ d.name, file, d.span.line, d.span.column, d.message });
                c.notes += 1;
            }
            warned += 1;
        }
    }

    var unfinished: usize = 0;
    var unresolved: usize = 0;
    for (report.coverage) |note| {
        const file = project.inputs[note.file.raw()].name;
        const gating = if (note.rule) |rule| chosen.base.level(rule) == .gate else false;
        const stops = switch (note.reason) {
            .parsed, .unsupported => false,
            .invalid_syntax, .invalid_lowering, .budget_exhausted => true,
            .unresolved => gating,
        };
        if (stops or (gating and note.reason != .parsed)) {
            if (unfinished < printed) c.report("glint: incomplete: {s}:{d}: {s}{s}{s}: {s}\n", .{ file, lineAt(project.inputs[note.file.raw()].bytes, note.start), note.rule_name, if (note.rule_name.len != 0) " " else "", @tagName(note.reason), note.detail });
            unfinished += 1;
        } else if (note.reason == .unresolved) unresolved += 1;
    }
    if (unfinished > printed) c.report("glint: {d} more incomplete sites\n", .{unfinished - printed});
    if (!report.complete) {
        c.fail("glint: the analysis is incomplete ({d} sites or files undecided, {d} suppressions that suppress nothing); an incomplete run is not a pass", .{ unfinished, report.stale_suppressions });
    }
    c.report("preflight: glint: {d} files, {d} findings fail, {d} reported, {d} suppressed, {d} sites unresolved\n", .{ project.inputs.len, failing, warned, report.suppressed, unresolved });
}

/// The one-based line of a byte offset.
fn lineAt(bytes: []const u8, offset: u32) usize {
    return 1 + std.mem.count(u8, bytes[0..@min(offset, bytes.len)], "\n");
}

fn parsed(a: std.mem.Allocator, text: []const u8) !src.Value {
    return (try std.json.parseFromSlice(src.Value, a, text, .{ .allocate = .alloc_always })).value;
}

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    c: src.Context,

    fn init() !*Fixture {
        const self = try std.testing.allocator.create(Fixture);
        self.arena = .init(std.testing.allocator);
        self.tmp = std.testing.tmpDir(.{});
        self.c = .{ .a = self.arena.allocator(), .io = std.testing.io, .dir = self.tmp.dir };
        return self;
    }
    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        self.arena.deinit();
        std.testing.allocator.destroy(self);
    }
    fn file(self: *Fixture, path: []const u8, text: []const u8) !void {
        if (std.Io.Dir.path.dirname(path)) |parent| try self.tmp.dir.createDirPath(self.c.io, parent);
        try self.tmp.dir.writeFile(self.c.io, .{ .sub_path = path, .data = text });
    }
    /// Runs the check on the files written so far; the errors it counted.
    fn run(self: *Fixture, config: []const u8, build: assembly.Build) !usize {
        self.c.errors = 0;
        try check(&self.c, .{ .gpa = std.testing.allocator, .config = try parsed(self.c.a, config), .build = build });
        return self.c.errors;
    }
};

test "a clean repository passes and one finding of the policy's gate fails it" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.file("src/root.zig", "pub fn answer() u32 {\n    return 42;\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"]}", .{}));
    // An unreachable catch carries its invariant.
    try f.file("src/root.zig", "pub fn run(f: anytype) void {\n    f() catch unreachable;\n}\n");
    try std.testing.expect(try f.run("{\"glint_paths\":[\"src\"]}", .{}) != 0);
    try f.file("src/root.zig", "pub fn run(f: anytype) void {\n    f() catch unreachable; // unreachable: f has no error path\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"]}", .{}));
    // A discarded error is reported until a repository gates it, then carries its reason at the site.
    try f.file("src/root.zig", "pub fn drop(f: anytype) void {\n    f() catch {};\n}\n");
    const gated = "{\"glint_paths\":[\"src\"],\"glint\":{\"rules\":[{\"id\":\"Z026\",\"level\":\"gate\"}]}}";
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"]}", .{}));
    try std.testing.expect(try f.run(gated, .{}) != 0);
    try f.file("src/root.zig", "pub fn drop(f: anytype) void {\n    // glint-ignore: Z026 -- cleanup after a failure the caller already gets\n    f() catch {};\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run(gated, .{}));
}

test "style is reported and does not fail; a repository may gate it" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.file("src/root.zig", "pub const BadName = 1;\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"]}", .{}));
    try std.testing.expect(try f.run("{\"glint_paths\":[\"src\"],\"glint\":{\"rules\":[{\"id\":\"Z006\",\"level\":\"gate\"}]}}", .{}) != 0);
}

test "casts need their reason in production, not in tests, and in test support as in production" {
    const f = try Fixture.init();
    defer f.deinit();
    const cast = "pub fn view(p: *u8) *u32 {\n    return @ptrCast(p);\n}\n";
    try f.file("src/root.zig", cast);
    try std.testing.expect(try f.run("{\"glint_paths\":[\"src\"]}", .{}) != 0);
    try f.file("src/root.zig", "pub fn view(p: *u8) *u32 {\n    return @ptrCast(@alignCast(p)); // safe: p points at a u32\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"]}", .{}));
    try f.file("src/root.zig", "pub const x = 1;\n");
    try f.file("src/root_test.zig", cast);
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"]}", .{}));
    try f.file("src/testing/harness.zig", cast);
    try std.testing.expect(try f.run("{\"glint_paths\":[\"src\"]}", .{}) != 0);
    try f.file("src/root_test.zig", "pub const t = 1;\n");
    try f.file("src/testing/harness.zig", "pub const h = 1;\n");
    try f.file("src/tls.zig", cast);
    try std.testing.expect(try f.run("{\"glint_paths\":[\"src\"]}", .{}) != 0);
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"],\"vendored\":{\"src/tls.zig\":\"std's client, verified byte for byte by check-tls\"}}", .{}));
}

test "function length: the limit, a per-path ceiling and a reasoned exception that cannot grow or go stale" {
    const f = try Fixture.init();
    defer f.deinit();
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(f.c.a, "pub fn long() void {\n");
    for (0..30) |_| try body.appendSlice(f.c.a, "    _ = 1;\n");
    try body.appendSlice(f.c.a, "}\n");
    try f.file("src/root.zig", body.items);
    const paths = "\"glint_paths\":[\"src\"]";
    try std.testing.expectEqual(@as(usize, 0), try f.run("{" ++ paths ++ "}", .{}));
    try std.testing.expect(try f.run("{" ++ paths ++ ",\"function_limit\":20}", .{}) != 0);
    try std.testing.expect(try f.run("{" ++ paths ++ ",\"function_limits\":{\"src/**\":20}}", .{}) != 0);
    try std.testing.expectEqual(@as(usize, 0), try f.run("{" ++ paths ++ ",\"function_limit\":20,\"function_limits\":{\"bench/**\":10},\"function_exceptions\":{\"src/root.zig:long\":{\"lines\":32,\"reason\":\"a table\"}}}", .{}));
    // Grown past its ceiling.
    try std.testing.expect(try f.run("{" ++ paths ++ ",\"function_limit\":20,\"function_exceptions\":{\"src/root.zig:long\":{\"lines\":31,\"reason\":\"a table\"}}}", .{}) != 0);
    // Named for a function that is gone: the exception is stale, and a stale one is not a pass.
    try std.testing.expect(try f.run("{" ++ paths ++ ",\"function_exceptions\":{\"src/root.zig:gone\":{\"lines\":200,\"reason\":\"a table\"}}}", .{}) != 0);
}

test "a debug print and a deprecated call are findings the standard library's declarations decide" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.file("stdlib/std.zig", "pub const debug = @import(\"debug.zig\");\npub const mem = @import(\"mem.zig\");\n");
    try f.file("stdlib/debug.zig", "pub fn print(comptime fmt: []const u8, args: anytype) void {\n    _ = fmt;\n    _ = args;\n}\n");
    try f.file("stdlib/mem.zig", "/// Deprecated: use `find`.\npub fn indexOf(haystack: []const u8, needle: u8) ?usize {\n    _ = haystack;\n    _ = needle;\n    return null;\n}\npub fn find(haystack: []const u8, needle: u8) ?usize {\n    _ = haystack;\n    _ = needle;\n    return null;\n}\n");
    const build: assembly.Build = .{ .std_dir = "stdlib" };
    const paths = "\"glint_paths\":[\"src\"]";
    try f.file("src/root.zig", "const std = @import(\"std\");\npub fn run() void {\n    std.debug.print(\"hi\", .{});\n}\n");
    try std.testing.expect(try f.run("{" ++ paths ++ "}", build) != 0);
    // The same code without the standard library's declarations is unresolved, not a finding.
    try std.testing.expectEqual(@as(usize, 0), try f.run("{" ++ paths ++ "}", .{}));
    try std.testing.expectEqual(@as(usize, 0), try f.run("{" ++ paths ++ ",\"glint\":{\"rules\":[{\"id\":\"P005\",\"level\":\"off\"}]}}", build));
    try f.file("src/root.zig", "const std = @import(\"std\");\npub fn run() void {\n    std.debug.print(\"hi\", .{}); // glint-ignore: P005 -- the tool's one line of output\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run("{" ++ paths ++ "}", build));
    try f.file("src/root.zig", "const std = @import(\"std\");\npub fn run(text: []const u8) ?usize {\n    return std.mem.indexOf(text, 'x');\n}\n");
    try std.testing.expect(try f.run("{" ++ paths ++ "}", build) != 0);
    try f.file("src/root_test.zig", "const std = @import(\"std\");\ntest {\n    std.debug.print(\"in a test\", .{});\n}\n");
    try f.file("src/root.zig", "pub const x = 1;\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run("{" ++ paths ++ "}", build));
}

test "an analysis glint did not finish is never a pass, whatever its findings" {
    const f = try Fixture.init();
    defer f.deinit();
    const paths = "\"glint_paths\":[\"src\"]";
    // Source Zig's parser rejects.
    try f.file("src/root.zig", "pub fn broken( {\n");
    try std.testing.expect(try f.run("{" ++ paths ++ "}", .{}) != 0);
    // Source its lowering rejects.
    try f.file("src/root.zig", "pub fn twice() void {\n    const a = 1;\n    const a = 2;\n    _ = a;\n}\n");
    try std.testing.expect(try f.run("{" ++ paths ++ "}", .{}) != 0);
    // Work it ran out of budget for.
    try f.file("src/root.zig", "const std = @import(\"std\");\npub fn run() void {\n    _ = std.mem;\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run("{" ++ paths ++ "}", .{}));
    try std.testing.expect(try f.run("{" ++ paths ++ ",\"glint\":{\"fact_budget\":1}}", .{}) != 0);
    // A suppression that suppresses nothing.
    try f.file("src/root.zig", "// glint-ignore: Z026 -- there is no empty catch here\npub const x = 1;\n");
    try std.testing.expect(try f.run("{" ++ paths ++ "}", .{}) != 0);
    try std.testing.expectEqual(@as(usize, 0), try f.run("{" ++ paths ++ ",\"glint\":{\"strict_suppressions\":false}}", .{}));
    // A finding allowed by amendment does not hide what else is wrong.
    try f.file("src/root.zig", "pub fn drop(f: anytype) void {\n    f() catch {};\n}\npub fn broken( {\n");
    try std.testing.expect(try f.run("{" ++ paths ++ ",\"glint\":{\"rules\":[{\"id\":\"Z026\",\"level\":\"off\"}]}}", .{}) != 0);
}

test "a file that cannot be read fails the run with the cause, never a pass" {
    const FaultIo = @import("shakedown").FaultIo;
    const f = try Fixture.init();
    defer f.deinit();
    try f.file("src/root.zig", "pub const x = 1;\n");
    for ([_]anyerror{ error.AccessDenied, error.Canceled }) |failure| {
        const faults = try FaultIo.init(std.testing.allocator, std.testing.io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .dirOpenFile, .n = 1 } }, .fault = .{ .fail = failure } }} });
        defer faults.deinit();
        f.c.io = faults.io();
        f.c.errors = 0;
        const result = check(&f.c, .{ .gpa = std.testing.allocator, .config = try parsed(f.c.a, "{\"glint_paths\":[\"src\"]}") });
        try std.testing.expectError(failure, result);
        try std.testing.expectEqual(@as(u64, 1), faults.count(.dirOpenFile));
    }
    f.c.io = std.testing.io;
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"]}", .{}));
}
