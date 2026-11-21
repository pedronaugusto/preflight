//! The code rules are glint's, and glint is a program the lint runs (its program contract,
//! version 1): preflight writes a project file (the build's modules, the files it selects with
//! what each is, the policy as data), runs glint over it, and reads glint's report back with the
//! run's record, which vouches that the report is this run's and whole. Nothing stands between a
//! finding and the gate, and a run that did not finish is not a run that passed.
const std = @import("std");
const src = @import("source.zig");
const seam = @import("input.zig");
const fetched = @import("manifest.zig");
pub const policy = @import("glint/policy.zig");
pub const assembly = @import("glint/assembly.zig");
pub const project = @import("glint/project.zig");
pub const report = @import("glint/report.zig");

test {
    _ = policy;
    _ = assembly;
    _ = project;
    _ = report;
}

pub const Inputs = struct {
    gpa: std.mem.Allocator,
    /// `ci/preflight.json`.
    config: src.Value,
    build: assembly.Build = .{},
    /// The modules the package exports, by the name a consumer imports each by.
    exported: []const project.Exported = &.{},
    /// The glint program the lint runs: the one preflight's toolchain builds, or the build's own.
    glint: []const u8,
    /// Apply the findings' fixes to the package's sources (`zig build fix`).
    fix: bool = false,
    /// With `fix`, the escapes a lint before reported, by which an escape in the older form is
    /// named (`zig build fix -- --escapes-before FILE`): glint's migration aid.
    escapes_before: ?[]const u8 = null,
    /// The release tier's bar: every shipped ban's finding fails, the reported ones too,
    /// which the default policy only reports while a landing reads them.
    release: bool = false,
};

/// How many lines of one kind a run prints before it counts the rest.
const printed = 25;

/// Where the lint keeps what it hands glint and what glint answers, relative to the package.
const lint_dir = ".zig-cache/preflight-lint";
const project_path = lint_dir ++ "/project.json";
const report_path = lint_dir ++ "/report.json";
const record_path = lint_dir ++ "/result.json";

/// Fails the run on a finding glint's verdict fails and on any analysis glint did not finish: a
/// file it could not parse or lower, work it ran out of budget for, a suppression that
/// suppresses nothing; and on a glint that cannot read this project file, or whose report its
/// record does not vouch for.
pub fn check(c: *src.Context, inputs: Inputs) !void {
    const shipped = fetched.shippedPaths(c) catch |err| switch (err) {
        error.InvalidManifest => return,
        error.FileNotFound => {
            c.fail("build.zig.zon: not found: what it ships is the danger rules' scope", .{});
            return;
        },
        else => return err,
    };
    const chosen = (try policy.parse(c, inputs.config, shipped)) orelse return;
    const paths = (try assembly.select(c, chosen)) orelse return;
    const before = c.errors;
    const kept = try upstreamCopies(c, chosen);
    if (c.errors != before) return;
    const file = try projectFile(c, inputs, chosen, paths, kept);
    if (!try contract(c, inputs.glint)) return;
    const answer = (try runGlint(c, inputs, file)) orelse return;
    if (answer.fixed) |fixed| c.report("preflight: glint: fixed {d} sites in {d} files; what follows is the run before them\n", .{ fixed.sites, fixed.files });
    for (answer.notes) |note| {
        c.report("glint: note: {s}\n", .{note});
        c.notes += 1;
    }
    judge(c, kept, answer, paths.len);
    assertions(c, answer);
}

/// The project file for the files `paths` selects, each with what it is: a test, test support or
/// production code; whether it ships; its function budget and reasoned ceilings; the upstream
/// whose verification it carries while it is that copy (`kept`).
fn projectFile(c: *src.Context, inputs: Inputs, chosen: policy.Policy, paths: []const []const u8, kept: []const policy.Vendored) !project.ProjectFile {
    const a = c.a;
    const files = try a.alloc(project.File, paths.len);
    for (files, paths) |*entry, path| {
        const vendored = for (kept) |copy| {
            if (std.mem.eql(u8, copy.path, path)) break project.Vendored{ .upstream = copy.upstream, .verification = copy.verification };
        } else null;
        entry.* = .{
            .path = path,
            .kind = switch (chosen.kind(path)) {
                .production => .production,
                .test_file => .@"test",
                .support => .support,
            },
            .ships = chosen.ships(path),
            .max_function_lines = chosen.functionLines(path),
            .function_exceptions = try chosen.exceptionsAt(a, path),
            .vendored = vendored,
        };
    }
    const modules = try a.alloc(project.Module, inputs.build.modules.len);
    for (modules, inputs.build.modules) |*module, built| {
        const imports = try a.alloc(project.Binding, built.imports.len);
        for (imports, built.imports) |*binding, import| binding.* = .{ .name = import.name, .module = import.module };
        module.* = .{ .root = built.root, .contents = built.contents, .script = built.script, .imports = imports };
    }
    // glint's options have one home, the repository's glint.json, which a glint run without
    // preflight reads too; glint reads it where the package has one.
    const options: ?[]const u8 = if (c.directory().access(c.io, "glint.json", .{})) |_| "glint.json" else |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    return .{
        .zig_lib = if (inputs.build.std_dir) |dir| std.Io.Dir.path.dirname(dir) else null,
        .release = inputs.release,
        .modules = modules,
        .exported = inputs.exported,
        .files = files,
        .policy = chosen.data(options),
    };
}

/// Whether `glint` reads the project file this preflight writes (`glint --contract` lists its
/// version); one that does not fails the run by name.
fn contract(c: *src.Context, glint: []const u8) !bool {
    const listed = seam.run(c.a, c.io, .{ .argv = &.{ glint, "--contract" }, .cwd = c.childCwd(), .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(60) } } }, .line) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            c.fail("glint: {s} did not run ({t})", .{ glint, err });
            return false;
        },
    };
    const line = std.mem.trim(u8, listed.stdout, " \r\n");
    if (listed.term == .exited and listed.term.exited == 0) if (std.mem.cutPrefix(u8, line, "glint-contract ")) |versions| {
        var each = std.mem.tokenizeScalar(u8, versions, ' ');
        while (each.next()) |text| if ((std.fmt.parseInt(u32, text, 10) catch continue) == project.version) return true;
    };
    c.fail("glint: {s} reads no project file of version {d}, the one this preflight writes (`glint --contract` said `{s}`): a glint older than 0.9.0, or another contract's", .{ glint, project.version, line });
    return false;
}

/// Runs glint over `file`: its report, once its record vouches for it; null where the run failed,
/// named.
fn runGlint(c: *src.Context, inputs: Inputs, file: project.ProjectFile) !?report.Report {
    const a = c.a;
    const dir = c.directory();
    try dir.createDirPath(c.io, lint_dir);
    try dir.writeFile(c.io, .{ .sub_path = project_path, .data = try project.text(a, file) });
    // A record a run before left is no record of this one; the id says which run wrote it.
    dir.deleteFile(c.io, record_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var id: [8]u8 = undefined;
    c.io.random(&id);
    const run_id = try a.print("lint-{x}", .{&id});
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ inputs.glint, "--project", project_path, "--format", "json", "--result", record_path, "--run-id", run_id });
    if (inputs.fix) try argv.append(a, "--fix");
    if (inputs.escapes_before) |path| try argv.appendSlice(a, &.{ "--escapes-before", try std.Io.Dir.cwd().realPathFileAlloc(c.io, path, a) });
    const status = status: {
        const out = try dir.createFile(c.io, report_path, .{});
        defer out.close(c.io);
        break :status try c.runStatus(.{ .name = "glint", .argv = argv.items, .cwd = c.childCwd(), .environ_map = c.environ_map, .stdout = out });
    };
    const output = try seam.document(c.io, dir, report_path, a, .report);
    const record = seam.document(c.io, dir, record_path, a, .list) catch |err| switch (err) {
        error.FileNotFound => {
            c.fail("glint: the run left no record ({s}), exit status {?d}: it ended before it began, and its report is no answer", .{ record_path, status });
            return null;
        },
        else => return err,
    };
    switch (try report.verdict(a, record, run_id, status, output)) {
        .report => {},
        .failed => |outcome| {
            c.fail("glint: the run ended with {s}, which glint says above: no report", .{outcome});
            return null;
        },
        .mismatch => |why| {
            c.fail("glint: the run's report is not vouched for: {s}", .{why});
            return null;
        },
    }
    return report.parse(a, output) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            c.fail("glint: {s}: not a report this preflight reads ({t})", .{ report_path, err });
            return null;
        },
    };
}

/// glint's assertion counts, each call by the declaration it resolves to (std's `debug.assert`,
/// and what a package names in its place), never by its spelling: a report, never a gate, since a
/// count says nothing of what an assertion checks. In a hosted job the per-file table goes to its
/// summary.
fn assertions(c: *src.Context, answer: report.Report) void {
    const metrics = answer.metrics orelse return;
    c.report("preflight: assertions: {d} in {d} functions, {d} of them with one\n", .{ report.total(metrics.assertions), metrics.functions, metrics.asserted });
    const path = c.summary_path orelse return;
    var text: std.Io.Writer.Allocating = .init(c.a);
    text.writer.writeAll("\nAssertions (report only)\n\n| File | Functions | With one | Assertions |\n|---|---:|---:|---:|\n") catch @panic("OOM");
    for (metrics.files) |file| {
        if (file.functions == 0) continue;
        text.writer.print("| `{s}` | {d} | {d} | {d} |\n", .{ file.source, file.functions, file.asserted, report.total(file.assertions) }) catch @panic("OOM");
    }
    // The summary is a copy for the hosted job: one not written leaves the line printed above.
    appendTo(c.*, c.directory(), path, text.written()) catch |err| c.report("preflight: assertions: the job's summary {s} was not written ({t})\n", .{ path, err });
}

/// Prints and counts what `answer` says of the `selected` files: each finding by glint's verdict,
/// the first `printed` of a rule, every one in the cache's list; each incomplete site likewise.
fn judge(c: *src.Context, kept: []const policy.Vendored, answer: report.Report, selected: usize) void {
    var failing: usize = 0;
    var warned: usize = 0;
    // How many of each rule's findings the run has met, for the first `printed` it prints.
    var shown: std.array_hash_map.String(usize) = .empty;
    // Each shipped ban's findings, for the line a sizing or a review reads.
    var bans: std.array_hash_map.String(usize) = .empty;
    for (shipped_order) |rule| bans.put(c.a, rule, 0) catch @panic("OOM");
    // Every finding, where the run prints the first `printed` of a rule.
    var all: std.Io.Writer.Allocating = .init(c.a);
    var held = false;
    const carried = c.a.alloc(usize, kept.len) catch @panic("OOM");
    @memset(carried, 0);
    for (answer.diagnostics) |d| {
        all.writer.print("{s}: {s}:{d}:{d}: {s}", .{ d.rule, d.source, d.span.line, d.span.column, d.message }) catch @panic("OOM");
        // A danger site of an upstream's unchanged file carries the upstream's verification.
        if (d.carried) if (for (kept, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.path, d.source)) break i;
        } else null) |at| {
            all.writer.print(" (vendored: carried by {s}'s verification)\n", .{kept[at].upstream}) catch @panic("OOM");
            carried[at] += 1;
            continue;
        };
        all.writer.writeByte('\n') catch @panic("OOM");
        if (d.shipped_ban) (bans.getOrPutValue(c.a, d.rule, 0) catch @panic("OOM")).value_ptr.* += 1;
        const count = shown.getOrPutValue(c.a, d.rule, 0) catch @panic("OOM");
        count.value_ptr.* += 1;
        if (count.value_ptr.* == printed + 1) c.report("glint: more {s} follow\n", .{d.rule});
        const quiet = count.value_ptr.* > printed;
        held = held or quiet;
        if (d.fails) {
            if (quiet) c.errors += 1 else c.fail("{s}: {s}:{d}:{d}: {s}", .{ d.rule, d.source, d.span.line, d.span.column, d.message });
            failing += 1;
        } else {
            if (!quiet) {
                c.report("glint: {s}: {s}:{d}:{d}: {s}\n", .{ d.rule, d.source, d.span.line, d.span.column, d.message });
                c.notes += 1;
            }
            warned += 1;
        }
    }

    for (kept, carried) |entry, count| c.report("preflight: vendored: {s}: {d} danger sites, their reason {s}'s verification: {s}\n", .{ entry.path, count, entry.upstream, entry.verification });
    // Every list is the run's own, written whether or not the run prints all of it: a list
    // an earlier run left would read as this run's.
    const findings_at = writeList(c, findings_path, all.written());
    if (held) c.report("glint: every finding: {s}\n", .{findings_at});

    var unfinished: usize = 0;
    // Every run error, where the run prints the first `printed`: glint's output is findings,
    // reports and run errors, and a run error stops the run.
    var sites: std.Io.Writer.Allocating = .init(c.a);
    for (answer.errors) |run_error| {
        const start = sites.written().len;
        if (run_error.source) |file| {
            sites.writer.print("glint: error: {s}: {s}\n", .{ file, run_error.why }) catch @panic("OOM");
        } else sites.writer.print("glint: error: {s}\n", .{run_error.why}) catch @panic("OOM");
        if (unfinished < printed) c.report("{s}", .{sites.written()[start..]});
        unfinished += 1;
    }
    for (answer.malformed) |entry| {
        const start = sites.written().len;
        sites.writer.print("glint: incomplete: {s}:{d}: malformed: {s}\n", .{ entry.source, entry.line, entry.why }) catch @panic("OOM");
        if (unfinished < printed) c.report("{s}", .{sites.written()[start..]});
        unfinished += 1;
    }
    for (answer.stale) |stale| {
        const start = sites.written().len;
        sites.writer.print("glint: incomplete: {s}:{d}: {s} suppression suppresses nothing\n", .{ stale.source, stale.line, stale.rule }) catch @panic("OOM");
        if (unfinished < printed) c.report("{s}", .{sites.written()[start..]});
        unfinished += 1;
    }
    const sites_at = writeList(c, sites_path, sites.written());
    if (unfinished > printed) {
        summarizeSites(c, sites.written());
        c.report("glint: {d} more incomplete sites; all {d}: {s}\n", .{ unfinished - printed, unfinished, sites_at });
    }
    if (!answer.analysis_complete) {
        c.fail("glint: the run did not complete ({d} run errors, malformed or stale suppressions, {d} of them suppressions that suppress nothing): an incomplete run is not a pass", .{ unfinished, answer.stale_suppressions });
    }
    c.report("preflight: glint: {d} files, {d} findings fail, {d} reported, {d} suppressed, {d} incomplete\n", .{ selected, failing, warned, answer.suppressed, unfinished });
    byRule(c, bans);
}

/// The family's shipped bans, first in the line that counts them; the packages' follow as met.
const shipped_order = policy.shipped_bans;

/// Each shipped ban's findings, counted: the line a sizing or a review reads (P007, P008, P009,
/// then the rules the packages declare).
fn byRule(c: *src.Context, bans: std.array_hash_map.String(usize)) void {
    var line: std.Io.Writer.Allocating = .init(c.a);
    for (bans.keys(), bans.values()) |rule, found| {
        if (found == 0) continue;
        line.writer.print("{s}{s} {d}", .{ if (line.written().len == 0) "" else ", ", rule, found }) catch @panic("OOM");
    }
    if (line.written().len != 0) c.report("preflight: glint: shipped bans' findings: {s}\n", .{line.written()});
}

/// The vendored files that are still their upstream's copy, by the SHA-256 their entries record.
/// One that is not fails the run: changed, it is the package's own code, and its danger sites
/// need their own reasons.
fn upstreamCopies(c: *src.Context, chosen: policy.Policy) ![]const policy.Vendored {
    var out: std.ArrayList(policy.Vendored) = .empty;
    for (chosen.vendored) |entry| {
        const bytes = seam.document(c.io, c.directory(), entry.path, c.a, .whole) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                c.fail("vendored: {s}: not read ({t})", .{ entry.path, err });
                continue;
            },
        };
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, &digest, &entry.sha256)) {
            c.fail("vendored: {s}: its SHA-256 is {x}, not the {x} of {s}'s file its entry records; changed, it is the package's own code", .{ entry.path, &digest, &entry.sha256, entry.upstream });
            continue;
        }
        try out.append(c.a, entry);
    }
    return out.items;
}

/// In a hosted job, the whole list of incomplete sites in the job's summary too,
/// when the run's report holds only the first `printed`.
fn summarizeSites(c: *src.Context, sites: []const u8) void {
    const dir = c.directory();
    // The summary is a copy for the hosted job: one not written leaves the list's file, named in the report.
    if (c.summary_path) |path| appendTo(c.*, dir, path, c.a.print("<details><summary>glint: every incomplete site</summary>\n\n```\n{s}```\n</details>\n", .{sites}) catch @panic("OOM")) catch |err| c.report("preflight: glint: the job's summary {s} was not written ({t})\n", .{ path, err });
}

/// Writes a list in the package's cache, whole, empty when the run has none: its path,
/// or why it was not written, which is reported, since the list an earlier run left stays.
fn writeList(c: *src.Context, path: []const u8, text: []const u8) []const u8 {
    const dir = c.directory();
    const why = why: {
        dir.createDirPath(c.io, std.Io.Dir.path.dirname(path).?) catch |err| break :why err;
        dir.writeFile(c.io, .{ .sub_path = path, .data = text }) catch |err| break :why err;
        return path;
    };
    const said = c.a.print("not written ({t})", .{why}) catch @panic("OOM");
    c.report("preflight: {s}: {s}\n", .{ path, said });
    return said;
}

/// The whole list of a lint's incomplete sites, relative to the package; empty after a run with none.
pub const sites_path = lint_dir ++ "/incomplete.txt";

/// Every finding of a lint, relative to the package; empty after a run with none.
pub const findings_path = lint_dir ++ "/findings.txt";

fn appendTo(c: src.Context, dir: std.Io.Dir, path: []const u8, text: []const u8) !void {
    const file = try dir.createFile(c.io, path, .{ .truncate = false, .read = true });
    defer file.close(c.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(c.io, &buffer);
    writer.pos = (try file.stat(c.io)).size;
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

fn parsed(a: std.mem.Allocator, text: []const u8) !src.Value {
    return (try std.json.parseFromSlice(src.Value, a, text, .{ .allocate = .alloc_always })).value;
}

/// The glint the tests run: the one preflight pins, built by the test build.
const test_glint = @import("test_options").glint;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    c: src.Context,

    fn init() !*Fixture {
        const self = try std.testing.allocator.create(Fixture);
        self.arena = .init(std.testing.allocator);
        self.tmp = std.testing.tmpDir(.{});
        self.c = .{ .a = self.arena.allocator(), .io = std.testing.io, .dir = .of(self.tmp.dir) };
        // What a package of the tests ships: the danger rules' scope.
        try self.tmp.dir.writeFile(self.c.io, .{ .sub_path = "build.zig.zon", .data = ".{ .name = .fixture, .version = \"0.0.0\", .paths = .{ \"build.zig\", \"build.zig.zon\", \"src\" } }\n" });
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
        try check(&self.c, .{ .gpa = std.testing.allocator, .config = try parsed(self.c.a, config), .build = build, .glint = test_glint });
        return self.c.errors;
    }
};

test "a clean repository passes and one finding of the policy's gate fails it" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.file("src/root.zig", "pub fn answer() u32 {\n    return 42;\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"policy\":\"family\",\"glint_paths\":[\"src\"]}", .{}));
    // A pointer conversion is P007's site: a suppression names it.
    try f.file("src/root.zig", "pub fn run(p: *const u8) *const u8 {\n    return @ptrCast(p);\n}\n");
    try std.testing.expect(try f.run("{\"policy\":\"family\",\"glint_paths\":[\"src\"]}", .{}) != 0);
    try f.file("src/root.zig", "pub fn run(p: *const u8) *const u8 {\n    return @ptrCast(p); // glint-ignore: P007 -- the same type\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"policy\":\"family\",\"glint_paths\":[\"src\"]}", .{}));
    // A discarded error fails unless its reason is written at the site; under the family's
    // policy a repository cannot lower it to a report (glint refuses it below the floor), and
    // without it the report is its choice, which glint notes.
    try f.file("src/root.zig", "pub fn drop(f: anytype) void {\n    f() catch {};\n}\n");
    const reported = "{\"glint_paths\":[\"src\"],\"glint\":{\"rules\":[{\"id\":\"Z026\",\"level\":\"report\"}]}}";
    try std.testing.expect(try f.run("{\"glint_paths\":[\"src\"]}", .{}) != 0);
    try std.testing.expect(try f.run("{\"policy\":\"family\"," ++ reported[1..], .{}) != 0);
    f.c.notes = 0;
    try std.testing.expectEqual(@as(usize, 0), try f.run(reported, .{}));
    try std.testing.expect(f.c.notes != 0);
    try f.file("src/root.zig", "pub fn drop(f: anytype) void {\n    // glint-ignore: Z026 -- cleanup after a failure the caller already gets\n    f() catch {};\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"]}", .{}));
    // A name no rule of the run has is glint's to refuse, in its words: no report.
    try std.testing.expect(try f.run("{\"glint_paths\":[\"src\"],\"glint\":{\"rules\":[{\"id\":\"Z999\",\"level\":\"gate\"}]}}", .{}) != 0);
}

test "the shipped bans are findings under the family's policy and reports elsewhere" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.file("src/root.zig", "pub fn run(p: *const u8) *const u8 {\n    return @ptrCast(p);\n}\n");
    try std.testing.expect(try f.run("{\"policy\":\"family\",\"glint_paths\":[\"src\"]}", .{}) != 0);
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"]}", .{}));
    // The release tier fails a shipped ban's finding wherever it reports.
    f.c.errors = 0;
    try check(&f.c, .{ .gpa = std.testing.allocator, .config = try parsed(f.c.a, "{\"glint_paths\":[\"src\"]}"), .glint = test_glint, .release = true });
    try std.testing.expect(f.c.errors != 0);
    // `glint.escapes` went with the escape form.
    try std.testing.expect(try f.run("{\"glint_paths\":[\"src\"],\"glint\":{\"escapes\":{\"no-danger\":{\"P007\":1}}}}", .{}) != 0);
}

test "a clean run leaves its lists empty, not as the run before it wrote them" {
    const f = try Fixture.init();
    defer f.deinit();
    // More findings than the run prints, a suppression, and one that suppresses nothing.
    var dirty: std.Io.Writer.Allocating = .init(f.c.a);
    for (0..printed + 1) |i| try dirty.writer.print("pub fn view{d}(p: *u8) *u32 {{\n    return @ptrCast(@alignCast(p));\n}}\n", .{i});
    try dirty.writer.writeAll("pub fn same(p: *const u8) *const u8 {\n    return @ptrCast(p); // glint-ignore: P007 -- the same type\n}\n");
    try dirty.writer.writeAll("pub fn plain() u32 {\n    return 1; // glint-ignore: P007 -- nothing here\n}\n");
    try f.file("src/root.zig", dirty.written());
    try std.testing.expect(try f.run("{\"policy\":\"family\",\"glint_paths\":[\"src\"]}", .{}) != 0);
    for ([_][]const u8{ findings_path, sites_path }) |path| try std.testing.expect((try f.c.read(path)).len != 0);
    try f.file("src/root.zig", "pub fn answer() u32 {\n    return 42;\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"policy\":\"family\",\"glint_paths\":[\"src\"]}", .{}));
    for ([_][]const u8{ findings_path, sites_path }) |path| try std.testing.expectEqualStrings("", try f.c.read(path));
}

test "style is reported and does not fail; a repository may gate it" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.file("src/root.zig", "pub const BadName = 1;\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"]}", .{}));
    try std.testing.expect(try f.run("{\"glint_paths\":[\"src\"],\"glint\":{\"rules\":[{\"id\":\"Z006\",\"level\":\"gate\"}]}}", .{}) != 0);
}

test "a shipped ban's site fails in production unless a suppression names it; tests are not shipped, a vendored file is" {
    const f = try Fixture.init();
    defer f.deinit();
    const cast = "pub fn view(p: *u8) *u32 {\n    return @ptrCast(@alignCast(p));\n}\n";
    const paths = "{\"policy\":\"family\",\"glint_paths\":[\"src\"]}";
    try f.file("src/root.zig", cast);
    try std.testing.expect(try f.run(paths, .{}) != 0);
    try f.file("src/root.zig", "pub fn view(p: *u8) *u32 {\n    return @ptrCast(@alignCast(p)); // glint-ignore: P007 -- p points at a u32 the kernel wrote\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run(paths, .{}));
    // The old escape form is read no more: the run is incomplete until `zig build fix` rewrites it.
    try f.file("src/root.zig", "pub fn view(p: *u8) *u32 {\n    return @ptrCast(@alignCast(p)); // aegis: boundary(A019): p points at a u32 the kernel wrote\n}\n");
    try std.testing.expect(try f.run(paths, .{}) != 0);
    try f.file("src/root.zig", "pub const x = 1;\n");
    try f.file("src/root_test.zig", cast);
    try f.file("src/testing/harness.zig", cast);
    try std.testing.expectEqual(@as(usize, 0), try f.run(paths, .{}));
    try f.file("src/root_test.zig", "pub const t = 1;\n");
    try f.file("src/testing/harness.zig", "pub const h = 1;\n");
    // An upstream's file kept unchanged: its verification is the reason its danger sites carry,
    // while it is the copy the entry's SHA-256 names: a site a ban cannot decide is a finding it
    // carries as any other.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(cast, &digest, .{});
    const entry = "{{\"policy\":\"family\",\"glint_paths\":[\"src\"],\"vendored\":{{\"src/vendor/fiat.zig\":{{\"upstream\":\"fiat-crypto\",\"verification\":\"fiat's CI regenerates it\",\"sha256\":\"{x}\"}}}}}}";
    var buffer: [512]u8 = undefined;
    var vendored: std.Io.Writer = .fixed(&buffer);
    try vendored.print(entry, .{&digest});
    try f.file("src/vendor/fiat.zig", cast);
    try std.testing.expectEqual(@as(usize, 0), try f.run(vendored.buffered(), .{}));
    try f.file("src/vendor/fiat.zig", cast ++ "pub const edited = 1;\n");
    try std.testing.expect(try f.run(vendored.buffered(), .{}) != 0);
    const unsure = "const flags = struct { var checked: bool = true; };\npub fn f() void {\n    @setRuntimeSafety(flags.checked);\n}\n";
    std.crypto.hash.sha2.Sha256.hash(unsure, &digest, .{});
    try f.file("src/vendor/fiat.zig", unsure);
    vendored = .fixed(&buffer);
    try vendored.print(entry, .{&digest});
    try std.testing.expectEqual(@as(usize, 0), try f.run(vendored.buffered(), .{}));
}

test "the list of every finding names a vendored file's carried sites as carried" {
    const f = try Fixture.init();
    defer f.deinit();
    const cast = "pub fn view(p: *u8) *u32 {\n    return @ptrCast(@alignCast(p));\n}\n";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(cast, &digest, .{});
    try f.file("src/vendor/fiat.zig", cast);
    // More sites of the package's own than the run prints, so it writes the list.
    var own: std.Io.Writer.Allocating = .init(f.c.a);
    for (0..printed + 1) |i| try own.writer.print("pub fn view{d}(p: *u8) *u32 {{\n    return @ptrCast(@alignCast(p));\n}}\n", .{i});
    try f.file("src/root.zig", own.written());
    var buffer: [512]u8 = undefined;
    var config: std.Io.Writer = .fixed(&buffer);
    try config.print("{{\"policy\":\"family\",\"glint_paths\":[\"src\"],\"vendored\":{{\"src/vendor/fiat.zig\":{{\"upstream\":\"fiat-crypto\",\"verification\":\"fiat's CI regenerates it\",\"sha256\":\"{x}\"}}}}}}", .{&digest});
    try std.testing.expect(try f.run(config.buffered(), .{}) != 0);
    const list = try f.c.read(findings_path);
    var lines = std.mem.splitScalar(u8, list, '\n');
    var carried: usize = 0;
    var failing: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.find(u8, line, "src/vendor/fiat.zig:") != null) {
            try std.testing.expect(std.mem.endsWith(u8, line, " (vendored: carried by fiat-crypto's verification)"));
            carried += 1;
        } else if (std.mem.find(u8, line, "src/root.zig:") != null) {
            try std.testing.expect(std.mem.find(u8, line, "vendored") == null);
            failing += 1;
        }
    }
    try std.testing.expect(carried > 0);
    try std.testing.expect(failing > printed);
}

test "a site a ban cannot decide is a finding, and `glint.unresolved` is retired by name" {
    const f = try Fixture.init();
    defer f.deinit();
    // `@setRuntimeSafety` with a computed argument: P007 cannot show the checks stay on.
    try f.file("src/root.zig", "pub fn run(comptime on: bool) void {\n    @setRuntimeSafety(on);\n}\n");
    try std.testing.expect(try f.run("{\"policy\":\"family\",\"glint_paths\":[\"src\"]}", .{}) != 0);
    try std.testing.expect(try f.run("{\"policy\":\"family\",\"glint_paths\":[\"src\"],\"glint\":{\"unresolved\":{\"P007\":1}}}", .{}) != 0);
}

test "function length: the limit, a per-path ceiling and a reasoned exception that cannot grow or go stale" {
    const f = try Fixture.init();
    defer f.deinit();
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(f.c.a, "pub fn long() void {\n");
    for (0..30) |_| try body.appendSlice(f.c.a, "    _ = 1;\n");
    try body.appendSlice(f.c.a, "}\n");
    try f.file("src/root.zig", body.items);
    // A house style: reported until the package gates it.
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"],\"function_limit\":20}", .{}));
    const paths = "\"glint_paths\":[\"src\"],\"glint\":{\"rules\":[{\"id\":\"P003\",\"level\":\"gate\"}]}";
    try std.testing.expectEqual(@as(usize, 0), try f.run("{" ++ paths ++ "}", .{}));
    try std.testing.expect(try f.run("{" ++ paths ++ ",\"function_limit\":20}", .{}) != 0);
    try std.testing.expect(try f.run("{" ++ paths ++ ",\"function_limits\":{\"src/**\":20}}", .{}) != 0);
    try std.testing.expectEqual(@as(usize, 0), try f.run("{" ++ paths ++ ",\"function_limit\":20,\"function_limits\":{\"bench/**\":10},\"function_exceptions\":{\"src/root.zig:long\":{\"lines\":32,\"reason\":\"a table\"}}}", .{}));
    // Grown past its ceiling.
    try std.testing.expect(try f.run("{" ++ paths ++ ",\"function_limit\":20,\"function_exceptions\":{\"src/root.zig:long\":{\"lines\":31,\"reason\":\"a table\"}}}", .{}) != 0);
    // Named for a function that is gone: the exception is stale, and a stale one is not a pass.
    try std.testing.expect(try f.run("{" ++ paths ++ ",\"function_exceptions\":{\"src/root.zig:gone\":{\"lines\":200,\"reason\":\"a table\"}}}", .{}) != 0);
}

test "a debug print, a deprecated call and, under the family's policy, a file's sync are findings the standard library's declarations decide" {
    const f = try Fixture.init();
    defer f.deinit();
    // The standard library of the Zig that builds these tests: the debug print, the deprecated
    // calls and, under the family's policy, the durability door name its declarations.
    const build: assembly.Build = .{ .std_dir = @import("test_options").zig_std };
    const paths = "{\"glint_paths\":[\"src\"]}";
    try f.file("src/root.zig", "const std = @import(\"std\");\npub fn run() void {\n    std.debug.print(\"hi\", .{});\n}\n");
    try std.testing.expect(try f.run(paths, build) != 0);
    // Without the standard library the import names nothing the run maps: the run stops.
    try std.testing.expect(try f.run(paths, .{}) != 0);
    try f.file("src/root.zig", "const std = @import(\"std\");\npub fn run() void {\n    std.debug.print(\"hi\", .{}); // glint-ignore: P005 -- the tool's one line of output\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run(paths, build));
    try f.file("src/root.zig", "const std = @import(\"std\");\npub fn run(text: []const u8) ?usize {\n    return std.mem.indexOfScalar(u8, text, 'x');\n}\n");
    try std.testing.expect(try f.run(paths, build) != 0);
    // A file's own sync says nothing of what reached the disk: under the family's policy it is
    // airlock's, and a stranger's project is held to no such door.
    try f.file("src/root.zig", "const std = @import(\"std\");\npub fn flush(file: std.Io.File, io: std.Io) !void {\n    try file.sync(io);\n}\n");
    try std.testing.expect(try f.run("{\"policy\":\"family\",\"glint_paths\":[\"src\"]}", build) != 0);
    try std.testing.expectEqual(@as(usize, 0), try f.run(paths, build));
    try f.file("src/root_test.zig", "const std = @import(\"std\");\ntest {\n    std.debug.print(\"in a test\", .{});\n}\n");
    try f.file("src/root.zig", "pub const x = 1;\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run(paths, build));
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
    const with_std: assembly.Build = .{ .std_dir = @import("test_options").zig_std };
    try f.file("src/root.zig", "const std = @import(\"std\");\npub fn run() void {\n    _ = std.mem;\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run("{" ++ paths ++ "}", with_std));
    // The budget is glint's option, in glint.json.
    try f.file("glint.json", "{\"fact_budget\":1}");
    try std.testing.expect(try f.run("{" ++ paths ++ "}", with_std) != 0);
    try f.file("glint.json", "{}");
    // A suppression that suppresses nothing.
    try f.file("src/root.zig", "// glint-ignore: Z026 -- there is no empty catch here\npub const x = 1;\n");
    try std.testing.expect(try f.run("{" ++ paths ++ "}", .{}) != 0);
    // A finding its site allows does not hide what else is wrong.
    try f.file("src/root.zig", "pub fn drop(f: anytype) void {\n    // glint-ignore: Z026 -- cleanup after a failure the caller already gets\n    f() catch {};\n}\npub fn broken( {\n");
    try std.testing.expect(try f.run("{" ++ paths ++ "}", .{}) != 0);
}

test "a run counts every incomplete site, prints the first ones and lists them all in the cache and the job's summary" {
    const f = try Fixture.init();
    defer f.deinit();
    for (0..printed + 5) |i| try f.file(try f.c.a.print("src/broken{d}.zig", .{i}), "pub fn broken( {\n");
    var held: std.Io.Writer.Allocating = .init(f.c.a);
    f.c.held = &held;
    f.c.summary_path = "summary.md";
    try std.testing.expect(try f.run("{\"glint_paths\":[\"src\"]}", .{}) != 0);
    const out = held.written();
    try std.testing.expectEqual(@as(usize, printed), std.mem.count(u8, out, "glint: error: "));
    try std.testing.expect(std.mem.find(u8, out, "glint: 5 more incomplete sites; all 30: " ++ sites_path) != null);
    try std.testing.expect(std.mem.find(u8, out, ", 30 incomplete") != null);
    const all = try f.c.read(sites_path);
    try std.testing.expectEqual(@as(usize, printed + 5), std.mem.count(u8, all, "glint: error: "));
    const summary = try f.c.read("summary.md");
    try std.testing.expectEqual(@as(usize, printed + 5), std.mem.count(u8, summary, "glint: error: "));
}

test "assertions are counted by the declaration a call resolves to, never by its spelling" {
    const f = try Fixture.init();
    defer f.deinit();
    // A stub standard library: `debug.assert` is the declaration the counts look for.
    try f.file("lib/std/std.zig", "pub const debug = @import(\"debug.zig\");\n");
    try f.file("lib/std/debug.zig", "pub fn assert(ok: bool) void {\n    if (!ok) unreachable; // unreachable: what an assertion is\n}\n");
    try f.file("src/root.zig",
        \\const std = @import("std");
        \\pub fn checked(x: u8) u8 {
        \\    std.debug.assert(x != 0);
        \\    return mine(x);
        \\}
        \\fn mine(x: u8) u8 {
        \\    assert(x == 1);
        \\    const text = "assert(false)";
        \\    return @intCast(text.len);
        \\}
        \\fn assert(ok: bool) void {
        \\    _ = ok;
        \\}
        \\
    );
    var held: std.Io.Writer.Allocating = .init(f.c.a);
    f.c.held = &held;
    f.c.summary_path = "summary.md";
    _ = try f.run("{\"glint_paths\":[\"src\"]}", .{ .std_dir = "lib/std" });
    const out = held.written();
    try std.testing.expect(std.mem.find(u8, out, "preflight: assertions: 1 in 3 functions, 1 of them with one") != null);
    const summary = try f.c.read("summary.md");
    try std.testing.expect(std.mem.find(u8, summary, "| `src/root.zig` | 3 | 1 | 1 |") != null);
}

test "a glint that reads no project file of this version fails the run by name, never a pass" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.file("src/root.zig", "pub const x = 1;\n");
    var held: std.Io.Writer.Allocating = .init(f.c.a);
    f.c.held = &held;
    f.c.errors = 0;
    // Any program that does not print the line, as glint 0.8 exits with its usage: here the
    // tests' stand-in for bay, which knows no `--contract`.
    try check(&f.c, .{ .gpa = std.testing.allocator, .config = try parsed(f.c.a, "{\"glint_paths\":[\"src\"]}"), .glint = @import("test_options").fake_bay });
    try std.testing.expectEqual(@as(usize, 1), f.c.errors);
    try std.testing.expect(std.mem.find(u8, held.written(), "reads no project file of version 1") != null);
}

/// An `Io` on which every task has been asked to stop.
const Canceled = @import("shakedown").Layer(u8, .{
    .checkCancel = struct {
        fn checkCancel(_: ?*anyopaque) std.Io.Cancelable!void {
            return error.Canceled;
        }
    }.checkCancel,
});

test "a cancel while the lint gathers the project or glint runs ends the check with Canceled, never a failure or a pass" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.file("src/root.zig", "pub const x = 1;\n");
    var canceled: Canceled = .init(std.testing.io, 0);
    f.c.io = canceled.io();
    f.c.errors = 0;
    try std.testing.expectError(error.Canceled, check(&f.c, .{ .gpa = std.testing.allocator, .config = try parsed(f.c.a, "{\"glint_paths\":[\"src\"]}"), .glint = test_glint }));
    try std.testing.expect(f.c.errors == 0);
    f.c.io = std.testing.io;
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"]}", .{}));
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
        const result = check(&f.c, .{ .gpa = std.testing.allocator, .config = try parsed(f.c.a, "{\"glint_paths\":[\"src\"]}"), .glint = test_glint });
        try std.testing.expectError(failure, result);
        try std.testing.expectEqual(@as(u64, 1), faults.count(.dirOpenFile));
    }
    f.c.io = std.testing.io;
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"]}", .{}));
}
