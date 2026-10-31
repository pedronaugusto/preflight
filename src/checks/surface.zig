//! A package's public surface: one line for each declaration a consumer reaches through the
//! modules the package exports, read with glint's project model (its declarations, their
//! visibility and scopes), so a release can tell whether it removed or changed one.
//!
//! A line names the declaration by its path from the module (`conduit.Child.spawn`) and holds
//! what a consumer's code depends on: a function's parameter and return types, a field's type,
//! the fields a struct literal must name, the expression a public constant aliases, a
//! constant's value, and an exhaustive enum's tags and a tagged union's fields as one set,
//! which every exhaustive switch names. A type is written as what it names: a container by the
//! public path it is listed under, an alias by what it comes to. Whitespace, comments and
//! parameter names are not part of it. Added lines are additions; a line gone is a removed or
//! changed declaration, a breaking change, but for a constant's value (which `added` lists)
//! and a struct that requires fewer fields than it did.
//!
//! What the lines cannot see: the body of a function that returns a type, an inferred error
//! set (`!T`), which only the compiler's analysis knows, and the members of what another
//! package's module declares (`@import("std")` is a line, not std's surface).
const std = @import("std");
const glint = @import("glint");
const Ast = std.zig.Ast;

/// A module the package exports: its name and root file, relative to the package's root.
pub const Module = struct { name: []const u8, root: []const u8 };

/// Files read for one surface at most, and how deep an alias is followed.
const max_files = 4096;
const max_depth = 32;

/// The surface's lines, sorted and without repeats. `reader.read(a, path)` gives a file of the
/// package by its path from the package's root, or null when it is not there. `io` is asked for
/// a cancel before each file glint builds.
pub fn list(a: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, modules: []const Module, reader: anytype) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    var texts: std.ArrayList([]const u8) = .empty;
    var index: std.StringHashMapUnmanaged(u32) = .empty;
    var edges: std.ArrayList(glint.Project.Import) = .empty;
    for (modules) |module| _ = try load(a, reader, try normalize(a, "", module.root), &paths, &texts, &index);
    // Each file's relative imports, read in turn: the files a module's root reaches.
    var next: usize = 0;
    while (next < paths.items.len) : (next += 1) {
        var tree = try Ast.parse(a, try a.dupeSentinel(u8, texts.items[next], 0), .{});
        defer tree.deinit(a);
        for (tree.nodes.items(.tag), 0..) |tag, n| {
            if (tag != .builtin_call_two and tag != .builtin_call_two_comma) continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(n));
            const spelling = importSpelling(&tree, node) orelse continue;
            if (!std.mem.endsWith(u8, spelling, ".zig")) continue;
            const target = normalize(a, std.Io.Dir.path.dirname(paths.items[next]) orelse "", spelling) catch continue;
            const id = (try load(a, reader, target, &paths, &texts, &index)) orelse continue;
            for (edges.items) |edge| {
                if (edge.from == next and std.mem.eql(u8, edge.spelling, spelling)) break;
            } else try edges.append(a, .{ .from = next, .spelling = spelling, .target = id });
        }
        if (paths.items.len > max_files) return error.SurfaceTooLarge;
    }
    const inputs = try a.alloc(glint.Project.Input, paths.items.len);
    for (inputs, paths.items, texts.items) |*input, path, text| input.* = .{ .name = path, .bytes = text };
    var project = try glint.Project.init(gpa, inputs, edges.items, .{ .lowering = false, .io = io });
    defer project.deinit();

    // Twice: first to learn the public path each container is listed under, then to list the
    // lines, a container named in a signature by that path whatever it is spelled there.
    var walk: Walk = .{ .a = a, .project = &project, .lines = .empty, .open = .empty, .naming = true };
    for ([_]bool{ true, false }) |naming| {
        walk.naming = naming;
        walk.lines = .empty;
        for (modules) |module| {
            const root = try normalize(a, "", module.root);
            const position = index.get(root) orelse continue;
            try walk.container(module.name, try project.fileAt(position), .root, 0);
        }
    }
    const lines = walk.lines.items;
    std.mem.sort([]const u8, lines, {}, lessThan);
    var unique: std.ArrayList([]const u8) = .empty;
    for (lines) |line| if (unique.items.len == 0 or !std.mem.eql(u8, unique.items[unique.items.len - 1], line)) try unique.append(a, line);
    return unique.items;
}

/// The modules a `build.zig` exports, as its text says them: each `addModule("name", .{
/// .root_source_file = b.path("root") })`, with `build.zig` itself, which a build that
/// depends on the package imports. Null when an `addModule` says either through anything
/// but a literal: what such a build exports is known only by running it.
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
        _, const method = tree.nodeData(call.ast.fn_expr).node_and_token;
        if (!std.mem.eql(u8, tree.tokenSlice(method), "addModule")) continue;
        if (call.ast.params.len != 2) return null;
        const name = (try stringLiteral(a, &tree, call.ast.params[0])) orelse return null;
        var fields: [2]Ast.Node.Index = undefined;
        const options = tree.fullStructInit(&fields, call.ast.params[1]) orelse return null;
        for (options.ast.fields) |field| {
            if (!std.mem.eql(u8, tree.tokenSlice(tree.firstToken(field) - 2), "root_source_file")) continue;
            var inner: [1]Ast.Node.Index = undefined;
            const path = tree.fullCall(&inner, field) orelse return null;
            if (tree.nodeTag(path.ast.fn_expr) != .field_access or path.ast.params.len != 1) return null;
            _, const named = tree.nodeData(path.ast.fn_expr).node_and_token;
            if (!std.mem.eql(u8, tree.tokenSlice(named), "path")) return null;
            try out.append(a, .{ .name = name, .root = (try stringLiteral(a, &tree, path.ast.params[0])) orelse return null });
        }
    }
    return out.items;
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

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn load(a: std.mem.Allocator, reader: anytype, path: []const u8, paths: *std.ArrayList([]const u8), texts: *std.ArrayList([]const u8), index: *std.StringHashMapUnmanaged(u32)) !?u32 {
    if (index.get(path)) |id| return id;
    const text = (try reader.read(a, path)) orelse return null;
    const id: u32 = @intCast(paths.items.len); // safe: list stops past max_files
    try paths.append(a, path);
    try texts.append(a, text);
    try index.put(a, path, id);
    return id;
}

/// `spelling` from `directory`, both relative to the package's root; outside it is an error.
fn normalize(a: std.mem.Allocator, directory: []const u8, spelling: []const u8) ![]const u8 {
    if (std.Io.Dir.path.isAbsolute(spelling)) return error.OutsidePackage;
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, directory, "/\\");
    while (it.next()) |part| try parts.append(a, part);
    var rest = std.mem.tokenizeAny(u8, spelling, "/\\");
    while (rest.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.pop() == null) return error.OutsidePackage;
            continue;
        }
        try parts.append(a, part);
    }
    return std.mem.join(a, "/", parts.items);
}

/// The string an `@import("...")` names, or null for any other call.
fn importSpelling(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma => {},
        else => return null,
    }
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) return null;
    const first = tree.nodeData(node).opt_node_and_opt_node[0].unwrap() orelse return null;
    if (tree.nodeTag(first) != .string_literal) return null;
    const literal = tree.tokenSlice(tree.nodeMainToken(first));
    if (literal.len < 2) return null;
    return literal[1 .. literal.len - 1];
}

const Walk = struct {
    a: std.mem.Allocator,
    project: *const glint.Project,
    lines: std.ArrayList([]const u8),
    /// The containers being listed, so a container that reaches itself ends there.
    open: std.ArrayList(struct { file: glint.Project.FileId, node: Ast.Node.Index }),
    /// The public path each container is listed under: the shortest, the first in order of
    /// those as short. A signature names a container by it.
    names: std.AutoHashMapUnmanaged(Place, []const u8) = .empty,
    /// Whether this walk learns `names`, its lines then not yet the surface's.
    naming: bool,

    fn handle(w: *Walk, file: glint.Project.FileId) glint.Project.Handle {
        return w.project.handle(file);
    }

    fn tree(w: *Walk, file: glint.Project.FileId) *const Ast {
        return w.project.syntax(w.handle(file)) catch unreachable; // unreachable: file indexes come from the project
    }

    fn add(w: *Walk, comptime fmt: []const u8, args: anytype) !void {
        try w.lines.append(w.a, try w.a.print(fmt, args));
    }

    /// The scope glint's model gives the container at `node` (the file's own at the root).
    fn scopeOf(w: *Walk, file: glint.Project.FileId, node: Ast.Node.Index) ?glint.Scope.Id {
        const scopes = w.project.scopes(w.handle(file)) catch unreachable; // unreachable: the handle is the project's own
        if (node == .root) return scopes[0].id;
        for (scopes) |scope| if (scope.kind == .container and scope.node == node) return scope.id;
        return null;
    }

    /// Lists the public declarations and the fields of the container at `node` in `file`.
    fn container(w: *Walk, prefix: []const u8, file: glint.Project.FileId, node: Ast.Node.Index, depth: usize) anyerror!void {
        if (depth > max_depth) return;
        for (w.open.items) |open| if (open.file == file and open.node == node) return;
        try w.open.append(w.a, .{ .file = file, .node = node });
        defer _ = w.open.pop();
        if (w.naming) {
            const entry = try w.names.getOrPut(w.a, .{ .file = file, .node = node });
            if (!entry.found_existing or prefix.len < entry.value_ptr.len or (prefix.len == entry.value_ptr.len and std.mem.lessThan(u8, prefix, entry.value_ptr.*))) entry.value_ptr.* = prefix;
        }
        const t = w.tree(file);
        const scope = w.scopeOf(file, node) orelse return;
        const declarations = w.project.declarations(w.handle(file)) catch unreachable; // unreachable: file indexes come from the project
        var required: std.ArrayList([]const u8) = .empty;
        // An enum's tags and a union's fields, `_` left out: what an exhaustive switch names.
        var named: std.ArrayList([]const u8) = .empty;
        var exhaustive = true;
        var fields: usize = 0;
        const is_enum = node != .root and isEnum(t, node);
        // The fields, from the syntax: an enum's tags and a tuple's fields have no `name:`.
        var container_buffer: [2]Ast.Node.Index = undefined;
        const members = if (node == .root) t.rootDecls() else (t.fullContainerDecl(&container_buffer, node) orelse return).ast.members;
        for (members) |member| {
            const field = t.fullContainerField(member) orelse continue;
            const positional = field.ast.tuple_like and !is_enum and !isUnion(t, node);
            const name = if (positional) try w.a.print("{d}", .{fields}) else t.tokenSlice(field.ast.main_token);
            fields += 1;
            // `_` is no tag a consumer names: it makes the enum non-exhaustive.
            if (std.mem.eql(u8, name, "_")) {
                exhaustive = false;
                continue;
            }
            try named.append(w.a, name);
            if (is_enum) {
                try w.add("{s}.{s} tag", .{ prefix, name });
                continue;
            }
            // A union's `a,` is a field of type void; a tuple's field is its type alone.
            const bare = field.ast.tuple_like and !positional;
            const type_text = if (bare) "void" else if (field.ast.type_expr.unwrap()) |expr| try w.tokens(file, t, expr) else "void";
            try w.add("{s}.{s} field: {s}", .{ prefix, name, type_text });
            if (field.ast.value_expr == .none) try required.append(w.a, name);
        }
        for (declarations) |declaration| {
            if (declaration.scope != scope) continue;
            switch (declaration.kind) {
                .function => if (declaration.public) {
                    var buffer: [1]Ast.Node.Index = undefined;
                    const proto = t.fullFnProto(&buffer, declaration.node) orelse continue;
                    const name = t.tokenSlice(proto.name_token.?);
                    try w.add("{s}.{s} {s}", .{ prefix, name, try w.signature(file, t, proto) });
                    try w.made(try w.a.print("{s}.{s}()", .{ prefix, name }), file, declaration.node, depth);
                },
                .variable => if (declaration.public) try w.variable(prefix, file, declaration.node, depth),
                else => {},
            }
        }
        if (!is_enum and ((node == .root and fields != 0) or (node != .root and isStruct(t, node)))) {
            std.mem.sort([]const u8, required.items, {}, lessThan);
            try w.add("{s} requires: {s}", .{ prefix, try std.mem.join(w.a, ", ", required.items) });
        }
        // A tag or a union field added breaks every exhaustive switch over the type, and `_`
        // added or taken away breaks each switch either way: the whole set is one line.
        std.mem.sort([]const u8, named.items, {}, lessThan);
        if (is_enum) {
            if (exhaustive) {
                try w.add("{s} exhaustive: {s}", .{ prefix, try std.mem.join(w.a, ", ", named.items) });
            } else try w.add("{s} non-exhaustive", .{prefix});
        } else if (node != .root and isTagged(t, node)) try w.add("{s} tagged: {s}", .{ prefix, try std.mem.join(w.a, ", ", named.items) });
    }

    /// The members of the type a function that returns one makes (`pub fn List(comptime T:
    /// type) type { return struct { ... }; }`), under `path`: what each of its `return`s
    /// gives, as far as the project shows it.
    fn made(w: *Walk, path: []const u8, file: glint.Project.FileId, proto_node: Ast.Node.Index, depth: usize) !void {
        const t = w.tree(file);
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = t.fullFnProto(&buffer, proto_node) orelse return;
        const returned = proto.ast.return_type.unwrap() orelse return;
        if (t.nodeTag(returned) != .identifier or !std.mem.eql(u8, t.tokenSlice(t.nodeMainToken(returned)), "type")) return;
        const body = for (t.nodes.items(.tag), 0..) |tag, n| {
            if (tag != .fn_decl) continue;
            const decl, const block = t.nodeData(@fromBackingInt(@intCast(n))).node_and_node;
            if (decl == proto_node) break block;
        } else return;
        const first = t.firstToken(body);
        const last = t.lastToken(body);
        for (t.nodes.items(.tag), 0..) |tag, n| {
            if (tag != .@"return") continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(n));
            const token = t.nodeMainToken(node);
            if (token < first or token > last) continue;
            const value = t.nodeData(node).opt_node.unwrap() orelse continue;
            _ = try w.describe(path, file, value, depth + 1);
        }
    }

    fn variable(w: *Walk, prefix: []const u8, file: glint.Project.FileId, node: Ast.Node.Index, depth: usize) !void {
        const t = w.tree(file);
        const decl = t.fullVarDecl(node) orelse return;
        const name = t.tokenSlice(decl.ast.mut_token + 1);
        const path = try w.a.print("{s}.{s}", .{ prefix, name });
        const mutability = t.tokenSlice(decl.ast.mut_token);
        if (decl.ast.type_node.unwrap()) |type_node| try w.add("{s} {s}: {s}", .{ path, mutability, try w.tokens(file, t, type_node) });
        const init = decl.ast.init_node.unwrap() orelse return;
        if (isLiteral(t, init)) {
            if (decl.ast.type_node == .none) try w.add("{s} {s}", .{ path, mutability });
            // What a consumer computes with: a value changed needs an entry, though no build breaks.
            if (std.mem.eql(u8, mutability, "const")) try w.add("{s} value = {s}", .{ path, try w.tokens(file, t, init) });
            return;
        }
        const described = try w.describe(path, file, init, depth + 1);
        if (decl.ast.type_node == .none) try w.add("{s} {s} {s}", .{ path, mutability, described });
    }

    /// What a public constant is, listing the members of any container it is or names under
    /// `path`: a container's kind as it is written (`struct`, `enum ( u8 )`, a file is a
    /// struct), else `= ` and the expression it comes to, followed through the names it is
    /// spelled with, so a renamed alias or a moved file is no change. A comptime choice
    /// between two (`if (linux) A else B`) lists the members of both.
    fn describe(w: *Walk, path: []const u8, file: glint.Project.FileId, node: Ast.Node.Index, depth: usize) anyerror![]const u8 {
        if (depth > max_depth) return "= ...";
        switch (w.resolve(file, node, depth)) {
            .container => |place| {
                try w.container(path, place.file, place.node, depth + 1);
                return w.head(place);
            },
            .expression => |place| {
                const t = w.tree(place.file);
                if (t.fullIf(place.node)) |choice| if (choice.ast.else_expr.unwrap()) |otherwise| {
                    const then = try w.describe(path, place.file, choice.ast.then_expr, depth + 1);
                    const other = try w.describe(path, place.file, otherwise, depth + 1);
                    return w.a.print("either {s} or {s}", .{ then, other });
                };
                return w.a.print("= {s}", .{try w.tokens(place.file, t, place.node)});
            },
        }
    }

    /// A container's kind as it is written before its members: `struct`, `enum ( u8 )`,
    /// `extern union`; a file is a struct.
    fn head(w: *Walk, place: Place) ![]const u8 {
        if (place.node == .root) return "struct";
        const t = w.tree(place.file);
        var last = t.firstToken(place.node);
        while (t.tokenTag(last + 1) != .l_brace) last += 1;
        return w.span(place.file, t, t.firstToken(place.node), last, &.{}, 0);
    }

    const Place = struct { file: glint.Project.FileId, node: Ast.Node.Index };
    const Resolved = union(enum) {
        /// A container the project holds: a container expression, or a file.
        container: Place,
        /// The expression a name comes to where it is no container the project holds.
        expression: Place,
    };

    /// Follows an expression through the names it is spelled with to a container, or to the
    /// expression they come to.
    fn resolve(w: *Walk, file: glint.Project.FileId, node: Ast.Node.Index, depth: usize) Resolved {
        const here: Resolved = .{ .expression = .{ .file = file, .node = node } };
        if (depth > max_depth) return here;
        const t = w.tree(file);
        if (isContainer(t, node)) return .{ .container = .{ .file = file, .node = node } };
        switch (t.nodeTag(node)) {
            .builtin_call_two, .builtin_call_two_comma => {
                const spelling = importSpelling(t, node) orelse return here;
                const target = w.project.imported(file, spelling) orelse return here;
                return .{ .container = .{ .file = target, .node = .root } };
            },
            .identifier => {
                const name = t.tokenSlice(t.nodeMainToken(node));
                const scopes = w.project.scopes(w.handle(file)) catch return here;
                var scope = w.scopeAt(file, t.nodeMainToken(node));
                while (scope) |s| : (scope = scopes[@backingInt(s)].parent) {
                    const index = scopes[@backingInt(s)].names.get(name) orelse continue;
                    return w.declared(file, index, depth) orelse here;
                }
                return here;
            },
            .field_access => {
                const left, const member = t.nodeData(node).node_and_token;
                const outer = switch (w.resolve(file, left, depth + 1)) {
                    .container => |place| place,
                    .expression => return here,
                };
                const scope = w.scopeOf(outer.file, outer.node) orelse return here;
                const scopes = w.project.scopes(w.handle(outer.file)) catch return here;
                const index = scopes[@backingInt(scope)].names.get(t.tokenSlice(member)) orelse return here;
                return w.declared(outer.file, index, depth) orelse here;
            },
            else => return here,
        }
    }

    /// What the constant a name binds comes to; null for any other declaration.
    fn declared(w: *Walk, file: glint.Project.FileId, index: glint.Declaration.Id, depth: usize) ?Resolved {
        const declarations = w.project.declarations(w.handle(file)) catch return null;
        const declaration = declarations[@backingInt(index)];
        if (declaration.kind != .variable) return null;
        const t = w.tree(file);
        const decl = t.fullVarDecl(declaration.node) orelse return null;
        if (decl.ast.type_node != .none) return null;
        const init = decl.ast.init_node.unwrap() orelse return null;
        return w.resolve(file, init, depth + 1);
    }

    fn scopeAt(w: *Walk, file: glint.Project.FileId, token: Ast.TokenIndex) ?glint.Scope.Id {
        const scopes = w.project.scopes(w.handle(file)) catch return null;
        var best = &scopes[0];
        for (scopes) |*scope| {
            if (scope.first <= token and token <= scope.last and scope.first >= best.first and scope.last <= best.last) best = scope;
        }
        return best.id;
    }

    /// The tokens of `node`, one space apart, doc comments left out, each name as `canonical`
    /// gives it.
    fn tokens(w: *Walk, file: glint.Project.FileId, t: *const Ast, node: Ast.Node.Index) ![]const u8 {
        return w.span(file, t, t.firstToken(node), t.lastToken(node), &.{}, 0);
    }

    /// The tokens from `first` to `last` of `file`, one space apart, doc comments and `skipped`
    /// left out. Once the walk knows `names`, a name a declaration binds is written as what it
    /// comes to (`canonical`), so respelling a type through an alias changes no line, and
    /// changing what a private alias names does.
    fn span(w: *Walk, file: glint.Project.FileId, t: *const Ast, first: Ast.TokenIndex, last: Ast.TokenIndex, skipped: []const Ast.TokenIndex, depth: usize) anyerror![]const u8 {
        var out: std.Io.Writer.Allocating = .init(w.a);
        var token = first;
        while (token <= last) : (token += 1) {
            if (t.tokenTag(token) == .doc_comment or t.tokenTag(token) == .container_doc_comment) continue;
            if (std.mem.findScalar(Ast.TokenIndex, skipped, token) != null) continue;
            if (out.written().len != 0) try out.writer.writeByte(' ');
            const resolving = !w.naming and depth <= max_depth;
            const chain = if (resolving) chainEnd(t, token, last) else token;
            if (resolving and nameStart(t, token)) {
                try out.writer.writeAll(try w.canonical(file, t, token, chain, depth));
                token = chain;
            } else try out.writer.writeAll(t.tokenSlice(token));
        }
        return out.written();
    }

    /// The name `first..last` of `file` spells (`a`, `a.b.C`, `@This()`), as a signature
    /// means it: a container by the public path it is listed under, a constant by the
    /// expression it comes to, and anything the package does not declare as it is spelled.
    fn canonical(w: *Walk, file: glint.Project.FileId, t: *const Ast, first: Ast.TokenIndex, last: Ast.TokenIndex, depth: usize) ![]const u8 {
        const spelled = try w.span(file, t, first, last, &.{}, max_depth + 1);
        if (depth > max_depth) return spelled;
        if (t.tokenTag(first) == .builtin) {
            const place = w.enclosing(file, first) orelse return spelled;
            return w.names.get(place) orelse spelled;
        }
        const node = chainNode(t, first, last) orelse return spelled;
        return switch (w.resolve(file, node, depth)) {
            .container => |place| w.names.get(place) orelse spelled,
            .expression => |place| if (place.file == file and place.node == node) spelled else {
                const target = w.tree(place.file);
                return w.span(place.file, target, target.firstToken(place.node), target.lastToken(place.node), &.{}, depth + 1);
            },
        };
    }

    /// The container `@This()` at `token` of `file` names: the innermost one around it.
    fn enclosing(w: *Walk, file: glint.Project.FileId, token: Ast.TokenIndex) ?Place {
        const scopes = w.project.scopes(w.handle(file)) catch return null;
        var scope = w.scopeAt(file, token);
        while (scope) |s| : (scope = scopes[@backingInt(s)].parent) {
            if (s == scopes[0].id) return .{ .file = file, .node = .root };
            if (scopes[@backingInt(s)].kind == .container) return .{ .file = file, .node = scopes[@backingInt(s)].node };
        }
        return null;
    }

    /// `fn (types) return`: the prototype without its name and the names of its parameters.
    fn signature(w: *Walk, file: glint.Project.FileId, t: *const Ast, proto: Ast.full.FnProto) ![]const u8 {
        var skipped: std.ArrayList(Ast.TokenIndex) = .empty;
        if (proto.name_token) |token| try skipped.append(w.a, token);
        var it = proto.iterate(t);
        while (it.next()) |param| if (param.name_token) |token| {
            if (param.type_expr != null and t.tokenTag(token + 1) == .colon) {
                try skipped.append(w.a, token);
                try skipped.append(w.a, token + 1);
            }
        };
        return w.span(file, t, proto.ast.fn_token, t.lastToken(proto.ast.return_type.unwrap() orelse return w.span(file, t, proto.ast.fn_token, proto.ast.fn_token, &.{}, 0)), skipped.items, 0);
    }
};

/// Whether `token` starts a name: an identifier no `.` comes before, or `@This`.
fn nameStart(t: *const Ast, token: Ast.TokenIndex) bool {
    if (token > 0 and t.tokenTag(token - 1) == .period) return false;
    return switch (t.tokenTag(token)) {
        .identifier => true,
        .builtin => std.mem.eql(u8, t.tokenSlice(token), "@This"),
        else => false,
    };
}

/// The last token of the name starting at `token` (`a.b.C`; `@This()`), no further than
/// `last`; `token` itself when no name starts there.
fn chainEnd(t: *const Ast, token: Ast.TokenIndex, last: Ast.TokenIndex) Ast.TokenIndex {
    if (!nameStart(t, token)) return token;
    if (t.tokenTag(token) == .builtin) {
        if (token + 2 <= last and t.tokenTag(token + 1) == .l_paren and t.tokenTag(token + 2) == .r_paren) return token + 2;
        return token;
    }
    var end = token;
    while (end + 2 <= last and t.tokenTag(end + 1) == .period and t.tokenTag(end + 2) == .identifier) end += 2;
    return end;
}

/// The identifier or field access spanning exactly `first..last`.
fn chainNode(t: *const Ast, first: Ast.TokenIndex, last: Ast.TokenIndex) ?Ast.Node.Index {
    for (t.nodes.items(.tag), 0..) |tag, n| {
        if (tag != .identifier and tag != .field_access) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(n));
        if (t.firstToken(node) == first and t.lastToken(node) == last) return node;
    }
    return null;
}

fn isContainer(t: *const Ast, node: Ast.Node.Index) bool {
    var buffer: [2]Ast.Node.Index = undefined;
    return t.fullContainerDecl(&buffer, node) != null;
}

fn containerKeyword(t: *const Ast, node: Ast.Node.Index) ?std.zig.Token.Tag {
    var buffer: [2]Ast.Node.Index = undefined;
    const decl = t.fullContainerDecl(&buffer, node) orelse return null;
    return t.tokenTag(decl.ast.main_token);
}

fn isEnum(t: *const Ast, node: Ast.Node.Index) bool {
    return containerKeyword(t, node) == .keyword_enum;
}

fn isUnion(t: *const Ast, node: Ast.Node.Index) bool {
    return containerKeyword(t, node) == .keyword_union;
}

fn isStruct(t: *const Ast, node: Ast.Node.Index) bool {
    return containerKeyword(t, node) == .keyword_struct;
}

/// A union with a tag, `union(enum)` or `union(Tag)`: one a switch takes.
fn isTagged(t: *const Ast, node: Ast.Node.Index) bool {
    var buffer: [2]Ast.Node.Index = undefined;
    const decl = t.fullContainerDecl(&buffer, node) orelse return false;
    return t.tokenTag(decl.ast.main_token) == .keyword_union and (decl.ast.enum_token != null or decl.ast.arg != .none);
}

/// A literal whose value is not part of the surface: a number, a string, a character, `true`.
fn isLiteral(t: *const Ast, node: Ast.Node.Index) bool {
    return switch (t.nodeTag(node)) {
        .number_literal, .string_literal, .multiline_string_literal, .char_literal, .enum_literal => true,
        .identifier => {
            const name = t.tokenSlice(t.nodeMainToken(node));
            return std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false") or std.mem.eql(u8, name, "null");
        },
        else => false,
    };
}

// Tests ------------------------------------------------------------------

pub const Files = struct {
    entries: []const struct { []const u8, []const u8 },

    pub fn read(files: Files, a: std.mem.Allocator, path: []const u8) !?[]const u8 {
        for (files.entries) |entry| if (std.mem.eql(u8, entry[0], path)) return try a.dupe(u8, entry[1]);
        return null;
    }
};

fn surfaceOf(a: std.mem.Allocator, entries: []const struct { []const u8, []const u8 }) ![]const []const u8 {
    const files: Files = .{ .entries = entries };
    return list(a, std.testing.allocator, std.testing.io, &.{.{ .name = "pkg", .root = "src/root.zig" }}, files);
}

test "a cancel while glint builds the surface's project ends the list with Canceled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Canceled = @import("shakedown").Layer(u8, .{
        .checkCancel = struct {
            fn checkCancel(_: ?*anyopaque) std.Io.Cancelable!void {
                return error.Canceled;
            }
        }.checkCancel,
    });
    var canceled: Canceled = .init(std.testing.io, 0);
    const files: Files = .{ .entries = &.{.{ "src/root.zig", "pub const limit = 64;\n" }} };
    try std.testing.expectError(error.Canceled, list(arena.allocator(), std.testing.allocator, canceled.io(), &.{.{ .name = "pkg", .root = "src/root.zig" }}, files));
}

test "the surface lists public declarations through files, aliases and containers, and nothing private" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try surfaceOf(a, &.{
        .{
            "src/root.zig",
            \\//! The root.
            \\pub const Map = @import("map.zig");
            \\pub const Alias = Hidden;
            \\pub const limit = 64;
            \\pub const std = @import("std");
            \\const Hidden = struct {
            \\    a: u8,
            \\    b: u16 = 0,
            \\    pub fn get(self: Hidden, index: usize) u8 { _ = index; return self.a; }
            \\    fn private() void {}
            \\};
            \\fn helper() void {}
        },
        .{
            "src/map.zig",
            \\/// A kind.
            \\pub const Kind = enum { one, two };
            \\pub fn put(key: []const u8, value: u32) !void { _ = key; _ = value; }
            \\const secret = 1;
        },
    });
    const expected = [_][]const u8{
        "pkg.Alias const struct",
        "pkg.Alias requires: a",
        "pkg.Alias.a field: u8",
        "pkg.Alias.b field: u16",
        "pkg.Alias.get fn ( pkg.Alias , usize ) u8",
        "pkg.Map const struct",
        "pkg.Map.Kind const enum",
        "pkg.Map.Kind exhaustive: one, two",
        "pkg.Map.Kind.one tag",
        "pkg.Map.Kind.two tag",
        "pkg.Map.put fn ( [ ] const u8 , u32 ) ! void",
        "pkg.limit const",
        "pkg.limit value = 64",
        "pkg.std const = @import ( \"std\" )",
    };
    try std.testing.expectEqualStrings(try std.mem.join(a, "\n", &expected), try std.mem.join(a, "\n", lines));
}

test "a removed declaration, a changed signature and a new required field are removed lines; an addition is not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try surfaceOf(a, &.{.{
        "src/root.zig",
        \\pub const Options = struct { size: usize = 1 };
        \\pub fn run(options: Options) void { _ = options; }
        \\pub fn gone() void {}
    }});
    // Only layout, comments and parameter names moved: the same surface.
    const same = try surfaceOf(a, &.{.{
        "src/root.zig",
        \\/// Options.
        \\pub const Options = struct {
        \\    size: usize = 2,
        \\};
        \\pub fn run(given: Options) void {
        \\    _ = given;
        \\}
        \\pub fn gone() void {}
    }});
    try std.testing.expectEqual(0, (try removed(a, before, same)).len);
    // An addition alone removes nothing.
    const more = try surfaceOf(a, &.{.{
        "src/root.zig",
        \\pub const Options = struct { size: usize = 1, depth: u8 = 0 };
        \\pub fn run(options: Options) void { _ = options; }
        \\pub fn gone() void {}
        \\pub fn more() void {}
    }});
    try std.testing.expectEqual(0, (try removed(a, before, more)).len);
    const broken = try surfaceOf(a, &.{.{
        "src/root.zig",
        \\pub const Options = struct { size: usize = 1, depth: u8 };
        \\pub fn run(options: Options, extra: bool) void { _ = options; _ = extra; }
    }});
    const gone = try removed(a, before, broken);
    const expected = [_][]const u8{ "pkg.Options requires: ", "pkg.gone fn ( ) void", "pkg.run fn ( pkg.Options ) void" };
    try std.testing.expectEqualStrings(try std.mem.join(a, "\n", &expected), try std.mem.join(a, "\n", gone));
}

test "the members of a type a function makes are listed under its call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try surfaceOf(a, &.{.{
        "src/root.zig",
        \\pub fn List(comptime T: type) type {
        \\    return struct {
        \\        const Self = @This();
        \\        items: []T,
        \\        pub fn append(self: *Self, item: T) void { _ = self; _ = item; }
        \\    };
        \\}
    }});
    const expected = [_][]const u8{
        "pkg.List fn ( comptime type ) type",
        "pkg.List() requires: items",
        "pkg.List().append fn ( * pkg.List() , T ) void",
        "pkg.List().items field: [ ] T",
    };
    try std.testing.expectEqualStrings(try std.mem.join(a, "\n", &expected), try std.mem.join(a, "\n", lines));
}

test "an import outside the package and a container that reaches itself end the walk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try surfaceOf(a, &.{.{
        "src/root.zig",
        \\pub const Self = @This();
        \\pub const Again = @import("root.zig");
        \\pub const Outside = @import("../../elsewhere.zig");
    }});
    try std.testing.expect(lines.len >= 3);
}

test "a tag or a field an exhaustive switch names, added or taken away, is a removed line; a non-exhaustive enum's is not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try surfaceOf(a, &.{.{ "src/root.zig", "pub const Kind = enum { one, two };\npub const Open = enum(u8) { one, _ };\npub const Value = union(enum) { int: u32, text: []const u8 };\npub const Raw = union { int: u32, float: f32 };\n" }});
    const grown = try surfaceOf(a, &.{.{ "src/root.zig", "pub const Kind = enum { one, two, three };\npub const Open = enum(u8) { one, two, _ };\npub const Value = union(enum) { int: u32, text: []const u8, none };\npub const Raw = union { int: u32, float: f32, other: u8 };\n" }});
    const gone = try removed(a, before, grown);
    const expected = [_][]const u8{ "pkg.Kind exhaustive: one, two", "pkg.Value tagged: int, text" };
    try std.testing.expectEqualStrings(try std.mem.join(a, "\n", &expected), try std.mem.join(a, "\n", gone));
    // `_` added makes every switch over it need an `else`; taken away, an `else` there fails.
    const opened = try surfaceOf(a, &.{.{ "src/root.zig", "pub const Kind = enum { one, two, _ };\npub const Open = enum(u8) { one };\npub const Value = union(enum) { int: u32, text: []const u8 };\npub const Raw = union { int: u32, float: f32 };\n" }});
    const flipped = [_][]const u8{ "pkg.Kind exhaustive: one, two", "pkg.Open non-exhaustive" };
    try std.testing.expectEqualStrings(try std.mem.join(a, "\n", &flipped), try std.mem.join(a, "\n", try removed(a, before, opened)));
}

test "a field given a default, a constant's new value and a type respelled remove nothing; a private alias that names another type does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try surfaceOf(a, &.{
        .{ "src/root.zig", "const Bytes = u64;\npub const Map = @import(\"map.zig\");\npub const Options = struct { size: usize, depth: u8 };\npub const limit = 64;\npub fn take(n: Bytes, kind: Map.Kind) void { _ = n; _ = kind; }\n" },
        .{ "src/map.zig", "pub const Kind = enum { one, two };\n" },
    });
    const after = try surfaceOf(a, &.{
        .{ "src/root.zig", "const Kind = @import(\"map.zig\").Kind;\npub const Map = @import(\"map.zig\");\npub const Options = struct { size: usize, depth: u8 = 0 };\npub const limit = 128;\npub fn take(n: u64, kind: Kind) void { _ = n; _ = kind; }\n" },
        .{ "src/map.zig", "pub const Kind = enum { one, two };\n" },
    });
    try std.testing.expectEqual(0, (try removed(a, before, after)).len);
    // The value and the fewer required fields are additions, each needing an entry.
    const new = [_][]const u8{ "pkg.Options requires: size", "pkg.limit value = 128" };
    try std.testing.expectEqualStrings(try std.mem.join(a, "\n", &new), try std.mem.join(a, "\n", try added(a, before, after)));
    const narrowed = try surfaceOf(a, &.{
        .{ "src/root.zig", "const Bytes = u32;\npub const Map = @import(\"map.zig\");\npub const Options = struct { size: usize, depth: u8 };\npub const limit = 64;\npub fn take(n: Bytes, kind: Map.Kind) void { _ = n; _ = kind; }\n" },
        .{ "src/map.zig", "pub const Kind = enum { one, two };\n" },
    });
    const gone = [_][]const u8{"pkg.take fn ( u64 , pkg.Map.Kind ) void"};
    try std.testing.expectEqualStrings(try std.mem.join(a, "\n", &gone), try std.mem.join(a, "\n", try removed(a, before, narrowed)));
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
    try std.testing.expectEqual(@as(?[]const Module, null), try declaredModules(a, "pub fn build(b: *@import(\"std\").Build) void {\n    const name = \"pkg\";\n    _ = b.addModule(name, .{ .root_source_file = b.path(\"src/pkg.zig\") });\n}\n"));
    try std.testing.expectEqual(@as(?[]const Module, null), try declaredModules(a, "pub fn build(b: *@import(\"std\").Build) void {\n    _ = b.addModule(\"pkg\", .{ .root_source_file = root(b) });\n}\n"));
}
