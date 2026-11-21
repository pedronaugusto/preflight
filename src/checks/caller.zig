//! The package's caller: the workflow under `.github/workflows` that `generate` made for
//! it, found from the package's directory, and checked to be what `generate` makes now for
//! the package's pins and configuration. The gate and the lint check it first, so the
//! hosted runs check the package with the preflight it pins and the jobs `ci/workflow.json`
//! declares; `generate` makes it again after a pin moves.
const std = @import("std");
const src = @import("source.zig");
const seam = @import("input.zig");
const actions = @import("actions.zig");
const workflow = @import("workflow.zig");
const matrix = @import("matrix.zig");

/// Adds `sdk_targets` and `fuzzed` to a gate configuration, read from the build in the gate's directory.
pub const Sdk = *const fn (*src.Context, *src.Value, []const u8) anyerror!void;

/// A git command's outcome, its output trimmed.
const Ran = struct { ok: bool, out: []const u8, err: []const u8 };

fn git(c: *src.Context, args: []const []const u8) !Ran {
    const argv = try std.mem.concat(c.a, []const u8, &.{ &.{"git"}, args });
    const result = try seam.run(c.a, c.io, .{ .argv = argv, .cwd = c.childCwd(), .environ_map = c.environ_map }, .line);
    return .{ .ok = result.term == .exited and result.term.exited == 0, .out = std.mem.trim(u8, result.stdout, " \t\r\n"), .err = std.mem.trim(u8, result.stderr, " \t\r\n") };
}

/// `git <args>`, which must succeed; a failure is reported with what git said.
fn must(c: *src.Context, args: []const []const u8) ![]const u8 {
    const ran = try git(c, args);
    if (ran.ok) return ran.out;
    c.fail("gate: git {s}: {s}", .{ try std.mem.join(c.a, " ", args), ran.err });
    return error.CallerRefused;
}

/// The caller generated for this package: its file under the repository's
/// `.github/workflows`, the repository's top, the package's directory in it, the directory
/// its gate runs in, the configuration it was generated from and the directory it was
/// generated for when not the package's.
const Caller = struct { name: []const u8, top: []const u8, directory: []const u8, gate: []const u8 = ".", config: []const u8 = "ci/workflow.json", working_directory: ?[]const u8 = null };

/// The workflow file under the repository's `.github/workflows` that is this package's
/// caller: the one whose gate runs in `working_directory`, given; else the one whose gate
/// runs in the package's directory; else the one generated workflow planned to run in a
/// directory inside the package, as preflight's own runs in its sample. Null when no
/// workflow is one; more than one fails, naming them.
fn findCaller(c: *src.Context, working_directory: ?[]const u8) !?Caller {
    const top = try must(c, &.{ "rev-parse", "--show-toplevel" });
    const prefix = std.mem.trimEnd(u8, try must(c, &.{ "rev-parse", "--show-prefix" }), "/");
    const directory = if (prefix.len == 0) "." else prefix;
    const Found = struct { name: []const u8, planned: workflow.Planned, gate: []const u8 };
    var generated: std.ArrayList(Found) = .empty;
    const folder = try std.Io.Dir.path.join(c.a, &.{ top, ".github", "workflows" });
    if (std.Io.Dir.cwd().openDir(c.io, folder, .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(c.io);
        var entries = dir.iterate();
        while (try entries.next(c.io)) |entry| {
            if (entry.kind != .file or !(std.mem.endsWith(u8, entry.name, ".yml") or std.mem.endsWith(u8, entry.name, ".yaml"))) continue;
            const text = try seam.document(c.io, dir, entry.name, c.a, .source);
            const planned = workflow.planned(text) orelse continue;
            try generated.append(c.a, .{ .name = try c.a.dupe(u8, entry.name), .planned = planned, .gate = gateOf(text) orelse continue });
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    var found: std.ArrayList(Found) = .empty;
    for (generated.items) |each| if (std.mem.eql(u8, each.gate, working_directory orelse directory)) try found.append(c.a, each);
    // A package whose gate runs in a directory of its own, planned so from the package.
    if (found.items.len == 0 and working_directory == null) for (generated.items) |each| {
        const elsewhere = each.planned.working_directory orelse continue;
        if (std.mem.eql(u8, directory, ".") or std.mem.startsWith(u8, elsewhere, try c.a.print("{s}/", .{directory}))) try found.append(c.a, each);
    };
    if (found.items.len == 1) {
        const one = found.items[0];
        return .{ .name = one.name, .top = top, .directory = directory, .gate = one.gate, .config = one.planned.config, .working_directory = one.planned.working_directory };
    }
    if (found.items.len == 0) return null;
    var callers: std.ArrayList([]const u8) = .empty;
    for (found.items) |each| try callers.append(c.a, each.name);
    c.fail("gate: {s} are each a caller of this package; keep one, or name its directory with --working-directory", .{try std.mem.join(c.a, ", ", callers.items)});
    return error.CallerRefused;
}

/// Every `uses:` in the repository's `.github` (its workflows and its own actions), and in
/// each local action a `./` use reaches wherever it lives, names what it runs by commit: a
/// path in this repository (`./`), or `owner/repo[/path]@<commit>`. A tag or a branch is the
/// other repository's to move, and a run would take what it moved to unseen; the caller pins
/// preflight's workflow by commit, which pins nothing that workflow takes in turn unless it
/// pins it so too.
fn pinnedActions(c: *src.Context, top: []const u8) !void {
    var root = std.Io.Dir.cwd().openDir(c.io, top, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer root.close(c.io);
    const before = c.errors;
    // The local actions the files checked use, by their path from the top, to follow.
    var local: std.array_hash_map.String(void) = .empty;
    if (root.openDir(c.io, ".github", .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(c.io);
        var walker = try dir.walk(c.a);
        defer walker.deinit();
        while (try walker.next(c.io)) |entry| {
            if (entry.kind != .file or !(std.mem.endsWith(u8, entry.basename, ".yml") or std.mem.endsWith(u8, entry.basename, ".yaml"))) continue;
            try checkUses(c, root, try c.a.print(".github/{s}", .{entry.path}), &local);
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    // Each local action outside .github, its own `./` uses followed in turn.
    var next: usize = 0;
    while (next < local.count()) : (next += 1) {
        const action = local.keys()[next];
        if (action.len == 0 or std.mem.eql(u8, action, ".github") or std.mem.startsWith(u8, action, ".github/")) continue;
        const file = for ([_][]const u8{ "action.yml", "action.yaml" }) |name| {
            const candidate = try std.Io.Dir.path.join(c.a, &.{ action, name });
            if (root.access(c.io, candidate, .{})) |_| break candidate else |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
        } else {
            c.fail("gate: `uses: ./{s}` names no action: {s} holds no action.yml", .{ action, action });
            continue;
        };
        try checkUses(c, root, file, &local);
    }
    if (c.errors != before) return error.CallerRefused;
}

/// Checks each `uses:` of the YAML at `path` (from the repository's top), adding the local
/// actions it names to `local`.
fn checkUses(c: *src.Context, root: std.Io.Dir, path: []const u8, local: *std.array_hash_map.String(void)) !void {
    const text = try seam.document(c.io, root, path, c.a, .source);
    var problem: actions.Problem = .{ .line = 0, .what = "" };
    const used = actions.uses(c.a, text, &problem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unreadable => {
            c.fail("gate: {s}:{d}: {s}; the gate reads each `uses` from the workflow's YAML, and cannot read this one for certain", .{ path, problem.line, problem.what });
            return;
        },
    };
    for (used) |use| {
        if (!pinned(use.value)) c.fail("gate: {s}:{d}: `uses: {s}` names no commit; pin it as `owner/repo@<commit>`, the tag in a comment beside it", .{ path, use.line, use.value });
        if (std.mem.startsWith(u8, use.value, "./")) try local.put(c.a, std.mem.trimEnd(u8, use.value[2..], "/"), {});
    }
}

/// Whether `used` names a fixed revision: a path in this repository, a container image by
/// its digest, or a repository at a full commit id.
fn pinned(used: []const u8) bool {
    if (std.mem.startsWith(u8, used, "./")) return true;
    if (std.mem.startsWith(u8, used, "docker://")) {
        // A digest ends the value: `@sha256:` and exactly 64 lowercase hex digits.
        const at = std.mem.findLast(u8, used, "@sha256:") orelse return false;
        return lowerHex(used[at + "@sha256:".len ..], 64);
    }
    const at = std.mem.findScalarLast(u8, used, '@') orelse return false;
    const commit = used[at + 1 ..];
    return lowerHex(commit, 40) or lowerHex(commit, 64);
}

/// Whether `text` is exactly `len` lowercase hex digits.
fn lowerHex(text: []const u8, len: usize) bool {
    if (text.len != len) return false;
    for (text) |ch| if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return false;
    return true;
}

test "a workflow's uses names a commit, a path here or an image's digest; a tag or a branch does not" {
    for ([_][]const u8{
        "actions/checkout@11d5960a326750d5838078e36cf38b85af677262",
        "o/r/.github/workflows/zig.yml@11d5960a326750d5838078e36cf38b85af677262",
        "./.github/actions/setup",
        "docker://alpine@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1",
    }) |used| try std.testing.expect(pinned(used));
    for ([_][]const u8{
        "actions/checkout@v4",
        "mlugg/setup-zig@v2",
        "o/r/.github/workflows/zig.yml@main",
        "actions/checkout@11d5960",
        "actions/checkout@11D5960A326750D5838078E36CF38B85AF677262",
        "docker://alpine:3.20",
        "actions/checkout",
        // A digest that is not the whole rest of the value, or not 64 lowercase hex digits.
        "docker://alpine@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1:latest",
        "docker://alpine@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d",
        "docker://alpine@sha256:4BCFF63911FCB4448BD4FDACEC207030997CAF25E9BEA4045FA6C8C44DE311D1",
        "docker://alpine@sha256:",
        "docker://alpine@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1x",
    }) |used| try std.testing.expect(!pinned(used));
}

/// The directory a generated caller's gate runs in, as its `working-directory:` line says.
fn gateOf(text: []const u8) ?[]const u8 {
    const key = "      working-directory: \"";
    const at = std.mem.find(u8, text, key) orelse return null;
    const start = at + key.len;
    const end = std.mem.findScalarPos(u8, text, start, '"') orelse return null;
    return text[start..end];
}

/// What preflight's own caller names as the preflight it runs: the commit under test.
const own_ref = "preflight-ref: ${{ github.sha }}\n";

/// The caller at `path` (from the repository's top), `existing` if there is one, as
/// `generate` makes it now for the package's pins and configuration.
/// Only `generate` `writes`: it takes retired keys out of the configuration. The gate and the
/// lint change nothing in the package, and refuse a retired key by name.
fn generateCaller(c: *src.Context, found: Caller, sdk: ?Sdk, path: []const u8, existing: ?[]const u8, own: bool, manifest: []const u8, drops: []const []const u8, writes: bool) ![]const u8 {
    const given = if (std.mem.eql(u8, found.config, "ci/workflow.json")) null else found.config;
    const label = try workflow.heading(c.a, given, path, found.working_directory, own, c.stepCommand("generate"));
    var config = try workflow.configuration(c.*, found.config);
    if (writes) try dropRetired(c, found.config, &config) else try refuseRetired(c, found.config, config);
    if (sdk) |add| try add(c, &config, found.gate);
    return workflow.generate(c.*, config, manifest, found.gate, own, label, existing, drops) catch |err| {
        if (err == error.UndeclaredCallerJob) {
            c.fail("generate: {s} holds the job {s}, which {s} does not declare; declare it in jobs, or let it go with `generate -- --drop {s}`", .{ path, workflow.undeclared, found.config, workflow.undeclared });
        } else if (matrix.problem.len != 0) {
            c.fail("{s}: refused: {s}", .{ found.config, matrix.problem });
        } else c.fail("generate: {s} cannot be generated again: {t}", .{ path, err });
        return error.CallerRefused;
    };
}

/// Takes the keys of triggers and switches that are gone (`matrix.obsolete_triggers`,
/// `matrix.obsolete_switches`) out of the package's
/// configuration at `path`, writing it again without them and naming each: moving a package
/// to this preflight is `generate` alone, where `plan` and `gate` refuse them by name.
fn dropRetired(c: *src.Context, path: []const u8, config: *src.Value) !void {
    if (config.* != .object) return;
    // The file as written: the configuration read for planning holds the records beside it.
    var written = try c.options(path);
    if (written != .object) return;
    var dropped = false;
    for (matrix.obsolete_triggers) |name| if (written.object.orderedRemove(name)) {
        _ = config.object.orderedRemove(name);
        c.report("generate: {s}: dropped `{s}`: every push to main runs the ci tier, and the release tier runs weekly at the package's own time\n", .{ path, name });
        dropped = true;
    };
    for (matrix.obsolete_switches) |name| if (written.object.orderedRemove(name)) {
        _ = config.object.orderedRemove(name);
        c.report("generate: {s}: dropped `{s}`: the tests compile once exactly when the build's are portable (addCi's .portable_tests, its ci-build step)\n", .{ path, name });
        dropped = true;
    };
    if (!dropped) return;
    var text: std.Io.Writer.Allocating = .init(c.a);
    try std.json.Stringify.value(written, .{ .whitespace = .indent_2 }, &text.writer);
    try text.writer.writeByte('\n');
    try c.directory().writeFile(c.io, .{ .sub_path = path, .data = text.written() });
}

/// Refuses, by name, each key of triggers and switches that are gone in the configuration at
/// `path`: `generate` takes them out, and nothing but `generate` writes the package.
fn refuseRetired(c: *src.Context, path: []const u8, config: src.Value) !void {
    if (config != .object) return;
    const before = c.errors;
    for (matrix.obsolete_triggers ++ matrix.obsolete_switches) |name| if (config.object.contains(name))
        c.fail("{s}: `{s}` is retired: run `{s}`, which takes it out, and commit it", .{ path, name, c.stepCommand("generate") });
    if (c.errors != before) return error.CallerRefused;
}

/// `c` reading and writing from `top`, the repository's top opened.
fn atTop(c: *src.Context, top: std.Io.Dir) src.Context {
    var at_top = c.*;
    at_top.dir = .of(top);
    return at_top;
}

/// Refuses a caller that is not what `generate` makes for the package's pins and
/// configuration: a release that left it so would have the hosted runs check the package
/// with another preflight than it pins, or other jobs than ci/workflow.json declares.
fn requireCurrentCaller(c: *src.Context, found: Caller, sdk: ?Sdk) !void {
    var top = try std.Io.Dir.cwd().openDir(c.io, found.top, .{});
    defer top.close(c.io);
    const at_top = atTop(c, top);
    const path = try c.a.print(".github/workflows/{s}", .{found.name});
    const existing = try at_top.read(path);
    const own = std.mem.find(u8, existing, own_ref) != null;
    if (std.mem.eql(u8, existing, try generateCaller(c, found, sdk, path, existing, own, "build.zig.zon", &.{}, false))) return;
    c.fail("{s} is not what generate makes for this package's pins and {s}: run `{s}` and commit it", .{ path, found.config, c.stepCommand("generate") });
    return error.CallerRefused;
}

/// `lint`'s look at the caller, so a stale one fails the local gate and the ci tier, not only
/// a release's gate: in a git work tree, the package's caller, if it has one, is what
/// `generate` makes now for its pins and configuration. A caller generated from another
/// directory for this one (`generate -- --working-directory`, preflight's sample) is that
/// directory's lint's to check, where the configuration it names is read. Outside a work
/// tree no caller is committed, and none is checked.
pub fn lintCaller(c: *src.Context, sdk: ?Sdk) !void {
    const inside = git(c, &.{ "rev-parse", "--is-inside-work-tree" }) catch |err| switch (err) {
        // No git to ask: nothing committed to compare.
        error.FileNotFound => return,
        else => return err,
    };
    if (!inside.ok) return;
    const found = (findCaller(c, null) catch |err| switch (err) {
        // Reported where it failed.
        error.CallerRefused => return,
        else => return err,
    }) orelse return;
    if (found.working_directory != null and std.mem.eql(u8, found.gate, found.directory)) return;
    requireCurrentCaller(c, found, sdk) catch |err| switch (err) {
        error.CallerRefused => return,
        else => return err,
    };
}

/// What `generate` is given: where the planned jobs run when not the package's directory,
/// the configuration when not the caller's, whether it is preflight's own caller, the
/// manifest whose preflight pin the caller names, and jobs of the old caller to let go.
pub const Request = struct { working_directory: ?[]const u8 = null, config: ?[]const u8 = null, own: bool = false, manifest: []const u8 = "build.zig.zon", drops: []const []const u8 = &.{} };

/// `generate`: the package's caller made again where it is, or, when it has none, made at
/// `.github/workflows/ci.yml` at the repository's top, its jobs run in the package's
/// directory (or the request's). Writes nothing when it is current; returns its path from the top.
pub fn generate(c: *src.Context, request: Request, sdk: ?Sdk) ![]const u8 {
    var found = (try findCaller(c, request.working_directory)) orelse fresh: {
        const top = try must(c, &.{ "rev-parse", "--show-toplevel" });
        const prefix = std.mem.trimEnd(u8, try must(c, &.{ "rev-parse", "--show-prefix" }), "/");
        const directory = if (prefix.len == 0) "." else prefix;
        break :fresh Caller{ .name = "ci.yml", .top = top, .directory = directory, .gate = request.working_directory orelse directory, .working_directory = request.working_directory };
    };
    if (request.config) |given| found.config = given;
    var top = try std.Io.Dir.cwd().openDir(c.io, found.top, .{});
    defer top.close(c.io);
    const at_top = atTop(c, top);
    const path = try c.a.print(".github/workflows/{s}", .{found.name});
    const existing = if (try at_top.exists(path)) try at_top.read(path) else null;
    const own = request.own or (if (existing) |text| std.mem.find(u8, text, own_ref) != null else false);
    const text = try generateCaller(c, found, sdk, path, existing, own, request.manifest, request.drops, true);
    if (existing) |old| if (std.mem.eql(u8, old, text)) return path;
    try top.createDirPath(c.io, ".github/workflows");
    try workflow.write(at_top, path, text);
    return path;
}

/// `gate`'s look at the caller: the package's caller, if it has one, is what `plan` generates
/// for its pins and configuration. `config` overrides the configuration its first line names.
/// Returns where the caller's gate runs, from the package's directory: the directory the gate
/// runs the planned jobs in when it is given none (preflight's own runs in its sample).
pub fn currentCaller(c: *src.Context, working_directory: ?[]const u8, config: ?[]const u8, sdk: ?Sdk) !?[]const u8 {
    try pinnedActions(c, try must(c, &.{ "rev-parse", "--show-toplevel" }));
    var found = (try findCaller(c, working_directory)) orelse return null;
    if (config) |given| found.config = given;
    try requireCurrentCaller(c, found, sdk);
    if (std.mem.eql(u8, found.directory, ".") or std.mem.eql(u8, found.gate, found.directory)) return if (std.mem.eql(u8, found.directory, ".")) found.gate else ".";
    if (std.mem.startsWith(u8, found.gate, found.directory) and found.gate.len > found.directory.len and found.gate[found.directory.len] == '/') return found.gate[found.directory.len + 1 ..];
    return null;
}
