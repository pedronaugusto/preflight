//! A package's public surface as a release compares it: the lines glint lists of it (`glint
//! surface`, its program contract, `checks/glint.zig`), one for each declaration a consumer
//! reaches through the modules the package exports, and what this file reads beside them: the
//! modules a `build.zig` exports, and which lines a change removed or added.
//!
//! A line names the declaration by its path from the module (`conduit.Child.spawn`) and holds
//! what a consumer's code depends on. Added lines are additions; a line gone is a removed or
//! changed declaration, a breaking change, but for a constant's value (which `added` lists)
//! and a struct that requires fewer fields than it did.
const std = @import("std");
const Ast = std.zig.Ast;

/// A module the package exports: its name and root file, relative to the package's root.
pub const Module = struct { name: []const u8, root: []const u8 };

/// The modules a `build.zig` exports, as its text says them: each `addModule("name", .{
/// .root_source_file = b.path("root") })`, and each module put in the build's modules by name
/// (`b.modules.put(gpa, "name", module)`) that a `createModule` or `addModule` of the file makes,
/// directly or as the one value a function of the file returns; with `build.zig` itself, which
/// a build that depends on the package imports. A name, options or module may be a constant in
/// the call's scope that holds it (`const options: Module.CreateOptions = .{ ... }`). Null when
/// an export says any of them through anything else: what such a build exports is known only
/// by running it, and a build read as exporting less than it does would hide what it removed.
pub fn declaredModules(a: std.mem.Allocator, text: []const u8) !?[]const Module {
    var tree = try Ast.parse(a, try a.dupeSentinel(u8, text, 0), .{});
    defer tree.deinit(a);
    if (tree.errors.len != 0) return null;
    var out: std.ArrayList(Module) = .empty;
    try out.append(a, .{ .name = "build.zig", .root = "build.zig" });
    for (tree.nodes.items(.tag), 0..) |tag, n| {
        switch (tag) {
            .call_one, .call_one_comma, .call, .call_comma => {},
            else => continue,
        }
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, @fromBackingInt(@intCast(n))) orelse continue;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) continue;
        const receiver, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
        const spelled = tree.tokenSlice(method);
        // The module's name, and where the call says what it is.
        const name_at: usize, const root: Root = if (std.mem.eql(u8, spelled, "addModule")) said: {
            if (call.ast.params.len != 2) return null;
            break :said .{ 0, try optionsRoot(a, &tree, call.ast.params[1]) };
        } else if ((std.mem.eql(u8, spelled, "put") or std.mem.eql(u8, spelled, "putNoClobber")) and
            tree.nodeTag(receiver) == .field_access and
            std.mem.eql(u8, tree.tokenSlice(tree.nodeData(receiver).node_and_token[1]), "modules"))
        put: {
            if (call.ast.params.len != 3) return null;
            // Another package's module handed on is that package's surface, a line in this one's.
            if (dependencyModule(&tree, call.ast.params[2])) continue;
            break :put .{ 1, try createdRoot(a, &tree, call.ast.params[2], 0) };
        } else continue;
        const name = (try stringLiteral(a, &tree, constantValue(&tree, call.ast.params[name_at]) orelse return null)) orelse return null;
        switch (root) {
            .unknown => return null,
            // A module with no Zig root of its own exports no declarations.
            .none => continue,
            .path => |path| try out.append(a, .{ .name = name, .root = path }),
        }
    }
    return out.items;
}

/// Whether `node` is a module a dependency of the build gives (`dependency.module("name")`),
/// directly or through a constant in scope.
fn dependencyModule(tree: *const Ast, node: Ast.Node.Index) bool {
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, constantValue(tree, node) orelse return false) orelse return false;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access or call.ast.params.len != 1) return false;
    _, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
    return std.mem.eql(u8, tree.tokenSlice(method), "module");
}

/// What a module's options say of its root: a literal `b.path("...")`, none given, or unknown.
const Root = union(enum) { unknown, none, path: []const u8 };

/// The root a module's options name, the options a struct literal or a constant holding one.
fn optionsRoot(a: std.mem.Allocator, tree: *const Ast, node: Ast.Node.Index) !Root {
    var fields: [2]Ast.Node.Index = undefined;
    const options = tree.fullStructInit(&fields, constantValue(tree, node) orelse return .unknown) orelse return .unknown;
    for (options.ast.fields) |field| {
        if (!std.mem.eql(u8, tree.tokenSlice(tree.firstToken(field) - 2), "root_source_file")) continue;
        var inner: [1]Ast.Node.Index = undefined;
        const path = tree.fullCall(&inner, field) orelse return .unknown;
        if (tree.nodeTag(path.ast.fn_expr) != .field_access or path.ast.params.len != 1) return .unknown;
        _, const named = tree.nodeData(path.ast.fn_expr).node_and_token;
        if (!std.mem.eql(u8, tree.tokenSlice(named), "path")) return .unknown;
        return .{ .path = (try stringLiteral(a, tree, path.ast.params[0])) orelse return .unknown };
    }
    return .none;
}

/// The root of the module `node` evaluates to: a `createModule` or `addModule` call of the file,
/// or a call of a function of the file whose one return gives such a module, followed at most
/// `max_helpers` functions deep.
fn createdRoot(a: std.mem.Allocator, tree: *const Ast, node: Ast.Node.Index, depth: u8) !Root {
    const max_helpers = 4;
    if (depth == max_helpers) return .unknown;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, constantValue(tree, node) orelse return .unknown) orelse return .unknown;
    switch (tree.nodeTag(call.ast.fn_expr)) {
        .field_access => {
            _, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
            const spelled = tree.tokenSlice(method);
            if (std.mem.eql(u8, spelled, "createModule") and call.ast.params.len == 1) return optionsRoot(a, tree, call.ast.params[0]);
            if (std.mem.eql(u8, spelled, "addModule") and call.ast.params.len == 2) return optionsRoot(a, tree, call.ast.params[1]);
            return .unknown;
        },
        .identifier => {
            const returned = soleReturn(tree, tree.tokenSlice(tree.nodeMainToken(call.ast.fn_expr))) orelse return .unknown;
            return createdRoot(a, tree, returned, depth + 1);
        },
        else => return .unknown,
    }
}

/// The value of the one `return` in the body of the file's top-level function `name`; null when
/// there is no such function, or it returns from more than one place or without a value.
fn soleReturn(tree: *const Ast, name: []const u8) ?Ast.Node.Index {
    const tags = tree.nodes.items(.tag);
    for (tree.rootDecls()) |decl| {
        if (tree.nodeTag(decl) != .fn_decl) continue;
        const proto_node, const body = tree.nodeData(decl).node_and_node;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, proto_node) orelse continue;
        const named = proto.name_token orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(named), name)) continue;
        const first = tree.firstToken(body);
        const last = tree.lastToken(body);
        var found: ?Ast.Node.Index = null;
        for (tags, 0..) |tag, n| {
            if (tag != .@"return") continue;
            const at: Ast.Node.Index = @fromBackingInt(@intCast(n));
            const token = tree.nodeMainToken(at);
            if (token < first or token > last) continue;
            if (found != null) return null;
            found = tree.nodeData(at).opt_node.unwrap() orelse return null;
        }
        return found;
    }
    return null;
}

/// The expression `node` stands for: itself, or, when it is a name, the value of the one
/// constant of that name whose scope holds `node` (one declared before it in a block around it,
/// or at the file's top level). Null for a name bound any other way (a parameter, a variable,
/// a capture), whose value is known only by running the build. Zig refuses a name that shadows
/// another, so at most one constant is in scope; more than one found is not trusted.
fn constantValue(tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    if (tree.nodeTag(node) != .identifier) return node;
    const spelling = tree.tokenSlice(tree.nodeMainToken(node));
    const at = tree.firstToken(node);
    const tags = tree.nodes.items(.tag);
    var found: ?Ast.Node.Index = null;
    for (tags, 0..) |tag, n| {
        switch (tag) {
            .simple_var_decl, .local_var_decl, .aligned_var_decl, .global_var_decl => {},
            else => continue,
        }
        const decl_node: Ast.Node.Index = @fromBackingInt(@intCast(n));
        const decl = tree.fullVarDecl(decl_node) orelse continue;
        if (tree.tokenTag(decl.ast.mut_token) != .keyword_const) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(decl.ast.mut_token + 1), spelling)) continue;
        const value = decl.ast.init_node.unwrap() orelse continue;
        if (!inScope(tree, decl_node, at)) continue;
        if (found != null) return null;
        found = value;
    }
    return found;
}

/// Whether the declaration `decl` is visible at token `at`: declared at the file's top level, or
/// before `at` in the innermost block around it that also holds `at`.
fn inScope(tree: *const Ast, decl: Ast.Node.Index, at: Ast.TokenIndex) bool {
    for (tree.rootDecls()) |root| if (root == decl) return true;
    const first = tree.firstToken(decl);
    if (tree.lastToken(decl) >= at) return false;
    // The innermost block around the declaration: the one with the fewest tokens.
    var block: ?[2]Ast.TokenIndex = null;
    for (tree.nodes.items(.tag), 0..) |tag, n| {
        switch (tag) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => {},
            else => continue,
        }
        const around: Ast.Node.Index = @fromBackingInt(@intCast(n));
        const range: [2]Ast.TokenIndex = .{ tree.firstToken(around), tree.lastToken(around) };
        if (range[0] > first or range[1] < first) continue;
        if (block) |inner| if (range[1] - range[0] >= inner[1] - inner[0]) continue;
        block = range;
    }
    const inner = block orelse return false;
    return inner[0] <= at and at <= inner[1];
}

/// The string a literal node holds; null for any other expression.
fn stringLiteral(a: std.mem.Allocator, tree: *const Ast, node: Ast.Node.Index) !?[]const u8 {
    if (tree.nodeTag(node) != .string_literal) return null;
    return std.zig.string_literal.parseAlloc(a, tree.tokenSlice(tree.nodeMainToken(node))) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
}

/// The lines of `before` that `after` does not hold, as a consumer's build sees them: a
/// declaration removed or changed, a breaking change. A constant's value changed is not one
/// (`added` lists it), and neither is a struct that requires fewer fields than it did.
pub fn removed(a: std.mem.Allocator, before: []const []const u8, after: []const []const u8) ![]const []const u8 {
    var now: std.StringHashMapUnmanaged(void) = .empty;
    var requires: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (after) |line| {
        try now.put(a, line, {});
        if (split(line, " requires: ")) |parts| try requires.put(a, parts[0], parts[1]);
    }
    var gone: std.ArrayList([]const u8) = .empty;
    for (before) |line| {
        if (now.contains(line) or split(line, " value = ") != null) continue;
        if (split(line, " requires: ")) |parts| if (requires.get(parts[0])) |fewer| if (within(fewer, parts[1])) continue;
        try gone.append(a, line);
    }
    return gone.items;
}

/// The lines of `after` that `before` does not hold: declarations added, and constants whose
/// value changed. Each needs an entry.
pub fn added(a: std.mem.Allocator, before: []const []const u8, after: []const []const u8) ![]const []const u8 {
    var then: std.StringHashMapUnmanaged(void) = .empty;
    for (before) |line| try then.put(a, line, {});
    var new: std.ArrayList([]const u8) = .empty;
    for (after) |line| if (!then.contains(line)) try new.append(a, line);
    return new.items;
}

/// A line's declaration path and what follows `marker` after it, when the path is the line's
/// first word and the marker comes right after it.
fn split(line: []const u8, marker: []const u8) ?[2][]const u8 {
    const space = std.mem.findScalar(u8, line, ' ') orelse return null;
    if (!std.mem.startsWith(u8, line[space..], marker)) return null;
    return .{ line[0..space], line[space + marker.len ..] };
}

/// Whether every name of the list `fewer` is in the list `more`, both `, ` apart.
fn within(fewer: []const u8, more: []const u8) bool {
    var names = std.mem.tokenizeSequence(u8, fewer, ", ");
    outer: while (names.next()) |name| {
        var others = std.mem.tokenizeSequence(u8, more, ", ");
        while (others.next()) |other| if (std.mem.eql(u8, name, other)) continue :outer;
        return false;
    }
    return true;
}

// Tests ------------------------------------------------------------------

test "a removed declaration, a changed signature and a new required field are removed lines; an addition is not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before: []const []const u8 = &.{ "pkg.Options requires: ", "pkg.gone fn ( ) void", "pkg.run fn ( pkg.Options ) void" };
    // An addition alone removes nothing, a field with a default among it.
    const more: []const []const u8 = &.{ "pkg.Options requires: ", "pkg.gone fn ( ) void", "pkg.more fn ( ) void", "pkg.run fn ( pkg.Options ) void" };
    try std.testing.expectEqual(0, (try removed(a, before, more)).len);
    try std.testing.expectEqualSlices([]const u8, &.{"pkg.more fn ( ) void"}, try added(a, before, more));
    const broken: []const []const u8 = &.{ "pkg.Options requires: depth", "pkg.run fn ( pkg.Options , bool ) void" };
    const gone = try removed(a, before, broken);
    const expected = [_][]const u8{ "pkg.Options requires: ", "pkg.gone fn ( ) void", "pkg.run fn ( pkg.Options ) void" };
    try std.testing.expectEqualStrings(try std.mem.join(a, "\n", &expected), try std.mem.join(a, "\n", gone));
}

test "a constant's new value and fewer required fields remove nothing, and each is an added line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before: []const []const u8 = &.{ "pkg.Options requires: size, depth", "pkg.limit value = 64" };
    const after: []const []const u8 = &.{ "pkg.Options requires: size", "pkg.limit value = 128" };
    try std.testing.expectEqual(0, (try removed(a, before, after)).len);
    try std.testing.expectEqualStrings("pkg.Options requires: size\npkg.limit value = 128", try std.mem.join(a, "\n", try added(a, before, after)));
    // More required fields is a removed line: a literal that named the fewer no longer builds.
    try std.testing.expectEqualStrings("pkg.Options requires: size", try std.mem.join(a, "\n", try removed(a, after, before)));
}

test "the modules a build exports are read from its literal addModule calls, and a build that computes one is not read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const modules = (try declaredModules(a,
        \\pub fn build(b: *@import("std").Build) void {
        \\    const root = b.addModule("pkg", .{ .root_source_file = b.path("src/pkg.zig"), .target = b.graph.host });
        \\    _ = b.addModule("pkg.extra", .{
        \\        .root_source_file = b.path("src/extra.zig"),
        \\        .imports = &.{.{ .name = "pkg", .module = root }},
        \\    });
        \\    _ = b.createModule(.{ .root_source_file = b.path("src/private.zig") });
        \\}
    )).?;
    try std.testing.expectEqual(@as(usize, 3), modules.len);
    try std.testing.expectEqualStrings("build.zig", modules[0].name);
    try std.testing.expectEqualStrings("pkg", modules[1].name);
    try std.testing.expectEqualStrings("src/pkg.zig", modules[1].root);
    try std.testing.expectEqualStrings("src/extra.zig", modules[2].root);
    try std.testing.expectEqual(@as(?[]const Module, null), try declaredModules(a, "pub fn build(b: *@import(\"std\").Build) void {\n    _ = b.addModule(\"pkg\", .{ .root_source_file = root(b) });\n}\n"));
}

test "a module put in the build's modules is read through the helper of the file that creates it; one the text cannot follow makes the exports unknown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // warp 0.4.4's shape: the module made by a function of the file, then put by name.
    const modules = (try declaredModules(a,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const module = warpModule(b, target);
        \\    b.modules.put(b.allocator, "warp", module) catch @panic("OOM");
        \\    b.modules.put(b.allocator, "warp.direct", b.createModule(.{ .root_source_file = b.path("src/direct.zig") })) catch @panic("OOM");
        \\}
        \\fn warpModule(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Module {
        \\    const root = b.createModule(.{ .root_source_file = b.path("src/warp.zig"), .target = target });
        \\    addImports(b, root);
        \\    return root;
        \\}
    )).?;
    try std.testing.expectEqual(@as(usize, 3), modules.len);
    try std.testing.expectEqualStrings("warp", modules[1].name);
    try std.testing.expectEqualStrings("src/warp.zig", modules[1].root);
    try std.testing.expectEqualStrings("warp.direct", modules[2].name);
    try std.testing.expectEqualStrings("src/direct.zig", modules[2].root);
    // Read as exporting nothing, a build like these would hide every removal since its tag.
    for ([_][]const u8{
        "pub fn build(b: *@import(\"std\").Build) void {\n    put(b, b.createModule(.{ .root_source_file = b.path(\"src/pkg.zig\") }));\n}\nfn put(b: *@import(\"std\").Build, module: *@import(\"std\").Build.Module) void {\n    b.modules.put(b.allocator, \"pkg\", module) catch @panic(\"OOM\");\n}\n",
        "pub fn build(b: *@import(\"std\").Build) void {\n    b.modules.put(b.allocator, \"pkg\", make(b, true)) catch @panic(\"OOM\");\n}\nfn make(b: *@import(\"std\").Build, wide: bool) *@import(\"std\").Build.Module {\n    if (wide) return b.createModule(.{ .root_source_file = b.path(\"src/wide.zig\") });\n    return b.createModule(.{ .root_source_file = b.path(\"src/pkg.zig\") });\n}\n",
    }) |text| try std.testing.expectEqual(@as(?[]const Module, null), try declaredModules(a, text));
    // Another package's module put again under a name (visor 0.5.9 hands on morse's) is that
    // package's surface, a line in this one's: it is left out, whatever names it.
    const reexported = (try declaredModules(a,
        \\pub fn build(b: *@import("std").Build) void {
        \\    const morse = b.dependency("morse", .{});
        \\    _ = b.addModule("visor", .{ .root_source_file = b.path("src/visor.zig") });
        \\    b.modules.put(b.allocator, b.graph.dupeString("morse"), morse.module("morse")) catch @panic("OOM");
        \\    const other = b.dependency("other", .{}).module("other");
        \\    b.modules.put(b.allocator, "other", other) catch @panic("OOM");
        \\}
    )).?;
    try std.testing.expectEqual(@as(usize, 2), reexported.len);
    try std.testing.expectEqualStrings("visor", reexported[1].name);
}

test "an addModule's name or options held in a constant in scope are read through it; a parameter, a variable or another function's constant is not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // uplink 0.10.2's shape: each module's options a typed constant of the function that adds it,
    // beside a constant of the same name in another function that it must not be read from.
    const modules = (try declaredModules(a,
        \\const std = @import("std");
        \\const prefix = "pkg";
        \\pub fn build(b: *std.Build) void {
        \\    const wire_options: std.Build.Module.CreateOptions = .{
        \\        .root_source_file = b.path("src/wire.zig"),
        \\        .target = b.graph.host,
        \\    };
        \\    const wire = b.addModule(prefix ++ ".wire", wire_options);
        \\    _ = wire;
        \\    if (b.option(bool, "client", "") orelse true) {
        \\        const name = "pkg";
        \\        const root_options: std.Build.Module.CreateOptions = .{ .root_source_file = b.path("src/pkg.zig") };
        \\        _ = b.addModule(name, root_options);
        \\    }
        \\}
        \\fn other(b: *std.Build) void {
        \\    const root_options: std.Build.Module.CreateOptions = .{ .root_source_file = b.path("src/wrong.zig") };
        \\    _ = root_options;
        \\}
    ));
    // `prefix ++ ".wire"` is computed, so this build is not read; take that call out and it is.
    try std.testing.expectEqual(@as(?[]const Module, null), modules);
    const read = (try declaredModules(a,
        \\const std = @import("std");
        \\const wire_name = "pkg.wire";
        \\pub fn build(b: *std.Build) void {
        \\    const wire_options: std.Build.Module.CreateOptions = .{
        \\        .root_source_file = b.path("src/wire.zig"),
        \\        .target = b.graph.host,
        \\    };
        \\    _ = b.addModule(wire_name, wire_options);
        \\    if (b.option(bool, "client", "") orelse true) {
        \\        const name = "pkg";
        \\        const root_options: std.Build.Module.CreateOptions = .{ .root_source_file = b.path("src/pkg.zig") };
        \\        _ = b.addModule(name, root_options);
        \\    }
        \\}
        \\fn other(b: *std.Build) void {
        \\    const root_options: std.Build.Module.CreateOptions = .{ .root_source_file = b.path("src/wrong.zig") };
        \\    _ = root_options;
        \\}
    )).?;
    try std.testing.expectEqual(@as(usize, 3), read.len);
    try std.testing.expectEqualStrings("pkg.wire", read[1].name);
    try std.testing.expectEqualStrings("src/wire.zig", read[1].root);
    try std.testing.expectEqualStrings("pkg", read[2].name);
    try std.testing.expectEqualStrings("src/pkg.zig", read[2].root);
    // Options from outside the function, or in a variable that may change before the call, are
    // known only by running the build.
    for ([_][]const u8{
        "pub fn build(b: *@import(\"std\").Build) void {\n    add(b, .{ .root_source_file = b.path(\"src/pkg.zig\") });\n}\nfn add(b: *@import(\"std\").Build, options: @import(\"std\").Build.Module.CreateOptions) void {\n    _ = b.addModule(\"pkg\", options);\n}\n",
        "pub fn build(b: *@import(\"std\").Build) void {\n    var options: @import(\"std\").Build.Module.CreateOptions = .{ .root_source_file = b.path(\"src/pkg.zig\") };\n    options.root_source_file = b.path(\"src/other.zig\");\n    _ = b.addModule(\"pkg\", options);\n}\n",
        "pub fn build(b: *@import(\"std\").Build) void {\n    _ = b.addModule(\"pkg\", options);\n}\nfn other(b: *@import(\"std\").Build) void {\n    const options: @import(\"std\").Build.Module.CreateOptions = .{ .root_source_file = b.path(\"src/pkg.zig\") };\n    _ = options;\n}\n",
    }) |text| try std.testing.expectEqual(@as(?[]const Module, null), try declaredModules(a, text));
}
