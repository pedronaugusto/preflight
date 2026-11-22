//! What glint's rules weigh in preflight's default policy, and where the exceptions are, read
//! from `ci/preflight.json`: the data a project file hands glint (`project.zig`). glint decides
//! what a rule finds and resolves the levels (its rules', the packages', the repository's);
//! this says which rules weigh what, which files the lint reads, and what each file is.
const std = @import("std");
const gantry = @import("gantry");
const src = @import("../source.zig");
const family = @import("../../family.zig");
const project = @import("project.zig");

/// Work glint may do on one run. The largest repository preflight checks fits in
/// a fraction of it; a run that spends it is incomplete, never green.
pub const fact_budget: usize = 4_000_000;

/// The family's one door for durability: only airlock makes a file durable, because only
/// airlock says what a sync reached (its levels, the refusals std turns into panics). Under the
/// family's policy every package's production code is held to it by what a reference resolves
/// to (P006, gated): std's raw sync declarations and the symbols every `extern` declaration of
/// them binds, and std's `Io` publish and sync, an atomic file's creation, its link or replace
/// and a file's `sync`, which say nothing of what reached the disk. The entries name their
/// owners, which carry no suppression for them: airlock, the door itself, and reactor, whose
/// `Io` backends implement `fileSync`. Any other site that must make the call says why with
/// `// glint-ignore: P006 -- <reason>`; a governed name that does not resolve is undecided, and
/// an undecided site does not pass a gate. A project outside the family is held to neither
/// door: airlock and aegis are the family's.
pub const durability = blk: {
    const reason = "durability belongs to airlock: only it says what a sync reached";
    const replacement = "airlock.syncFile, airlock.syncDir or an airlock commit";
    const owners: []const []const u8 = &.{ "airlock", "reactor" };
    const std_paths = [_][]const u8{
        "posix.syncfs",            "posix.fdatasync",        "os.linux.syncfs",     "os.linux.fsync",
        "os.linux.fdatasync",      "os.linux.IoUring.fsync", "c.F.FULLFSYNC",       "c.F.BARRIERFSYNC",
        "Io.Dir.createFileAtomic", "Io.File.sync",           "Io.File.Atomic.link", "Io.File.Atomic.replace",
    };
    // A whole-system `sync` is no file's durability, and is not governed.
    const symbols = [_][]const u8{ "fsync", "fdatasync", "syncfs", "FlushFileBuffers", "NtFlushBuffersFile", "NtFlushBuffersFileEx" };
    var out: [std_paths.len + symbols.len]project.Disallowed = undefined;
    for (std_paths, out[0..std_paths.len]) |path, *entry| entry.* = .{ .source = "std", .declaration = path, .reason = reason, .replacement = replacement, .scope = .production, .owners = owners };
    for (symbols, out[std_paths.len..]) |symbol, *entry| entry.* = .{ .declaration = symbol, .reason = reason, .replacement = replacement, .scope = .production, .owners = owners };
    break :blk out;
};

/// The family's whole-file read: std 0.17's `Dir.readFileAlloc` and `readFileAllocOptions` lose a
/// cancel that lands on the file's length (its writer takes the failed length as a guess and
/// reads on), so production code reads a whole file through `aegis.own.readFile`, which returns
/// it, bounded by a limit the caller gives. aegis owns the entry, as airlock owns durability's.
pub const whole_reads = blk: {
    const reason = "std's whole-file read loses a cancel that lands on the file's length";
    const replacement = "aegis.own.readFile, with the limit the caller gives";
    const owners: []const []const u8 = &.{"aegis"};
    const std_paths = [_][]const u8{ "Io.Dir.readFileAlloc", "Io.Dir.readFileAllocOptions" };
    var out: [std_paths.len]project.Disallowed = undefined;
    for (std_paths, &out) |path, *entry| entry.* = .{ .source = "std", .declaration = path, .reason = reason, .replacement = replacement, .scope = .production, .owners = owners };
    break :blk out;
};

/// How a rule weighs on the gate. `gate`: its findings fail the run. `finding`: glint reports it,
/// and any finding it makes fails the run. `report` prints and never fails. `off` does not run.
pub const Weight = project.Weight;

/// preflight's default policy, for any project with no configuration. Correctness gates, and so
/// does a debug print the project forbids (P005). glint's shipped bans (P007's unchecked
/// operations, P008's same-typed ids, P009's frame pointer carried out) weigh as findings under
/// the family's policy and report elsewhere; the rules the program's packages declare join at
/// their own defaults, a ban a finding and hygiene a report, which glint reads from the
/// packages. glint leaves no site undecided: a site is a finding, a report or nothing. The
/// function reading budget (P003) is a house style, reported until a package gates it in its
/// `glint.rules`. A discarded error (Z026, an empty `catch` with no reason written at it) is a
/// result nobody read, and gates: a best-effort cleanup is a fine reason, silence is not. Two
/// operators Zig 0.18 refuses to order without parentheses (Z034) gate, so a package fixes them
/// while 0.17 still reads them, before they stop its build. The Zig style rules are reported
/// until a package is clean under them and gates them itself. A private declaration its file
/// never names (D001) is dead code or a use gone missing, and is reported. The readability report
/// (Z024) stays off, as the fork's selection kept it.
const defaults = [_]project.LevelEntry{
    .{ .rule = "Z003", .weight = .gate },
    .{ .rule = "Z011", .weight = .finding },
    .{ .rule = "Z013", .weight = .gate },
    .{ .rule = "P003", .weight = .report },
    .{ .rule = "P005", .weight = .finding },
    .{ .rule = "Z026", .weight = .gate },
    .{ .rule = "P006", .weight = .gate },
    .{ .rule = "Z034", .weight = .gate },
    .{ .rule = "Z012", .weight = .report },
    .{ .rule = "Z016", .weight = .report },
    .{ .rule = "Z001", .weight = .report },
    .{ .rule = "Z005", .weight = .report },
    .{ .rule = "Z006", .weight = .report },
    .{ .rule = "Z009", .weight = .report },
    .{ .rule = "Z014", .weight = .report },
    .{ .rule = "Z031", .weight = .report },
    .{ .rule = "Z032", .weight = .report },
    .{ .rule = "D001", .weight = .report },
    .{ .rule = "P007", .weight = .finding },
    .{ .rule = "P008", .weight = .finding },
    .{ .rule = "P009", .weight = .finding },
};

/// The family's bans that hold what a package ships: glint's P007, P008 and P009. The rules the
/// run's packages declare hold it too, which glint knows from the packages.
pub const shipped_bans = [_][]const u8{ "P007", "P008", "P009" };

/// Keys that were ziglint's or a ledger's. A repository still naming one
/// would lose the gate it believes it has, so each fails by name.
const retired = [_]struct { key: []const u8, instead: []const u8 }{
    .{ .key = "ziglint_exceptions", .instead = "write `// glint-ignore: <rule> -- <reason>` at the site" },
    .{ .key = "ziglint_paths", .instead = "name the files in `glint_paths`" },
    .{ .key = "unreachable_exceptions", .instead = "write `// glint-ignore: <rule> -- <reason>` at the site" },
    .{ .key = "debug_print_exceptions", .instead = "write `// glint-ignore: P005 -- <reason>` at the site" },
    .{ .key = "glint_config", .instead = "move its fields into the `glint` object" },
};

const glint_keys = [_][]const u8{"rules"};

/// glint settings that went with the rules they set: P001's cast reasons are the danger rules'
/// now (A010's integer conversions, A019's pointer conversions), whose sites carry the pack's
/// escape.
const retired_glint = [_]struct { key: []const u8, instead: []const u8 }{
    .{ .key = "casts", .instead = "P007 finds every pointer conversion; write `// glint-ignore: P007 -- <reason>` at a raw one" },
    .{ .key = "escapes", .instead = "the aegis escape form is gone: every rule takes `// glint-ignore: <rule> -- <reason>`, which the report counts" },
    .{ .key = "unresolved", .instead = "glint 0.8 leaves no site undecided: a ban reports what it cannot decide and hygiene stays silent, so there is no count to hold" },
    .{ .key = "cast_scope", .instead = "the danger rules read production code only" },
    .{ .key = "fact_budget", .instead = "glint's options have one home: write `fact_budget` in the repository's glint.json" },
    .{ .key = "max_line_length", .instead = "glint's options have one home: write `max_line_length` in the repository's glint.json" },
    .{ .key = "disallowed", .instead = "glint's options have one home: write `disallowed` in the repository's glint.json" },
    .{ .key = "peer_writers", .instead = "it went with A018, which read it" },
    .{ .key = "strict_suppressions", .instead = "suppressions are strict in every repository: one that suppresses nothing fails" },
};

pub const Limit = struct { pattern: *const gantry.rules.Pattern, lines: u32 };
pub const Exception = struct { path: []const u8, function: []const u8, lines: u32, reason: []const u8 };
/// A file kept as its upstream wrote it: where it comes from, how the upstream's copy is
/// verified, and the SHA-256 of that copy. While the file is the copy, its verification is the
/// reason every danger site in it carries, as an escape's is for its line.
pub const Vendored = struct { path: []const u8, upstream: []const u8, verification: []const u8, sha256: [32]u8 };

pub const Policy = struct {
    /// The levels the rules weigh at by default, the shipped bans reported outside the family.
    levels: []const project.LevelEntry,
    /// Under the family's policy a repository may only raise a rule.
    family: bool,
    /// What production code may not reference: the family's doors, under its policy.
    disallowed: []const project.Disallowed,
    /// The repository's amendments, by rule, as `glint.rules` writes them.
    rules: []const project.Setting,
    function_limit: u32,
    /// Where function length is checked: the shipped `sources`, and any path
    /// a `function_limits` pattern names.
    sources: []const []const u8,
    limits: []const Limit,
    exceptions: []const Exception,
    vendored: []const Vendored,
    /// Test code by name and by `test_support`.
    tests: []const *const gantry.rules.Pattern,
    /// The part of `tests` that is a test by its file name alone.
    named_tests: []const *const gantry.rules.Pattern,
    /// `glint_paths`: what the repository lints beside what it ships.
    paths: ?[]const []const u8,
    /// What `build.zig.zon`'s `.paths` ships, files and directories: the danger
    /// rules' scope, which no setting narrows.
    shipped: []const []const u8,

    /// Whether `path` is in what the package ships.
    pub fn ships(policy: Policy, path: []const u8) bool {
        for (policy.shipped) |entry| {
            if (std.mem.eql(u8, path, entry)) return true;
            if (std.mem.startsWith(u8, path, entry) and path.len > entry.len and path[entry.len] == '/') return true;
        }
        return false;
    }

    /// A test file, one that tests name, or neither.
    pub fn kind(policy: Policy, path: []const u8) Kind {
        if (gantry.rules.anyOf(policy.named_tests, path)) return .test_file;
        return if (gantry.rules.anyOf(policy.tests, path)) .support else .production;
    }
    pub const Kind = enum { production, test_file, support };

    fn inSources(policy: Policy, path: []const u8) bool {
        for (policy.sources) |root| {
            if (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/') return true;
        }
        return false;
    }

    /// The function reading budget at `path`: the limit, or the lowest ceiling a pattern names
    /// for it. Null outside the sources unless a pattern names the path: the length of a function
    /// was never checked there, and a build script or an example is long for reasons of its own.
    pub fn functionLines(policy: Policy, path: []const u8) ?u32 {
        var limit = policy.function_limit;
        var named = false;
        for (policy.limits) |entry| if (entry.pattern.matches(path)) {
            limit = @min(limit, entry.lines);
            named = true;
        };
        return if (named or policy.inSources(path)) limit else null;
    }

    /// The reasoned ceilings of `path`'s functions.
    pub fn exceptionsAt(policy: Policy, a: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]const project.FunctionException {
        var out: std.ArrayList(project.FunctionException) = .empty;
        for (policy.exceptions) |entry| if (std.mem.eql(u8, entry.path, path)) {
            try out.append(a, .{ .function = entry.function, .lines = entry.lines, .reason = entry.reason });
        };
        return out.items;
    }

    /// The project file's policy: the levels; under the family's policy the floor they are,
    /// the packages' defaults held too; the shipped bans; the doors; the repository's rules as
    /// it wrote them; its glint.json, `repo_options`, where it has one.
    pub fn data(policy: Policy, repo_options: ?[]const u8) project.Policy {
        return .{
            .levels = policy.levels,
            .floor = if (policy.family) .{ .rules = policy.levels, .package_defaults = true, .refuse_repo_options = false } else null,
            .shipped_bans = &shipped_bans,
            .disallowed = policy.disallowed,
            .fact_budget = fact_budget,
            .strict_suppressions = true,
            .metrics = true,
            .config = if (policy.rules.len != 0) .{ .rules = policy.rules } else null,
            .repo_options = repo_options,
        };
    }
};

/// Reads the default policy and the repository's amendments to it. Anything
/// the repository wrote that cannot be honoured is reported and yields null:
/// a setting that is ignored is a gate that is not there. A rule's name and its level against
/// the floor are glint's to judge, in its words.
pub fn parse(c: *src.Context, config: src.Value, shipped: []const []const u8) !?Policy {
    const a = c.a;
    const before = c.errors;
    for (retired) |entry| if (src.get(config, entry.key) != .null) c.fail("glint: `{s}` is retired: {s}", .{ entry.key, entry.instead });
    const policy_kind = family.of(src.get(config, family.key)) catch fail: {
        c.fail("{s}", .{family.refusal});
        break :fail .family;
    };

    const block = src.get(config, "glint");
    var rules: std.ArrayList(project.Setting) = .empty;
    if (block != .null and block != .object) c.fail("glint: the `glint` setting is an object", .{});
    if (block == .object) {
        var keys = block.object.iterator();
        while (keys.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "profile")) {
                c.fail("glint: `profile` is not a setting: the default policy is preflight's, and a repository amends it by rule in `rules`", .{});
            } else for (retired_glint) |gone| {
                if (std.mem.eql(u8, key, gone.key)) {
                    c.fail("glint: `{s}` is retired: {s}", .{ key, gone.instead });
                    break;
                }
            } else if (!known(&glint_keys, key)) c.fail("glint: unknown setting `{s}`", .{key});
        }
        try parseRules(c, src.get(block, "rules"), &rules);
    }

    // The family's shipped bans are findings under its policy; elsewhere they report, as a
    // project outside the family has not taken them on.
    const levels = try a.dupe(project.LevelEntry, &defaults);
    if (policy_kind != .family) for (levels) |*entry| {
        for (shipped_bans) |ban| if (std.mem.eql(u8, entry.rule, ban)) {
            entry.weight = .report;
        };
    };
    var globs: gantry.rules.Globs = .{ .arena = a };
    var policy: Policy = .{
        .levels = levels,
        .family = policy_kind == .family,
        // The family's durability door and its whole-file read hold under the family's policy,
        // beside what the repository's glint.json disallows.
        .disallowed = if (policy_kind == .family) &(durability ++ whole_reads) else &.{},
        .rules = rules.items,
        .function_limit = 120,
        .sources = try src.roots(a, config),
        .limits = &.{},
        .exceptions = &.{},
        .vendored = &.{},
        .tests = try globs.list(.path, try src.testPaths(a, config)),
        .named_tests = try globs.list(.path, &src.test_files),
        .paths = null,
        .shipped = shipped,
    };
    const limit = src.get(config, "function_limit");
    if (limit != .null) {
        if (limit != .integer or limit.integer < 1 or limit.integer > std.math.maxInt(u32)) c.fail("glint: function_limit is a positive line count", .{}) else policy.function_limit = @intCast(limit.integer);
    }
    policy.limits = try parseLimits(c, &globs, src.get(config, "function_limits"));
    policy.exceptions = try parseExceptions(c, src.get(config, "function_exceptions"));
    policy.vendored = try parseVendored(c, src.get(config, "vendored"));
    policy.paths = try parsePaths(c, src.get(config, "glint_paths"));
    return if (c.errors == before) policy else null;
}

fn known(names: []const []const u8, key: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, key)) return true;
    return false;
}

/// The repository's `rules`, each an id and a level glint reads. Whether glint or a package of
/// the run has the id, and whether the level is below the floor, is glint's to say.
fn parseRules(c: *src.Context, rules: src.Value, out: *std.ArrayList(project.Setting)) !void {
    if (rules == .null) return;
    if (rules != .array) {
        c.fail("glint: `rules` is a list of {{id, level}}", .{});
        return;
    }
    for (rules.array.items) |entry| {
        const id = src.get(entry, "id");
        const named = src.get(entry, "level");
        if (id != .string or named != .string) {
            c.fail("glint: a rule needs an `id` and a `level` (off, report or gate)", .{});
            continue;
        }
        const level = std.meta.stringToEnum(project.Level, named.string) orelse {
            c.fail("glint: {s}: level `{s}` is not off, report or gate", .{ id.string, named.string });
            continue;
        };
        try out.append(c.a, .{ .id = id.string, .level = level });
    }
}

fn parseLimits(c: *src.Context, globs: *gantry.rules.Globs, value: src.Value) ![]const Limit {
    if (value == .null) return &.{};
    if (value != .object) {
        c.fail("glint: function_limits maps path patterns to line counts", .{});
        return &.{};
    }
    var out: std.ArrayList(Limit) = .empty;
    var entries = value.object.iterator();
    while (entries.next()) |entry| {
        const lines = entry.value_ptr.*;
        const count: u32 = if (lines == .integer and lines.integer >= 1) std.math.cast(u32, lines.integer) orelse 0 else 0;
        if (count == 0) {
            c.fail("glint: function_limits: {s}: a positive line count", .{entry.key_ptr.*});
            continue;
        }
        try out.append(c.a, .{ .pattern = try globs.get(.path, entry.key_ptr.*), .lines = count });
    }
    return out.items;
}

fn parseExceptions(c: *src.Context, value: src.Value) ![]const Exception {
    if (value == .null) return &.{};
    if (value != .object) {
        c.fail("glint: function_exceptions maps `path:function` to a ceiling and a reason", .{});
        return &.{};
    }
    var out: std.ArrayList(Exception) = .empty;
    var entries = value.object.iterator();
    while (entries.next()) |entry| {
        const label = entry.key_ptr.*;
        const split = std.mem.findScalarLast(u8, label, ':') orelse {
            c.fail("glint: function_exceptions: {s}: name it `path:function`", .{label});
            continue;
        };
        const lines = src.get(entry.value_ptr.*, "lines");
        const reason = std.mem.trim(u8, try src.string(src.get(entry.value_ptr.*, "reason"), ""), " \t\r\n");
        if (lines != .integer or lines.integer < 1 or lines.integer > std.math.maxInt(u32) or reason.len == 0 or split == 0 or split + 1 == label.len) {
            c.fail("glint: function_exceptions: {s}: needs a line ceiling and a reason", .{label});
            continue;
        }
        try out.append(c.a, .{ .path = label[0..split], .function = label[split + 1 ..], .lines = @intCast(lines.integer), .reason = reason });
    }
    return out.items;
}

fn parseVendored(c: *src.Context, value: src.Value) ![]const Vendored {
    if (value == .null) return &.{};
    if (value != .object) {
        c.fail("glint: vendored maps a path to its upstream, how it is verified and its SHA-256", .{});
        return &.{};
    }
    var out: std.ArrayList(Vendored) = .empty;
    var entries = value.object.iterator();
    while (entries.next()) |entry| {
        const path = entry.key_ptr.*;
        const upstream = std.mem.trim(u8, try src.string(src.get(entry.value_ptr.*, "upstream"), ""), " \t\r\n");
        const verification = std.mem.trim(u8, try src.string(src.get(entry.value_ptr.*, "verification"), ""), " \t\r\n");
        var sha256: [32]u8 = undefined;
        const digest = try src.string(src.get(entry.value_ptr.*, "sha256"), "");
        const hex = digest.len == 64 and if (std.fmt.hexToBytes(&sha256, digest)) |_| true else |_| false;
        if (entry.value_ptr.* != .object or upstream.len == 0 or verification.len == 0 or !hex) {
            c.fail("vendored: {s} needs its upstream, its verification and the SHA-256 of the upstream file, 64 hex digits", .{path});
            continue;
        }
        try out.append(c.a, .{ .path = path, .upstream = upstream, .verification = verification, .sha256 = sha256 });
    }
    return out.items;
}

fn parsePaths(c: *src.Context, value: src.Value) !?[]const []const u8 {
    if (value == .null) return null;
    if (value != .array or value.array.items.len == 0) {
        c.fail("glint: glint_paths is a nonempty list of files and directories", .{});
        return null;
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (value.array.items) |item| {
        if (item != .string or item.string.len == 0) {
            c.fail("glint: glint_paths names files and directories", .{});
            continue;
        }
        try out.append(c.a, item.string);
    }
    return out.items;
}

fn parsed(a: std.mem.Allocator, text: []const u8) !src.Value {
    return (try std.json.parseFromSlice(src.Value, a, text, .{ .allocate = .alloc_always })).value;
}

/// What a package of the tests ships, as most do: its build files and its sources.
const test_shipped: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src" };

fn weightOf(levels: []const project.LevelEntry, rule: []const u8) ?Weight {
    for (levels) |entry| if (std.mem.eql(u8, entry.rule, rule)) return entry.weight;
    return null;
}

test "the default policy gates correctness, weighs the shipped bans as findings under the family's policy, and reports the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io };
    const policy = (try parse(&c, try parsed(c.a, "{}"), test_shipped)).?;
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    const told = policy.data(null);
    try std.testing.expect(told.strict_suppressions and told.metrics);
    try std.testing.expectEqual(fact_budget, told.fact_budget);
    for ([_][]const u8{ "Z003", "Z013", "Z026", "Z034", "P006" }) |rule| try std.testing.expectEqual(Weight.gate, weightOf(told.levels, rule).?);
    for ([_][]const u8{ "Z011", "P005" }) |rule| try std.testing.expectEqual(Weight.finding, weightOf(told.levels, rule).?);
    for ([_][]const u8{ "P003", "Z012", "Z016", "Z001", "Z006", "Z032", "D001" }) |rule| try std.testing.expectEqual(Weight.report, weightOf(told.levels, rule).?);
    // The readability report is left out: off, as glint has it.
    try std.testing.expectEqual(@as(?Weight, null), weightOf(told.levels, "Z024"));
    // The durability door and the whole-file read are the family's, and only its policy names
    // them; its floor holds every default, and the packages' defaults too. A stranger's project
    // has no floor, and lowering a rule is its choice, which glint notes.
    try std.testing.expectEqual(@as(usize, 0), told.disallowed.len);
    try std.testing.expectEqual(@as(?project.Floor, null), told.floor);
    const family_told = (try parse(&c, try parsed(c.a, "{\"policy\":\"family\"}"), test_shipped)).?.data("glint.json");
    try std.testing.expectEqual(durability.len + whole_reads.len, family_told.disallowed.len);
    try std.testing.expectEqual(family_told.levels.len, family_told.floor.?.rules.len);
    try std.testing.expect(family_told.floor.?.package_defaults and !family_told.floor.?.refuse_repo_options);
    try std.testing.expectEqualStrings("glint.json", family_told.repo_options.?);
    for (shipped_bans) |rule| {
        try std.testing.expectEqual(Weight.report, weightOf(told.levels, rule).?);
        try std.testing.expectEqual(Weight.finding, weightOf(family_told.levels, rule).?);
    }
    try std.testing.expectEqual(@as(usize, 3), told.shipped_bans.len);
}

test "a repository's rules reach glint as it wrote them, and a setting preflight does not read fails by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io };
    const amended = (try parse(&c, try parsed(c.a,
        \\{"glint":{"rules":[{"id":"Z006","level":"gate"},{"id":"A004","level":"report"},{"id":"Z026","level":"off"}]}}
    ), test_shipped)).?;
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    const rules = amended.data(null).config.?.rules;
    try std.testing.expectEqual(@as(usize, 3), rules.len);
    try std.testing.expectEqualStrings("A004", rules[1].id);
    try std.testing.expectEqual(project.Level.off, rules[2].level);
    // No amendment: no configuration.
    try std.testing.expectEqual(@as(?project.Written, null), (try parse(&c, try parsed(c.a, "{}"), test_shipped)).?.data(null).config);
    for ([_][]const u8{
        "{\"glint\":{\"strict_suppressions\":false}}",
        "{\"glint\":{\"profile\":\"none\"}}",
        "{\"glint\":{\"rule\":[]}}",
        "{\"glint\":{\"rules\":[{\"id\":\"Z006\",\"level\":\"loud\"}]}}",
        "{\"glint\":{\"rules\":[{\"id\":\"Z006\"}]}}",
        "{\"glint\":{\"rules\":{\"Z006\":\"gate\"}}}",
        "{\"glint\":{\"casts\":\"all\"}}",
        "{\"glint\":{\"cast_scope\":\"all\"}}",
        "{\"glint\":{\"unresolved\":{\"A007\":0}}}",
        "{\"glint\":{\"escapes\":3}}",
        "{\"glint\":{\"fact_budget\":0}}",
        "{\"glint\":{\"disallowed\":[]}}",
        "{\"glint\":3}",
        "{\"glint_paths\":[]}",
        "{\"function_exceptions\":{\"src/a.zig:f\":{\"lines\":9,\"reason\":\" \"}}}",
        "{\"function_exceptions\":{\"nocolon\":{\"lines\":9,\"reason\":\"why\"}}}",
        "{\"function_limit\":0}",
        "{\"vendored\":{\"src/a.zig\":\"\"}}",
        "{\"vendored\":{\"src/a.zig\":\"upstream, verified\"}}",
        "{\"vendored\":{\"src/a.zig\":{\"upstream\":\"u\",\"verification\":\"v\"}}}",
        "{\"vendored\":{\"src/a.zig\":{\"upstream\":\"u\",\"verification\":\" \",\"sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}}",
        "{\"vendored\":{\"src/a.zig\":{\"upstream\":\"u\",\"verification\":\"v\",\"sha256\":\"aaaa\"}}}",
        "{\"vendored\":{\"src/a.zig\":{\"upstream\":\"u\",\"verification\":\"v\",\"sha256\":\"zzaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}}",
        "{\"ziglint_exceptions\":\"ci/ziglint-exceptions.json\"}",
        "{\"unreachable_exceptions\":\"ci/u.json\"}",
        "{\"debug_print_exceptions\":\"ci/d.json\"}",
        "{\"ziglint_paths\":[\"src\"]}",
        "{\"glint_config\":\"ci/glint.json\"}",
        // A policy misspelt holds the project to none.
        "{\"policy\":\"famliy\"}",
    }) |text| {
        c.errors = 0;
        try std.testing.expectEqual(@as(?Policy, null), try parse(&c, try parsed(c.a, text), test_shipped));
        try std.testing.expect(c.errors != 0);
    }
}

test "a file is configured by its path: ceilings, exceptions, what ships and test support" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io };
    const policy = (try parse(&c, try parsed(c.a,
        \\{"function_limit":100,"function_limits":{"src/fold/*.zig":60,"src/**":90},
        \\ "test_support":["src/testing/**"],
        \\ "function_exceptions":{"src/big.zig:compress":{"lines":150,"reason":"one asm block"}}}
    ), test_shipped)).?;
    const a = c.a;
    try std.testing.expectEqual(@as(?u32, 60), policy.functionLines("src/fold/crc.zig"));
    try std.testing.expectEqual(@as(?u32, 90), policy.functionLines("src/other.zig"));
    // Outside the sources the length is not checked, unless a pattern names the path.
    try std.testing.expectEqual(@as(?u32, null), policy.functionLines("bench/main.zig"));
    try std.testing.expectEqual(@as(?u32, null), policy.functionLines("build.zig"));
    const big = try policy.exceptionsAt(a, "src/big.zig");
    try std.testing.expectEqual(@as(usize, 1), big.len);
    try std.testing.expectEqualStrings("compress", big[0].function);
    try std.testing.expectEqual(@as(usize, 0), (try policy.exceptionsAt(a, "src/other.zig")).len);
    // The build script ships, and runs in every consumer's build: the shipped bans hold it.
    // A tool the package develops with ships nowhere.
    try std.testing.expect(policy.ships("build.zig") and policy.ships("src/a/b.zig"));
    try std.testing.expect(!policy.ships("bench/main.zig") and !policy.ships("srcx/a.zig"));
    try std.testing.expectEqual(Policy.Kind.test_file, policy.kind("src/deep/x_test.zig"));
    try std.testing.expectEqual(Policy.Kind.test_file, policy.kind("src/tests.zig"));
    try std.testing.expectEqual(Policy.Kind.support, policy.kind("src/testing/lfs/harness.zig"));
    try std.testing.expectEqual(Policy.Kind.production, policy.kind("src/testing.zig"));
}
