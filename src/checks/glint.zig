//! The code rules are glint's. This is the linter that runs them for a
//! repository: the default policy, amended, over the repository's files, in one
//! project glint holds in memory, so that nothing stands between a finding
//! and the gate, and a run that did not finish is not a run that passed.
const std = @import("std");
const aegis = @import("aegis");
const glint = @import("glint");
const src = @import("source.zig");
const matrix = @import("matrix.zig");
const fetched = @import("manifest.zig");
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
    /// Apply the findings' fixes to the package's sources (`zig build fix`).
    fix: bool = false,
    /// With `fix`, the escapes a lint before reported, by which an escape in the older form is
    /// named (`zig build fix -- --escapes-before FILE`): glint's migration aid.
    escapes_before: ?[]const u8 = null,
    /// The release tier's bar: every aegis-pack finding fails, the flow rules' too,
    /// which the default policy only reports while a landing reads them.
    release: bool = false,
};

/// How many lines of one kind a run prints before it counts the rest.
const printed = 25;

/// Fails the run on a finding the policy gates and on any analysis glint
/// did not finish: a file it could not parse or lower, work it ran out of
/// budget for, a site a gating rule could not decide, a suppression that
/// suppresses nothing.
pub fn check(c: *src.Context, inputs: Inputs) !void {
    // Read before this run writes its own record over the one kept.
    const before: []const glint.Fix.Escaped = if (inputs.escapes_before) |path| (try escapeRecord(c, path)) orelse return else &.{};
    const shipped = fetched.shippedPaths(c) catch |err| switch (err) {
        error.InvalidManifest => return,
        error.FileNotFound => {
            c.fail("build.zig.zon: not found: what it ships is the danger rules' scope", .{});
            return;
        },
        else => return err,
    };
    var chosen = (try policy.parse(c, inputs.config, shipped)) orelse return;
    chosen.base.peer_writers = try peerWriters(c, chosen.base.peer_writers, inputs.build.modules);
    chosen.base.pointer_widths = try pointerWidths(c);
    const paths = (try assembly.select(c, chosen)) orelse return;
    var assembled = (try assembly.assemble(c, inputs.gpa, chosen, paths, inputs.build)) orelse return;
    defer assembled.deinit();
    var files: std.ArrayList(glint.FileConfig) = .empty;
    for (assembled.selected, 0..) |file, index| {
        try files.append(c.a, .{ .file = .fromRaw(@intCast(index)), .config = try chosen.forFile(c.a, file.path) });
    }
    var report = glint.runConfigured(inputs.gpa, &assembled.project, chosen.base, .{
        .project_rules = &policy.project_rules,
        .files = files.items,
        .io = c.io,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => {
            c.fail("glint: the run did not finish ({t})", .{err});
            return;
        },
    };
    defer report.deinit();
    if (inputs.fix) try applyFixes(c, &assembled.project, &report, before);
    judge(c, chosen, &assembled.project, &report, inputs.release);
    assertions(c, &assembled.project, &report);
}

/// The peer writers A018 reads: the package's own, then those each package it depends on
/// declares in its `ci/preflight.json` (found beside the `build.zig.zon` above a dependency
/// module's root).
/// The pointer widths glint reads ranges at: those of the targets `ci/workflow.json` names
/// and of this machine, whose tests run natively, so a package with no 32-bit target is not
/// held to a 32-bit `usize`. A package that names no targets is read at both 32 and 64 bits.
fn pointerWidths(c: *src.Context) ![]const u16 {
    const targets = try src.items(src.get(try c.options("ci/workflow.json"), "targets"));
    if (targets.len == 0) return &.{};
    var out: std.ArrayList(u16) = .empty;
    try out.append(c.a, @import("builtin").target.ptrBitWidth());
    for (targets) |target| {
        // A target the matrix refuses is named there; its width cannot be read here.
        const query = std.Target.Query.parse(.{ .arch_os_abi = try matrix.targetName(target) }) catch continue;
        const arch = query.cpu_arch orelse continue;
        const width = std.Target.ptrBitWidth_arch_abi(arch, query.abi orelse .none);
        if (std.mem.findScalar(u16, out.items, width) == null) try out.append(c.a, width);
    }
    return out.items;
}

fn peerWriters(c: *src.Context, own: []const glint.Config.PeerWriter, modules: []const src.BuildModule) ![]const glint.Config.PeerWriter {
    var out: std.ArrayList(glint.Config.PeerWriter) = .empty;
    try out.appendSlice(c.a, own);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (modules) |module| {
        const root = module.root orelse continue;
        if (!std.fs.path.isAbsolute(root)) continue;
        var dir = std.fs.path.dirname(root);
        const package = while (dir) |at| : (dir = std.fs.path.dirname(at)) {
            const manifest = try std.fs.path.join(c.a, &.{ at, "build.zig.zon" });
            if (std.Io.Dir.cwd().access(c.io, manifest, .{})) |_| break at else |_| {}
        } else continue;
        if ((try seen.getOrPut(c.a, package)).found_existing) continue;
        const path = try std.fs.path.join(c.a, &.{ package, "ci", "preflight.json" });
        // A dependency without the file declares no writers.
        const bytes = aegis.own.readFile(c.io, std.Io.Dir.cwd(), path, c.a, .fromRaw(1 << 20)) catch continue;
        const config = std.json.parseFromSliceLeaky(src.Value, c.a, bytes, .{}) catch {
            c.fail("glint: {s}: not JSON, so its peer writers cannot be read", .{path});
            continue;
        };
        try out.appendSlice(c.a, try policy.parsePeerWriters(c, src.get(config, "glint")));
    }
    return out.items;
}

/// Writes each source glint's fixes change (`zig build fix`): the deterministic answers, the
/// escape for a reason written the older way, an unused escape gone. The run's report is the
/// one before them; the next lint reads what is left.
fn applyFixes(c: *src.Context, project: *const glint.Project, report: *const glint.Report, before: []const glint.Fix.Escaped) !void {
    const changed = try glint.Fix.apply(c.a, project, report, .{ .escapes_before = before });
    var made: usize = 0;
    for (changed) |file| {
        c.directory().writeFile(c.io, .{ .sub_path = project.inputs[file.file.raw()].name, .data = file.bytes }) catch |err| {
            c.fail("glint: {s}: the fixed source was not written ({t})", .{ project.inputs[file.file.raw()].name, err });
            continue;
        };
        made += file.edits;
    }
    c.report("preflight: glint: fixed {d} sites in {d} files; what follows is the run before them\n", .{ made, changed.len });
}

/// The escapes a lint before reported (its `escapes.txt`, kept), each with the rules it covered.
fn escapeRecord(c: *src.Context, path: []const u8) !?[]const glint.Fix.Escaped {
    const bytes = aegis.own.readFile(c.io, std.Io.Dir.cwd(), path, c.a, .fromRaw(16 << 20)) catch |err| {
        c.fail("glint: {s}: the escapes before were not read ({t})", .{ path, err });
        return null;
    };
    // A record is a file another run wrote: input until parsed.
    return aegis.input.Untrusted([]const u8).init(bytes).parse(c.a, glint.Fix.escapeRecord) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidEscapeRecord => {
            c.fail("glint: {s}: a line names an escape and is not one", .{path});
            return null;
        },
    };
}

/// glint's assertion counts, each call by the declaration it resolves to
/// (std's `debug.assert`, aegis's `assert` contracts), never by its
/// spelling: a report, never a gate, since a count says nothing of what an
/// assertion checks. In a hosted job the per-file table goes to its summary.
fn assertions(c: *src.Context, project: *const glint.Project, report: *const glint.Report) void {
    const metrics = report.metrics orelse return;
    const t = metrics.total;
    c.report("preflight: assertions: {d} in {d} functions, {d} of them with one; {d} calls spelled like one unresolved\n", .{ t.total(), t.functions, t.asserted, t.unresolved });
    const path = c.summary_path orelse return;
    var text: std.Io.Writer.Allocating = .init(c.a);
    text.writer.writeAll("\nAssertions (report only)\n\n| File | Functions | With one | Assertions | Unresolved |\n|---|---:|---:|---:|---:|\n") catch @panic("OOM");
    for (metrics.files) |file| {
        const n = file.counts;
        if (n.functions == 0 and n.unresolved == 0) continue;
        text.writer.print("| `{s}` | {d} | {d} | {d} | {d} |\n", .{ project.inputs[file.file.raw()].name, n.functions, n.asserted, n.total(), n.unresolved }) catch @panic("OOM");
    }
    // glint-ignore: Z026 -- a summary that cannot be written leaves the line printed above
    appendTo(c.*, c.directory(), path, text.written()) catch {};
}

fn judge(c: *src.Context, chosen: policy.Policy, project: *const glint.Project, report: *const glint.Report, release: bool) void {
    var failing: usize = 0;
    var warned: usize = 0;
    var shown: std.AutoHashMapUnmanaged(glint.Rule, usize) = .empty;
    // Every finding, where the run prints the first `printed` of a rule.
    var all: std.Io.Writer.Allocating = .init(c.a);
    var held = false;
    const kept = upstreamCopies(c, chosen);
    const carried = c.a.alloc(usize, kept.len) catch @panic("OOM");
    @memset(carried, 0);
    for (report.diagnostics) |d| {
        const file = project.inputs[d.span.file.raw()].name;
        all.writer.print("{s}: {s}:{d}:{d}: {s}", .{ d.name, file, d.span.line, d.span.column, d.message }) catch @panic("OOM");
        // A danger site of an upstream's unchanged file carries the upstream's verification.
        if (policy.inPack(d.rule)) if (for (kept, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.path, file)) break i;
        } else null) |at| {
            all.writer.print(" (vendored: carried by {s}'s verification)\n", .{kept[at].upstream}) catch @panic("OOM");
            carried[at] += 1;
            continue;
        };
        all.writer.writeByte('\n') catch @panic("OOM");
        const fails = d.level == .gate or chosen.fails(d.rule) or (release and policy.inPack(d.rule));
        const seen = shown.getOrPutValue(c.a, d.rule, 0) catch null;
        if (seen) |count| {
            count.value_ptr.* += 1;
            if (count.value_ptr.* == printed + 1) c.report("glint: more {s} follow\n", .{d.name});
            held = held or count.value_ptr.* > printed;
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

    for (kept, carried) |entry, count| c.report("preflight: vendored: {s}: {d} danger sites, their reason {s}'s verification: {s}\n", .{ entry.path, count, entry.upstream, entry.verification });
    // Every list is the run's own, written whether or not the run prints all of it: a list
    // an earlier run left would read as this run's.
    const findings_at = writeList(c, findings_path, all.written());
    if (held) c.report("glint: every finding: {s}\n", .{findings_at});

    var unfinished: usize = 0;
    var unresolved: usize = 0;
    // A finding rule's undecided sites, by rule, against the repository's ceiling for it.
    var undecided: std.array_hash_map.Auto(glint.Rule, usize) = .empty;
    // Every incomplete site, where the run prints the first `printed`.
    var sites: std.Io.Writer.Allocating = .init(c.a);
    for (report.coverage) |note| {
        const file = project.inputs[note.file.raw()].name;
        const gating = if (note.rule) |rule| chosen.base.level(rule) == .gate else false;
        const stops = switch (note.reason) {
            .parsed, .unsupported => false,
            .invalid_syntax, .invalid_lowering, .budget_exhausted => true,
            .unresolved => gating,
        };
        if (stops or (gating and note.reason != .parsed)) {
            const start = sites.written().len;
            sites.writer.print("glint: incomplete: {s}:{d}: {s}{s}{s}: {s}\n", .{ file, lineAt(project.inputs[note.file.raw()].bytes, note.start), note.rule_name, if (note.rule_name.len != 0) " " else "", @tagName(note.reason), note.detail }) catch @panic("OOM");
            if (unfinished < printed) c.report("{s}", .{sites.written()[start..]});
            unfinished += 1;
        } else if (note.reason == .unresolved) {
            unresolved += 1;
            if (note.rule) |rule| if (chosen.fails(rule) and policy.inPack(rule)) {
                const count = undecided.getOrPutValue(c.a, rule, 0) catch @panic("OOM");
                count.value_ptr.* += 1;
                const start = sites.written().len;
                sites.writer.print("glint: undecided: {s}:{d}: {s}: {s}\n", .{ file, lineAt(project.inputs[note.file.raw()].bytes, note.start), note.rule_name, note.detail }) catch @panic("OOM");
                if (count.value_ptr.* <= printed) c.report("{s}", .{sites.written()[start..]});
            };
        }
    }
    ceilings(c, chosen, report, undecided);
    escapes(c, chosen, project, report);
    for (report.malformed) |entry| {
        const start = sites.written().len;
        sites.writer.print("glint: incomplete: {s}:{d}: malformed: {s}\n", .{ project.inputs[entry.span.file.raw()].name, entry.span.line, entry.why }) catch @panic("OOM");
        if (unfinished < printed) c.report("{s}", .{sites.written()[start..]});
        unfinished += 1;
    }
    for (report.stale) |stale| {
        const start = sites.written().len;
        sites.writer.print("glint: incomplete: {s}:{d}: {s} suppression suppresses nothing\n", .{ project.inputs[stale.span.file.raw()].name, stale.span.line, stale.name }) catch @panic("OOM");
        if (unfinished < printed) c.report("{s}", .{sites.written()[start..]});
        unfinished += 1;
    }
    const sites_at = writeList(c, sites_path, sites.written());
    if (unfinished > printed) {
        summarizeSites(c, sites.written());
        c.report("glint: {d} more incomplete sites; all {d}: {s}\n", .{ unfinished - printed, unfinished, sites_at });
    }
    if (!report.complete) {
        c.fail("glint: the analysis is incomplete ({d} sites or files undecided, {d} of them suppressions that suppress nothing); an incomplete run is not a pass", .{ unfinished, report.stale_suppressions });
    }
    c.report("preflight: glint: {d} files, {d} findings fail, {d} reported, {d} suppressed, {d} sites incomplete, {d} sites unresolved\n", .{ project.inputs.len, failing, warned, report.suppressed, unfinished, unresolved });
    byRule(c, report, shown, undecided);
}

/// The vendored files that are still their upstream's copy, by the SHA-256 their entries record.
/// One that is not fails the run: changed, it is the package's own code, and its danger sites
/// need their own reasons.
fn upstreamCopies(c: *src.Context, chosen: policy.Policy) []const policy.Vendored {
    var out: std.ArrayList(policy.Vendored) = .empty;
    for (chosen.vendored) |entry| {
        const bytes = aegis.own.readFile(c.io, c.directory(), entry.path, c.a, .fromRaw(64 << 20)) catch |err| {
            c.fail("vendored: {s}: not read ({t})", .{ entry.path, err });
            continue;
        };
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, &digest, &entry.sha256)) {
            c.fail("vendored: {s}: its SHA-256 is {x}, not the {x} of {s}'s file its entry records; changed, it is the package's own code", .{ entry.path, &digest, &entry.sha256, entry.upstream });
            continue;
        }
        out.append(c.a, entry) catch @panic("OOM");
    }
    return out.items;
}

/// Each rule's findings and undecided sites, counted: the line a sizing or a review reads.
fn byRule(c: *src.Context, report: *const glint.Report, shown: std.AutoHashMapUnmanaged(glint.Rule, usize), undecided: std.array_hash_map.Auto(glint.Rule, usize)) void {
    var line: std.Io.Writer.Allocating = .init(c.a);
    for (policy.project_rules) |rule| {
        const id = rule.definition.id;
        const found = shown.get(id) orelse 0;
        const open = undecided.get(id) orelse 0;
        var escaped: usize = 0;
        for (report.escapes) |escape| for (escape.covered) |covered| if (std.mem.eql(u8, covered.name, rule.definition.name)) {
            escaped += 1;
        };
        if (found == 0 and open == 0 and escaped == 0) continue;
        line.writer.print("{s}{s} {d}/{d}/{d}", .{ if (line.written().len == 0) "" else ", ", rule.definition.name, found, escaped, open }) catch @panic("OOM");
    }
    if (line.written().len != 0) c.report("preflight: glint: by rule (findings/escaped/undecided): {s}\n", .{line.written()});
}

/// A finding rule's undecided sites against the repository's ceiling (`glint.unresolved`, none
/// by default): above it fails, since the count the reviews read may not grow; below it asks
/// for the ceiling to come down to what is left.
fn ceilings(c: *src.Context, chosen: policy.Policy, report: *const glint.Report, undecided: std.array_hash_map.Auto(glint.Rule, usize)) void {
    for (chosen.findings) |rule| {
        if (!policy.inPack(rule)) continue;
        const count = undecided.get(rule) orelse 0;
        var ceiling: usize = 0;
        var name: []const u8 = "";
        for (chosen.ceilings) |entry| if (entry.rule == rule) {
            ceiling = entry.sites;
            name = entry.name;
        };
        if (count > ceiling) {
            for (report.diagnostics) |d| if (d.rule == rule) {
                name = d.name;
            };
            if (name.len == 0) name = ruleName(rule);
            c.fail("glint: {s} leaves {d} sites undecided, above the {d} `glint.unresolved` allows: the count may not grow", .{ name, count, ceiling });
        } else if (count < ceiling) c.report("glint: {s} leaves {d} sites undecided, below its ceiling of {d}: lower `glint.unresolved.{s}` to {d}\n", .{ name, count, ceiling, name, count });
    }
}

fn ruleName(rule: glint.Rule) []const u8 {
    for (policy.project_rules) |entry| if (entry.definition.id == rule) return entry.definition.name;
    return @tagName(rule);
}

/// Every aegis escape, with the rules whose findings it covers: per rule a count by reason, then
/// each escape, the first `printed` of a rule here and all of them in a file beside the
/// incomplete sites. The reviews read each one, and the findings they cover, by reason and
/// rule, hold to `glint.escapes`: above it fails, since a new escape, or one widened to a rule
/// it did not cover, is a visible line there, and below it fails too, until the line comes
/// down, so each count only falls. An escape in the older form, which names no rule, covers
/// nothing glint 0.8.0 holds it to: it is counted apart, in the report and in the file, and
/// held to no line, since `zig build fix` names its rules.
fn escapes(c: *src.Context, chosen: policy.Policy, project: *const glint.Project, report: *const glint.Report) void {
    var text: std.Io.Writer.Allocating = .init(c.a);
    var counts: std.array_hash_map.String([policy.escape_reasons.len]usize) = .empty;
    const reasons = policy.escape_reasons;
    var older: usize = 0;
    for (report.escapes) |escape| if (olderForm(project, escape)) {
        older += 1;
    } else for (escape.covered) |covered| {
        const entry = counts.getOrPutValue(c.a, covered.name, @splat(0)) catch @panic("OOM");
        for (reasons, 0..) |reason, r| if (std.mem.eql(u8, reason, escape.reason)) {
            entry.value_ptr[r] += 1;
        };
    };
    for (chosen.escapes) |held| _ = counts.getOrPutValue(c.a, held.name, @splat(0)) catch @panic("OOM");
    var pairs = counts.iterator();
    while (pairs.next()) |entry| for (reasons, entry.value_ptr.*, 0..) |reason, count, r| {
        const rule = entry.key_ptr.*;
        const ceiling = for (chosen.escapes) |held| {
            if (held.reason == r and std.mem.eql(u8, held.name, rule)) break held.findings;
        } else 0;
        if (count > ceiling) {
            c.fail("glint: `{s}` escapes cover {d} {s} findings, above the {d} `glint.escapes` holds: a new or widened escape is a line there, so set `glint.escapes.{s}.{s}` to {d} with it, or give the site aegis's type", .{ reason, count, rule, ceiling, reason, rule, count });
        } else if (count < ceiling) c.fail("glint: `{s}` escapes cover {d} {s} findings, below the {d} `glint.escapes` holds: lower `glint.escapes.{s}.{s}` to {d}, so the count only falls", .{ reason, count, rule, ceiling, reason, rule, count });
    };
    if (report.escapes.len == 0) {
        _ = writeList(c, escapes_path, "");
        return;
    }
    for (report.escapes) |escape| {
        text.writer.print("glint: escape: {s}:{d}:{d}: {s}: {s} (", .{ project.inputs[escape.span.file.raw()].name, escape.span.line, escape.span.column, escape.reason, escape.why }) catch @panic("OOM");
        for (escape.covered, 0..) |covered, i| text.writer.print("{s}{s}", .{ if (i == 0) "" else ", ", covered.name }) catch @panic("OOM");
        text.writer.writeAll(")\n") catch @panic("OOM");
    }
    var lines = std.mem.splitScalar(u8, text.written(), '\n');
    var shown: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (shown == printed) break;
        c.report("{s}\n", .{line});
        shown += 1;
    }
    var summary: std.Io.Writer.Allocating = .init(c.a);
    var rules = counts.iterator();
    while (rules.next()) |entry| {
        if (std.mem.allEqual(usize, entry.value_ptr, 0)) continue;
        summary.writer.print("{s}{s} ", .{ if (summary.written().len == 0) "" else ", ", entry.key_ptr.* }) catch @panic("OOM");
        var first = true;
        for (reasons, entry.value_ptr.*) |reason, n| if (n != 0) {
            summary.writer.print("{s}{s} {d}", .{ if (first) "(" else ", ", reason, n }) catch @panic("OOM");
            first = false;
        };
        summary.writer.writeByte(')') catch @panic("OOM");
    }
    const apart = if (older == 0) "" else c.a.print(" ({d} in the older form, naming no rule, so covering nothing: `zig build fix` names their rules)", .{older}) catch @panic("OOM");
    const covered = if (summary.written().len == 0) "" else c.a.print(": {s}", .{summary.written()}) catch @panic("OOM");
    const line = c.a.print("preflight: escapes: {d}{s}{s}", .{ report.escapes.len, apart, covered }) catch @panic("OOM");
    text.writer.print("{s}\n", .{line}) catch @panic("OOM");
    c.report("{s}; all of them: {s}\n", .{ line, writeList(c, escapes_path, text.written()) });
}

/// Whether `escape` is written in the older form, `// aegis: <reason>: <why>`, naming no rule.
fn olderForm(project: *const glint.Project, escape: glint.Report.Escape) bool {
    const bytes = project.inputs[escape.span.file.raw()].bytes;
    const comment = bytes[@min(escape.span.start, bytes.len)..];
    const marker = "aegis:";
    const after = std.mem.trimStart(u8, comment[(std.mem.find(u8, comment, marker) orelse return false) + marker.len ..], " ");
    return !std.mem.startsWith(u8, after[@min(escape.reason.len, after.len)..], "(");
}

/// Every aegis escape of a lint, relative to the package; empty after a run with none.
pub const escapes_path = ".zig-cache/preflight-lint/escapes.txt";

/// In a hosted job, the whole list of incomplete sites in the job's summary too,
/// when the run's report holds only the first `printed`.
fn summarizeSites(c: *src.Context, sites: []const u8) void {
    const dir = c.directory();
    // glint-ignore: Z026 -- a summary that cannot be written leaves the file, named in the report
    if (c.summary_path) |path| appendTo(c.*, dir, path, c.a.print("<details><summary>glint: every incomplete site</summary>\n\n```\n{s}```\n</details>\n", .{sites}) catch @panic("OOM")) catch {};
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
pub const sites_path = ".zig-cache/preflight-lint/incomplete.txt";

/// Every finding of a lint, relative to the package; empty after a run with none.
pub const findings_path = ".zig-cache/preflight-lint/findings.txt";

fn appendTo(c: src.Context, dir: std.Io.Dir, path: []const u8, text: []const u8) !void {
    const file = try dir.createFile(c.io, path, .{ .truncate = false, .read = true });
    defer file.close(c.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(c.io, &buffer);
    writer.pos = (try file.stat(c.io)).size;
    try writer.interface.writeAll(text);
    try writer.interface.flush();
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
        self.c = .{ .a = self.arena.allocator(), .io = std.testing.io, .dir = .{ .data = self.tmp.dir } };
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
        try check(&self.c, .{ .gpa = std.testing.allocator, .config = try parsed(self.c.a, config), .build = build });
        return self.c.errors;
    }
};

test "a clean repository passes and one finding of the policy's gate fails it" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.file("src/root.zig", "pub fn answer() u32 {\n    return 42;\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"]}", .{}));
    // A pointer conversion is a danger site: it carries the aegis escape.
    try f.file("src/root.zig", "pub fn run(p: *const u8) *const u8 {\n    return @ptrCast(p);\n}\n");
    try std.testing.expect(try f.run("{\"glint_paths\":[\"src\"]}", .{}) != 0);
    try f.file("src/root.zig", "pub fn run(p: *const u8) *const u8 {\n    return @ptrCast(p); // aegis: no-danger(A019): the same type\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"],\"glint\":{\"escapes\":{\"no-danger\":{\"A019\":1}}}}", .{}));
    // A discarded error fails unless its reason is written at the site; a repository cannot
    // lower it to a report.
    try f.file("src/root.zig", "pub fn drop(f: anytype) void {\n    f() catch {};\n}\n");
    const reported = "{\"glint_paths\":[\"src\"],\"glint\":{\"rules\":[{\"id\":\"Z026\",\"level\":\"report\"}]}}";
    try std.testing.expect(try f.run("{\"glint_paths\":[\"src\"]}", .{}) != 0);
    try std.testing.expect(try f.run(reported, .{}) != 0);
    try f.file("src/root.zig", "pub fn drop(f: anytype) void {\n    // glint-ignore: Z026 -- cleanup after a failure the caller already gets\n    f() catch {};\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"]}", .{}));
}

test "a clean run leaves its lists empty, not as the run before it wrote them" {
    const f = try Fixture.init();
    defer f.deinit();
    // More findings than the run prints, an escape, and an escape that covers nothing.
    var dirty: std.Io.Writer.Allocating = .init(f.c.a);
    for (0..printed + 1) |i| try dirty.writer.print("pub fn view{d}(p: *u8) *u32 {{\n    return @ptrCast(@alignCast(p));\n}}\n", .{i});
    try dirty.writer.writeAll("pub fn same(p: *const u8) *const u8 {\n    return @ptrCast(p); // aegis: no-danger: the same type\n}\n");
    try dirty.writer.writeAll("pub fn plain() u32 {\n    return 1; // aegis: no-danger: nothing here\n}\n");
    try f.file("src/root.zig", dirty.written());
    try std.testing.expect(try f.run("{\"glint_paths\":[\"src\"]}", .{}) != 0);
    for ([_][]const u8{ findings_path, sites_path, escapes_path }) |path| try std.testing.expect((try f.c.read(path)).len != 0);
    try f.file("src/root.zig", "pub fn answer() u32 {\n    return 42;\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"]}", .{}));
    for ([_][]const u8{ findings_path, sites_path, escapes_path }) |path| try std.testing.expectEqualStrings("", try f.c.read(path));
}

test "style is reported and does not fail; a repository may gate it" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.file("src/root.zig", "pub const BadName = 1;\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"]}", .{}));
    try std.testing.expect(try f.run("{\"glint_paths\":[\"src\"],\"glint\":{\"rules\":[{\"id\":\"Z006\",\"level\":\"gate\"}]}}", .{}) != 0);
}

test "glint reads ranges at the pointer widths of the workflow's targets and of this machine" {
    if (@import("builtin").target.ptrBitWidth() != 64) return error.SkipZigTest;
    const f = try Fixture.init();
    defer f.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try pointerWidths(&f.c)).len);
    try f.file("ci/workflow.json", "{\"targets\":[\"x86_64-linux-gnu\",{\"target\":\"aarch64-macos\",\"cpu\":\"apple_m1\"}]}");
    try std.testing.expectEqualSlices(u16, &.{64}, try pointerWidths(&f.c));
    try f.file("ci/workflow.json", "{\"targets\":[\"x86_64-linux-gnu\",\"wasm32-freestanding\"]}");
    try std.testing.expectEqualSlices(u16, &.{ 64, 32 }, try pointerWidths(&f.c));
}

test "a danger site fails in production unless it carries the aegis escape; tests are not shipped, a vendored file is" {
    const f = try Fixture.init();
    defer f.deinit();
    const cast = "pub fn view(p: *u8) *u32 {\n    return @ptrCast(@alignCast(p));\n}\n";
    const paths = "{\"glint_paths\":[\"src\"]}";
    try f.file("src/root.zig", cast);
    try std.testing.expect(try f.run(paths, .{}) != 0);
    try f.file("src/root.zig", "pub fn view(p: *u8) *u32 {\n    return @ptrCast(@alignCast(p)); // aegis: boundary(A019): p points at a u32 the kernel wrote\n}\n");
    // The package holds the findings its escapes cover, by reason and rule: one more than
    // `glint.escapes` holds fails, and one fewer fails until the count comes down.
    const held = "{\"glint_paths\":[\"src\"],\"glint\":{\"escapes\":{\"boundary\":{\"A019\":2}}}}";
    try std.testing.expect(try f.run(paths, .{}) != 0);
    try std.testing.expectEqual(@as(usize, 0), try f.run(held, .{}));
    try std.testing.expect(try f.run("{\"glint_paths\":[\"src\"],\"glint\":{\"escapes\":{\"boundary\":{\"A019\":3}}}}", .{}) != 0);
    try std.testing.expect(try f.run("{\"glint_paths\":[\"src\"],\"glint\":{\"escapes\":{\"no-danger\":{\"A019\":2}}}}", .{}) != 0);
    // An escape widened to a rule it did not cover is a new pair, however many escapes there
    // are: here it would hide an input's conversion (review-1029 M3), which a landing reports
    // and a release fails.
    // The read is std's, so the input fact needs std itself.
    const with_std: assembly.Build = .{ .std_dir = @import("test_options").zig_std };
    const read = "pub fn view(p: *u8, r: *@import(\"std\").Io.Reader) !*u32 {\n    const n = try r.takeInt(u64, .little);\n    if (@as(u32, @intCast(n)) == 7) return error.X; return @ptrCast(@alignCast(p)); // aegis: ";
    try f.file("src/root.zig", read ++ "boundary(A019): p points at a u32 the kernel wrote\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run(held, with_std));
    try f.file("src/root.zig", read ++ "boundary(A019, A010): p points at a u32 the kernel wrote\n}\n");
    try std.testing.expect(try f.run(held, with_std) != 0);
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"],\"glint\":{\"escapes\":{\"boundary\":{\"A019\":2,\"A010\":1}}}}", with_std));
    // An escape in the older form names no rule, so it covers nothing it is held to: counted
    // apart in the report and in the file, never against `glint.escapes` (review-1029b m-b).
    var report: std.Io.Writer.Allocating = .init(f.c.a);
    f.c.held = &report;
    try f.file("src/root.zig", "pub fn view(p: *u8) *u32 {\n    return @ptrCast(@alignCast(p)); // aegis: boundary: p points at a u32 the kernel wrote\n}\n");
    try std.testing.expect(try f.run(held, .{}) != 0);
    try std.testing.expect(std.mem.find(u8, report.written(), "below the 2 `glint.escapes` holds") != null);
    const older = "preflight: escapes: 1 (1 in the older form, naming no rule, so covering nothing: `zig build fix` names their rules)";
    try std.testing.expect(std.mem.find(u8, report.written(), older) != null);
    try std.testing.expect(std.mem.find(u8, try f.c.read(escapes_path), older) != null);
    f.c.held = null;
    try f.file("src/root.zig", "pub fn view(p: *u8) *u32 {\n    return @ptrCast(@alignCast(p)); // aegis: boundary(A019): p points at a u32 the kernel wrote\n}\n");
    // An escape needs one of the five reasons and a why, and the pack takes no other suppression.
    try f.file("src/root.zig", "pub fn view(p: *u8) *u32 {\n    return @ptrCast(@alignCast(p)); // aegis: fast: it is\n}\n");
    try std.testing.expect(try f.run(paths, .{}) != 0);
    try f.file("src/root.zig", "pub fn view(p: *u8) *u32 {\n    return @ptrCast(@alignCast(p)); // glint-ignore: A019 -- boundary\n}\n");
    try std.testing.expect(try f.run(paths, .{}) != 0);
    try f.file("src/root.zig", "pub const x = 1;\n");
    try f.file("src/root_test.zig", cast);
    try f.file("src/testing/harness.zig", cast);
    try std.testing.expectEqual(@as(usize, 0), try f.run(paths, .{}));
    try f.file("src/root_test.zig", "pub const t = 1;\n");
    try f.file("src/testing/harness.zig", "pub const h = 1;\n");
    // An upstream's file kept unchanged: its verification is the reason its danger sites carry,
    // while it is the copy the entry's SHA-256 names, and an undecided site is still undecided.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(cast, &digest, .{});
    const entry = "{{\"glint_paths\":[\"src\"],\"vendored\":{{\"src/vendor/fiat.zig\":{{\"upstream\":\"fiat-crypto\",\"verification\":\"fiat's CI regenerates it\",\"sha256\":\"{x}\"}}}}}}";
    var buffer: [512]u8 = undefined;
    var vendored: std.Io.Writer = .fixed(&buffer);
    try vendored.print(entry, .{&digest});
    try f.file("src/vendor/fiat.zig", cast);
    try std.testing.expectEqual(@as(usize, 0), try f.run(vendored.buffered(), .{}));
    try f.file("src/vendor/fiat.zig", cast ++ "pub const edited = 1;\n");
    try std.testing.expect(try f.run(vendored.buffered(), .{}) != 0);
    const undecided = "const flags = struct { var checked: bool = true; };\npub fn f() void {\n    @setRuntimeSafety(flags.checked);\n}\n";
    std.crypto.hash.sha2.Sha256.hash(undecided, &digest, .{});
    try f.file("src/vendor/fiat.zig", undecided);
    vendored = .fixed(&buffer);
    try vendored.print(entry, .{&digest});
    try std.testing.expect(try f.run(vendored.buffered(), .{}) != 0);
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
    try config.print("{{\"glint_paths\":[\"src\"],\"vendored\":{{\"src/vendor/fiat.zig\":{{\"upstream\":\"fiat-crypto\",\"verification\":\"fiat's CI regenerates it\",\"sha256\":\"{x}\"}}}}}}", .{&digest});
    try std.testing.expect(try f.run(config.buffered(), .{}) != 0);
    const list = try f.tmp.dir.readFileAlloc(f.c.io, findings_path, f.c.a, .limited(1 << 20));
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

test "a finding rule's undecided sites count against the repository's ceiling, which may not grow" {
    const f = try Fixture.init();
    defer f.deinit();
    // `@setRuntimeSafety` with a computed argument: A019 cannot decide it.
    try f.file("src/root.zig", "pub fn run(comptime on: bool) void {\n    @setRuntimeSafety(on);\n}\n");
    try std.testing.expect(try f.run("{\"glint_paths\":[\"src\"]}", .{}) != 0);
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"],\"glint\":{\"unresolved\":{\"A019\":1}}}", .{}));
    // A ceiling above the count passes and asks to come down.
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"],\"glint\":{\"unresolved\":{\"A019\":3}}}", .{}));
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

test "a debug print and a deprecated call are findings the standard library's declarations decide" {
    const f = try Fixture.init();
    defer f.deinit();
    // The standard library of the Zig that builds these tests: the durability door and the
    // danger rules name its declarations, as they do in every repository.
    const build: assembly.Build = .{ .std_dir = @import("test_options").zig_std };
    const paths = "{\"glint_paths\":[\"src\"]}";
    try f.file("src/root.zig", "const std = @import(\"std\");\npub fn run() void {\n    std.debug.print(\"hi\", .{});\n}\n");
    try std.testing.expect(try f.run(paths, build) != 0);
    // The same code without the standard library's declarations is unresolved, not a finding.
    try std.testing.expectEqual(@as(usize, 0), try f.run(paths, .{}));
    try f.file("src/root.zig", "const std = @import(\"std\");\npub fn run() void {\n    std.debug.print(\"hi\", .{}); // glint-ignore: P005 -- the tool's one line of output\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run(paths, build));
    try f.file("src/root.zig", "const std = @import(\"std\");\npub fn run(text: []const u8) ?usize {\n    return std.mem.indexOfScalar(u8, text, 'x');\n}\n");
    try std.testing.expect(try f.run(paths, build) != 0);
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
    try f.file("src/root.zig", "const std = @import(\"std\");\npub fn run() void {\n    _ = std.mem;\n}\n");
    try std.testing.expectEqual(@as(usize, 0), try f.run("{" ++ paths ++ "}", .{}));
    try std.testing.expect(try f.run("{" ++ paths ++ ",\"glint\":{\"fact_budget\":1}}", .{}) != 0);
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
    try std.testing.expectEqual(@as(usize, printed), std.mem.count(u8, out, "glint: incomplete: "));
    try std.testing.expect(std.mem.find(u8, out, "glint: 5 more incomplete sites; all 30: " ++ sites_path) != null);
    try std.testing.expect(std.mem.find(u8, out, ", 30 sites incomplete, ") != null);
    const all = try f.c.read(sites_path);
    try std.testing.expectEqual(@as(usize, printed + 5), std.mem.count(u8, all, "glint: incomplete: "));
    const summary = try f.c.read("summary.md");
    try std.testing.expectEqual(@as(usize, printed + 5), std.mem.count(u8, summary, "glint: incomplete: "));
}

test "assertions are counted by the declaration a call resolves to, never by its spelling" {
    const f = try Fixture.init();
    defer f.deinit();
    // A stub standard library: `debug.assert` is the declaration the counts look for.
    try f.file("stdlib/std.zig", "pub const debug = @import(\"debug.zig\");\n");
    try f.file("stdlib/debug.zig", "pub fn assert(ok: bool) void {\n    if (!ok) unreachable; // unreachable: what an assertion is\n}\n");
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
    _ = try f.run("{\"glint_paths\":[\"src\"]}", .{ .std_dir = "stdlib" });
    const out = held.written();
    try std.testing.expect(std.mem.find(u8, out, "preflight: assertions: 1 in 3 functions, 1 of them with one; 0 calls spelled like one unresolved") != null);
    const summary = try f.c.read("summary.md");
    try std.testing.expect(std.mem.find(u8, summary, "| `src/root.zig` | 3 | 1 | 1 | 0 |") != null);
}

/// An `Io` on which every task has been asked to stop.
const Canceled = @import("shakedown").Layer(u8, .{
    .checkCancel = struct {
        fn checkCancel(_: ?*anyopaque) std.Io.Cancelable!void {
            return error.Canceled;
        }
    }.checkCancel,
});

test "a cancel while glint builds the project or runs its rules ends the check with Canceled, never a failure or a pass" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.file("src/root.zig", "pub const x = 1;\n");
    var canceled: Canceled = .init(std.testing.io, 0);
    f.c.io = canceled.io();
    f.c.errors = 0;
    try std.testing.expectError(error.Canceled, check(&f.c, .{ .gpa = std.testing.allocator, .config = try parsed(f.c.a, "{\"glint_paths\":[\"src\"]}") }));
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
        const result = check(&f.c, .{ .gpa = std.testing.allocator, .config = try parsed(f.c.a, "{\"glint_paths\":[\"src\"]}") });
        try std.testing.expectError(failure, result);
        try std.testing.expectEqual(@as(u64, 1), faults.count(.dirOpenFile));
    }
    f.c.io = std.testing.io;
    try std.testing.expectEqual(@as(usize, 0), try f.run("{\"glint_paths\":[\"src\"]}", .{}));
}
