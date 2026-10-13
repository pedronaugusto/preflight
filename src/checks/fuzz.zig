//! The untrusted-input report: the parsers and decoders a package exports
//! with no fuzz target. Report only; it never fails a check.
//!
//! A parser is a public function of the package's own code (not a test,
//! not test support) named as one (`parse…`, `decode…`, `deserialize…`,
//! `unpack…`, `unmarshal…`, `fromBytes…`) that takes bytes or a reader, or
//! any function `ci/preflight.json` names under `fuzz.parsers`. A fuzz
//! target is a test that runs a shakedown `check` property or
//! `std.testing.fuzz`; a parser is fuzzed when such a test reaches it by
//! name, in its body or in a function of the package the body calls, by
//! name, some calls deep: a property that drives a whole pipeline (a scan
//! that hands each file to its parser) reaches the parsers through it. `fuzz.trusted` names a parser whose input is the package's
//! own, with the reason, and leaves it out.
const std = @import("std");
const Ast = std.zig.Ast;
const src = @import("source.zig");

pub const Parser = struct { path: []const u8, name: []const u8, line: usize };

pub const Report = struct {
    parsers: []const Parser,
    unfuzzed: []const Parser,
};

const verbs = [_][]const u8{ "parse", "decode", "deserialize", "unpack", "unmarshal", "fromBytes" };

/// How many calls deep from a fuzz target a parser is looked for.
const reach_depth = 8;

pub fn report(a: std.mem.Allocator, sources: []const src.Source, config: src.Value) !Report {
    const fuzz = src.get(config, "fuzz");
    const named = try src.strings(a, src.get(fuzz, "parsers"));
    const trusted = src.get(fuzz, "trusted");
    var parsers: std.ArrayList(Parser) = .empty;
    var functions: Functions = .empty;
    for (sources) |*s| {
        const test_code = try src.testCode(a, s.path, config);
        if (!test_code) try collectParsers(a, s.*, named, trusted, &parsers);
        try collectFunctions(a, s, &functions);
    }
    var reached: std.StringHashMapUnmanaged(void) = .empty;
    for (sources) |*s| try collectReached(a, s, &functions, &reached);
    var unfuzzed: std.ArrayList(Parser) = .empty;
    for (parsers.items) |p| if (!reached.contains(p.name)) try unfuzzed.append(a, p);
    return .{ .parsers = parsers.items, .unfuzzed = unfuzzed.items };
}

fn isTrusted(trusted: src.Value, name: []const u8) bool {
    return trusted == .object and trusted.object.get(name) != null;
}

fn collectParsers(a: std.mem.Allocator, s: src.Source, named: []const []const u8, trusted: src.Value, out: *std.ArrayList(Parser)) !void {
    const tree = s.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .fn_decl) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, node).?;
        const name_token = proto.name_token orelse continue;
        const name = tree.tokenSlice(name_token);
        if (isTrusted(trusted, name)) continue;
        const listed = for (named) |n| {
            if (std.mem.eql(u8, n, name)) break true;
        } else false;
        if (!listed) {
            const visible = proto.visib_token != null;
            if (!visible or !verbNamed(name) or !takesInput(tree, proto)) continue;
        }
        try out.append(a, .{ .path = s.path, .name = name, .line = s.line(name_token) });
    }
}

fn verbNamed(name: []const u8) bool {
    for (verbs) |verb| if (std.mem.startsWith(u8, name, verb)) return true;
    return false;
}

/// Whether a parameter is bytes or a reader.
fn takesInput(tree: Ast, proto: Ast.full.FnProto) bool {
    var it = proto.iterate(&tree);
    while (it.next()) |param| {
        const type_node = param.type_expr orelse continue;
        const text = tree.getNodeSource(type_node);
        for ([_][]const u8{ "[]const u8", "[:0]const u8", "Reader" }) |shape| {
            if (std.mem.find(u8, text, shape) != null) return true;
        }
    }
    return false;
}

/// A function of the package, by its name: where it is.
const Function = struct { source: *const src.Source, node: Ast.Node.Index };
/// Every function of the package by name; one name may be several functions.
const Functions = std.StringHashMapUnmanaged(std.ArrayList(Function));

fn collectFunctions(a: std.mem.Allocator, s: *const src.Source, functions: *Functions) !void {
    const tree = s.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .fn_decl) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, node).?;
        const name_token = proto.name_token orelse continue;
        const entry = try functions.getOrPut(a, tree.tokenSlice(name_token));
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(a, .{ .source = s, .node = node });
    }
}

/// Every name a fuzz target of `s` reaches: the identifiers of each test
/// that runs `check` or `std.testing.fuzz`, and of the package's functions
/// of those names it calls, `reach_depth` calls deep.
fn collectReached(a: std.mem.Allocator, s: *const src.Source, functions: *const Functions, reached: *std.StringHashMapUnmanaged(void)) !void {
    const tree = s.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .test_decl) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (!isFuzzTarget(tree, node)) continue;
        try reach(a, s, node, functions, reached, reach_depth);
    }
}

fn isFuzzTarget(tree: Ast, node: Ast.Node.Index) bool {
    const tags = tree.tokens.items(.tag);
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    var t = first;
    while (t < last) : (t += 1) {
        if (tags[t] != .identifier or tags[t + 1] != .l_paren) continue;
        const word = tree.tokenSlice(t);
        if (std.mem.eql(u8, word, "check")) return true;
        if (std.mem.eql(u8, word, "fuzz") and t > 0 and tags[t - 1] == .period) return true;
    }
    return false;
}

fn reach(a: std.mem.Allocator, s: *const src.Source, node: Ast.Node.Index, functions: *const Functions, reached: *std.StringHashMapUnmanaged(void), depth: u32) !void {
    const tree = s.tree;
    const tags = tree.tokens.items(.tag);
    var t = tree.firstToken(node);
    const last = tree.lastToken(node);
    while (t <= last) : (t += 1) {
        if (tags[t] != .identifier) continue;
        const word = tree.tokenSlice(t);
        const fresh = !reached.contains(word);
        try reached.put(a, word, {});
        if (!fresh or depth == 0) continue;
        const callees = functions.get(word) orelse continue;
        for (callees.items) |callee| try reach(a, callee.source, callee.node, functions, reached, depth - 1);
    }
}

/// Prints the report, and adds it to the job summary when there is one.
pub fn summary(c: *src.Context, sources: []const src.Source, config: src.Value, output: ?[]const u8) !void {
    const r = try report(c.a, sources, config);
    c.report("preflight: fuzz: {d} parsers of untrusted input, {d} with no fuzz target\n", .{ r.parsers.len, r.unfuzzed.len });
    for (r.unfuzzed) |p| c.report("preflight: fuzz:   {s}:{d}: {s}\n", .{ p.path, p.line, p.name });
    const path = output orelse return;
    var text: std.Io.Writer.Allocating = .init(c.a);
    try text.writer.writeAll("\nUntrusted input with no fuzz target (report only)\n\n| Parser | Where |\n|---|---|\n");
    for (r.unfuzzed) |p| try text.writer.print("| `{s}` | `{s}:{d}` |\n", .{ p.name, p.path, p.line });
    try text.writer.print("\n{d} parsers, {d} with no fuzz target.\n", .{ r.parsers.len, r.unfuzzed.len });
    const file = try c.directory().createFile(c.io, path, .{ .truncate = false, .read = true });
    defer file.close(c.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(c.io, &buffer);
    writer.pos = (try file.stat(c.io)).size;
    try writer.interface.writeAll(text.written());
    try writer.interface.flush();
}

test "a parser of bytes is reported until a check property reaches it, a trusted one never" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sources = [_]src.Source{
        try .parse(a, "src/codec.zig",
            \\pub fn parseHeader(bytes: []const u8) !u32 { return bytes.len; }
            \\pub fn decodeFrame(r: *std.Io.Reader) !void { _ = r; }
            \\pub fn parseOwnCache(bytes: []const u8) !void { _ = bytes; }
            \\pub fn parseCount(n: u32) u32 { return n; }
            \\fn parseInternal(bytes: []const u8) void { _ = bytes; }
            \\pub fn read(bytes: []const u8) void { _ = bytes; }
        ),
        try .parse(a, "src/codec_test.zig",
            \\fn property(source: anytype) !void { _ = try codec.parseHeader(source.bytes()); }
            \\test "header" { try shakedown.check(property, .{}); }
            \\test "frame, by hand" { try codec.decodeFrame(undefined); }
        ),
    };
    const config = (try std.json.parseFromSlice(src.Value, a,
        \\{"fuzz":{"parsers":["read"],"trusted":{"parseOwnCache":"the package's own cache file"}}}
    , .{})).value;
    const r = try report(a, &sources, config);
    try std.testing.expectEqual(@as(usize, 3), r.parsers.len);
    try std.testing.expectEqual(@as(usize, 2), r.unfuzzed.len);
    try std.testing.expectEqualStrings("decodeFrame", r.unfuzzed[0].name);
    try std.testing.expectEqualStrings("read", r.unfuzzed[1].name);
}

test "a parser a property reaches through the package's pipeline, file to file, is fuzzed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sources = [_]src.Source{
        try .parse(a, "src/manifest.zig",
            \\pub fn parseManifest(bytes: []const u8) !void { _ = bytes; }
            \\pub fn parseLockfile(bytes: []const u8) !void { _ = bytes; }
        ),
        try .parse(a, "src/scan.zig",
            \\pub fn scan(bytes: []const u8) !void { try each(bytes); }
            \\fn each(bytes: []const u8) !void { try manifest.parseManifest(bytes); }
        ),
        try .parse(a, "src/scan_test.zig",
            \\fn property(source: anytype) !void { try scan.scan(source.bytes()); }
            \\test "scan" { try shakedown.check(property, .{}); }
        ),
    };
    const r = try report(a, &sources, .null);
    try std.testing.expectEqual(@as(usize, 2), r.parsers.len);
    try std.testing.expectEqual(@as(usize, 1), r.unfuzzed.len);
    try std.testing.expectEqualStrings("parseLockfile", r.unfuzzed[0].name);
}
