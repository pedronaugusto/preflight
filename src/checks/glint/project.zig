//! The project file preflight hands glint (glint's program contract, version 1): the build's
//! modules, the files the lint selects with what each is, and the policy as data. glint reads it
//! and answers with its report; preflight writes it and never sees glint's types: the contract is
//! the file's text, its fields glint's `Contract.ProjectFile`, unknown fields refused there.
const std = @import("std");

/// The version this preflight writes, which `glint --contract` must list.
pub const version: u32 = 1;

pub const ProjectFile = struct {
    version: u32 = version,
    /// What every path below is relative to: the package's directory, where glint runs.
    root: []const u8 = ".",
    /// Zig's library, where `std` is; null leaves `std` unresolved.
    zig_lib: ?[]const u8,
    /// The release tier: every shipped ban's finding fails, the reported ones too.
    release: bool,
    modules: []const Module,
    exported: []const Exported,
    files: []const File,
    policy: Policy,
};

/// A module of the build, as `facts` reads it from the configured graph.
pub const Module = struct {
    root: ?[]const u8,
    contents: ?[]const u8,
    script: bool,
    imports: []const Binding,
};
pub const Binding = struct { name: []const u8, module: usize };
pub const Exported = struct { name: []const u8, root: []const u8 };

pub const File = struct {
    path: []const u8,
    kind: Kind,
    /// In what build.zig.zon ships: the shipped bans hold it.
    ships: bool,
    /// The function reading budget here; null: P003 is off.
    max_function_lines: ?u32,
    function_exceptions: []const FunctionException,
    /// The upstream's copy, verified by its SHA-256 before the run.
    vendored: ?Vendored,
};
pub const Kind = enum { production, @"test", support };
pub const FunctionException = struct { function: []const u8, lines: u32, reason: []const u8 };
pub const Vendored = struct { upstream: []const u8, verification: []const u8 };

pub const Policy = struct {
    levels: []const LevelEntry,
    /// Under the family's policy, what a repository may only raise; null outside it.
    floor: ?Floor,
    shipped_bans: []const []const u8,
    disallowed: []const Disallowed,
    fact_budget: usize,
    strict_suppressions: bool,
    metrics: bool,
    /// The repository's `glint` block of ci/preflight.json in glint's schema: its rules.
    config: ?Written,
    /// The repository's glint.json, where it has one.
    repo_options: ?[]const u8,
};
pub const Floor = struct {
    rules: []const LevelEntry,
    package_defaults: bool,
    refuse_repo_options: bool,
};
pub const Weight = enum { gate, finding, report, off };
pub const LevelEntry = struct { rule: []const u8, weight: Weight };
pub const Disallowed = struct {
    source: ?[]const u8 = null,
    declaration: []const u8,
    reason: []const u8,
    replacement: []const u8,
    scope: enum { all, production } = .all,
    owners: []const []const u8 = &.{},
};
/// glint's in-repo configuration, as written: only `rules` is preflight's to hand on, the
/// code options being glint.json's (`repo_options`).
pub const Written = struct { rules: []const Setting };
pub const Setting = struct { id: []const u8, level: Level };
pub const Level = enum { gate, report, off };

/// The file's text.
pub fn text(a: std.mem.Allocator, file: ProjectFile) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, file, .{});
}

test "a project file is glint's contract version 1, every field written, a null as null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const written = try text(a, .{
        .zig_lib = null,
        .release = false,
        .modules = &.{.{ .root = "src/root.zig", .contents = null, .script = false, .imports = &.{.{ .name = "self", .module = 0 }} }},
        .exported = &.{.{ .name = "sample", .root = "src/root.zig" }},
        .files = &.{.{ .path = "src/root.zig", .kind = .production, .ships = true, .max_function_lines = null, .function_exceptions = &.{}, .vendored = null }},
        .policy = .{ .levels = &.{.{ .rule = "Z026", .weight = .gate }}, .floor = null, .shipped_bans = &.{"P007"}, .disallowed = &.{}, .fact_budget = 1, .strict_suppressions = true, .metrics = true, .config = null, .repo_options = null },
    });
    try std.testing.expectEqualStrings(
        \\{"version":1,"root":".","zig_lib":null,"release":false,"modules":[{"root":"src/root.zig","contents":null,"script":false,"imports":[{"name":"self","module":0}]}],"exported":[{"name":"sample","root":"src/root.zig"}],"files":[{"path":"src/root.zig","kind":"production","ships":true,"max_function_lines":null,"function_exceptions":[],"vendored":null}],"policy":{"levels":[{"rule":"Z026","weight":"gate"}],"floor":null,"shipped_bans":["P007"],"disallowed":[],"fact_budget":1,"strict_suppressions":true,"metrics":true,"config":null,"repo_options":null}}
    , written);
}
