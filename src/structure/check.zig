//! Layers and cycles hold for the production graph, the edges a non-test
//! build compiles. Test code is in no layer: it may import anything, but no
//! production edge may reach it, and an inline test may not import a higher
//! layer than its file. An import no build compiles is unused.
const std = @import("std");
const gantry = @import("gantry");
const source = @import("../checks/source.zig");

/// A package's declared structure, from its `ci/layers.zig` and the test
/// code `ci/preflight.json` names.
pub const Declared = struct {
    /// Production sources, lowest layer first.
    layers: []const gantry.rules.Layer,
    /// Paths that must exist: production sources and test roots.
    required: []const []const u8 = &.{},
    /// Files nothing may import, besides every `main.zig`.
    entries: []const []const u8 = &.{},
    modules: []const gantry.NamedModule = &.{},
    references: []const gantry.rules.ReferenceRule = &.{},
    owned: []const gantry.rules.TokenRule = &.{},
    /// Path patterns of test code, as `source.testPaths` returns them.
    test_paths: []const []const u8,

    pub fn testCode(d: Declared, path: []const u8) bool {
        for (d.test_paths) |pattern| if (gantry.rules.matches(pattern, path)) return true;
        return false;
    }
};

pub fn options(d: Declared) gantry.Options {
    return .{
        .manifests = false,
        .strict_imports = true,
        .named_modules = d.modules,
        .test_paths = d.test_paths,
        .tokens = d.owned,
    };
}

/// Writes one line per problem and returns how many there are. The graph is
/// a full scan with `options(d)`; `a` should be an arena.
pub fn report(a: std.mem.Allocator, graph: *const gantry.Graph, d: Declared, out: *std.Io.Writer) !usize {
    var problems = try ownership(graph, d, out);
    problems += graph.unread().len;
    for (graph.unread()) |path| try out.print("imports: {s}: unread\n", .{path});
    problems += try unused(graph, out);
    // The entry rule reads the production graph, which holds no test code.
    for (d.entries) |path| if (d.testCode(path)) {
        try out.print("imports: entry files: {s}: test code, never checked\n", .{path});
        problems += 1;
    };

    var production = try productionGraph(a, graph, d);
    defer production.deinit();
    var found = try production.check(a, try productionRules(a, d));
    defer found.deinit();
    problems += try print(out, found.items());

    var full = try graph.check(a, try fullRules(a, d));
    defer full.deinit();
    problems += try print(out, full.items());
    return problems;
}

/// Every production source is in exactly one layer, every test source in
/// none. A glob over a directory covers its production files and passes
/// over the tests beside them; a literal pattern naming a test file fails.
fn ownership(graph: *const gantry.Graph, d: Declared, out: *std.Io.Writer) !usize {
    var problems: usize = 0;
    for (graph.paths()) |path| {
        const test_code = d.testCode(path);
        var owners: usize = 0;
        var owner: []const u8 = "";
        for (d.layers) |layer| for (layer.patterns) |pattern| {
            if (test_code and std.mem.findAny(u8, pattern, "*?") != null) continue;
            if (!gantry.rules.matches(pattern, path)) continue;
            owners += 1;
            owner = layer.name;
            break;
        };
        if (test_code) {
            if (owners == 0) continue;
            try out.print("imports: {s}: test source in a layer ({s})\n", .{ path, owner });
        } else if (owners > 1) {
            try out.print("imports: {s}: source belongs to multiple layers\n", .{path});
        } else if (owners == 0) {
            try out.print("imports: {s}: source has no named layer\n", .{path});
        } else continue;
        problems += 1;
    }
    return problems;
}

/// An import in a declaration nothing reaches, as gantry marks it: no build
/// compiles it.
fn unused(graph: *const gantry.Graph, out: *std.Io.Writer) !usize {
    var problems: usize = 0;
    for (graph.references()) |ref| if (ref.dead and ref.member == null) {
        try out.print("imports: unused imports: {s}: @import(\"{f}\")\n", .{ ref.from, std.zig.fmtString(ref.name) });
        problems += 1;
    };
    return problems;
}

/// Production sources and the edges between them that are not test edges.
/// An edge from production into test code is the full graph's to report.
fn productionGraph(a: std.mem.Allocator, graph: *const gantry.Graph, d: Declared) !gantry.Graph {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(a);
    for (graph.paths()) |path| if (!d.testCode(path)) try paths.append(a, path);
    var edges: std.ArrayList(gantry.Edge) = .empty;
    defer edges.deinit(a);
    for (graph.edges()) |edge| {
        if (edge.kind == .@"test" or d.testCode(edge.from) or d.testCode(edge.to)) continue;
        try edges.append(a, edge);
    }
    return gantry.Graph.fromEdges(a, paths.items, edges.items);
}

fn productionRules(a: std.mem.Allocator, d: Declared) !gantry.rules.Rules {
    const entries = try a.alloc(gantry.rules.EdgeRule, d.entries.len + 1);
    entries[0] = .{ .name = "entry files", .to = "**/main.zig" };
    for (d.entries, entries[1..]) |path, *rule| rule.* = .{ .name = "entry files", .to = path };
    const ordered = try a.alloc(gantry.rules.OrderedLayers, 1);
    ordered[0] = .{ .name = "layers", .layers = d.layers };
    return .{ .ordered = ordered, .nothing_imports = entries, .no_cycles = "cycles" };
}

fn fullRules(a: std.mem.Allocator, d: Declared) !gantry.rules.Rules {
    const forbidden = try a.alloc(gantry.rules.EdgeRule, d.test_paths.len);
    for (d.test_paths, forbidden) |pattern, *rule| rule.* = .{ .name = "production reaches tests", .to = pattern, .kind = .import };
    // "test layers" reads test edges from layered files alone: every other
    // kind, and every edge out of test code, is allowed.
    const kinds = comptime std.meta.tags(gantry.Kind);
    var allowed: std.ArrayList(gantry.rules.Allow) = .empty;
    for (kinds) |kind| if (kind != .@"test") try allowed.append(a, .{ .rule = "test layers", .kind = kind });
    for (d.test_paths) |pattern| try allowed.append(a, .{ .rule = "test layers", .from = pattern });
    const ordered = try a.alloc(gantry.rules.OrderedLayers, 1);
    ordered[0] = .{ .name = "test layers", .layers = d.layers };
    const required = try a.alloc(gantry.rules.Required, 1);
    required[0] = .{ .name = "named sources", .paths = d.required };
    return .{
        .ordered = ordered,
        .forbidden = forbidden,
        .allowed = allowed.items,
        .references = d.references,
        .required = required,
        .tokens = d.owned,
    };
}

fn print(out: *std.Io.Writer, findings: []const gantry.rules.Violation) !usize {
    for (findings) |finding| {
        if (finding.edge) |edge| {
            try out.print("imports: {s}: {s} -> {s} ({s})\n", .{ finding.rule, edge.from, edge.to, @tagName(finding.reason) });
        } else if (finding.reference) |ref| {
            try out.print("imports: {s}: {s}: @import(\"{s}\")\n", .{ finding.rule, ref.from, ref.name });
        } else if (finding.token) |token| {
            try out.print("imports: {s}: {s}:{d}:{d}: {t} \"{f}\"\n", .{ finding.rule, token.path, token.line, token.column, token.kind, std.zig.fmtString(token.text) });
        } else if (finding.path) |path| {
            try out.print("imports: {s}: {s}\n", .{ finding.rule, path });
        } else try out.print("imports: {s}: {t}\n", .{ finding.rule, finding.reason });
    }
    return findings.len;
}

const File = struct { path: []const u8, text: []const u8 };

fn readFile(_: std.mem.Allocator, _: std.Io, files: []const File, path: []const u8) error{}!?[]const u8 {
    for (files) |file| if (std.mem.eql(u8, file.path, path)) return file.text;
    return null;
}

const two_layers: []const gantry.rules.Layer = &.{
    .{ .name = "low", .patterns = &.{"src/low.zig"} },
    .{ .name = "high", .patterns = &.{"src/high.zig"} },
};

fn expectReport(files: []const File, layers: []const gantry.rules.Layer, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d: Declared = .{ .layers = layers, .entries = &.{"src/tool.zig"}, .test_paths = try source.testPaths(a, .null) };
    var paths: std.ArrayList([]const u8) = .empty;
    for (files) |file| try paths.append(a, file.path);
    var graph = try gantry.scan(a, std.testing.io, paths.items, files, readFile, options(d));
    defer graph.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    const problems = try report(a, &graph, d, &out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
    try std.testing.expectEqual(std.mem.count(u8, expected, "\n"), problems);
}

test "an upward production edge fails the layers" {
    try expectReport(&.{
        .{ .path = "src/low.zig", .text = "pub const high = @import(\"high.zig\");\n" },
        .{ .path = "src/high.zig", .text = "pub const x = 1;\n" },
    }, two_layers, "imports: layers: src/low.zig -> src/high.zig (upward)\n");
}

test "an upward import inside a test block passes the layers and fails the test layers" {
    try expectReport(&.{
        .{ .path = "src/low.zig", .text = "pub const x = 1;\ntest { _ = @import(\"high.zig\"); }\n" },
        .{ .path = "src/high.zig", .text = "pub const low = @import(\"low.zig\");\n" },
    }, two_layers, "imports: test layers: src/low.zig -> src/high.zig (upward)\n");
}

test "an alias only tests use is a test edge" {
    try expectReport(&.{
        .{ .path = "src/low.zig", .text = "const high = @import(\"high.zig\");\npub const x = 1;\ntest { _ = high; }\n" },
        .{ .path = "src/high.zig", .text = "pub const low = @import(\"low.zig\");\n" },
    }, two_layers, "imports: test layers: src/low.zig -> src/high.zig (upward)\n");
}

test "a test file imports anything and sits in no layer" {
    try expectReport(&.{
        .{ .path = "src/low.zig", .text = "pub const x = 1;\n" },
        .{ .path = "src/high.zig", .text = "pub const low = @import(\"low.zig\");\n" },
        .{ .path = "src/low_test.zig", .text = "const high = @import(\"high.zig\");\nconst fixture = @import(\"testing/deep/fixture.zig\");\ntest { _ = high; _ = fixture; }\n" },
        .{ .path = "src/testing/deep/fixture.zig", .text = "pub const low = @import(\"../../low.zig\");\n" },
        .{ .path = "src/tests.zig", .text = "test { _ = @import(\"low_test.zig\"); _ = @import(\"high.zig\"); }\n" },
    }, two_layers, "");
}

test "a fixture listed in a layer fails" {
    const layers: []const gantry.rules.Layer = &.{
        .{ .name = "low", .patterns = &.{ "src/low.zig", "src/testing/fixture.zig" } },
        .{ .name = "high", .patterns = &.{"src/high.zig"} },
    };
    try expectReport(&.{
        .{ .path = "src/low.zig", .text = "pub const x = 1;\n" },
        .{ .path = "src/high.zig", .text = "pub const x = 1;\n" },
        .{ .path = "src/testing/fixture.zig", .text = "pub const x = 1;\n" },
    }, layers, "imports: src/testing/fixture.zig: test source in a layer (low)\n");
}

test "production code that imports test code fails" {
    try expectReport(&.{
        .{ .path = "src/low.zig", .text = "pub const x = 1;\n" },
        .{ .path = "src/high.zig", .text = "pub const fixture = @import(\"testing/x.zig\");\npub const helper = @import(\"low_test.zig\");\n" },
        .{ .path = "src/testing/x.zig", .text = "pub const x = 1;\n" },
        .{ .path = "src/low_test.zig", .text = "pub const x = 1;\n" },
    }, two_layers,
        \\imports: production reaches tests: src/high.zig -> src/low_test.zig (forbidden)
        \\imports: production reaches tests: src/high.zig -> src/testing/x.zig (forbidden)
        \\
    );
}

test "a cycle through a test edge passes, a production cycle fails" {
    const layers: []const gantry.rules.Layer = &.{.{ .name = "one", .patterns = &.{ "src/low.zig", "src/high.zig" } }};
    try expectReport(&.{
        .{ .path = "src/low.zig", .text = "pub const high = @import(\"high.zig\");\n" },
        .{ .path = "src/high.zig", .text = "pub const x = 1;\ntest { _ = @import(\"low.zig\"); }\n" },
    }, layers, "");
    try expectReport(&.{
        .{ .path = "src/low.zig", .text = "pub const high = @import(\"high.zig\");\n" },
        .{ .path = "src/high.zig", .text = "pub const low = @import(\"low.zig\");\n" },
    }, layers, "imports: cycles: src/high.zig -> src/low.zig (cycle)\n");
}

test "every production source has exactly one layer" {
    const layers: []const gantry.rules.Layer = &.{
        .{ .name = "low", .patterns = &.{ "src/low.zig", "src/both.zig" } },
        .{ .name = "high", .patterns = &.{ "src/high.zig", "src/b*.zig" } },
    };
    try expectReport(&.{
        .{ .path = "src/low.zig", .text = "pub const x = 1;\n" },
        .{ .path = "src/high.zig", .text = "pub const x = 1;\n" },
        .{ .path = "src/both.zig", .text = "pub const x = 1;\n" },
        .{ .path = "src/deep/stray.zig", .text = "pub const x = 1;\n" },
    }, layers,
        \\imports: src/both.zig: source belongs to multiple layers
        \\imports: src/deep/stray.zig: source has no named layer
        \\
    );
}

test "an entry imported by production fails, by a test passes" {
    const layers: []const gantry.rules.Layer = &.{
        .{ .name = "low", .patterns = &.{"src/tool.zig"} },
        .{ .name = "high", .patterns = &.{"src/high.zig"} },
    };
    try expectReport(&.{
        .{ .path = "src/tool.zig", .text = "pub fn main() void {}\n" },
        .{ .path = "src/high.zig", .text = "pub const x = 1;\ntest { _ = @import(\"tool.zig\"); }\n" },
    }, layers, "");
    try expectReport(&.{
        .{ .path = "src/tool.zig", .text = "pub fn main() void {}\n" },
        .{ .path = "src/high.zig", .text = "pub const tool = @import(\"tool.zig\");\n" },
    }, layers, "imports: entry files: src/high.zig -> src/tool.zig (entry)\n");
}

test "an import nothing reaches is unused, in production and test code" {
    try expectReport(&.{
        .{ .path = "src/low.zig", .text = "const std = @import(\"std\");\nfn helper() void { _ = std; }\npub const x = 1;\n" },
        .{ .path = "src/high.zig", .text = "const low = @import(\"low.zig\");\npub const y = 1;\n" },
        .{ .path = "src/low_test.zig", .text = "const low = @import(\"low.zig\");\nconst unused = low.x;\ntest {}\n" },
    }, two_layers,
        \\imports: unused imports: src/high.zig: @import("low.zig")
        \\imports: unused imports: src/low.zig: @import("std")
        \\imports: unused imports: src/low_test.zig: @import("low.zig")
        \\
    );
}

test "a decl literal reaches its declaration and its import" {
    try expectReport(&.{
        .{ .path = "src/low.zig", .text = "pub const v = 1;\n" },
        .{ .path = "src/high.zig", .text = "const Self = @This();\nconst low = @import(\"low.zig\");\nx: u32,\nconst default: Self = .{ .x = low.v };\npub fn init() Self { return .default; }\n" },
    }, two_layers, "");
}

test "a glob over a directory leaves its test files out of the layer" {
    const layers: []const gantry.rules.Layer = &.{
        .{ .name = "low", .patterns = &.{"src/low/**"} },
        .{ .name = "high", .patterns = &.{"src/*.zig"} },
    };
    try expectReport(&.{
        .{ .path = "src/low/json.zig", .text = "pub const x = 1;\n" },
        .{ .path = "src/low/json_test.zig", .text = "const json = @import(\"json.zig\");\ntest { _ = json; }\n" },
        .{ .path = "src/low/testing/fixture.zig", .text = "pub const x = 1;\n" },
        .{ .path = "src/high.zig", .text = "pub const json = @import(\"low/json.zig\");\n" },
        .{ .path = "src/tests.zig", .text = "test { _ = @import(\"low/json_test.zig\"); _ = @import(\"low/testing/fixture.zig\"); }\n" },
    }, layers, "");
}

test "an entry that is test code is reported, since no production rule reads it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d: Declared = .{ .layers = two_layers, .entries = &.{ "src/testing/helper.zig", "src/test_runner.zig" }, .test_paths = try source.testPaths(a, .null) };
    const files = [_]File{
        .{ .path = "src/low.zig", .text = "pub const x = 1;\n" },
        .{ .path = "src/high.zig", .text = "pub const x = 1;\n" },
        .{ .path = "src/testing/helper.zig", .text = "pub fn main() void {}\n" },
        .{ .path = "src/test_runner.zig", .text = "pub fn main() void {}\n" },
    };
    var paths: std.ArrayList([]const u8) = .empty;
    for (files) |file| try paths.append(a, file.path);
    var graph = try gantry.scan(a, std.testing.io, paths.items, @as([]const File, &files), readFile, options(d));
    defer graph.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    try std.testing.expectEqual(@as(usize, 2), try report(a, &graph, d, &out.writer));
    try std.testing.expectEqualStrings(
        \\imports: entry files: src/testing/helper.zig: test code, never checked
        \\imports: entry files: src/test_runner.zig: test code, never checked
        \\
    , out.written());
}
