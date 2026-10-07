//! One file's references to deprecated std declarations, rewritten from its
//! syntax tree. A name resolves through the file's aliases (`const mem =
//! std.mem;`) and through std's own, so `mem.indexOf` and `std.mem.indexOf`
//! both become a call of `find`.
const std = @import("std");
const Ast = std.zig.Ast;
const library = @import("library.zig");
const table = @import("table.zig");
const Path = library.Path;
const Allocator = std.mem.Allocator;

pub const Kind = enum {
    /// A path std aliases or the table renames.
    path,
    /// A call whose first argument became the receiver.
    receiver,
    memmove,
    orelse_to_catch,
    /// An alias the rewrites left unused.
    unused,
};

pub const Change = struct { line: usize, kind: Kind, old: []const u8, new: []const u8 };

/// A deprecated reference nothing in the table moves.
pub const Leftover = struct { line: usize, name: []const u8, doc: []const u8 };

pub const Outcome = struct {
    /// The rewritten source, formatted; the input when nothing changed.
    text: []const u8,
    changes: []const Change,
    leftovers: []const Leftover,
};

const Edit = struct { start: usize, end: usize, text: []const u8 };
const Group = struct { kind: Kind, edits: []const Edit };

/// Every rewrite of a file needs a second look at the parts it moved, so
/// edits apply in passes until a pass finds nothing.
const max_passes = 8;

pub fn file(a: Allocator, lib: *library.Library, entries: []const table.Entry, source: []const u8) !Outcome {
    var text: [:0]const u8 = try a.dupeSentinel(u8, source, 0);
    var changes: std.ArrayList(Change) = .empty;
    var leftovers: std.ArrayList(Leftover) = .empty;
    const original = try Ast.parse(a, text, .{});
    if (original.errors.len > 0) return error.Unparsable;
    const first_names = try Names.collect(a, &original);
    var passes: usize = 0;
    while (true) : (passes += 1) {
        if (passes == max_passes) return error.RewriteDidNotSettle;
        const tree = try Ast.parse(a, text, .{});
        if (tree.errors.len > 0) return error.RewriteBrokeSyntax;
        var view: View = .{ .a = a, .lib = lib, .entries = entries, .tree = &tree, .names = try Names.collect(a, &tree) };
        const groups = try view.groups(if (passes == 0) &leftovers else null);
        if (groups.len == 0) break;
        text = try apply(a, text, groups, &changes);
    }
    while (try unusedAliases(a, text, &original, first_names)) |group| {
        text = try apply(a, text, &.{group}, &changes);
    }
    std.mem.sort(Change, changes.items, {}, struct {
        fn earlier(_: void, x: Change, y: Change) bool {
            return x.line < y.line;
        }
    }.earlier);
    std.mem.sort(Leftover, leftovers.items, {}, struct {
        fn before(_: void, x: Leftover, y: Leftover) bool {
            return x.line < y.line;
        }
    }.before);
    if (changes.items.len == 0) return .{ .text = source, .changes = &.{}, .leftovers = leftovers.items };
    const tree = try Ast.parse(a, text, .{});
    if (tree.errors.len > 0) return error.RewriteBrokeSyntax;
    return .{ .text = try tree.renderAlloc(a), .changes = changes.items, .leftovers = leftovers.items };
}

/// The names a file binds: aliases of std paths, declarations with a std
/// type, and the rest. Zig forbids shadowing, so a name bound one way
/// everywhere means that everywhere.
const Names = struct {
    aliases: std.StringHashMapUnmanaged(Path) = .empty,
    typed: std.StringHashMapUnmanaged(Path) = .empty,
    /// Aliases declared at the top of the file, where every scope sees them.
    top: std.StringHashMapUnmanaged(Path) = .empty,

    const Binding = struct { init: ?Ast.Node.Index = null, type: ?Ast.Node.Index = null };

    fn collect(a: Allocator, tree: *const Ast) !Names {
        var bound: std.StringHashMapUnmanaged(std.ArrayList(Binding)) = .empty;
        for (0..tree.nodes.len) |i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (tree.fullVarDecl(node)) |decl| {
                try bind(a, &bound, tree.tokenSlice(decl.ast.mut_token + 1), .{ .init = decl.ast.init_node.unwrap(), .type = decl.ast.type_node.unwrap() });
            }
            var buffer: [1]Ast.Node.Index = undefined;
            if (tree.nodeTag(node) == .fn_decl) continue;
            const proto = tree.fullFnProto(&buffer, node) orelse continue;
            if (proto.name_token) |name| try bind(a, &bound, tree.tokenSlice(name), .{});
            var it = proto.iterate(tree);
            while (it.next()) |param| if (param.name_token) |name| try bind(a, &bound, tree.tokenSlice(name), .{ .type = param.type_expr });
        }
        try captures(a, tree, &bound);
        var names: Names = .{};
        // Aliases of aliases resolve over rounds: `const mem = std.mem;` first.
        var changed = true;
        while (changed) {
            changed = false;
            var it = bound.iterator();
            while (it.next()) |entry| {
                if (names.aliases.contains(entry.key_ptr.*)) continue;
                const path = try agreed(.init, a, &names, tree, entry.value_ptr.items) orelse continue;
                try names.aliases.put(a, entry.key_ptr.*, path);
                changed = true;
            }
        }
        var it = bound.iterator();
        while (it.next()) |entry| {
            if (try agreed(.type, a, &names, tree, entry.value_ptr.items)) |path| try names.typed.put(a, entry.key_ptr.*, path);
        }
        for (tree.rootDecls()) |decl| {
            const name = library.declarationName(tree, decl) orelse continue;
            if (names.aliases.get(name)) |path| try names.top.put(a, name, path);
        }
        return names;
    }

    fn bind(a: Allocator, bound: *std.StringHashMapUnmanaged(std.ArrayList(Binding)), name: []const u8, binding: Binding) !void {
        const entry = try bound.getOrPut(a, name);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(a, binding);
    }

    /// Payload captures, `|x|` and `|*x, i|`, bind names with no declared type.
    fn captures(a: Allocator, tree: *const Ast, bound: *std.StringHashMapUnmanaged(std.ArrayList(Binding))) !void {
        const tags = tree.tokens.items(.tag);
        var i: usize = 1;
        while (i < tags.len) : (i += 1) {
            if (tags[i] != .pipe) continue;
            switch (tags[i - 1]) {
                .r_paren, .keyword_else, .keyword_catch, .equal_angle_bracket_right => {},
                else => continue,
            }
            var j = i + 1;
            while (j < tags.len and tags[j] != .pipe) : (j += 1) {
                if (tags[j] == .identifier) try bind(a, bound, tree.tokenSlice(@intCast(j)), .{});
            }
            i = j;
        }
    }

    /// The one path every binding of a name gives by `field`, if they agree.
    fn agreed(comptime field: enum { init, type }, a: Allocator, names: *const Names, tree: *const Ast, bindings: []const Binding) !?Path {
        var agreed_path: ?Path = null;
        for (bindings) |binding| {
            const node = (if (field == .init) binding.init else binding.type) orelse return null;
            const path = (if (field == .init) try names.pathOf(a, tree, node) else try names.typePath(a, tree, node)) orelse return null;
            if (agreed_path) |seen| if (!samePath(seen, path)) return null;
            agreed_path = path;
        }
        return agreed_path;
    }

    /// The std path an expression names: an alias, `@import("std")`, and
    /// fields of either.
    fn pathOf(names: *const Names, a: Allocator, tree: *const Ast, node: Ast.Node.Index) !?Path {
        switch (tree.nodeTag(node)) {
            .identifier => return names.aliases.get(tree.tokenSlice(tree.nodeMainToken(node))),
            .field_access => {
                const lhs, const field = tree.nodeData(node).node_and_token;
                const base = try names.pathOf(a, tree, lhs) orelse return null;
                const out = try a.alloc([]const u8, base.len + 1);
                @memcpy(out[0..base.len], base);
                out[base.len] = tree.tokenSlice(field);
                return out;
            },
            .builtin_call_two, .builtin_call_two_comma => return if (library.importsStd(tree, node)) &.{"std"} else null,
            else => return null,
        }
    }

    /// The std type a declared type names, through pointers and optionals.
    fn typePath(names: *const Names, a: Allocator, tree: *const Ast, node: Ast.Node.Index) !?Path {
        if (tree.nodeTag(node) == .optional_type) return names.typePath(a, tree, tree.nodeData(node).node);
        if (tree.fullPtrType(node)) |pointer| return names.typePath(a, tree, pointer.ast.child_type);
        return names.pathOf(a, tree, node);
    }
};

/// One pass over one parse of the file.
const View = struct {
    a: Allocator,
    lib: *library.Library,
    entries: []const table.Entry,
    tree: *const Ast,
    names: Names,

    /// The groups of edits this pass makes, none overlapping another; a
    /// call's move wins over a rename of its callee, an outer path over the
    /// paths inside it. The first pass also lists what it cannot move.
    fn groups(v: *View, leftovers: ?*std.ArrayList(Leftover)) ![]const Group {
        var calls: std.ArrayList(Group) = .empty;
        var paths: std.ArrayList(Group) = .empty;
        var orelses: std.AutoHashMapUnmanaged(Ast.Node.Index, Ast.TokenIndex) = .empty;
        const tree = v.tree;
        for (0..tree.nodes.len) |i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (tree.nodeTag(node) == .@"orelse") try orelses.put(v.a, tree.nodeData(node).node_and_node[0], tree.nodeMainToken(node));
        }
        for (0..tree.nodes.len) |i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            var buffer: [1]Ast.Node.Index = undefined;
            if (tree.fullCall(&buffer, node)) |call| {
                if (try v.callGroup(node, call, orelses, leftovers)) |group| try calls.append(v.a, group);
            }
            switch (tree.nodeTag(node)) {
                .identifier, .field_access => if (try v.pathGroup(node, leftovers)) |group| try paths.append(v.a, group),
                else => {},
            }
        }
        std.mem.sort(Group, paths.items, {}, struct {
            fn wider(_: void, x: Group, y: Group) bool {
                return x.edits[0].end - x.edits[0].start > y.edits[0].end - y.edits[0].start;
            }
        }.wider);
        var chosen: std.ArrayList(Group) = .empty;
        for ([_][]const Group{ calls.items, paths.items }) |list| for (list) |group| {
            if (!overlaps(chosen.items, group)) try chosen.append(v.a, group);
        };
        return chosen.items;
    }

    /// A call the table moves: a receiver, a memmove or an orelse.
    fn callGroup(v: *View, node: Ast.Node.Index, call: Ast.full.Call, orelses: std.AutoHashMapUnmanaged(Ast.Node.Index, Ast.TokenIndex), leftovers: ?*std.ArrayList(Leftover)) !?Group {
        const tree = v.tree;
        const callee = call.ast.fn_expr;
        if (tree.nodeTag(callee) == .field_access) {
            const lhs, const method = tree.nodeData(callee).node_and_token;
            if (tree.nodeTag(lhs) == .identifier) if (v.names.typed.get(tree.tokenSlice(tree.nodeMainToken(lhs)))) |type_path| {
                return v.methodGroup(node, type_path, method, orelses, leftovers);
            };
        }
        const path = try v.names.pathOf(v.a, tree, callee) orelse return null;
        if (path.len < 2) return null;
        const owner = try v.lib.normalize(path[0 .. path.len - 1]);
        const written = try std.mem.join(v.a, ".", owner.path);
        const name = path[path.len - 1];
        for (v.entries) |entry| switch (entry) {
            .receiver => |r| if (matches(written, name, r.old)) return v.receiverGroup(call, r.new),
            .memmove => |m| if (matches(written, name, m)) {
                if (try v.memmoveGroup(node, call)) |group| return group;
                if (leftovers) |list| try list.append(v.a, .{ .line = v.line(tree.firstToken(node)), .name = m, .doc = "the source is not a plain name; @memmove would evaluate it twice" });
                return null;
            },
            else => {},
        };
        return null;
    }

    /// `old(a, rest)` as `a.method(rest)`, when `a` reads as a receiver.
    fn receiverGroup(v: *View, call: Ast.full.Call, new: []const u8) !?Group {
        const tree = v.tree;
        if (call.ast.params.len == 0) return null;
        const receiver = call.ast.params[0];
        if (!suffix(tree.nodeTag(receiver))) return null;
        const method = new[std.mem.findScalarLast(u8, new, '.').? + 1 ..];
        const callee_start = v.start(tree.firstToken(call.ast.fn_expr));
        const receiver_start = v.start(tree.firstToken(receiver));
        const receiver_end = v.end(tree.lastToken(receiver));
        const tail = if (call.ast.params.len > 1) v.start(tree.firstToken(call.ast.params[1])) else v.closingParen(call);
        const edits = try v.a.dupe(Edit, &.{
            .{ .start = callee_start, .end = receiver_start, .text = "" },
            .{ .start = receiver_end, .end = tail, .text = try std.mem.concat(v.a, u8, &.{ ".", method, "(" }) },
        });
        return if (v.dropsComment(edits)) null else .{ .kind = .receiver, .edits = edits };
    }

    /// `copy(T, dest, source)` as `@memmove(dest[0..source.len], source)`,
    /// when `source` is a plain name that reads the same twice.
    fn memmoveGroup(v: *View, node: Ast.Node.Index, call: Ast.full.Call) !?Group {
        const tree = v.tree;
        if (call.ast.params.len != 3 or !plainName(tree, call.ast.params[2])) return null;
        const dest = call.ast.params[1];
        const source = tree.getNodeSource(call.ast.params[2]);
        const wrap = !suffix(tree.nodeTag(dest));
        const edits = try v.a.dupe(Edit, &.{
            .{ .start = v.start(tree.firstToken(node)), .end = v.start(tree.firstToken(dest)), .text = if (wrap) "@memmove((" else "@memmove(" },
            .{ .start = v.end(tree.lastToken(dest)), .end = v.start(tree.firstToken(call.ast.params[2])), .text = try std.mem.concat(v.a, u8, &.{ if (wrap) ")" else "", "[0..", source, ".len], " }) },
        });
        return if (v.dropsComment(edits)) null else .{ .kind = .memmove, .edits = edits };
    }

    /// `value.old(args) orelse x` as `value.new(args) catch x`, for a value
    /// whose declared type the table names.
    fn methodGroup(v: *View, node: Ast.Node.Index, type_path: Path, method: Ast.TokenIndex, orelses: std.AutoHashMapUnmanaged(Ast.Node.Index, Ast.TokenIndex), leftovers: ?*std.ArrayList(Leftover)) !?Group {
        const tree = v.tree;
        const name = tree.tokenSlice(method);
        const normal = try v.lib.normalize(type_path);
        const written = try std.mem.join(v.a, ".", normal.path);
        for (v.entries) |entry| switch (entry) {
            .orelse_to_catch => |r| if (std.mem.eql(u8, written, r.type) and std.mem.eql(u8, name, r.old)) {
                const keyword = orelses.get(node) orelse break;
                return .{ .kind = .orelse_to_catch, .edits = try v.a.dupe(Edit, &.{
                    .{ .start = v.start(method), .end = v.end(method), .text = r.new },
                    .{ .start = v.start(keyword), .end = v.end(keyword), .text = "catch" },
                }) };
            },
            else => {},
        };
        const list = leftovers orelse return null;
        const found = try v.lib.lookup(try appendPath(v.a, normal.path, name)) orelse return null;
        const doc = library.deprecation(v.a, found) orelse return null;
        try list.append(v.a, .{ .line = v.line(method), .name = try std.mem.join(v.a, ".", &.{ written, name }), .doc = doc });
        return null;
    }

    /// A path std or the table replaces, rewritten with as much of the
    /// original spelling as still names the same thing.
    fn pathGroup(v: *View, node: Ast.Node.Index, leftovers: ?*std.ArrayList(Leftover)) !?Group {
        const tree = v.tree;
        const path = try v.names.pathOf(v.a, tree, node) orelse return null;
        if (path.len < 2) return null;
        const normal = try v.lib.normalize(path);
        if (samePath(normal.path, path)) {
            if (normal.leftover) |doc| if (leftovers) |list| try v.leftover(list, node, path, doc);
            return null;
        }
        // An alias moves with its own declaration's rewrite.
        if (tree.nodeTag(node) == .identifier) return null;
        // The outermost part of the chain whose rewritten path starts the
        // new one keeps its spelling: `path.resolve` becomes
        // `path.resolveAlloc` while `const path = std.fs.path;` moves too.
        var part = tree.nodeData(node).node_and_token[0];
        while (true) {
            const kept = (try v.lib.normalize((try v.names.pathOf(v.a, tree, part)).?)).path;
            if (kept.len <= normal.path.len and samePath(kept, normal.path[0..kept.len])) {
                const rest = try std.mem.join(v.a, ".", normal.path[kept.len..]);
                const edit: Edit = .{ .start = v.end(tree.lastToken(part)), .end = v.end(tree.lastToken(node)), .text = if (rest.len == 0) "" else try std.mem.concat(v.a, u8, &.{ ".", rest }) };
                // Only the kept part moves, by a rewrite of its own.
                if (std.mem.eql(u8, edit.text, tree.source[edit.start..edit.end])) return null;
                return v.pathEdit(edit, path, leftovers);
            }
            if (tree.nodeTag(part) != .field_access) break;
            part = tree.nodeData(part).node_and_token[0];
        }
        const edit: Edit = .{ .start = v.start(tree.firstToken(node)), .end = v.end(tree.lastToken(node)), .text = try v.spell(normal.path) };
        return v.pathEdit(edit, path, leftovers);
    }

    fn leftover(v: *View, list: *std.ArrayList(Leftover), node: Ast.Node.Index, path: Path, doc: []const u8) !void {
        // A table move covers the callee's deprecation where it applies.
        const name = try std.mem.join(v.a, ".", path);
        for (v.entries) |entry| switch (entry) {
            .memmove => |m| if (std.mem.eql(u8, m, name)) return,
            else => {},
        };
        try list.append(v.a, .{ .line = v.line(v.tree.firstToken(node)), .name = name, .doc = doc });
    }

    /// `path` from the top-level alias that covers most of it, or from
    /// `@import("std")` when the file has none.
    fn spell(v: *View, path: Path) ![]const u8 {
        var best_name: ?[]const u8 = null;
        var best_len: usize = 0;
        var it = v.names.top.iterator();
        while (it.next()) |entry| {
            const alias = entry.value_ptr.*;
            if (alias.len > path.len or !samePath(alias, path[0..alias.len])) continue;
            if (alias.len > best_len or (alias.len == best_len and entry.key_ptr.len < best_name.?.len)) {
                best_name = entry.key_ptr.*;
                best_len = alias.len;
            }
        }
        const head = best_name orelse "@import(\"std\")";
        const used = if (best_name == null) 1 else best_len;
        if (used == path.len) return head;
        return std.mem.concat(v.a, u8, &.{ head, ".", try std.mem.join(v.a, ".", path[used..]) });
    }

    fn pathEdit(v: *View, edit: Edit, path: Path, leftovers: ?*std.ArrayList(Leftover)) !?Group {
        const edits = try v.a.dupe(Edit, &.{edit});
        if (!v.dropsComment(edits)) return .{ .kind = .path, .edits = edits };
        if (leftovers) |list| try list.append(v.a, .{ .line = v.lineAt(edit.start), .name = try std.mem.join(v.a, ".", path), .doc = "a comment sits inside the rewrite" });
        return null;
    }

    /// A rewrite never deletes a comment: one inside the text an edit
    /// replaces leaves that reference to a person.
    fn dropsComment(v: *View, edits: []const Edit) bool {
        for (edits) |edit| if (std.mem.find(u8, v.tree.source[edit.start..edit.end], "//") != null) return true;
        return false;
    }

    fn closingParen(v: *View, call: Ast.full.Call) usize {
        var token = v.tree.lastToken(call.ast.params[call.ast.params.len - 1]) + 1;
        while (v.tree.tokenTag(token) != .r_paren) token += 1;
        return v.start(token);
    }

    fn start(v: *View, token: Ast.TokenIndex) usize {
        return v.tree.tokenStart(token);
    }

    fn end(v: *View, token: Ast.TokenIndex) usize {
        return v.tree.tokenStart(token) + v.tree.tokenSlice(token).len;
    }

    fn line(v: *View, token: Ast.TokenIndex) usize {
        return v.lineAt(v.tree.tokenStart(token));
    }

    fn lineAt(v: *View, offset: usize) usize {
        return 1 + std.mem.count(u8, v.tree.source[0..offset], "\n");
    }
};

/// Whether a callee written as `owner.name`, its owner normalized, is `old`.
fn matches(owner: []const u8, name: []const u8, old: []const u8) bool {
    return old.len == owner.len + 1 + name.len and std.mem.startsWith(u8, old, owner) and
        old[owner.len] == '.' and std.mem.endsWith(u8, old, name);
}

/// Expressions a `.method(...)` or `[a..b]` suffix applies to as a whole.
fn suffix(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .identifier, .field_access, .call_one, .call_one_comma, .call, .call_comma, .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma, .array_access, .deref, .unwrap_optional, .grouped_expression, .slice, .slice_open, .slice_sentinel => true,
        else => false,
    };
}

/// A name or a field of one: evaluating it twice reads the same value.
fn plainName(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .identifier => true,
        .field_access => plainName(tree, tree.nodeData(node).node_and_token[0]),
        else => false,
    };
}

fn overlaps(chosen: []const Group, group: Group) bool {
    for (chosen) |other| for (other.edits) |x| for (group.edits) |y| {
        if (x.start < y.end and y.start < x.end) return true;
    };
    return false;
}

fn apply(a: Allocator, text: [:0]const u8, groups: []const Group, changes: *std.ArrayList(Change)) ![:0]const u8 {
    var edits: std.ArrayList(Edit) = .empty;
    for (groups) |group| {
        try edits.appendSlice(a, group.edits);
        const first = group.edits[0].start;
        var last = group.edits[0].end;
        for (group.edits) |edit| last = @max(last, edit.end);
        var replaced: std.ArrayList(u8) = .empty;
        var cursor = first;
        for (group.edits) |edit| {
            try replaced.appendSlice(a, text[cursor..edit.start]);
            try replaced.appendSlice(a, edit.text);
            cursor = edit.end;
        }
        try replaced.appendSlice(a, text[cursor..last]);
        try changes.append(a, .{
            .line = 1 + std.mem.count(u8, text[0..first], "\n"),
            .kind = group.kind,
            .old = try compact(a, text[first..last]),
            .new = try compact(a, replaced.items),
        });
    }
    std.mem.sort(Edit, edits.items, {}, struct {
        fn before(_: void, x: Edit, y: Edit) bool {
            return x.start < y.start;
        }
    }.before);
    var out: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    for (edits.items) |edit| {
        try out.appendSlice(a, text[cursor..edit.start]);
        try out.appendSlice(a, edit.text);
        cursor = edit.end;
    }
    try out.appendSlice(a, text[cursor..]);
    return out.toOwnedSliceSentinel(a, 0);
}

/// The text on one line, runs of whitespace as one space.
fn compact(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (tokens.next()) |token| {
        if (out.items.len > 0 and !std.mem.endsWith(u8, out.items, "(") and token[0] != ')') try out.append(a, ' ');
        try out.appendSlice(a, token);
    }
    return out.items;
}

/// A private alias the rewrites left without a use, removed with its line:
/// `const fmt = std.fmt;` once no call goes through `fmt`.
fn unusedAliases(a: Allocator, text: [:0]const u8, original: *const Ast, before: Names) !?Group {
    const tree = try Ast.parse(a, text, .{});
    const names = try Names.collect(a, &tree);
    var it = names.aliases.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!before.aliases.contains(name) or uses(original, name) == 0 or uses(&tree, name) > 0) continue;
        for (0..tree.nodes.len) |i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const decl = tree.fullVarDecl(node) orelse continue;
            if (decl.visib_token != null or !std.mem.eql(u8, tree.tokenSlice(decl.ast.mut_token + 1), name)) continue;
            return .{ .kind = .unused, .edits = try a.dupe(Edit, &.{lineSpan(&tree, node)}) };
        }
    }
    return null;
}

/// References to `name`: identifiers that are not a field after `.` and not
/// the name a declaration binds.
fn uses(tree: *const Ast, name: []const u8) usize {
    const tags = tree.tokens.items(.tag);
    var count: usize = 0;
    for (tags, 0..) |tag, i| {
        if (tag != .identifier or i == 0) continue;
        if (tags[i - 1] == .period or tags[i - 1] == .keyword_const or tags[i - 1] == .keyword_var) continue;
        if (std.mem.eql(u8, tree.tokenSlice(@intCast(i)), name)) count += 1;
    }
    return count;
}

/// A declaration from the start of its first line through its newline, doc
/// comments included.
fn lineSpan(tree: *const Ast, node: Ast.Node.Index) Edit {
    var first = tree.firstToken(node);
    while (first > 0 and tree.tokenTag(first - 1) == .doc_comment) first -= 1;
    var semicolon = tree.lastToken(node) + 1;
    while (tree.tokenTag(semicolon) != .semicolon) semicolon += 1;
    const source = tree.source;
    var begin = tree.tokenStart(first);
    while (begin > 0 and (source[begin - 1] == ' ' or source[begin - 1] == '\t')) begin -= 1;
    var finish = tree.tokenStart(semicolon) + 1;
    while (finish < source.len and (source[finish] == ' ' or source[finish] == '\t' or source[finish] == '\r')) finish += 1;
    if (finish < source.len and source[finish] == '\n') finish += 1;
    return .{ .start = begin, .end = finish, .text = "" };
}

fn samePath(x: Path, y: Path) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

fn appendPath(a: Allocator, path: Path, name: []const u8) !Path {
    const out = try a.alloc([]const u8, path.len + 1);
    @memcpy(out[0..path.len], path);
    out[path.len] = name;
    return out;
}
