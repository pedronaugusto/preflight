//! The untrusted-input report: the parsers and decoders a package exports
//! with no fuzz target. Under the family's policy a parser with none fails the
//! check (the family's bar: a fuzz target for every parser); otherwise it is a
//! report.
//!
//! A parser is a public function of the package's own code (not a test,
//! not test support) named as one (`parse…`, `decode…`, `deserialize…`,
//! `unpack…`, `unmarshal…`, `fromBytes…`) that takes bytes or a reader, or
//! any function `ci/preflight.json` names under `fuzz.parsers`, by its name or
//! as `Container.name` (the struct it is declared in, or its file's name), so a
//! project can mean the one `Config.parse` among several `parse`s. A fuzz
//! target is a test that runs a shakedown `check` property or
//! `std.testing.fuzz`; a parser is fuzzed when such a test reaches it by
//! name, in its body or in a function of the package the body calls, by
//! name, some calls deep: a property that drives a whole pipeline (a scan
//! that hands each file to its parser) reaches the parsers through it. A call
//! qualified by a container's name (`Config.parse(`) reaches that container's
//! function when the package declares one, any function of the name otherwise.
//! `fuzz.trusted` names a parser whose input is the package's own, with the
//! reason, and leaves it out.
const std = @import("std");
const Ast = std.zig.Ast;
const src = @import("source.zig");
const family = @import("../family.zig");

pub const Parser = struct { path: []const u8, name: []const u8, line: usize, decl: Decl };

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
        if (!test_code) try collectParsers(a, s, named, trusted, &parsers);
        try collectFunctions(a, s, &functions);
    }
    var reached: Reached = .empty;
    for (sources) |*s| try collectReached(a, s, &functions, &reached);
    var unfuzzed: std.ArrayList(Parser) = .empty;
    for (parsers.items) |p| if (!reached.contains(p.decl)) try unfuzzed.append(a, p);
    return .{ .parsers = parsers.items, .unfuzzed = unfuzzed.items };
}

/// Whether the report fails the check: under the family's policy, any parser with no fuzz target.
pub fn fails(policy: family.Policy, r: Report) bool {
    return policy == .family and r.unfuzzed.len != 0;
}

/// Whether `entry`, a name in `fuzz.parsers` or `fuzz.trusted`, names the function `name`
/// declared in `container`: by its bare name, or as `container.name`.
fn names(entry: []const u8, container: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, entry, name)) return true;
    return entry.len == container.len + 1 + name.len and std.mem.startsWith(u8, entry, container) and
        entry[container.len] == '.' and std.mem.endsWith(u8, entry, name);
}

fn isTrusted(trusted: src.Value, container: []const u8, name: []const u8) bool {
    if (trusted != .object) return false;
    for (trusted.object.keys()) |entry| if (names(entry, container, name)) return true;
    return false;
}

fn collectParsers(a: std.mem.Allocator, s: *const src.Source, named: []const []const u8, trusted: src.Value, out: *std.ArrayList(Parser)) !void {
    const tree = s.tree;
    const containers = try containersOf(a, s);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .fn_decl) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, node).?;
        const name_token = proto.name_token orelse continue;
        const name = tree.tokenSlice(name_token);
        const container = containerAt(s, containers, name_token);
        if (isTrusted(trusted, container, name)) continue;
        const listed = for (named) |n| {
            if (names(n, container, name)) break true;
        } else false;
        if (!listed) {
            const visible = proto.visib_token != null;
            if (!visible or !verbNamed(name) or !takesInput(tree, proto)) continue;
        }
        try out.append(a, .{ .path = s.path, .name = name, .line = s.line(name_token), .decl = .{ .source = s, .node = node } });
    }
}

/// A container declared in a file: `const Name = struct { ... }` (or enum, union, opaque), by
/// the tokens it spans.
const Container = struct { name: []const u8, first: Ast.TokenIndex, last: Ast.TokenIndex };

fn containersOf(a: std.mem.Allocator, s: *const src.Source) ![]const Container {
    const tree = s.tree;
    var out: std.ArrayList(Container) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        switch (tag) {
            .simple_var_decl, .local_var_decl, .global_var_decl, .aligned_var_decl => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const decl = tree.fullVarDecl(node) orelse continue;
        const init = decl.ast.init_node.unwrap() orelse continue;
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buffer, init) == null) continue;
        try out.append(a, .{ .name = tree.tokenSlice(decl.ast.mut_token + 1), .first = tree.firstToken(init), .last = tree.lastToken(init) });
    }
    return out.items;
}

/// The innermost container that declares the token at `token`, or the file's own (its name
/// without `.zig`).
fn containerAt(s: *const src.Source, containers: []const Container, token: Ast.TokenIndex) []const u8 {
    var found: ?Container = null;
    for (containers) |c| if (c.first <= token and token <= c.last) {
        if (found == null or c.first >= found.?.first) found = c;
    };
    if (found) |c| return c.name;
    const base = std.Io.Dir.path.basename(s.path);
    return if (std.mem.endsWith(u8, base, ".zig")) base[0 .. base.len - ".zig".len] else base;
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

/// A function's declaration: its file and its node there.
const Decl = struct { source: *const src.Source, node: Ast.Node.Index };
/// A function of the package: its declaration and the container it is declared in.
const Function = struct { decl: Decl, container: []const u8 };
/// Every function of the package by name; one name may be several functions.
const Functions = std.StringHashMapUnmanaged(std.ArrayList(Function));
/// Every declaration a fuzz target reaches, with the most calls it had left to follow from there.
const Reached = std.AutoHashMapUnmanaged(Decl, u32);

fn collectFunctions(a: std.mem.Allocator, s: *const src.Source, functions: *Functions) !void {
    const tree = s.tree;
    const containers = try containersOf(a, s);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .fn_decl) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, node).?;
        const name_token = proto.name_token orelse continue;
        const entry = try functions.getOrPut(a, tree.tokenSlice(name_token));
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(a, .{ .decl = .{ .source = s, .node = node }, .container = containerAt(s, containers, name_token) });
    }
}

/// Every declaration a fuzz target of `s` reaches: the functions each test
/// that runs `check` or `std.testing.fuzz` names, and those they name in
/// turn, `reach_depth` calls deep.
fn collectReached(a: std.mem.Allocator, s: *const src.Source, functions: *const Functions, reached: *Reached) !void {
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

/// Marks what the body of `node` names, with `depth` calls left to follow. A declaration met
/// again with more calls left than the first time is followed again: what is reached does not
/// depend on the order the paths are walked in.
fn reach(a: std.mem.Allocator, s: *const src.Source, node: Ast.Node.Index, functions: *const Functions, reached: *Reached, depth: u32) !void {
    const tree = s.tree;
    const tags = tree.tokens.items(.tag);
    var t = tree.firstToken(node);
    const last = tree.lastToken(node);
    // A function's own name is no call of it, nor of the others of its name.
    var buffer: [1]Ast.Node.Index = undefined;
    const own: ?Ast.TokenIndex = if (tree.fullFnProto(&buffer, node)) |proto| proto.name_token else null;
    while (t <= last) : (t += 1) {
        if (tags[t] != .identifier or t == own) continue;
        const callees = functions.get(tree.tokenSlice(t)) orelse continue;
        // `Container.name`: that container's function, when the package declares one.
        const qualifier: ?[]const u8 = if (t >= 2 and tags[t - 1] == .period and tags[t - 2] == .identifier) tree.tokenSlice(t - 2) else null;
        const narrowed = if (qualifier) |q| for (callees.items) |callee| {
            if (std.mem.eql(u8, callee.container, q)) break true;
        } else false else false;
        for (callees.items) |callee| {
            if (narrowed and !std.mem.eql(u8, callee.container, qualifier.?)) continue;
            const entry = try reached.getOrPut(a, callee.decl);
            if (entry.found_existing and entry.value_ptr.* >= depth) continue;
            entry.value_ptr.* = depth;
            if (depth != 0) try reach(a, callee.decl.source, callee.decl.node, functions, reached, depth - 1);
        }
    }
}

/// Prints the report, and adds it to the job summary when there is one.
pub fn summary(c: *src.Context, sources: []const src.Source, config: src.Value, output: ?[]const u8) !void {
    const r = try report(c.a, sources, config);
    const failing = fails(src.policy(config), r);
    c.report("preflight: fuzz: {d} parsers of untrusted input, {d} with no fuzz target\n", .{ r.parsers.len, r.unfuzzed.len });
    for (r.unfuzzed) |p| {
        if (failing) c.fail("fuzz: {s}:{d}: {s} parses untrusted input and no fuzz target reaches it", .{ p.path, p.line, p.name }) else c.report("preflight: fuzz:   {s}:{d}: {s}\n", .{ p.path, p.line, p.name });
    }
    const path = output orelse return;
    var text: std.Io.Writer.Allocating = .init(c.a);
    try text.writer.print("\nUntrusted input with no fuzz target ({s})\n\n| Parser | Where |\n|---|---|\n", .{if (failing) "fails under the family's policy" else "report only"});
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

test "a parser reached by a long path and then a short one is fuzzed, whichever is walked first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `f1` leads to `middle` at the depth limit, before the property's own call of `middle`,
    // two calls from the parser, is walked.
    const sources = [_]src.Source{
        try .parse(a, "src/chain.zig",
            \\pub fn parseRecord(bytes: []const u8) !void { _ = bytes; }
            \\fn middle(bytes: []const u8) !void { try parseRecord(bytes); }
            \\fn f1(b: []const u8) !void { try f2(b); }
            \\fn f2(b: []const u8) !void { try f3(b); }
            \\fn f3(b: []const u8) !void { try f4(b); }
            \\fn f4(b: []const u8) !void { try f5(b); }
            \\fn f5(b: []const u8) !void { try f6(b); }
            \\fn f6(b: []const u8) !void { try f7(b); }
            \\fn f7(b: []const u8) !void { try f8(b); }
            \\fn f8(b: []const u8) !void { try middle(b); }
        ),
        try .parse(a, "src/chain_test.zig",
            \\fn property(source: anytype) !void { try chain.f1(source.bytes()); try chain.middle(source.bytes()); }
            \\test "chain" { try shakedown.check(property, .{}); }
        ),
    };
    const r = try report(a, &sources, .null);
    try std.testing.expectEqual(@as(usize, 1), r.parsers.len);
    try std.testing.expectEqual(@as(usize, 0), r.unfuzzed.len);
}

test "parsers of one name are told apart by their container, in the configuration and at the call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sources = [_]src.Source{
        try .parse(a, "src/config.zig",
            \\pub fn parse(bytes: []const u8) !void { _ = bytes; }
        ),
        try .parse(a, "src/wire.zig",
            \\pub const Header = struct {
            \\    pub fn parse(bytes: []const u8) !void { _ = bytes; }
            \\};
            \\pub const Trailer = struct {
            \\    pub fn parse(bytes: []const u8) !void { _ = bytes; }
            \\};
        ),
        try .parse(a, "src/wire_test.zig",
            \\fn property(source: anytype) !void { try Header.parse(source.bytes()); }
            \\test "header" { try shakedown.check(property, .{}); }
        ),
    };
    // `config.parse` is named by its container; `Trailer.parse` is the package's own input.
    const config = (try std.json.parseFromSlice(src.Value, a,
        \\{"fuzz":{"parsers":["config.parse"],"trusted":{"Trailer.parse":"the package's own trailer"}}}
    , .{})).value;
    const r = try report(a, &sources, config);
    try std.testing.expectEqual(@as(usize, 2), r.parsers.len);
    // The property's `Header.parse` reaches Header's alone: config's stays unfuzzed.
    try std.testing.expectEqual(@as(usize, 1), r.unfuzzed.len);
    try std.testing.expectEqualStrings("src/config.zig", r.unfuzzed[0].path);
}

test "a parser with no fuzz target fails the check under the family's policy, and is a report without it" {
    const unfuzzed = [_]Parser{.{ .path = "src/x.zig", .name = "parseX", .line = 1, .decl = undefined }};
    const r: Report = .{ .parsers = &unfuzzed, .unfuzzed = &unfuzzed };
    try std.testing.expect(fails(.family, r));
    try std.testing.expect(!fails(.adapt, r));
    try std.testing.expect(!fails(.family, .{ .parsers = &unfuzzed, .unfuzzed = &.{} }));
}
