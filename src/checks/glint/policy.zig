//! What glint's rules weigh in preflight's default policy, and where the exceptions are.
//! glint decides what a rule finds; this decides which rules run, at which
//! level, on which file, from `ci/preflight.json`.
const std = @import("std");
const gantry = @import("gantry");
const glint = @import("glint");
const src = @import("../source.zig");

/// The rules a program can adopt beyond the default: glint's aegis pack.
pub const project_rules = glint.AegisPack.rules;

/// Work glint may do on one run. The largest repository preflight checks fits in
/// a fraction of it; a run that spends it is incomplete, never green.
pub const fact_budget: usize = 4_000_000;

/// How a rule weighs on the gate.
///
/// `gate` is glint's: its findings fail the run, and so does any site it
/// could not decide. `finding` is preflight's for rules whose sites glint
/// can only partly resolve (a call through an unknown receiver is not a
/// verdict either way): glint reports them, and any finding it does make
/// fails the run, while the sites it could not resolve are counted and do not.
/// `report` prints and never fails. `off` does not run.
pub const Weight = enum { gate, finding, report, off };

const Entry = struct { rule: glint.Rule, weight: Weight };
/// preflight's default policy. Correctness and the
/// package's own declared policy gate, as the ziglint fork's selection did; the
/// Zig style rules, and the discarded errors (Z026), are reported until a
/// package is clean under them and gates them itself: glint finds 3 times the
/// sites the fork's Z026 did,
/// and the review's order is reported, then gated. The readability report
/// (Z024) stays off, as the fork's selection kept it.
const defaults = [_]Entry{
    .{ .rule = .Z003, .weight = .gate },
    .{ .rule = .Z011, .weight = .finding },
    .{ .rule = .Z013, .weight = .gate },
    .{ .rule = .P001, .weight = .gate },
    .{ .rule = .P002, .weight = .gate },
    .{ .rule = .P003, .weight = .gate },
    .{ .rule = .P004, .weight = .gate },
    .{ .rule = .P005, .weight = .finding },
    .{ .rule = .Z026, .weight = .report },
    .{ .rule = .Z012, .weight = .report },
    .{ .rule = .Z016, .weight = .report },
    .{ .rule = .Z001, .weight = .report },
    .{ .rule = .Z005, .weight = .report },
    .{ .rule = .Z006, .weight = .report },
    .{ .rule = .Z009, .weight = .report },
    .{ .rule = .Z014, .weight = .report },
    .{ .rule = .Z031, .weight = .report },
    .{ .rule = .Z032, .weight = .report },
};

/// Keys that were ziglint's or a ledger's. A repository still naming one
/// would lose the gate it believes it has, so each fails by name.
const retired = [_]struct { key: []const u8, instead: []const u8 }{
    .{ .key = "ziglint_exceptions", .instead = "write `// glint-ignore: <rule> -- <reason>` at the site" },
    .{ .key = "ziglint_paths", .instead = "name the files in `glint_paths`" },
    .{ .key = "unreachable_exceptions", .instead = "write `// unreachable: <why>`, or `// glint-ignore: P004 -- <reason>`, at the site" },
    .{ .key = "debug_print_exceptions", .instead = "write `// glint-ignore: P005 -- <reason>` at the site" },
    .{ .key = "glint_config", .instead = "move its fields into the `glint` object" },
};

const glint_keys = [_][]const u8{ "rules", "casts", "cast_scope", "strict_suppressions", "fact_budget", "max_line_length", "disallowed" };

pub const Limit = struct { pattern: *const gantry.rules.Pattern, lines: u32 };
pub const Exception = struct { path: []const u8, function: []const u8, lines: u32, reason: []const u8 };

pub const Policy = struct {
    /// glint's configuration for a file nothing below sets apart.
    base: glint.Config,
    /// Rules whose findings fail the run although glint reports them.
    findings: []const glint.Rule,
    function_limit: u32,
    /// Where function length is checked: the shipped `sources`, and any path
    /// a `function_limits` pattern names.
    sources: []const []const u8,
    limits: []const Limit,
    exceptions: []const Exception,
    vendored: []const []const u8,
    /// Test code by name and by `test_support`.
    tests: []const *const gantry.rules.Pattern,
    /// The part of `tests` that is a test by its file name alone.
    named_tests: []const *const gantry.rules.Pattern,
    /// `glint_paths`, when the repository names its own selection.
    paths: ?[]const []const u8,

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

    pub fn isVendored(policy: Policy, path: []const u8) bool {
        for (policy.vendored) |name| if (std.mem.eql(u8, name, path)) return true;
        return false;
    }

    pub fn fails(policy: Policy, rule: glint.Rule) bool {
        for (policy.findings) |named| if (named == rule) return true;
        return false;
    }

    /// glint's configuration for one file: the base, its function ceilings
    /// and exceptions, what a vendored fork is exempt from and what
    /// test support is not.
    pub fn forFile(policy: Policy, a: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error!glint.Config {
        var config = policy.base;
        var limit = policy.function_limit;
        var named = false;
        for (policy.limits) |entry| if (entry.pattern.matches(path)) {
            limit = @min(limit, entry.lines);
            named = true;
        };
        config.max_function_lines = limit;
        // The length of a function was never checked outside the sources, and a
        // build script or an example is long for reasons of its own: a
        // repository that wants a ceiling there names the path.
        if (!named and !policy.inSources(path)) config = try withLevel(a, config, .P003, .off);
        var exceptions: std.ArrayList(glint.Config.FunctionException) = .empty;
        for (policy.exceptions) |entry| if (std.mem.eql(u8, entry.path, path)) {
            try exceptions.append(a, .{ .function = entry.function, .lines = entry.lines, .reason = entry.reason });
        };
        config.function_exceptions = exceptions.items;
        // Test support is code the package writes and ships to its tests; only
        // a file that is a test by its name is exempt from the cast reasons.
        if (policy.kind(path) == .support) config.cast_scope = .all;
        if (policy.isVendored(path)) {
            config = try withLevel(a, config, .P001, .off);
            config = try withLevel(a, config, .P003, .off);
        }
        return config;
    }
};

fn withLevel(a: std.mem.Allocator, config: glint.Config, rule: glint.Rule, level: glint.Config.Level) std.mem.Allocator.Error!glint.Config {
    const selections = try a.alloc(glint.Config.Selection, config.selections.len + 1);
    @memcpy(selections[0..config.selections.len], config.selections);
    var count = config.selections.len;
    for (selections[0..count]) |*selection| if (selection.rule == rule) {
        selection.level = level;
        var changed = config;
        changed.selections = selections[0..count];
        return changed;
    };
    selections[count] = .{ .rule = rule, .level = level };
    count += 1;
    var changed = config;
    changed.selections = selections[0..count];
    return changed;
}

fn levelOf(weight: Weight) glint.Config.Level {
    return switch (weight) {
        .gate => .gate,
        .finding, .report => .report,
        .off => .off,
    };
}

/// Reads the default policy and the repository's amendments to it. Anything
/// the repository wrote that cannot be honoured is reported and yields null:
/// a setting that is ignored is a gate that is not there.
pub fn parse(c: *src.Context, config: src.Value) !?Policy {
    const a = c.a;
    const before = c.errors;
    for (retired) |entry| if (src.get(config, entry.key) != .null) c.fail("glint: `{s}` is retired: {s}", .{ entry.key, entry.instead });

    var base: glint.Config = glint.Config.none();
    base.strict_suppressions = true;
    base.fact_budget = fact_budget;
    base.cast_scope = .production;
    base.casts = .pointer;

    const block = src.get(config, "glint");
    var chosen: std.ArrayList(glint.Config.Selection) = .empty;
    if (block != .null and block != .object) c.fail("glint: the `glint` setting is an object", .{});
    if (block == .object) {
        var keys = block.object.iterator();
        while (keys.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "profile")) {
                c.fail("glint: `profile` is not a setting: the default policy is preflight's, and a repository amends it by rule in `rules`", .{});
            } else if (!known(&glint_keys, key)) c.fail("glint: unknown setting `{s}`", .{key});
        }
        try parseBlock(c, block, &base, &chosen);
    }
    if (c.errors != before) return null;

    // The default rules at their weight, each amended by the repository's
    // choice; then the rules only the repository chose.
    var all: std.ArrayList(glint.Config.Selection) = .empty;
    var findings: std.ArrayList(glint.Rule) = .empty;
    for (defaults) |entry| {
        var weight = entry.weight;
        for (chosen.items) |amendment| if (amendment.rule == entry.rule) {
            weight = switch (amendment.level) {
                .gate => .gate,
                // A finding rule stays one: its weight is the default's, not a lesser level of glint's.
                .report => if (entry.weight == .finding) .finding else .report,
                .off => .off,
            };
        };
        if (weight == .finding) try findings.append(a, entry.rule);
        try all.append(a, .{ .rule = entry.rule, .level = levelOf(weight) });
    }
    for (chosen.items) |amendment| {
        var named = false;
        for (defaults) |entry| named = named or entry.rule == amendment.rule;
        if (!named) try all.append(a, amendment);
    }
    if (base.disallowed.len != 0) {
        var named = false;
        for (chosen.items) |amendment| named = named or amendment.rule == .P006;
        if (!named) try all.append(a, .{ .rule = .P006, .level = .gate });
    }
    base.selections = all.items;
    base.validate() catch {
        c.fail("glint: the `glint` setting is not valid: a rule is listed twice, or a disallowed declaration lacks its reason, replacement or source", .{});
        return null;
    };

    var globs: gantry.rules.Globs = .{ .arena = a };
    var policy: Policy = .{
        .base = base,
        .findings = findings.items,
        .function_limit = 120,
        .sources = try src.roots(a, config),
        .limits = &.{},
        .exceptions = &.{},
        .vendored = &.{},
        .tests = try globs.list(.path, try src.testPaths(a, config)),
        .named_tests = try globs.list(.path, &src.test_files),
        .paths = null,
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

fn parseBlock(c: *src.Context, block: src.Value, base: *glint.Config, selections: *std.ArrayList(glint.Config.Selection)) !void {
    const a = c.a;
    const rules = src.get(block, "rules");
    if (rules != .null and rules != .array) c.fail("glint: `rules` is a list of {{id, level}}", .{});
    const definitions = ruleDefinitions();
    for (src.items(rules)) |entry| {
        const id = src.get(entry, "id");
        const named = src.get(entry, "level");
        if (id != .string or named != .string) {
            c.fail("glint: a rule needs an `id` and a `level` (off, report or gate)", .{});
            continue;
        }
        const chosen = std.meta.stringToEnum(glint.Config.Level, named.string) orelse {
            c.fail("glint: {s}: level `{s}` is not off, report or gate", .{ id.string, named.string });
            continue;
        };
        const rule = glint.parseRule(id.string, &definitions) orelse {
            c.fail("glint: `{s}` is not a rule glint has (a removed rule is not an alias of anything)", .{id.string});
            continue;
        };
        for (selections.items) |earlier| if (earlier.rule == rule) c.fail("glint: {s} is listed twice", .{id.string});
        try selections.append(a, .{ .rule = rule, .level = chosen });
    }
    const casts = src.get(block, "casts");
    if (casts != .null) base.casts = std.meta.stringToEnum(@TypeOf(base.casts), src.string(casts, "")) orelse blk: {
        c.fail("glint: `casts` is all or pointer", .{});
        break :blk base.casts;
    };
    const scope = src.get(block, "cast_scope");
    if (scope != .null) base.cast_scope = std.meta.stringToEnum(@TypeOf(base.cast_scope), src.string(scope, "")) orelse blk: {
        c.fail("glint: `cast_scope` is all or production", .{});
        break :blk base.cast_scope;
    };
    const strict = src.get(block, "strict_suppressions");
    if (strict != .null) {
        if (strict == .bool) base.strict_suppressions = strict.bool else c.fail("glint: `strict_suppressions` is true or false", .{});
    }
    const budget = src.get(block, "fact_budget");
    if (budget != .null) {
        if (budget == .integer and budget.integer > 0) base.fact_budget = @intCast(budget.integer) else c.fail("glint: `fact_budget` is a positive count", .{});
    }
    const width = src.get(block, "max_line_length");
    if (width != .null) {
        if (width == .integer and width.integer > 0 and width.integer <= std.math.maxInt(u32)) base.max_line_length = @intCast(width.integer) else c.fail("glint: `max_line_length` is a positive byte count", .{});
    }
    const disallowed = src.get(block, "disallowed");
    if (disallowed != .null and disallowed != .array) c.fail("glint: `disallowed` is a list of {{source, declaration, reason, replacement}}", .{});
    var list: std.ArrayList(glint.Config.Disallowed) = .empty;
    for (src.items(disallowed)) |entry| {
        var fields: [4][]const u8 = undefined;
        for ([_][]const u8{ "source", "declaration", "reason", "replacement" }, &fields) |key, *field| {
            const value = src.get(entry, key);
            field.* = if (value == .string) value.string else "";
        }
        try list.append(a, .{ .source = fields[0], .declaration = fields[1], .reason = fields[2], .replacement = fields[3] });
    }
    base.disallowed = list.items;
}

fn ruleDefinitions() [project_rules.len]glint.RuleDefinition {
    var out: [project_rules.len]glint.RuleDefinition = undefined;
    for (project_rules, &out) |rule, *definition| definition.* = rule.definition;
    return out;
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
        if (lines != .integer or lines.integer < 1 or lines.integer > std.math.maxInt(u32)) {
            c.fail("glint: function_limits: {s}: a positive line count", .{entry.key_ptr.*});
            continue;
        }
        try out.append(c.a, .{ .pattern = try globs.get(.path, entry.key_ptr.*), .lines = @intCast(lines.integer) });
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
        const reason = std.mem.trim(u8, src.string(src.get(entry.value_ptr.*, "reason"), ""), " \t\r\n");
        if (lines != .integer or lines.integer < 1 or lines.integer > std.math.maxInt(u32) or reason.len == 0 or split == 0 or split + 1 == label.len) {
            c.fail("glint: function_exceptions: {s}: needs a line ceiling and a reason", .{label});
            continue;
        }
        try out.append(c.a, .{ .path = label[0..split], .function = label[split + 1 ..], .lines = @intCast(lines.integer), .reason = reason });
    }
    return out.items;
}

fn parseVendored(c: *src.Context, value: src.Value) ![]const []const u8 {
    if (value == .null) return &.{};
    if (value != .object) {
        c.fail("glint: vendored maps a path to its upstream and how the fork is verified", .{});
        return &.{};
    }
    var out: std.ArrayList([]const u8) = .empty;
    var entries = value.object.iterator();
    while (entries.next()) |entry| {
        if (std.mem.trim(u8, src.string(entry.value_ptr.*, ""), " \t\r\n").len == 0)
            c.fail("vendored: {s} needs provenance and verification", .{entry.key_ptr.*});
        try out.append(c.a, entry.key_ptr.*);
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

test "the default policy gates what the fork gated and reports the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io };
    const policy = (try parse(&c, try parsed(c.a, "{}"))).?;
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    try std.testing.expect(policy.base.strict_suppressions);
    try std.testing.expectEqual(.production, policy.base.cast_scope);
    try std.testing.expectEqual(.pointer, policy.base.casts);
    for ([_]glint.Rule{ .Z003, .Z013, .P001, .P002, .P003, .P004 }) |rule| try std.testing.expectEqual(.gate, policy.base.level(rule));
    for ([_]glint.Rule{ .Z011, .P005, .Z026, .Z012, .Z016, .Z001, .Z006, .Z032 }) |rule| try std.testing.expectEqual(.report, policy.base.level(rule));
    for ([_]glint.Rule{ .Z024, .P006, .D001 }) |rule| try std.testing.expectEqual(.off, policy.base.level(rule));
    try std.testing.expect(policy.fails(.Z011) and policy.fails(.P005));
    try std.testing.expect(!policy.fails(.Z012) and !policy.fails(.Z001));
    for (glint.AegisPack.rules) |rule| try std.testing.expectEqual(.off, policy.base.level(rule.definition.id));
}

test "a repository amends the policy by rule and cannot swap it for another profile" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io };
    const amended = (try parse(&c, try parsed(c.a,
        \\{"glint":{"rules":[{"id":"A004","level":"gate"},{"id":"Z006","level":"gate"},{"id":"P005","level":"off"}],"cast_scope":"all","casts":"all","strict_suppressions":false}}
    ))).?;
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    try std.testing.expectEqual(.gate, amended.base.level(glint.AegisPack.rules[3].definition.id));
    try std.testing.expectEqual(.gate, amended.base.level(.Z006));
    try std.testing.expectEqual(.off, amended.base.level(.P005));
    try std.testing.expect(!amended.fails(.P005) and amended.fails(.Z011));
    try std.testing.expectEqual(.all, amended.base.cast_scope);
    try std.testing.expect(!amended.base.strict_suppressions);
    // Asking a finding rule to report keeps it a finding: its weight is the default's.
    const same = (try parse(&c, try parsed(c.a, "{\"glint\":{\"rules\":[{\"id\":\"Z011\",\"level\":\"report\"}]}}"))).?;
    try std.testing.expect(same.fails(.Z011));
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    for ([_][]const u8{
        "{\"glint\":{\"profile\":\"none\"}}",
        "{\"glint\":{\"rule\":[]}}",
        "{\"glint\":{\"rules\":[{\"id\":\"Z999\",\"level\":\"gate\"}]}}",
        "{\"glint\":{\"rules\":[{\"id\":\"Z004\",\"level\":\"gate\"}]}}",
        "{\"glint\":{\"rules\":[{\"id\":\"Z006\",\"level\":\"loud\"}]}}",
        "{\"glint\":{\"rules\":[{\"id\":\"Z006\",\"level\":\"gate\"},{\"id\":\"Z006\",\"level\":\"off\"}]}}",
        "{\"glint\":{\"casts\":\"some\"}}",
        "{\"glint\":{\"fact_budget\":0}}",
        "{\"glint\":{\"disallowed\":[{\"source\":\"src/a.zig\",\"declaration\":\"x\",\"reason\":\"\",\"replacement\":\"y\"}]}}",
        "{\"glint_paths\":[]}",
        "{\"function_exceptions\":{\"src/a.zig:f\":{\"lines\":9,\"reason\":\" \"}}}",
        "{\"function_exceptions\":{\"nocolon\":{\"lines\":9,\"reason\":\"why\"}}}",
        "{\"function_limit\":0}",
        "{\"vendored\":{\"src/a.zig\":\"\"}}",
        "{\"ziglint_exceptions\":\"ci/ziglint-exceptions.json\"}",
        "{\"unreachable_exceptions\":\"ci/u.json\"}",
        "{\"debug_print_exceptions\":\"ci/d.json\"}",
        "{\"ziglint_paths\":[\"src\"]}",
        "{\"glint_config\":\"ci/glint.json\"}",
    }) |text| {
        c.errors = 0;
        try std.testing.expectEqual(@as(?Policy, null), try parse(&c, try parsed(c.a, text)));
        try std.testing.expect(c.errors != 0);
    }
}

test "a file is configured by its path: ceilings, exceptions, vendored forks and test support" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io };
    const policy = (try parse(&c, try parsed(c.a,
        \\{"function_limit":100,"function_limits":{"src/fold/*.zig":60,"src/**":90},"vendored":{"src/tls.zig":"std, verified by check-tls"},
        \\ "test_support":["src/testing/**"],
        \\ "function_exceptions":{"src/big.zig:compress":{"lines":150,"reason":"one asm block"}}}
    ))).?;
    const a = c.a;
    try std.testing.expectEqual(@as(u32, 60), (try policy.forFile(a, "src/fold/crc.zig")).max_function_lines);
    try std.testing.expectEqual(@as(u32, 90), (try policy.forFile(a, "src/other.zig")).max_function_lines);
    try std.testing.expectEqual(@as(u32, 90), (try policy.forFile(a, "src/main.zig")).max_function_lines);
    // Outside the sources the length is not checked, unless a pattern names the path.
    try std.testing.expectEqual(.off, (try policy.forFile(a, "bench/main.zig")).level(.P003));
    try std.testing.expectEqual(.off, (try policy.forFile(a, "build.zig")).level(.P003));
    try std.testing.expectEqual(.gate, (try policy.forFile(a, "src/main.zig")).level(.P003));
    const big = try policy.forFile(a, "src/big.zig");
    try std.testing.expectEqual(@as(usize, 1), big.function_exceptions.len);
    try std.testing.expectEqualStrings("compress", big.function_exceptions[0].function);
    try std.testing.expectEqual(@as(usize, 0), (try policy.forFile(a, "src/other.zig")).function_exceptions.len);
    const forked = try policy.forFile(a, "src/tls.zig");
    try std.testing.expectEqual(.off, forked.level(.P001));
    try std.testing.expectEqual(.off, forked.level(.P003));
    try std.testing.expectEqual(.report, forked.level(.Z026));
    try std.testing.expectEqual(.gate, (try policy.forFile(a, "src/other.zig")).level(.P001));
    try std.testing.expectEqual(Policy.Kind.test_file, policy.kind("src/deep/x_test.zig"));
    try std.testing.expectEqual(Policy.Kind.test_file, policy.kind("src/tests.zig"));
    try std.testing.expectEqual(Policy.Kind.support, policy.kind("src/testing/lfs/harness.zig"));
    try std.testing.expectEqual(Policy.Kind.production, policy.kind("src/testing.zig"));
    // Support is code the package writes: its casts need their reasons, test blocks included.
    try std.testing.expectEqual(.all, (try policy.forFile(a, "src/testing/lfs/harness.zig")).cast_scope);
    try std.testing.expectEqual(.production, (try policy.forFile(a, "src/x_test.zig")).cast_scope);
}
