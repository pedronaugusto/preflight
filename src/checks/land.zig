//! `preflight land`: the branch checked out reaches main through the package's own
//! merge gate.
//!
//! The landing commit is made apart from the branch: HEAD is detached, rebased on
//! origin's main, its pins tidied under bay, a changelog line written for the
//! dependencies it re-pins, and the release made and committed. That commit goes to
//! `land/vX.Y.Z` (`land/<branch>` when nothing the package ships changed), the
//! caller runs the merge tier on it with `land`, and the branch goes back to where
//! it was while the run runs. Green: main and the tag are on the commit, the branch
//! follows it and the land branch goes. Red: the failed jobs are named and nothing
//! moves, so landing again makes the same version.
const std = @import("std");
const src = @import("source.zig");
const release = @import("release.zig");
const nested = @import("../nested.zig");

pub const Options = struct {
    /// The release's date, `YYYY-MM-DD`.
    date: []const u8,
    /// Between two looks for the run the dispatch started.
    find_every: std.Io.Duration = .fromSeconds(5),
    /// Looks for that run before the dispatch counts as lost.
    find_attempts: usize = 60,
    /// Between two looks at the run while it runs.
    wait_every: std.Io.Duration = .fromSeconds(20),
};

pub const Outcome = union(enum) {
    /// Main already holds the branch, and the package needs no release.
    nothing: []const u8,
    /// Main and, with a release, its tag are on `sha`.
    landed: struct { name: []const u8, sha: []const u8, followed: bool },
};

/// Why `config` (`ci/workflow.json`) cannot land, or null when it lands and releases.
pub fn refusal(config: src.Value) ?[]const u8 {
    if (!enabled(config, "land")) return "ci/workflow.json does not set `land`, so the caller has no job that moves main";
    if (!enabled(config, "release")) return "ci/workflow.json does not set `release`, so a landing would tag nothing";
    return null;
}

fn enabled(config: src.Value, name: []const u8) bool {
    const value = src.get(config, name);
    return value == .bool and value.bool;
}

/// A dependency pinned at another revision than at the last release, and the version it names.
pub const Repin = struct { name: []const u8, version: []const u8 };

/// The version a Zig package hash names: `<name>-<version>-` before its 44 characters of hash.
pub fn hashVersion(hash: []const u8) ?[]const u8 {
    if (hash.len < 44 + 4 or hash[hash.len - 45] != '-') return null;
    const named = hash[0 .. hash.len - 45];
    const dash = std.mem.findScalar(u8, named, '-') orelse return null;
    return if (dash + 1 < named.len) named[dash + 1 ..] else null;
}

/// The pins of `after` that `before` does not hold: a package pinned at another hash, or new.
pub fn repinned(a: std.mem.Allocator, before: []const nested.Pin, after: []const nested.Pin) ![]const Repin {
    var found: std.ArrayList(Repin) = .empty;
    for (after) |pin| {
        const same = for (before) |old| {
            if (std.mem.eql(u8, old.name, pin.name)) break std.mem.eql(u8, old.hash, pin.hash);
        } else false;
        if (same) continue;
        // A hash that names no version still names the revision its URL ends in.
        const revision = if (std.mem.findScalar(u8, pin.url, '#')) |at| pin.url[at + 1 ..][0..@min(7, pin.url.len - at - 1)] else pin.hash;
        try found.append(a, .{ .name = pin.name, .version = hashVersion(pin.hash) orelse revision });
    }
    return found.items;
}

/// The changelog entry for `repins`: "- Pins a 1.0.0, b 0.2.1 and c 0.3.0."
pub fn repinEntry(a: std.mem.Allocator, repins: []const Repin) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.writeAll("- Pins ");
    for (repins, 0..) |repin, i| {
        const joint = if (i == 0) "" else if (i + 1 == repins.len) " and " else ", ";
        try out.writer.print("{s}{s} {s}", .{ joint, repin.name, repin.version });
    }
    try out.writer.writeAll(".");
    return out.written();
}

/// The changelog with `entry` under `### Changed` in `[Unreleased]`, the heading added at the
/// section's end when it has none; null when `[Unreleased]` already names one of `repins`.
pub fn noteRepins(a: std.mem.Allocator, changelog: []const u8, repins: []const Repin) !?[]const u8 {
    const range = release.unreleasedRange(changelog) orelse return error.NoUnreleasedSection;
    const body = changelog[range.start..range.end];
    for (repins) |repin| if (names(body, repin.name)) return null;
    const entry = try repinEntry(a, repins);
    // The `### Changed` subsection runs to the next heading; a new one follows the section's last line.
    var end = range.end;
    var changed: ?usize = null;
    var offset = range.start;
    while (offset < range.end) {
        const line_end = std.mem.findScalarPos(u8, changelog, offset, '\n') orelse changelog.len;
        const line = std.mem.trim(u8, changelog[offset..line_end], " \t\r");
        if (changed == null and std.mem.eql(u8, line, "### Changed")) {
            changed = line_end;
        } else if (changed != null and std.mem.startsWith(u8, line, "#")) {
            end = offset;
            break;
        }
        offset = line_end + 1;
    }
    // The end of the last line with text before `end`, or of the heading above an empty section.
    const floor = changed orelse range.start - 1;
    const last = floor + std.mem.trimEnd(u8, changelog[floor..end], " \t\r\n").len;
    const insert = if (changed != null) try a.print("{s}{s}", .{ if (last == floor) "\n\n" else "\n", entry }) else try a.print("\n\n### Changed\n\n{s}", .{entry});
    return try std.mem.concat(a, u8, &.{ changelog[0..last], insert, changelog[last..] });
}

/// Whether `text` holds `name` as a word, not inside a longer name.
fn names(text: []const u8, name: []const u8) bool {
    var from: usize = 0;
    while (std.mem.findPos(u8, text, from, name)) |at| {
        const before = at == 0 or !isWord(text[at - 1]);
        const after = at + name.len == text.len or !isWord(text[at + name.len]);
        if (before and after) return true;
        from = at + 1;
    }
    return false;
}

fn isWord(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// A git or gh command's outcome, its output trimmed.
const Ran = struct { ok: bool, out: []const u8, err: []const u8 };

fn exec(c: *src.Context, argv: []const []const u8) !Ran {
    const result = std.process.run(c.a, c.io, .{ .argv = argv, .cwd = c.childCwd(), .environ_map = c.environ_map }) catch |err| switch (err) {
        error.FileNotFound => {
            c.fail("land: {s} is not installed", .{argv[0]});
            return error.LandFailed;
        },
        else => return err,
    };
    return .{ .ok = result.term == .exited and result.term.exited == 0, .out = std.mem.trim(u8, result.stdout, " \t\r\n"), .err = std.mem.trim(u8, result.stderr, " \t\r\n") };
}

fn git(c: *src.Context, args: []const []const u8) !Ran {
    return exec(c, try std.mem.concat(c.a, []const u8, &.{ &.{"git"}, args }));
}

/// `git <args>`, which must succeed; a failure is reported with what git said.
fn must(c: *src.Context, args: []const []const u8) ![]const u8 {
    const ran = try git(c, args);
    if (ran.ok) return ran.out;
    c.fail("land: git {s}: {s}", .{ try std.mem.join(c.a, " ", args), ran.err });
    return error.LandFailed;
}

fn gh(c: *src.Context, args: []const []const u8) !src.Value {
    const ran = try exec(c, try std.mem.concat(c.a, []const u8, &.{ &.{"gh"}, args }));
    if (!ran.ok) {
        c.fail("land: gh {s}: {s}", .{ try std.mem.join(c.a, " ", args[0..@min(2, args.len)]), ran.err });
        return error.LandFailed;
    }
    if (ran.out.len == 0) return .null;
    return (std.json.parseFromSlice(src.Value, c.a, ran.out, .{}) catch {
        c.fail("land: gh {s} answered with something other than JSON", .{try std.mem.join(c.a, " ", args[0..@min(2, args.len)])});
        return error.LandFailed;
    }).value;
}

/// The caller generated from `ci/workflow.json` for this package: the workflow file under the
/// repository's `.github/workflows` whose gate runs in the package's directory.
fn caller(c: *src.Context) ![]const u8 {
    const top = try must(c, &.{ "rev-parse", "--show-toplevel" });
    const prefix = std.mem.trimEnd(u8, try must(c, &.{ "rev-parse", "--show-prefix" }), "/");
    const wanted = try c.a.print("      working-directory: {s}\n", .{try std.json.Stringify.valueAlloc(c.a, if (prefix.len == 0) "." else prefix, .{})});
    const folder = try std.Io.Dir.path.join(c.a, &.{ top, ".github", "workflows" });
    var found: std.ArrayList([]const u8) = .empty;
    if (std.Io.Dir.cwd().openDir(c.io, folder, .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(c.io);
        var entries = dir.iterate();
        while (try entries.next(c.io)) |entry| {
            if (entry.kind != .file or !(std.mem.endsWith(u8, entry.name, ".yml") or std.mem.endsWith(u8, entry.name, ".yaml"))) continue;
            const text = try dir.readFileAlloc(c.io, entry.name, c.a, .limited(16 * 1024 * 1024));
            if (std.mem.startsWith(u8, text, "# Generated by preflight from ci/workflow.json") and std.mem.find(u8, text, wanted) != null) try found.append(c.a, try c.a.dupe(u8, entry.name));
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    if (found.items.len == 1) return found.items[0];
    if (found.items.len == 0) {
        c.fail("land: no workflow in .github/workflows is the caller generated from ci/workflow.json for this package; generate it with plan -- --workflow .github/workflows/ci.yml", .{});
    } else c.fail("land: {s} are each a caller of this package; keep one", .{try std.mem.join(c.a, ", ", found.items)});
    return error.LandFailed;
}

/// What the landing commit is: its ref on origin and, with a release, its version.
const Prepared = struct { sha: []const u8, version: ?release.Version };

/// Lands the branch checked out; every failure is reported, and `error.LandFailed` says so.
pub fn run(c: *src.Context, options: Options) !Outcome {
    if (refusal(try c.options("ci/workflow.json"))) |why| {
        c.fail("land: {s}", .{why});
        return error.LandFailed;
    }
    const branch = (try git(c, &.{ "symbolic-ref", "--short", "-q", "HEAD" })).out;
    if (branch.len == 0) {
        c.fail("land: HEAD is detached; check out the branch to land", .{});
        return error.LandFailed;
    }
    if ((try must(c, &.{ "status", "--porcelain" })).len != 0) {
        c.fail("land: the tree has changes; commit or stash them first", .{});
        return error.LandFailed;
    }
    const workflow = try caller(c);
    _ = try must(c, &.{ "fetch", "-q", "--prune", "--tags", "origin" });
    const start = try must(c, &.{ "rev-parse", "HEAD" });
    const main = (try git(c, &.{ "rev-parse", "--verify", "-q", "refs/remotes/origin/main" })).out;
    if (main.len == 0) {
        c.fail("land: origin has no main to land on", .{});
        return error.LandFailed;
    }
    _ = try must(c, &.{ "checkout", "-q", "--detach" });
    const prepared = prepare(c, branch, options.date) catch |err| {
        back(c, branch);
        return err;
    };
    const ref = if (prepared.version) |version| try c.a.print("land/v{f}", .{version}) else try c.a.print("land/{s}", .{branch});
    if (prepared.version == null and std.mem.eql(u8, prepared.sha, main)) {
        back(c, branch);
        return .{ .nothing = try c.a.print("main holds {s}, and nothing the package ships changed since its last release", .{branch}) };
    }
    push(c, ref) catch |err| {
        back(c, branch);
        return err;
    };
    _ = try must(c, &.{ "checkout", "-q", branch });
    try say(c, "pushed {s} at {s}\n", .{ ref, prepared.sha[0..12] });
    try gate(c, workflow, ref, prepared.sha, options);
    return finish(c, branch, start, ref, prepared);
}

/// On a detached HEAD at the branch: rebased on origin's main, tidied, the changelog told of
/// re-pins, released and committed.
fn prepare(c: *src.Context, branch: []const u8, date: []const u8) !Prepared {
    const rebased = try git(c, &.{ "rebase", "-q", "refs/remotes/origin/main" });
    if (!rebased.ok) {
        const conflicts = (try git(c, &.{ "diff", "--name-only", "--diff-filter=U" })).out;
        _ = try git(c, &.{ "rebase", "--abort" });
        var files = std.mem.tokenizeScalar(u8, conflicts, '\n');
        var listed: std.ArrayList([]const u8) = .empty;
        while (files.next()) |file| try listed.append(c.a, file);
        if (listed.items.len == 0) {
            c.fail("land: {s} does not rebase on origin/main: {s}", .{ branch, rebased.err });
        } else c.fail("land: {s} conflicts with origin/main in {s}; rebase it by hand, then land", .{ branch, try std.mem.join(c.a, ", ", listed.items) });
        return error.LandFailed;
    }
    if (c.bay) |bay| {
        const tidied = try exec(c, &.{ bay, "tidy" });
        if (!tidied.ok) {
            c.fail("land: bay tidy: {s}", .{tidied.err});
            return error.LandFailed;
        }
    }
    try noteChangelog(c);
    const outcome = release.run(c, date) catch |err| switch (err) {
        // Each of these named its fix.
        error.InvalidVersion, error.InvalidManifest, error.NoChangelog, error.NoUnreleasedSection, error.EmptyUnreleased, error.TagExists => return error.LandFailed,
        else => return err,
    };
    const version: ?release.Version = switch (outcome) {
        .unchanged => null,
        .prepared => |version| version,
        .released => |made| made.to,
    };
    if ((try must(c, &.{ "status", "--porcelain", "--untracked-files=no" })).len != 0) {
        _ = try must(c, &.{ "add", "-u" });
        const message = if (version) |v| try c.a.print("Release v{f}", .{v}) else "Pin each dependency at its release";
        _ = try must(c, &.{ "commit", "-q", "-m", message });
    }
    return .{ .sha = try must(c, &.{ "rev-parse", "HEAD" }), .version = version };
}

/// A changelog line for the dependencies pinned at another revision than at the last release,
/// unless `[Unreleased]` names one of them already.
fn noteChangelog(c: *src.Context) !void {
    const tag = try release.lastTag(c.*) orelse return;
    const released = try git(c, &.{ "show", try c.a.print("{s}:./build.zig.zon", .{tag}) });
    if (!released.ok) return;
    const before = nested.pins(c.a, released.out) catch return;
    const after = nested.pins(c.a, try c.read("build.zig.zon")) catch {
        c.fail("land: build.zig.zon: not a manifest preflight can read", .{});
        return error.LandFailed;
    };
    const repins = try repinned(c.a, before, after);
    if (repins.len == 0 or !c.exists("CHANGELOG.md")) return;
    const changelog = try c.read("CHANGELOG.md");
    const noted = noteRepins(c.a, changelog, repins) catch |err| switch (err) {
        // The release names this fix.
        error.NoUnreleasedSection => return,
        else => return err,
    } orelse return;
    try c.directory().writeFile(c.io, .{ .sub_path = "CHANGELOG.md", .data = noted });
}

/// Pushes HEAD to `ref` on origin. A land branch an earlier, red landing left is replaced, and
/// only if it is still what this clone last fetched.
fn push(c: *src.Context, ref: []const u8) !void {
    const tracked = (try git(c, &.{ "rev-parse", "-q", "--verify", try c.a.print("refs/remotes/origin/{s}", .{ref}) })).out;
    _ = try must(c, &.{ "push", "-q", try c.a.print("--force-with-lease=refs/heads/{s}:{s}", .{ ref, tracked }), "origin", try c.a.print("HEAD:refs/heads/{s}", .{ref}) });
}

/// Back on `branch` as it was, after a landing commit that went nowhere.
fn back(c: *src.Context, branch: []const u8) void {
    const reset = git(c, &.{ "reset", "-q", "--hard" }) catch return;
    const checkout = git(c, &.{ "checkout", "-q", branch }) catch return;
    if (!reset.ok or !checkout.ok) c.fail("land: could not check {s} out again: {s}", .{ branch, if (checkout.ok) reset.err else checkout.err });
}

/// Dispatches the merge tier with `land` on `ref` and waits for the run; red reports the failed jobs.
fn gate(c: *src.Context, workflow: []const u8, ref: []const u8, sha: []const u8, options: Options) !void {
    const list: []const []const u8 = &.{ "run", "list", "--workflow", workflow, "--branch", ref, "--event", "workflow_dispatch", "--limit", "50", "--json", "databaseId,headSha,url" };
    // A run of an earlier landing of the same commit is not this one.
    const earlier = try gh(c, list);
    _ = try gh(c, &.{ "workflow", "run", workflow, "--ref", ref, "-f", "tier=merge", "-f", "land=true" });
    const id = find: for (0..options.find_attempts) |attempt| {
        if (attempt != 0) try std.Io.sleep(c.io, options.find_every, .awake);
        for (src.items(try gh(c, list))) |found| {
            if (!std.mem.eql(u8, src.string(src.get(found, "headSha"), ""), sha)) continue;
            const number = src.get(found, "databaseId");
            if (number != .integer) continue;
            const seen = for (src.items(earlier)) |old| {
                const known = src.get(old, "databaseId");
                if (known == .integer and known.integer == number.integer) break true;
            } else false;
            if (!seen) break :find number.integer;
        }
    } else {
        c.fail("land: the dispatch on {s} started no run that GitHub lists; look at the caller's runs", .{ref});
        return error.LandFailed;
    };
    const id_text = try c.a.print("{d}", .{id});
    var announced = false;
    while (true) {
        const view = try gh(c, &.{ "run", "view", id_text, "--json", "status,conclusion,url,jobs" });
        const url = src.string(src.get(view, "url"), id_text);
        if (!announced) try say(c, "run {s}\n", .{url});
        announced = true;
        if (!std.mem.eql(u8, src.string(src.get(view, "status"), ""), "completed")) {
            try std.Io.sleep(c.io, options.wait_every, .awake);
            continue;
        }
        const conclusion = src.string(src.get(view, "conclusion"), "");
        if (std.mem.eql(u8, conclusion, "success")) return;
        c.fail("land: {s} is red ({s}): {s}", .{ ref, if (conclusion.len == 0) "no conclusion" else conclusion, url });
        for (src.items(src.get(view, "jobs"))) |job| {
            const ended = src.string(src.get(job, "conclusion"), "");
            if (ended.len == 0 or std.mem.eql(u8, ended, "success") or std.mem.eql(u8, ended, "skipped") or std.mem.eql(u8, ended, "neutral")) continue;
            c.report("  {s} ({s})\n", .{ src.string(src.get(job, "name"), "a job"), ended });
        }
        c.report("the branch is as it was, and {s} stays on origin\n", .{ref});
        return error.LandFailed;
    }
}

/// After a green run: main and the tag are on the tested commit, the branch follows it unless
/// it moved meanwhile, and the land branch goes.
fn finish(c: *src.Context, branch: []const u8, start: []const u8, ref: []const u8, prepared: Prepared) !Outcome {
    _ = try must(c, &.{ "fetch", "-q", "--prune", "--tags", "origin" });
    const main = try must(c, &.{ "rev-parse", "refs/remotes/origin/main" });
    if (!std.mem.eql(u8, main, prepared.sha)) {
        c.fail("land: the run passed, but origin/main is at {s}, not at the tested {s}", .{ main, prepared.sha });
        return error.LandFailed;
    }
    const name = if (prepared.version) |version| try c.a.print("v{f}", .{version}) else branch;
    if (prepared.version != null) {
        const tagged = (try git(c, &.{ "rev-parse", "-q", "--verify", try c.a.print("refs/tags/{s}^{{commit}}", .{name}) })).out;
        if (!std.mem.eql(u8, tagged, prepared.sha)) {
            c.fail("land: main moved to {s}, but the tag {s} is not on it", .{ prepared.sha, name });
            return error.LandFailed;
        }
    }
    // The branch follows unless it moved while the run ran.
    const here = (try git(c, &.{ "symbolic-ref", "--short", "-q", "HEAD" })).out;
    const followed = std.mem.eql(u8, here, branch) and std.mem.eql(u8, try must(c, &.{ "rev-parse", "HEAD" }), start);
    if (followed) {
        // Rebased commits are not a fast-forward of the branch; they are the branch.
        const ahead = (try git(c, &.{ "merge-base", "--is-ancestor", start, prepared.sha })).ok;
        _ = try must(c, if (ahead) &.{ "merge", "-q", "--ff-only", prepared.sha } else &.{ "reset", "-q", "--keep", prepared.sha });
    }
    _ = try must(c, &.{ "push", "-q", "origin", "--delete", ref });
    return .{ .landed = .{ .name = name, .sha = prepared.sha, .followed = followed } };
}

fn say(c: *src.Context, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(c.io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

// Tests ------------------------------------------------------------------

test "a landing needs land and release set in ci/workflow.json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parse = struct {
        fn value(allocator: std.mem.Allocator, text: []const u8) !src.Value {
            return (try std.json.parseFromSlice(src.Value, allocator, text, .{})).value;
        }
    }.value;
    try std.testing.expect(refusal(.{ .object = .empty }) != null);
    try std.testing.expect(std.mem.find(u8, refusal(try parse(a, "{\"release\":true}")).?, "`land`") != null);
    try std.testing.expect(std.mem.find(u8, refusal(try parse(a, "{\"land\":true}")).?, "`release`") != null);
    try std.testing.expect(std.mem.find(u8, refusal(try parse(a, "{\"land\":true,\"release\":\"yes\"}")).?, "`release`") != null);
    try std.testing.expect(refusal(try parse(a, "{\"land\":true,\"release\":true}")) == null);
}

const hash_tail = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

test "a hash names the version of the package it pins" {
    try std.testing.expectEqualStrings("0.2.0", hashVersion("glint-0.2.0-" ++ hash_tail).?);
    try std.testing.expectEqualStrings("1.0.0-rc.1", hashVersion("glint-1.0.0-rc.1-" ++ hash_tail).?);
    try std.testing.expect(hashVersion("glint-" ++ hash_tail) == null);
    try std.testing.expect(hashVersion("1220abcdef") == null);
}

test "the dependencies re-pinned since the release are the ones at another hash, or new" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try nested.pins(a, ".{ .dependencies = .{ .gantry = .{ .url = \"git+https://e.invalid/gantry#1111111\", .hash = \"gantry-0.1.0-" ++ hash_tail ++ "\" }, .glint = .{ .url = \"git+https://e.invalid/glint#2222222\", .hash = \"glint-0.1.0-" ++ hash_tail ++ "\" } }, .dev_dependencies = .{ .shakedown = .{ .url = \"u\", .hash = \"shakedown-0.1.0-" ++ hash_tail ++ "\" } } }");
    const after = try nested.pins(a, ".{ .dependencies = .{ .gantry = .{ .url = \"git+https://e.invalid/gantry#3333333\", .hash = \"gantry-0.1.4-" ++ hash_tail ++ "\" }, .glint = .{ .url = \"git+https://e.invalid/glint#2222222\", .hash = \"glint-0.1.0-" ++ hash_tail ++ "\" }, .aegis = .{ .url = \"git+https://e.invalid/aegis#abcdef0123\", .hash = \"aegis\" } }, .dev_dependencies = .{ .shakedown = .{ .url = \"u\", .hash = \"shakedown-0.2.0-" ++ hash_tail ++ "\" } } }");
    const found = try repinned(a, before, after);
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqualStrings("gantry", found[0].name);
    try std.testing.expectEqualStrings("0.1.4", found[0].version);
    // A hash without a version names the revision.
    try std.testing.expectEqualStrings("aegis", found[1].name);
    try std.testing.expectEqualStrings("abcdef0", found[1].version);
    try std.testing.expectEqualStrings("shakedown", found[2].name);
    try std.testing.expectEqualStrings("0.2.0", found[2].version);
    try std.testing.expectEqual(@as(usize, 0), (try repinned(a, after, after)).len);
}

test "the changelog line names each re-pinned dependency under Changed, once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one: []const Repin = &.{.{ .name = "gantry", .version = "0.1.4" }};
    const three: []const Repin = &.{ .{ .name = "gantry", .version = "0.1.4" }, .{ .name = "glint", .version = "0.2.0" }, .{ .name = "sweep", .version = "0.1.1" } };
    try std.testing.expectEqualStrings("- Pins gantry 0.1.4.", try repinEntry(a, one));
    try std.testing.expectEqualStrings("- Pins gantry 0.1.4, glint 0.2.0 and sweep 0.1.1.", try repinEntry(a, three));
    const tail = "## [0.1.0] - 2026-01-01\n\n- First.\n\n[Unreleased]: https://e.invalid/compare/v0.1.0...HEAD\n";
    // An empty section gets the heading.
    try std.testing.expectEqualStrings("# Changelog\n\n## [Unreleased]\n\n### Changed\n\n- Pins gantry 0.1.4.\n\n" ++ tail, (try noteRepins(a, "# Changelog\n\n## [Unreleased]\n\n" ++ tail, one)).?);
    // Entries under another heading keep it; the new heading follows them.
    try std.testing.expectEqualStrings("## [Unreleased]\n\n### Fixed\n\n- A fix.\n\n### Changed\n\n- Pins gantry 0.1.4.\n\n" ++ tail, (try noteRepins(a, "## [Unreleased]\n\n### Fixed\n\n- A fix.\n\n" ++ tail, one)).?);
    // An existing Changed takes the line after its entries, before the next heading.
    try std.testing.expectEqualStrings("## [Unreleased]\n\n### Changed\n\n- Faster.\n- Pins gantry 0.1.4.\n\n### Fixed\n\n- A fix.\n\n" ++ tail, (try noteRepins(a, "## [Unreleased]\n\n### Changed\n\n- Faster.\n\n### Fixed\n\n- A fix.\n\n" ++ tail, one)).?);
    try std.testing.expectEqualStrings("## [Unreleased]\n\n### Changed\n\n- Pins gantry 0.1.4.\n\n### Fixed\n\n- A fix.\n", (try noteRepins(a, "## [Unreleased]\n\n### Changed\n\n### Fixed\n\n- A fix.\n", one)).?);
    // A section that names a re-pinned dependency already says what it means; another name does not count.
    try std.testing.expect(try noteRepins(a, "## [Unreleased]\n\n### Changed\n\n- Takes glint's new rules.\n\n" ++ tail, three) == null);
    try std.testing.expect(try noteRepins(a, "## [Unreleased]\n\n- Takes gantry_extra.\n\n" ++ tail, one) != null);
    // A name in an earlier release is not in [Unreleased].
    try std.testing.expect(try noteRepins(a, "## [Unreleased]\n\n## [0.1.0] - x\n\n- Pins gantry 0.1.0.\n", one) != null);
    try std.testing.expectError(error.NoUnreleasedSection, noteRepins(a, "# Changelog\n", one));
}
