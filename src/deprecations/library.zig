//! Zig's standard library read as source: what a path names, whether std
//! deprecates it, and what a deprecated alias stands for.
const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

/// `std.mem.find` as its steps: `std`, `mem`, `find`.
pub const Path = []const []const u8;

pub const File = struct {
    /// Relative to the library's `std` directory.
    path: []const u8,
    tree: Ast,
    /// The path the walk first reached this file by.
    reached: ?Path = null,
    /// Container nodes with their token spans, innermost lookups first.
    scopes: ?[]const Ast.Node.Index = null,
};

/// A namespace, or a declaration that is not one.
pub const Target = struct {
    file: *File,
    node: Ast.Node.Index,
    kind: enum { container, declaration },

    pub fn same(a: Target, b: Target) bool {
        return a.file == b.file and a.node == b.node;
    }
};

/// A declaration and the namespace that declares it.
pub const Member = struct {
    owner: Target,
    /// A variable or function declaration node in `owner.file`.
    node: Ast.Node.Index,
};

/// A path with every deprecated step on it replaced.
pub const Normal = struct {
    path: Path,
    /// The declaration the last step names, when the walk reached it.
    member: ?Member,
    /// The deprecation std documents on the last step and nothing replaces.
    leftover: ?[]const u8,
};

pub const Param = struct { comptime_param: bool, type: []const u8 };

const max_depth = 24;

pub const Library = struct {
    a: Allocator,
    io: std.Io,
    /// The `std` directory of a Zig installation.
    dir: std.Io.Dir,
    files: std.StringHashMapUnmanaged(*File) = .empty,
    /// Replacements a release's table names, by joined old path.
    renames: std.StringHashMapUnmanaged(Path) = .empty,
    normals: std.StringHashMapUnmanaged(Normal) = .empty,

    fn load(lib: *Library, path: []const u8) !?*File {
        if (lib.files.get(path)) |file| return file;
        const text = lib.dir.readFileAlloc(lib.io, path, lib.a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        const file = try lib.a.create(File);
        file.* = .{ .path = path, .tree = try Ast.parse(lib.a, try lib.a.dupeSentinel(u8, text, 0), .{}) };
        try lib.files.put(lib.a, path, file);
        return file;
    }

    pub fn root(lib: *Library) !Target {
        const file = try lib.load("std.zig") orelse return error.NoStandardLibrary;
        if (file.reached == null) file.reached = &.{"std"};
        return .{ .file = file, .node = .root, .kind = .container };
    }

    pub fn addRename(lib: *Library, old: []const u8, new: []const u8) !void {
        try lib.renames.put(lib.a, old, try split(lib.a, new));
    }

    /// Walks `path` as written, deprecated steps included.
    pub fn lookup(lib: *Library, path: Path) !?Member {
        var at: ?Target = try lib.root();
        var found: ?Member = null;
        for (path[1..]) |name| {
            const owner = at orelse return null;
            found = .{ .owner = owner, .node = member(owner, name) orelse return null };
            at = try lib.targetOf(found.?, 0);
        }
        return found;
    }

    /// Replaces each deprecated step of `path` that std aliases or the table
    /// renames, left to right, so `std.fs.path.resolve` becomes
    /// `std.Io.Dir.path.resolveAlloc`.
    pub fn normalize(lib: *Library, path: Path) !Normal {
        const key = try std.mem.join(lib.a, ".", path);
        if (lib.normals.get(key)) |normal| return normal;
        const normal = try lib.normalizeDepth(path, 0);
        try lib.normals.put(lib.a, key, normal);
        return normal;
    }

    fn normalizeDepth(lib: *Library, path: Path, depth: usize) !Normal {
        if (depth > max_depth) return error.AliasCycle;
        var out: std.ArrayList([]const u8) = .empty;
        try out.append(lib.a, "std");
        var at: ?Target = try lib.root();
        var last: ?Member = null;
        var leftover: ?[]const u8 = null;
        for (path[1..]) |name| {
            last = null;
            leftover = null;
            const owner = at orelse {
                try out.append(lib.a, name);
                continue;
            };
            const node = member(owner, name) orelse {
                at = null;
                try out.append(lib.a, name);
                continue;
            };
            const found: Member = .{ .owner = owner, .node = node };
            const owner_path = try lib.a.dupe([]const u8, out.items);
            try out.append(lib.a, name);
            if (deprecation(lib.a, found)) |doc| {
                if (try lib.replacement(found, owner_path, out.items, depth)) |new| {
                    const next = try lib.normalizeDepth(new, depth + 1);
                    out.clearRetainingCapacity();
                    try out.appendSlice(lib.a, next.path);
                    last = next.member;
                    leftover = next.leftover;
                    at = if (next.member) |m| try lib.targetOf(m, 0) else null;
                    continue;
                }
                leftover = doc;
            }
            last = found;
            at = try lib.targetOf(found, 0);
            if (at) |t| if (t.node == .root and t.file.reached == null) {
                t.file.reached = try lib.a.dupe([]const u8, out.items);
            };
        }
        return .{ .path = out.items, .member = last, .leftover = leftover };
    }

    /// What a deprecated declaration becomes: the table's rename, or the
    /// declaration a `pub const old = new;` alias names.
    fn replacement(lib: *Library, found: Member, owner_path: Path, path: Path, depth: usize) !?Path {
        if (lib.renames.get(try std.mem.join(lib.a, ".", path))) |new| return new;
        const decl = found.owner.file.tree.fullVarDecl(found.node) orelse return null;
        const init = decl.ast.init_node.unwrap() orelse return null;
        return lib.pathOf(found.owner, owner_path, init, depth);
    }

    /// The path an alias's initializer names, from inside `owner`.
    fn pathOf(lib: *Library, owner: Target, owner_path: Path, node: Ast.Node.Index, depth: usize) !?Path {
        if (depth > max_depth) return error.AliasCycle;
        const tree = &owner.file.tree;
        switch (tree.nodeTag(node)) {
            .identifier => {
                const token = tree.nodeMainToken(node);
                const name = tree.tokenSlice(token);
                const found: Member = if (member(owner, name)) |decl|
                    .{ .owner = owner, .node = decl }
                else
                    try lib.lexical(owner.file, token, name) orelse return null;
                // A public declaration is named by its path; a private one,
                // such as `const mem = std.mem;`, by what it aliases.
                const base: ?Path = if (found.owner.same(owner)) owner_path else if (found.owner.node == .root) owner.file.reached else null;
                if (isPublic(tree, found.node)) return try append(lib.a, base orelse return null, name);
                const decl = tree.fullVarDecl(found.node) orelse return null;
                return lib.pathOf(found.owner, base orelse return null, decl.ast.init_node.unwrap() orelse return null, depth + 1);
            },
            .field_access => {
                const lhs, const field = tree.nodeData(node).node_and_token;
                const base = try lib.pathOf(owner, owner_path, lhs, depth + 1) orelse return null;
                return try append(lib.a, base, tree.tokenSlice(field));
            },
            .builtin_call_two, .builtin_call_two_comma => {
                return if (importsStd(tree, node)) &.{"std"} else null;
            },
            else => return null,
        }
    }

    /// The namespace or declaration a member stands for.
    pub fn targetOf(lib: *Library, found: Member, depth: usize) anyerror!?Target {
        const tree = &found.owner.file.tree;
        const declaration: Target = .{ .file = found.owner.file, .node = found.node, .kind = .declaration };
        const decl = tree.fullVarDecl(found.node) orelse return declaration;
        const init = decl.ast.init_node.unwrap() orelse return declaration;
        return try lib.evaluate(found.owner.file, init, depth) orelse declaration;
    }

    fn evaluate(lib: *Library, file: *File, node: Ast.Node.Index, depth: usize) anyerror!?Target {
        if (depth > max_depth) return error.AliasCycle;
        const tree = &file.tree;
        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buffer, node) != null) return .{ .file = file, .node = node, .kind = .container };
        switch (tree.nodeTag(node)) {
            .identifier => {
                const token = tree.nodeMainToken(node);
                const found = try lib.lexical(file, token, tree.tokenSlice(token)) orelse return null;
                return lib.targetOf(found, depth + 1);
            },
            .field_access => {
                const lhs, const field = tree.nodeData(node).node_and_token;
                const owner = try lib.evaluate(file, lhs, depth + 1) orelse return null;
                const decl = member(owner, tree.tokenSlice(field)) orelse return null;
                return lib.targetOf(.{ .owner = owner, .node = decl }, depth + 1);
            },
            .builtin_call_two, .builtin_call_two_comma => {
                if (importsStd(tree, node)) return try lib.root();
                const path = try lib.importPath(file, node) orelse return null;
                const imported = try lib.load(path) orelse return null;
                return .{ .file = imported, .node = .root, .kind = .container };
            },
            else => return null,
        }
    }

    /// The file an `@import("x.zig")` in `file` names, relative to `std`.
    fn importPath(lib: *Library, file: *File, node: Ast.Node.Index) !?[]const u8 {
        const tree = &file.tree;
        if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) return null;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = tree.builtinCallParams(&buffer, node) orelse return null;
        if (args.len != 1 or tree.nodeTag(args[0]) != .string_literal) return null;
        const literal = tree.tokenSlice(tree.nodeMainToken(args[0]));
        const name = literal[1 .. literal.len - 1];
        if (!std.mem.endsWith(u8, name, ".zig")) return null;
        var parts: std.ArrayList([]const u8) = .empty;
        var base = std.mem.splitScalar(u8, file.path, '/');
        while (base.next()) |part| try parts.append(lib.a, part);
        _ = parts.pop();
        var steps = std.mem.splitScalar(u8, name, '/');
        while (steps.next()) |step| {
            if (std.mem.eql(u8, step, "..")) {
                if (parts.pop() == null) return null;
            } else if (!std.mem.eql(u8, step, ".")) try parts.append(lib.a, step);
        }
        const joined = try std.mem.join(lib.a, "/", parts.items);
        return joined;
    }

    /// The declaration `name` refers to at `token`: the innermost enclosing
    /// namespace that declares it.
    fn lexical(lib: *Library, file: *File, token: Ast.TokenIndex, name: []const u8) !?Member {
        const tree = &file.tree;
        if (file.scopes == null) {
            var scopes: std.ArrayList(Ast.Node.Index) = .empty;
            var buffer: [2]Ast.Node.Index = undefined;
            for (0..tree.nodes.len) |i| {
                const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
                if (node != .root and tree.fullContainerDecl(&buffer, node) != null) try scopes.append(lib.a, node);
            }
            // By span, so the innermost enclosing namespace matches first.
            std.mem.sort(Ast.Node.Index, scopes.items, tree, struct {
                fn less(t: *const Ast, x: Ast.Node.Index, y: Ast.Node.Index) bool {
                    return t.lastToken(x) - t.firstToken(x) < t.lastToken(y) - t.firstToken(y);
                }
            }.less);
            file.scopes = scopes.items;
        }
        for (file.scopes.?) |scope| {
            if (token < tree.firstToken(scope) or token > tree.lastToken(scope)) continue;
            const owner: Target = .{ .file = file, .node = scope, .kind = .container };
            if (member(owner, name)) |node| return .{ .owner = owner, .node = node };
        }
        const owner: Target = .{ .file = file, .node = .root, .kind = .container };
        return if (member(owner, name)) |node| .{ .owner = owner, .node = node } else null;
    }

    /// The parameters of a function declaration, without their names.
    pub fn params(lib: *Library, found: Member) !?[]const Param {
        const tree = &found.owner.file.tree;
        if (tree.nodeTag(found.node) != .fn_decl) return null;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, found.node).?;
        var out: std.ArrayList(Param) = .empty;
        var it = proto.iterate(tree);
        while (it.next()) |param| {
            const is_comptime = if (param.comptime_noalias) |t| tree.tokenTag(t) == .keyword_comptime else false;
            const text = if (param.type_expr) |t| tree.getNodeSource(t) else "anytype";
            try out.append(lib.a, .{ .comptime_param = is_comptime, .type = text });
        }
        return out.items;
    }

    /// A function declaration's return type, as written.
    pub fn returnType(found: Member) ?[]const u8 {
        const tree = &found.owner.file.tree;
        if (tree.nodeTag(found.node) != .fn_decl) return null;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, found.node).?;
        return tree.getNodeSource(proto.ast.return_type.unwrap() orelse return null);
    }
};

/// The declaration named `name` directly inside a namespace.
pub fn member(owner: Target, name: []const u8) ?Ast.Node.Index {
    if (owner.kind != .container) return null;
    const tree = &owner.file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const members = if (owner.node == .root) tree.rootDecls() else (tree.fullContainerDecl(&buffer, owner.node) orelse return null).ast.members;
    for (members) |decl| {
        if (declarationName(tree, decl)) |declared| if (std.mem.eql(u8, declared, name)) return decl;
    }
    return null;
}

pub fn declarationName(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    if (tree.fullVarDecl(node)) |decl| return tree.tokenSlice(decl.ast.mut_token + 1);
    if (tree.nodeTag(node) != .fn_decl) return null;
    var buffer: [1]Ast.Node.Index = undefined;
    const name = tree.fullFnProto(&buffer, node).?.name_token orelse return null;
    return tree.tokenSlice(name);
}

fn isPublic(tree: *const Ast, node: Ast.Node.Index) bool {
    return tree.tokenTag(tree.firstToken(node)) == .keyword_pub;
}

/// `@import("std")`.
pub fn importsStd(tree: *const Ast, node: Ast.Node.Index) bool {
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) return false;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = tree.builtinCallParams(&buffer, node) orelse return false;
    return args.len == 1 and tree.nodeTag(args[0]) == .string_literal and
        std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(args[0])), "\"std\"");
}

/// A declaration's doc comment, when the comment marks it: a line that
/// starts with the word "Deprecated", alone or followed by punctuation or a
/// space, or with "This function is deprecated". ziglint reads it the same way.
pub fn deprecation(a: Allocator, found: Member) ?[]const u8 {
    const tree = &found.owner.file.tree;
    var first = tree.firstToken(found.node);
    while (first > 0 and tree.tokenTag(first - 1) == .doc_comment) first -= 1;
    var lines: std.ArrayList(u8) = .empty;
    var token = first;
    var deprecated = false;
    while (tree.tokenTag(token) == .doc_comment) : (token += 1) {
        const line = std.mem.trim(u8, tree.tokenSlice(token)[3..], " \t\r");
        if (deprecates(line)) deprecated = true;
        if (lines.items.len > 0) lines.append(a, ' ') catch return null;
        lines.appendSlice(a, line) catch return null;
    }
    return if (deprecated) lines.items else null;
}

fn deprecates(line: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(line, "this function is deprecated")) return true;
    if (!std.ascii.startsWithIgnoreCase(line, "deprecated")) return false;
    if (line.len == "deprecated".len) return true;
    return std.mem.findScalar(u8, ":;,. ", line["deprecated".len]) != null;
}

pub fn split(a: Allocator, dotted: []const u8) !Path {
    var out: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, dotted, '.');
    while (parts.next()) |part| try out.append(a, part);
    return out.items;
}

fn append(a: Allocator, path: Path, name: []const u8) !Path {
    const out = try a.alloc([]const u8, path.len + 1);
    @memcpy(out[0..path.len], path);
    out[path.len] = name;
    return out;
}

test "deprecation reads std's doc comments as ziglint does" {
    try std.testing.expect(deprecates("Deprecated in favor of `find`."));
    try std.testing.expect(deprecates("Deprecated; use `SafeAllocator`."));
    try std.testing.expect(deprecates("Deprecated"));
    try std.testing.expect(deprecates("This function is deprecated; use @memmove instead."));
    try std.testing.expect(!deprecates("Default initialization is deprecated; use .empty instead."));
    try std.testing.expect(!deprecates("Deprecatedness is a word."));
}
