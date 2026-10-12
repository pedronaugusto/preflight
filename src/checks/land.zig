//! `preflight land`: the branch checked out reaches origin's default branch, main below,
//! through the package's own merge gate.
//!
//! The landing commit is made apart from the branch, in a worktree of its own detached at
//! it, so the branch, its checkout and its tree are never touched: rebased on origin's main,
//! its pins tidied under bay, the caller generated again when it names another preflight than
//! the manifest pins, a changelog line written for the dependencies it re-pins, and the
//! release made and committed. That commit goes to a ref of its own, `land/vX.Y.Z-<sha>`
//! (`land/<branch>-<sha>` when nothing the package ships changed), so no push ever replaces
//! one, and the caller runs the merge tier on it with `land`. Green: main holds the commit and
//! the tag is on it, the branch follows when it has not moved, and the attempts at that
//! version no landing needs go. Red: the failed jobs are named and nothing moves, so landing
//! again makes the same version, and the red attempt's ref stays to be looked at.
const std = @import("std");
const src = @import("source.zig");
const release = @import("release.zig");
const nested = @import("../nested.zig");
const workflow = @import("workflow.zig");

pub const Options = struct {
    /// The release's date, `YYYY-MM-DD`.
    date: []const u8,
    /// Between two looks for the run the dispatch started.
    find_every: std.Io.Duration = .fromSeconds(5),
    /// Looks for that run before the dispatch counts as lost.
    find_attempts: usize = 60,
    /// Between two looks at the run while it runs.
    wait_every: std.Io.Duration = .fromSeconds(20),
    /// Failed looks in a row, at the run or for it, that end the landing: GitHub or the
    /// connection to it failing for a moment says nothing of the run.
    gh_failures: usize = 10,
};

pub const Outcome = union(enum) {
    /// The default branch already holds the branch, and the package needs no release.
    nothing: []const u8,
    /// The default branch, `onto`, holds `sha`, and with a release its tag is on it.
    landed: struct { name: []const u8, onto: []const u8, sha: []const u8, followed: bool },
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

/// `gh <args> --repo <repo>`'s JSON, which must come; a failure is reported with what gh said.
fn gh(c: *src.Context, repo: []const u8, args: []const []const u8) !src.Value {
    const ran = try exec(c, try std.mem.concat(c.a, []const u8, &.{ &.{"gh"}, args, &.{ "--repo", repo } }));
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

/// The GitHub repository a remote's URL names, as gh's `--repo` takes it: `OWNER/NAME` on
/// github.com, `HOST/OWNER/NAME` on another host. Null for a URL that names none, a local path
/// among them. Both forms of each: `https://host/owner/name.git`, `ssh://git@host/owner/name`,
/// `git@host:owner/name.git`.
pub fn repository(a: std.mem.Allocator, url: []const u8) !?[]const u8 {
    var authority: []const u8 = undefined;
    var path: []const u8 = undefined;
    if (std.mem.find(u8, url, "://")) |at| {
        const rest = url[at + 3 ..];
        const slash = std.mem.findScalar(u8, rest, '/') orelse return null;
        authority = rest[0..slash];
        path = rest[slash + 1 ..];
    } else {
        // scp-like `[user@]host:path`; a path with a slash before the colon is a local one.
        const colon = std.mem.findScalar(u8, url, ':') orelse return null;
        authority = url[0..colon];
        if (std.mem.findAny(u8, authority, "/\\") != null) return null;
        path = url[colon + 1 ..];
    }
    if (std.mem.findScalarLast(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    // A port follows the host in a URL; in the scp-like form there is none.
    if (std.mem.findScalar(u8, authority, ':')) |at| authority = authority[0..at];
    if (authority.len < 2) return null;
    path = std.mem.trimEnd(u8, path, "/");
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - ".git".len];
    const slash = std.mem.findScalar(u8, path, '/') orelse return null;
    const owner = path[0..slash];
    const name = path[slash + 1 ..];
    if (owner.len == 0 or name.len == 0 or std.mem.findScalar(u8, name, '/') != null) return null;
    if (std.ascii.eqlIgnoreCase(authority, "github.com")) return try a.print("{s}/{s}", .{ owner, name });
    return try a.print("{s}/{s}/{s}", .{ authority, owner, name });
}

/// The repository gh dispatches on: the one origin's configured URL names. The URL as
/// configured, not as `url.<base>.insteadOf` rewrites it for git's own transport.
fn githubRepository(c: *src.Context) ![]const u8 {
    const url = (try git(c, &.{ "config", "--get", "remote.origin.url" })).out;
    if (url.len == 0) {
        c.fail("land: there is no remote origin to land on", .{});
        return error.LandFailed;
    }
    return try repository(c.a, url) orelse {
        c.fail("land: origin ({s}) names no GitHub repository, which gh would dispatch the merge tier on", .{url});
        return error.LandFailed;
    };
}

/// origin's default branch, which a landing moves: the one `refs/remotes/origin/HEAD` names,
/// asked of origin when the clone has not recorded it.
fn defaultBranch(c: *src.Context) ![]const u8 {
    if (try recordedHead(c)) |name| return name;
    const asked = try git(c, &.{ "remote", "set-head", "origin", "--auto" });
    if (try recordedHead(c)) |name| return name;
    c.fail("land: origin's default branch is not known: refs/remotes/origin/HEAD is not set, and origin did not name one ({s}); set it with git remote set-head origin <branch>", .{if (asked.ok) "it has no HEAD" else asked.err});
    return error.LandFailed;
}

fn recordedHead(c: *src.Context) !?[]const u8 {
    const prefix = "refs/remotes/origin/";
    const head = (try git(c, &.{ "symbolic-ref", "-q", "refs/remotes/origin/HEAD" })).out;
    if (!std.mem.startsWith(u8, head, prefix) or head.len == prefix.len) return null;
    return head[prefix.len..];
}

/// The branch a landing goes onto: its name on origin, and the remote-tracking ref of it here.
const Base = struct { name: []const u8, ref: []const u8 };

/// Where a landing goes and what it lands: the repository gh names, the caller's workflow file
/// in it, the default branch, and the branch landing with the commit it was at.
const Landing = struct { repo: []const u8, file: []const u8, base: Base, branch: []const u8, start: []const u8 };

/// The caller generated from `ci/workflow.json` for this package: its file under the
/// repository's `.github/workflows`, the repository's top and the package's directory in it.
const Caller = struct { name: []const u8, top: []const u8, directory: []const u8 };

/// The workflow file under the repository's `.github/workflows` whose gate runs in the
/// package's directory.
fn caller(c: *src.Context) !Caller {
    const top = try must(c, &.{ "rev-parse", "--show-toplevel" });
    const prefix = std.mem.trimEnd(u8, try must(c, &.{ "rev-parse", "--show-prefix" }), "/");
    const directory = if (prefix.len == 0) "." else prefix;
    const wanted = try c.a.print("      working-directory: {s}\n", .{try std.json.Stringify.valueAlloc(c.a, directory, .{})});
    const folder = try std.Io.Dir.path.join(c.a, &.{ top, ".github", "workflows" });
    var found: std.ArrayList([]const u8) = .empty;
    if (std.Io.Dir.cwd().openDir(c.io, folder, .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(c.io);
        var entries = dir.iterate();
        while (try entries.next(c.io)) |entry| {
            if (entry.kind != .file or !(std.mem.endsWith(u8, entry.name, ".yml") or std.mem.endsWith(u8, entry.name, ".yaml"))) continue;
            const text = try dir.readFileAlloc(c.io, entry.name, c.a, .limited(16 * 1024 * 1024));
            if (std.mem.startsWith(u8, text, workflow.header) and std.mem.find(u8, text, wanted) != null) try found.append(c.a, try c.a.dupe(u8, entry.name));
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    if (found.items.len == 1) return .{ .name = found.items[0], .top = top, .directory = directory };
    if (found.items.len == 0) {
        c.fail("land: no workflow in .github/workflows is the caller generated from ci/workflow.json for this package; generate it with plan -- --workflow .github/workflows/ci.yml", .{});
    } else c.fail("land: {s} are each a caller of this package; keep one", .{try std.mem.join(c.a, ", ", found.items)});
    return error.LandFailed;
}

/// What the landing commit is: its commit and, with a release, its version; the stem of its
/// ref on origin and the ref, null when the default branch already holds the commit.
const Prepared = struct { sha: []const u8, version: ?release.Version, declared: release.Version, stem: []const u8 = "", ref: ?[]const u8 = null };

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
    const found = try caller(c);
    const repo = try githubRepository(c);
    _ = try must(c, &.{ "fetch", "-q", "--tags", "origin" });
    const start = try must(c, &.{ "rev-parse", "HEAD" });
    const default = try defaultBranch(c);
    const base: Base = .{ .name = default, .ref = try c.a.print("refs/remotes/origin/{s}", .{default}) };
    const main = (try git(c, &.{ "rev-parse", "--verify", "-q", base.ref })).out;
    if (main.len == 0) {
        c.fail("land: origin has no {s}, its default branch, to land on", .{base.name});
        return error.LandFailed;
    }
    const landing: Landing = .{ .repo = repo, .file = found.name, .base = base, .branch = branch, .start = start };
    const prepared = try assemble(c, branch, base, found, start, main, options.date);
    const ref = prepared.ref orelse return nothing(c, landing, prepared);
    try say(c, "pushed {s} at {s}\n", .{ ref, prepared.sha[0..12] });
    try gate(c, landing, ref, prepared.sha, options);
    return finish(c, landing, prepared);
}

/// The default branch holds the branch's work already, and nothing needs a release: an earlier
/// landing whose end this clone did not see, it may be. When the tag of the declared version is
/// on the default branch, that version's attempts that no landing needs go; the branch follows.
fn nothing(c: *src.Context, landing: Landing, prepared: Prepared) !Outcome {
    const tag = try c.a.print("v{f}", .{prepared.declared});
    const tagged = (try git(c, &.{ "rev-parse", "-q", "--verify", try c.a.print("refs/tags/{s}^{{commit}}", .{tag}) })).out;
    if (tagged.len != 0 and (try git(c, &.{ "merge-base", "--is-ancestor", tagged, landing.base.ref })).ok) try clearAttempts(c, landing, try c.a.print("land/{s}", .{tag}));
    const moved = !std.mem.eql(u8, landing.start, prepared.sha) and try follow(c, landing, prepared.sha);
    return .{ .nothing = try c.a.print("{s} holds {s}{s}, and nothing the package ships changed since its last release", .{ landing.base.name, landing.branch, if (moved) ", which follows it now" else "" }) };
}

/// A worktree of its own, detached at the branch's commit, where the landing commit is made, so
/// that the branch, its checkout and the tree it has are never touched. It lives in the git
/// directory, which no checkout's status lists.
const Scratch = struct {
    top: []const u8,
    /// The package's directory in it.
    dir: std.Io.Dir,

    fn add(c: *src.Context, start: []const u8, directory: []const u8) !Scratch {
        const common = try must(c, &.{ "rev-parse", "--path-format=absolute", "--git-common-dir" });
        const now = std.Io.Clock.real.now(c.io).toNanoseconds();
        const top = try std.Io.Dir.path.join(c.a, &.{ common, "preflight", try c.a.print("land-{s}-{d}", .{ start[0..12], now }) });
        _ = try must(c, &.{ "worktree", "add", "-q", "--detach", top, start });
        const package = if (std.mem.eql(u8, directory, ".")) top else try std.Io.Dir.path.join(c.a, &.{ top, directory });
        const dir = std.Io.Dir.cwd().openDir(c.io, package, .{}) catch |err| {
            removeWorktree(c, top);
            return err;
        };
        return .{ .top = top, .dir = dir };
    }

    fn remove(s: Scratch, c: *src.Context) void {
        s.dir.close(c.io);
        removeWorktree(c, s.top);
    }
};

fn removeWorktree(c: *src.Context, top: []const u8) void {
    const removed = git(c, &.{ "worktree", "remove", "--force", top }) catch |err| {
        c.report("land: the landing's worktree at {s} is left ({t}); remove it with git worktree remove --force\n", .{ top, err });
        return;
    };
    if (!removed.ok) c.report("land: the landing's worktree at {s} is left: {s}\n", .{ top, removed.err });
}

/// The landing commit, made in a scratch worktree, and pushed to a ref of its own unless the
/// default branch, at `main`, already holds it. The worktree goes on every way out.
fn assemble(c: *src.Context, branch: []const u8, base: Base, found: Caller, start: []const u8, main: []const u8, date: []const u8) !Prepared {
    const scratch = try Scratch.add(c, start, found.directory);
    defer scratch.remove(c);
    var w = c.*;
    w.dir = scratch.dir;
    w.errors = 0;
    defer c.errors += w.errors;
    var prepared = try prepare(&w, branch, base, .{ .name = found.name, .top = scratch.top, .directory = found.directory }, date);
    prepared.stem = if (prepared.version) |version| try c.a.print("land/v{f}", .{version}) else try c.a.print("land/{s}", .{branch});
    if (prepared.version == null and std.mem.eql(u8, prepared.sha, main)) return prepared;
    const ref = try c.a.print("{s}-{s}", .{ prepared.stem, prepared.sha[0..12] });
    _ = try must(&w, &.{ "push", "-q", "origin", try c.a.print("HEAD:refs/heads/{s}", .{ref}) });
    prepared.ref = ref;
    return prepared;
}

/// In the scratch worktree, detached at the branch: rebased on origin's default branch, tidied,
/// the changelog told of re-pins, released and committed. The rebase moves no branch, whatever
/// `rebase.updateRefs` says.
fn prepare(c: *src.Context, branch: []const u8, base: Base, found: Caller, date: []const u8) !Prepared {
    const rebased = try git(c, &.{ "rebase", "-q", "--no-update-refs", base.ref });
    if (!rebased.ok) {
        const conflicts = (try git(c, &.{ "diff", "--name-only", "--diff-filter=U" })).out;
        _ = try git(c, &.{ "rebase", "--abort" });
        var files = std.mem.tokenizeScalar(u8, conflicts, '\n');
        var listed: std.ArrayList([]const u8) = .empty;
        while (files.next()) |file| try listed.append(c.a, file);
        if (listed.items.len == 0) {
            c.fail("land: {s} does not rebase on origin/{s}: {s}", .{ branch, base.name, rebased.err });
        } else c.fail("land: {s} conflicts with origin/{s} in {s}; rebase it by hand, then land", .{ branch, base.name, try std.mem.join(c.a, ", ", listed.items) });
        return error.LandFailed;
    }
    if (c.bay) |bay| {
        const tidied = try exec(c, &.{ bay, "tidy" });
        if (!tidied.ok) {
            c.fail("land: bay tidy: {s}", .{tidied.err});
            return error.LandFailed;
        }
    }
    try refreshCaller(c, found);
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
    const declared = release.declared(c) catch |err| switch (err) {
        // It named its fix.
        error.InvalidVersion, error.InvalidManifest => return error.LandFailed,
        else => return err,
    };
    if ((try must(c, &.{ "status", "--porcelain", "--untracked-files=no" })).len != 0) {
        _ = try must(c, &.{ "add", "-u" });
        const message = if (version) |v| try c.a.print("Release v{f}", .{v}) else "Pin each dependency at its release";
        _ = try must(c, &.{ "commit", "-q", "-m", message });
    }
    return .{ .sha = try must(c, &.{ "rev-parse", "HEAD" }), .version = version, .declared = declared };
}

/// The caller generated again, as `plan -- --workflow <caller>` generates it, when it names
/// another preflight than the manifest pins, so the landed commit holds the caller its
/// preflight writes. preflight's own caller runs the commit under test and is left alone.
fn refreshCaller(c: *src.Context, found: Caller) !void {
    var top = try std.Io.Dir.cwd().openDir(c.io, found.top, .{});
    defer top.close(c.io);
    var at_top = c.*;
    at_top.dir = top;
    const path = try c.a.print(".github/workflows/{s}", .{found.name});
    const existing = try at_top.read(path);
    if (std.mem.find(u8, existing, "preflight-ref: ${{ github.sha }}\n") != null) return;
    const pin = workflow.pinned(c.*, "build.zig.zon") catch |err| {
        c.fail("land: build.zig.zon: {t}; {s} names preflight by the manifest's pin", .{ err, path });
        return error.LandFailed;
    };
    if (std.mem.find(u8, existing, try c.a.print("preflight-ref: {s}\n", .{pin})) != null) return;
    // The label the caller was generated with, so that only the pin changes.
    const label = if (std.mem.startsWith(u8, existing, workflow.header)) existing[workflow.header.len .. std.mem.findScalar(u8, existing, '\n') orelse existing.len] else path;
    const config = try workflow.configuration(c.*, "ci/workflow.json");
    const text = workflow.generate(c.*, config, "build.zig.zon", found.directory, false, label, existing, &.{}) catch |err| {
        if (err == error.UndeclaredCallerJob) {
            c.fail("land: {s} holds the job {s}, which ci/workflow.json does not declare; declare it in jobs, then land", .{ path, workflow.undeclared });
        } else c.fail("land: {s} cannot be generated again: {t}", .{ path, err });
        return error.LandFailed;
    };
    try workflow.write(at_top, path, text);
}

/// A changelog line for the dependencies pinned at another revision than at the last release,
/// unless `[Unreleased]` names one of them already, or lists nothing while files other than the
/// manifest changed: the release refuses that `[Unreleased]`, and the line must not hide it.
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
    // The release names the fix for a changelog with no [Unreleased].
    const written = release.unreleased(changelog) catch return;
    const others = release.changedBesides(c, tag, "build.zig.zon") catch |err| switch (err) {
        // It named its fix.
        error.InvalidManifest => return error.LandFailed,
        else => return err,
    };
    if (!written.entries and others) return;
    const noted = noteRepins(c.a, changelog, repins) catch |err| switch (err) {
        // The release names this fix.
        error.NoUnreleasedSection => return,
        else => return err,
    } orelse return;
    try c.directory().writeFile(c.io, .{ .sub_path = "CHANGELOG.md", .data = noted });
}

/// Dispatches the merge tier with `land` on `ref`, says which run it started as soon as GitHub
/// lists it, and waits for it; red reports the failed jobs.
fn gate(c: *src.Context, landing: Landing, ref: []const u8, sha: []const u8, options: Options) !void {
    const list: []const []const u8 = &.{ "run", "list", "--workflow", landing.file, "--branch", ref, "--event", "workflow_dispatch", "--limit", "50", "--json", "databaseId,headSha,url" };
    // A run of an earlier landing of the same commit is not this one.
    const earlier = try gh(c, landing.repo, list);
    _ = try gh(c, landing.repo, &.{ "workflow", "run", landing.file, "--ref", ref, "-f", "tier=merge", "-f", "land=true" });
    var looks: Looks = .{ .repo = landing.repo, .limit = options.gh_failures };
    const started = try find(c, &looks, list, earlier, ref, sha, options);
    try say(c, "run {s}\n", .{started.url});
    try wait(c, &looks, ref, started, options);
}

/// gh's answers in a loop that looks again: a failed look is reported and made again, and only
/// `limit` failures in a row end the landing.
const Looks = struct {
    repo: []const u8,
    limit: usize,
    failures: usize = 0,

    /// gh's JSON, or null after a failure that leaves room for another look.
    fn take(l: *Looks, c: *src.Context, args: []const []const u8) !?src.Value {
        const ran = try exec(c, try std.mem.concat(c.a, []const u8, &.{ &.{"gh"}, args, &.{ "--repo", l.repo } }));
        if (ran.ok) if (std.json.parseFromSlice(src.Value, c.a, ran.out, .{})) |parsed| {
            l.failures = 0;
            return parsed.value;
        } else |_| {};
        l.failures += 1;
        const name = try std.mem.join(c.a, " ", args[0..@min(2, args.len)]);
        const why = if (ran.ok) "it answered with something other than JSON" else ran.err;
        if (l.failures >= l.limit) {
            c.fail("land: gh {s} failed {d} times in a row, last: {s}", .{ name, l.failures, why });
            return error.LandFailed;
        }
        c.report("land: gh {s} failed, looking again: {s}\n", .{ name, why });
        return null;
    }
};

/// The run a dispatch started: its id, and where to see it.
const Started = struct { id: []const u8, url: []const u8 };

/// The run of `sha` on `ref` that `earlier` did not list.
fn find(c: *src.Context, looks: *Looks, list: []const []const u8, earlier: src.Value, ref: []const u8, sha: []const u8, options: Options) !Started {
    for (0..options.find_attempts) |attempt| {
        if (attempt != 0) try std.Io.sleep(c.io, options.find_every, .awake);
        const listed = try looks.take(c, list) orelse continue;
        for (src.items(listed)) |found| {
            if (!std.mem.eql(u8, src.string(src.get(found, "headSha"), ""), sha)) continue;
            const number = src.get(found, "databaseId");
            if (number != .integer) continue;
            const seen = for (src.items(earlier)) |old| {
                const known = src.get(old, "databaseId");
                if (known == .integer and known.integer == number.integer) break true;
            } else false;
            if (seen) continue;
            const id = try c.a.print("{d}", .{number.integer});
            return .{ .id = id, .url = src.string(src.get(found, "url"), id) };
        }
    }
    c.fail("land: the dispatch on {s} started no run that GitHub lists; look at the caller's runs", .{ref});
    return error.LandFailed;
}

/// Waits for the run to end; green returns, red names the failed jobs.
fn wait(c: *src.Context, looks: *Looks, ref: []const u8, started: Started, options: Options) !void {
    while (true) {
        const view = (looks.take(c, &.{ "run", "view", started.id, "--json", "status,conclusion,url,jobs" }) catch |err| {
            if (err == error.LandFailed) c.report("the run goes on without this landing, and may still land; look at {s}, then land again: a landed version lands nothing\n", .{started.url});
            return err;
        }) orelse {
            try std.Io.sleep(c.io, options.wait_every, .awake);
            continue;
        };
        if (!std.mem.eql(u8, src.string(src.get(view, "status"), ""), "completed")) {
            try std.Io.sleep(c.io, options.wait_every, .awake);
            continue;
        }
        const conclusion = src.string(src.get(view, "conclusion"), "");
        if (std.mem.eql(u8, conclusion, "success")) return;
        c.fail("land: {s} is red ({s}): {s}", .{ ref, if (conclusion.len == 0) "no conclusion" else conclusion, started.url });
        for (src.items(src.get(view, "jobs"))) |job| {
            const ended = src.string(src.get(job, "conclusion"), "");
            if (ended.len == 0 or std.mem.eql(u8, ended, "success") or std.mem.eql(u8, ended, "skipped") or std.mem.eql(u8, ended, "neutral")) continue;
            c.report("  {s} ({s})\n", .{ src.string(src.get(job, "name"), "a job"), ended });
        }
        c.report("the branch is as it was, and {s} stays on origin\n", .{ref});
        return error.LandFailed;
    }
}

/// After a green run: the default branch holds the tested commit and the tag is on it, the
/// branch follows, and the attempts at this version that no landing needs go. The run landed:
/// what this clone cannot see or do of it afterwards is reported, and the landing stands.
fn finish(c: *src.Context, landing: Landing, prepared: Prepared) !Outcome {
    const base = landing.base;
    const name = if (prepared.version) |version| try c.a.print("v{f}", .{version}) else landing.branch;
    var outcome: Outcome = .{ .landed = .{ .name = name, .onto = base.name, .sha = prepared.sha, .followed = false } };
    const fetched = try git(c, &.{ "fetch", "-q", "--tags", "origin" });
    if (!fetched.ok) {
        c.report("land: the run landed {s}, but origin could not be fetched to see it, so {s} stays where it is: {s}\n", .{ name, landing.branch, fetched.err });
        try clearAttempts(c, landing, prepared.stem);
        return outcome;
    }
    // Another landing may have gone on top since: the default branch holds the commit.
    if (!(try git(c, &.{ "merge-base", "--is-ancestor", prepared.sha, base.ref })).ok) {
        c.fail("land: the run passed, but origin/{s}, at {s}, does not hold the tested {s}", .{ base.name, try must(c, &.{ "rev-parse", base.ref }), prepared.sha });
        return error.LandFailed;
    }
    if (prepared.version != null) {
        const tagged = (try git(c, &.{ "rev-parse", "-q", "--verify", try c.a.print("refs/tags/{s}^{{commit}}", .{name}) })).out;
        if (!std.mem.eql(u8, tagged, prepared.sha)) {
            c.fail("land: {s} holds {s}, but the tag {s} is not on it", .{ base.name, prepared.sha, name });
            return error.LandFailed;
        }
    }
    outcome.landed.followed = try follow(c, landing, prepared.sha);
    try clearAttempts(c, landing, prepared.stem);
    return outcome;
}

/// Moves the branch to `sha`, which holds its work, when it is checked out here at the commit the
/// landing began from. One that moved since, or a tree whose edits git will not carry to `sha`,
/// stays where it is, and says why.
fn follow(c: *src.Context, landing: Landing, sha: []const u8) !bool {
    const here = (try git(c, &.{ "symbolic-ref", "--short", "-q", "HEAD" })).out;
    if (!std.mem.eql(u8, here, landing.branch) or !std.mem.eql(u8, try must(c, &.{ "rev-parse", "HEAD" }), landing.start)) {
        c.report("land: {s} is no longer checked out at the commit it landed from, so it stays where it is\n", .{landing.branch});
        return false;
    }
    // Rebased commits are not a fast-forward of the branch; they are the branch.
    const ahead = (try git(c, &.{ "merge-base", "--is-ancestor", landing.start, sha })).ok;
    const moved = try git(c, if (ahead) &.{ "merge", "-q", "--ff-only", sha } else &.{ "reset", "-q", "--keep", sha });
    if (!moved.ok) c.report("land: {s} stays where it is, since git would not carry the tree's edits to {s}: {s}\n", .{ landing.branch, sha[0..12], moved.err });
    return moved.ok;
}

/// Deletes the attempts at `stem` on origin that no landing needs any more: one whose commit
/// the default branch holds, and one whose runs of the caller have all ended. One with a run
/// still going, or with none yet (another landing that has just pushed it), stays, as does each
/// that origin or GitHub cannot answer for. What is left is reported; the landing stands.
fn clearAttempts(c: *src.Context, landing: Landing, stem: []const u8) !void {
    const listed = try git(c, &.{ "ls-remote", "--heads", "origin", try c.a.print("refs/heads/{s}-*", .{stem}) });
    if (!listed.ok) {
        c.report("land: the branches {s}-* stay on origin, which could not list them: {s}\n", .{ stem, listed.err });
        return;
    }
    var done: std.ArrayList([]const u8) = .empty;
    for (try attempts(c.a, listed.out, stem)) |attempt| {
        if (try needed(c, landing, attempt)) continue;
        try done.append(c.a, attempt.name);
    }
    if (done.items.len == 0) return;
    const deleted = try git(c, try std.mem.concat(c.a, []const u8, &.{ &.{ "push", "-q", "origin", "--delete" }, done.items }));
    if (!deleted.ok) c.report("land: {s} stay on origin: {s}\n", .{ try std.mem.join(c.a, ", ", done.items), deleted.err });
}

/// Whether a landing may still need `attempt`: its commit is not on the default branch, and
/// a run of the caller on it is going, or none has started, or GitHub cannot say.
fn needed(c: *src.Context, landing: Landing, attempt: Attempt) !bool {
    if ((try git(c, &.{ "merge-base", "--is-ancestor", attempt.sha, landing.base.ref })).ok) return false;
    const ran = try exec(c, &.{ "gh", "run", "list", "--workflow", landing.file, "--branch", attempt.name, "--event", "workflow_dispatch", "--limit", "20", "--json", "status", "--repo", landing.repo });
    if (!ran.ok) return true;
    const runs = std.json.parseFromSlice(src.Value, c.a, ran.out, .{}) catch return true;
    if (src.items(runs.value).len == 0) return true;
    for (src.items(runs.value)) |one| if (!std.mem.eql(u8, src.string(src.get(one, "status"), ""), "completed")) return true;
    return false;
}

/// A branch on origin that is an attempt at a landing, and the commit it holds.
pub const Attempt = struct { name: []const u8, sha: []const u8 };

/// The branches of `git ls-remote --heads` output that are attempts at the landing `stem`:
/// `<stem>-<sha>`, and not another stem that starts with this one.
pub fn attempts(a: std.mem.Allocator, listed: []const u8, stem: []const u8) ![]const Attempt {
    var found: std.ArrayList(Attempt) = .empty;
    var lines = std.mem.tokenizeScalar(u8, listed, '\n');
    while (lines.next()) |line| {
        const at = std.mem.find(u8, line, "refs/heads/") orelse continue;
        const name = std.mem.trim(u8, line[at + "refs/heads/".len ..], " \t\r");
        if (!std.mem.startsWith(u8, name, stem) or name.len <= stem.len + 1 or name[stem.len] != '-') continue;
        const short = name[stem.len + 1 ..];
        const hex = for (short) |byte| {
            if (!std.ascii.isHex(byte)) break false;
        } else true;
        if (hex) try found.append(a, .{ .name = name, .sha = std.mem.trim(u8, line[0..at], " \t") });
    }
    return found.items;
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

test "a landing's attempts are its stem and a commit, and no other stem's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const listed = "1111\trefs/heads/land/v0.1.1-0123456789ab\n2222\trefs/heads/land/v0.1.1-ba9876543210\n" ++
        "3333\trefs/heads/land/v0.1.1-rc-0123456789ab\n4444\trefs/heads/land/v0.1.10-0123456789ab\n5555\trefs/heads/land/v0.1.1-\n";
    const found = try attempts(arena.allocator(), listed, "land/v0.1.1");
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("land/v0.1.1-0123456789ab", found[0].name);
    try std.testing.expectEqualStrings("1111", found[0].sha);
    try std.testing.expectEqualStrings("land/v0.1.1-ba9876543210", found[1].name);
    try std.testing.expectEqualStrings("2222", found[1].sha);
    try std.testing.expectEqual(@as(usize, 0), (try attempts(arena.allocator(), "", "land/v0.1.1")).len);
}

test "the repository gh takes is the one origin's URL names, in either form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "https://github.com/owner/pkg.git", "https://github.com/owner/pkg", "https://user@github.com/owner/pkg/", "git@github.com:owner/pkg.git", "ssh://git@github.com/owner/pkg.git", "ssh://git@GitHub.com:22/owner/pkg" }) |url|
        try std.testing.expectEqualStrings("owner/pkg", (try repository(a, url)).?);
    try std.testing.expectEqualStrings("ghe.example.com/owner/pkg", (try repository(a, "git@ghe.example.com:owner/pkg.git")).?);
    try std.testing.expectEqualStrings("ghe.example.com/owner/pkg", (try repository(a, "https://ghe.example.com/owner/pkg.git")).?);
    for ([_][]const u8{ "/srv/git/pkg.git", "../pkg.git", "file:///srv/git/owner/pkg.git", "C:\\git\\pkg.git", "https://github.com/owner", "https://github.com/owner/pkg/more", "git@github.com:pkg.git" }) |url|
        try std.testing.expect(try repository(a, url) == null);
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
