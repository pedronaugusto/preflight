//! The files glint reads, and how each import in them resolves: the
//! selection the repository names, and the import of every file taken from
//! the build's own configuration, so that a name means what the compiler
//! will take it to mean.
const std = @import("std");
const aegis = @import("aegis");
const builtin = @import("builtin");
const glint = @import("glint");
const configure = @import("../../configure.zig");
const src = @import("../source.zig");
const policy_module = @import("policy.zig");
const manifest = @import("../manifest.zig");
const Policy = policy_module.Policy;

/// Files and bytes one project holds: glint's own bounds.
const max_files: usize = 4096;
const max_bytes: usize = 128 * 1024 * 1024;
const max_file: usize = 16 * 1024 * 1024;

pub const Error = std.mem.Allocator.Error || std.Io.Dir.ReadFileAllocError || glint.Project.InitError || error{ProjectBudgetExceeded};

/// What the build says about imports: the configured modules and where Zig's
/// standard library is.
pub const Build = struct {
    modules: []const src.BuildModule = &.{},
    /// Zig's `lib/std`; without it `std` stays unresolved.
    std_dir: ?[]const u8 = null,
    /// The root of each module the package exports (each `b.addModule`'s): glint reads the
    /// public surface as what these reach through `pub` declarations.
    exported: []const []const u8 = &.{},
};

pub const Selected = struct { path: []const u8, kind: Policy.Kind };

pub const Assembly = struct {
    project: glint.Project,
    /// The files to check, in file-identity order (0, 1, 2 ...).
    selected: []const Selected,

    pub fn deinit(self: *Assembly) void {
        self.project.deinit();
    }
};

/// The Zig files to check: every one the package ships (`build.zig.zon`'s `.paths`), those
/// in the directories a repository keeps code in beside them, and `build.zig`, with
/// `glint_paths` adding to them, never narrowing them. A named path that is not there is
/// an error; a shipped or default one that is not is not part of this repository.
pub fn select(c: *src.Context, policy: Policy) !?[]const []const u8 {
    var found: std.array_hash_map.String(void) = .empty;
    const before = c.errors;
    for (policy.shipped) |path| _ = try take(c, path, .ships, &found);
    for (src.code_directories) |path| _ = try take(c, path, .kept, &found);
    _ = try take(c, "build.zig", .ships, &found);
    for (policy.paths orelse &.{}) |path| switch (try take(c, path, .kept, &found)) {
        .taken => {},
        .absent => c.fail("glint: glint_paths: {s}: not found", .{path}),
        .other => c.fail("glint: glint_paths: {s}: not a Zig file or a directory", .{path}),
    };
    if (c.errors != before) return null;
    if (found.count() == 0) {
        c.fail("glint: no Zig file is selected: the package ships none, and `glint_paths` names none", .{});
        return null;
    }
    const paths = found.keys();
    std.mem.sort([]const u8, paths, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    return paths;
}

/// Whether a path is what the package ships, or code the repository keeps beside it.
const Scope = enum { ships, kept };

/// Adds the Zig files at `path`: the file, or those under the directory. What ships is
/// taken whole, since every file of it reaches the package's users, a nested
/// `build.zig.zon` among them; beside it, a nested package is left to its own build.
fn take(c: *src.Context, path: []const u8, scope: Scope, found: *std.array_hash_map.String(void)) !enum { taken, absent, other } {
    const clean = try normalize(c.a, path);
    const stat = c.directory().statFile(c.io, clean, .{}) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => return err,
    };
    if (stat.kind == .directory) {
        if (scope == .ships or !try nested(c, clean)) try collect(c, clean, scope, found);
    } else if (std.mem.endsWith(u8, clean, ".zig")) {
        try found.put(c.a, clean, {});
    } else return .other;
    return .taken;
}

fn collect(c: *src.Context, root: []const u8, scope: Scope, found: *std.array_hash_map.String(void)) !void {
    var dir = try c.directory().openDir(c.io, root, .{ .iterate = true });
    defer dir.close(c.io);
    var walker = try dir.walkSelectively(c.a);
    defer walker.deinit();
    while (try walker.next(c.io)) |entry| {
        if (entry.kind == .directory) {
            if (!configure.generated(entry.basename) and (scope == .ships or !try nested(c, try std.Io.Dir.path.join(c.a, &.{ root, entry.path })))) try walker.enter(c.io, entry);
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        try found.put(c.a, try normalize(c.a, try std.Io.Dir.path.join(c.a, &.{ root, entry.path })), {});
    }
}

/// Whether `directory` is a build of its own: one with its own `build.zig.zon`, or its own
/// `build.zig`, the build root `zig build` runs there, whose manifest `addNestedBuild` writes
/// under the cache from the package's. Its files only that build compiles, with the modules it
/// binds; its imports would not resolve in this build's lint, so it is left to that build.
fn nested(c: *src.Context, directory: []const u8) !bool {
    for ([_][]const u8{ "build.zig.zon", "build.zig" }) |name| {
        if (try c.exists(try std.Io.Dir.path.join(c.a, &.{ directory, name }))) return true;
    }
    return false;
}

/// A path in one lexical form: `/` separators, no `.` or `..` components
/// where they can be removed.
pub fn normalize(a: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]const u8 {
    const resolved = try std.Io.Dir.path.resolveAlloc(a, &.{path});
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, resolved, '\\', '/');
    return resolved;
}

/// Whether an import names a file by its path from the importing one, as Zig reads it: a Zig
/// file, or a ZON one (`@import("build.zig.zon")`), never a module.
fn relativeFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".zon");
}

fn join(a: std.mem.Allocator, directory: []const u8, name: []const u8) std.mem.Allocator.Error![]const u8 {
    return normalize(a, try std.Io.Dir.path.join(a, &.{ directory, name }));
}

/// The configured build's modules as an import in one of its files reads them: which modules
/// compile each file their roots reach through relative imports, and what a name imported in
/// a file binds to there. glint's assembly reads the package's files through it, and the public
/// surface (`surface.zig`) follows a facade into the package's own modules through it: one
/// reading of the build's bindings for both.
pub const ModuleMap = struct {
    build: Build,
    /// The configured modules whose sources reach a file through relative imports, by path.
    modules_of: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,

    /// What the modules of one compilation that compile a file bind a name to: nothing, or each
    /// root file (one, or several where those modules bind it apart). A module whose root the
    /// configuration holds no bytes of (translate-c's output, a Run step's output file) is
    /// `externalPath`'s: bodiless, read by glint as an external module.
    pub const Bound = union(enum) { unbound, unknown, paths: []const []const u8 };
    pub const In = enum { program, build };

    /// The map of `build` over the files `files` holds: `files.read(path)` gives a file's text by
    /// its path or null where there is none, and `files.importsOf(path, text)` the names it imports.
    pub fn init(a: std.mem.Allocator, build: Build, files: anytype) !ModuleMap {
        var map: ModuleMap = .{ .build = build };
        for (build.modules, 0..) |module, which| {
            const root = module.root orelse continue;
            var pending: std.ArrayList([]const u8) = .empty;
            const start = try normalize(a, root);
            if (try map.mark(a, start, @intCast(which))) try pending.append(a, start);
            while (pending.pop()) |path| {
                const bytes = (try files.read(path)) orelse continue;
                for (try files.importsOf(path, bytes)) |name| {
                    if (!relativeFile(name)) continue;
                    const target = try join(a, std.Io.Dir.path.dirname(path) orelse "", name);
                    if (try map.mark(a, target, @intCast(which))) try pending.append(a, target);
                }
            }
        }
        return map;
    }

    fn mark(map: *ModuleMap, a: std.mem.Allocator, path: []const u8, module: u32) !bool {
        const entry = try map.modules_of.getOrPut(a, path);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        for (entry.value_ptr.items) |earlier| if (earlier == module) return false;
        try entry.value_ptr.append(a, module);
        return true;
    }

    /// Whether a configured module compiles the file at `path`.
    pub fn compiles(map: ModuleMap, path: []const u8) bool {
        return map.modules_of.contains(path);
    }

    /// The configured modules that compile the file at `path`, by index in `build.modules`.
    pub fn modulesOf(map: ModuleMap, path: []const u8) []const u32 {
        return if (map.modules_of.get(path)) |modules| modules.items else &.{};
    }

    /// What the modules of one compilation that compile `from` bind `name` to.
    pub fn bound(map: ModuleMap, a: std.mem.Allocator, from: []const u8, name: []const u8, in: In) !Bound {
        var found: std.ArrayList([]const u8) = .empty;
        for (map.modulesOf(from)) |which| {
            if (map.build.modules[which].script != (in == .build)) continue;
            for (map.build.modules[which].imports) |binding| {
                if (!std.mem.eql(u8, binding.name, name)) continue;
                const path = if (map.build.modules[binding.module].root) |root| try normalize(a, root) else try externalPath(a, binding.name);
                for (found.items) |earlier| {
                    if (std.mem.eql(u8, earlier, path)) break;
                } else try found.append(a, path);
            }
        }
        return if (found.items.len == 0) .unbound else .{ .paths = found.items };
    }
};

/// The name preflight gives a module whose bytes exist only after a build step runs, as glint's
/// command line spells one (`--external NAME`): no file, a bodiless input glint reads as external.
fn externalPath(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return a.print("<external {s}>", .{name});
}

/// What `bytes` imports, each name once, in the order written. Text whose literals do not scan
/// imports nothing here: glint's own parse of it reports the file as unusable.
pub fn importNames(a: std.mem.Allocator, gpa: std.mem.Allocator, bytes: []const u8) ![]const []const u8 {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const facts = glint.token.scan(scratch.allocator(), bytes, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (facts.imports) |import| {
        var seen = false;
        for (out.items) |name| seen = seen or std.mem.eql(u8, name, import.name);
        if (!seen) try out.append(a, try a.dupe(u8, import.name));
    }
    return out.items;
}

const Loader = struct {
    c: *src.Context,
    gpa: std.mem.Allocator,
    build: Build,
    std_file: ?[]const u8,
    /// A file's bytes, once read; null for a file that is not there.
    bytes: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    /// The configured modules, read over the files: empty until `membership`.
    map: ModuleMap = .{ .build = .{} },
    /// What a file imports, by name, scanned once.
    names: std.StringHashMapUnmanaged([]const []const u8) = .empty,
    inputs: std.ArrayList(glint.Project.Input) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,
    /// The identity a directory's own `build.zig.zon` gives; null where it has none.
    manifests: std.StringHashMapUnmanaged(?manifest.Identity) = .empty,
    total: usize = 0,

    fn read(self: *Loader, path: []const u8) !?[]const u8 {
        const entry = try self.bytes.getOrPut(self.c.a, path);
        if (entry.found_existing) return entry.value_ptr.*;
        // A module the build generates whole as it configures: its text, which is on no disk.
        for (self.build.modules) |module| if (module.contents) |contents| if (module.root) |root| {
            if (!std.mem.eql(u8, try normalize(self.c.a, root), path)) continue;
            entry.value_ptr.* = contents;
            return contents;
        };
        entry.value_ptr.* = aegis.own.readFile(self.c.io, self.c.directory(), path, self.c.a, .fromRaw(max_file)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => {
                _ = self.bytes.remove(path);
                return err;
            },
        };
        return entry.value_ptr.*;
    }

    /// What `bytes` imports, each name once. A file whose literals do not scan
    /// has no names: glint's own parse of it reports the file as unusable.
    fn importsOf(self: *Loader, path: []const u8, bytes: []const u8) ![]const []const u8 {
        const entry = try self.names.getOrPut(self.c.a, path);
        if (entry.found_existing) return entry.value_ptr.*;
        entry.value_ptr.* = &.{};
        entry.value_ptr.* = try importNames(self.c.a, self.gpa, bytes);
        return entry.value_ptr.*;
    }

    /// Which configured modules compile each file their roots reach.
    fn membership(self: *Loader) !void {
        self.map = try ModuleMap.init(self.c.a, self.build, self);
    }

    /// Which compilations compile each input, as glint reads its imports in them: the
    /// program's where a module of the program's compiles it, the build runner's where a build
    /// script's does, and every compilation of each file that imports it. A file no module
    /// compiles and nothing compiled imports is the program's.
    fn compilations(self: *Loader, imports: []const glint.Project.Import) !void {
        const program = try self.c.a.alloc(bool, self.inputs.items.len);
        const build = try self.c.a.alloc(bool, self.inputs.items.len);
        for (self.inputs.items, program, build) |input, *in_program, *in_build| {
            in_program.* = false;
            in_build.* = false;
            for (self.map.modulesOf(input.name)) |which| {
                if (self.build.modules[which].script) in_build.* = true else in_program.* = true;
            }
        }
        spread(imports, program, build);
        for (program, build) |*in_program, in_build| in_program.* = in_program.* or !in_build;
        spread(imports, program, build);
        for (self.inputs.items, program, build) |*input, in_program, in_build| {
            input.compilations = if (in_program and in_build) .both else if (in_build) .build else .program;
        }
    }

    /// Each compilation of a file to every file it imports in that compilation, until none
    /// is added.
    fn spread(imports: []const glint.Project.Import, program: []bool, build: []bool) void {
        var growing = true;
        while (growing) {
            growing = false;
            for (imports) |edge| for ([_]glint.Project.Compilations{ .program, .build }) |in| {
                if (edge.compilation) |only| if (only != in) continue;
                const set = if (in == .program) program else build;
                if (set[edge.from] and !set[edge.target]) {
                    set[edge.target] = true;
                    growing = true;
                }
            };
        }
    }

    fn insideStd(self: *Loader, path: []const u8) bool {
        const dir = self.build.std_dir orelse return false;
        return std.mem.startsWith(u8, path, dir) and path.len > dir.len and path[dir.len] == '/';
    }

    /// The package whose tree holds `path`: the identity of the nearest `build.zig.zon` above
    /// it, the checked package's own included. None for std's files, and none where no
    /// directory up to the package's (or, outside it, the filesystem's root) has one.
    fn packageOf(self: *Loader, path: []const u8) !manifest.Identity {
        if (self.insideStd(path)) return .{};
        const outside = std.mem.startsWith(u8, path, "..") or std.Io.Dir.path.isAbsolute(path);
        var dir = std.Io.Dir.path.dirname(path);
        while (dir) |at| : (dir = std.Io.Dir.path.dirname(at)) {
            if (try self.manifestOf(at)) |found| return found;
        }
        if (!outside) if (try self.manifestOf("")) |found| return found;
        return .{};
    }

    fn manifestOf(self: *Loader, dir: []const u8) !?manifest.Identity {
        const entry = try self.manifests.getOrPut(self.c.a, dir);
        if (entry.found_existing) return entry.value_ptr.*;
        const path = try std.Io.Dir.path.join(self.c.a, &.{ dir, "build.zig.zon" });
        entry.value_ptr.* = if (aegis.own.readFile(self.c.io, self.c.directory(), path, self.c.a, .fromRaw(max_file))) |bytes|
            try manifest.identity(self.c.a, bytes)
        else |err| switch (err) {
            error.FileNotFound, error.NotDir => null,
            else => {
                _ = self.manifests.remove(dir);
                return err;
            },
        };
        return entry.value_ptr.*;
    }

    /// Adds a file to the project, once; null when it is not there.
    fn load(self: *Loader, path: []const u8, selected: bool, kind: Policy.Kind) !?u32 {
        if (self.index.get(path)) |known| {
            if (selected) self.inputs.items[known].selected = true;
            return known;
        }
        if (std.mem.startsWith(u8, path, "<external ")) {
            const id: u32 = @intCast(self.inputs.items.len);
            try self.inputs.append(self.c.a, .{ .name = path, .bytes = "", .stem = path["<external ".len .. path.len - 1], .selected = false, .external = true });
            try self.index.put(self.c.a, path, id);
            return id;
        }
        const bytes = (try self.read(path)) orelse return null;
        if (self.inputs.items.len >= max_files or bytes.len > max_bytes - self.total) return error.ProjectBudgetExceeded;
        self.total += bytes.len;
        const id: u32 = @intCast(self.inputs.items.len);
        const base = std.Io.Dir.path.basename(path);
        const package = try self.packageOf(path);
        try self.inputs.append(self.c.a, .{
            .name = path,
            .bytes = bytes,
            .stem = if (std.mem.endsWith(u8, base, ".zig")) base[0 .. base.len - 4] else base,
            // A ZON file a Zig file imports is data, read as ZON.
            .kind = if (std.mem.endsWith(u8, base, ".zon")) .zon else .zig,
            .selected = selected,
            .classification = if (kind == .production) .production else .@"test",
            .package = package.name,
            .fingerprint = package.fingerprint,
        });
        try self.index.put(self.c.a, path, id);
        return id;
    }

    /// Where an import written in `from` leads in each compilation that compiles it: each file
    /// a module that compiles it binds the name to, several a choice glint reads as any.
    const Lead = struct {
        /// Where it leads in every compilation of the file; empty where it leads nowhere.
        every: []const []const u8 = &.{},
        /// Where it leads in the program's and in the build runner's, when they bind it apart.
        program: []const []const u8 = &.{},
        build: []const []const u8 = &.{},
    };

    /// Where an import written in `from` leads, when the build says: `std`, a
    /// module the configuration binds the name to (whatever the name ends
    /// with: gantry's Zig frontend is the module `gantry.zig`), or else a
    /// relative file. The program and the build runner bind names apart: a file both
    /// compile leads to each one's modules, an edge apiece. Two modules of one compilation
    /// that both compile the file and bind the name to different files lead to each there, a
    /// choice; a binding to a module with no root file leads nowhere in that compilation.
    fn lead(self: *Loader, from: []const u8, name: []const u8) !Lead {
        if (std.mem.eql(u8, name, "std")) return .{ .every = if (self.std_file) |file| try self.c.a.dupe([]const u8, &.{file}) else &.{} };
        const program = try self.bound(from, name, .program);
        const build = try self.bound(from, name, .build);
        if (program == .unbound and build == .unbound) {
            if (!relativeFile(name)) return .{};
            const path = try join(self.c.a, std.Io.Dir.path.dirname(from) orelse "", name);
            const outside = std.mem.startsWith(u8, path, "..") or std.Io.Dir.path.isAbsolute(path);
            if (outside and !self.insideStd(path) and !self.map.compiles(path)) return .{};
            return .{ .every = try self.c.a.dupe([]const u8, &.{path}) };
        }
        const in_program: []const []const u8 = if (program == .paths) program.paths else &.{};
        const in_build: []const []const u8 = if (build == .paths) build.paths else &.{};
        // The same modules wherever the name is bound: the edges hold in every compilation.
        if (program != .unknown and build != .unknown) {
            if (in_program.len == 0 or in_build.len == 0 or samePaths(in_program, in_build))
                return .{ .every = if (in_program.len != 0) in_program else in_build };
        }
        return .{ .program = in_program, .build = in_build };
    }

    /// Whether two lists name the same files, in any order.
    fn samePaths(a: []const []const u8, b: []const []const u8) bool {
        if (a.len != b.len) return false;
        for (a) |one| {
            for (b) |other| {
                if (std.mem.eql(u8, one, other)) break;
            } else return false;
        }
        return true;
    }

    /// Whether the build binds no module named `name` in any module that compiles `from`:
    /// a module this build does not have there, as glint is told. A name ending in `.zig` or
    /// `.zon` is a file, as Zig reads it (a build script's `@import("build.zig.zon")`), never a
    /// module; Zig's own names (`std`, `builtin`, `root`) are always there, and a file no
    /// configured module compiles has no bindings to go by.
    fn absent(self: *Loader, from: []const u8, name: []const u8) !bool {
        if (relativeFile(name)) return false;
        for ([_][]const u8{ "std", "builtin", "root" }) |own| if (std.mem.eql(u8, name, own)) return false;
        if (!self.map.compiles(from)) return false;
        return try self.bound(from, name, .program) == .unbound and try self.bound(from, name, .build) == .unbound;
    }

    /// Whether an import names a module: not a file (`.zig`, `.zon`) and not one of Zig's own.
    fn moduleName(name: []const u8) bool {
        if (relativeFile(name)) return false;
        for ([_][]const u8{ "std", "builtin", "root" }) |own| if (std.mem.eql(u8, name, own)) return false;
        return true;
    }

    /// What the modules of one compilation that compile `from` bind `name` to.
    fn bound(self: *Loader, from: []const u8, name: []const u8, in: ModuleMap.In) !ModuleMap.Bound {
        return self.map.bound(self.c.a, from, name, in);
    }
};

/// Reads the selected files, the files they import, and records each import.
/// Null when the selection cannot be read as a project, which is reported.
pub fn assemble(c: *src.Context, gpa: std.mem.Allocator, policy: Policy, paths: []const []const u8, build: Build) !?Assembly {
    var loader: Loader = .{
        .c = c,
        .gpa = gpa,
        .build = build,
        .std_file = if (build.std_dir) |dir| try join(c.a, dir, "std.zig") else null,
    };
    const std_dir = if (build.std_dir) |dir| try normalize(c.a, dir) else null;
    loader.build.std_dir = std_dir;
    var selected: std.ArrayList(Selected) = .empty;
    for (paths) |path| {
        const kind = policy.kind(path);
        _ = (try loader.load(path, true, kind)) orelse {
            c.fail("glint: {s}: not found", .{path});
            return null;
        };
        try selected.append(c.a, .{ .path = path, .kind = kind });
    }
    // Every build script the build compiles is read, unselected, though no selected file
    // imports it: the root bay writes binds the package's `dev(b, tools)` there, a binding a
    // rule judges `dev`'s body at.
    for (loader.build.modules) |module| if (module.script) if (module.root) |root| {
        _ = loader.load(root, false, .production) catch |err| switch (err) {
            error.ProjectBudgetExceeded => return budget(c),
            else => return err,
        };
    };
    try loader.membership();

    var imports: std.ArrayList(glint.Project.Import) = .empty;
    var cursor: usize = 0;
    while (cursor < loader.inputs.items.len) : (cursor += 1) {
        const from = loader.inputs.items[cursor];
        var absent: std.ArrayList([]const u8) = .empty;
        // A selected file no module of the configured build compiles is in none of its
        // compilations: a module name it imports has no binding to read, which preflight names
        // once for the file, and glint reads as a name this build does not bind.
        const uncompiled = from.selected and loader.build.modules.len != 0 and !loader.map.compiles(from.name);
        var unbound: std.ArrayList([]const u8) = .empty;
        for (try loader.importsOf(from.name, from.bytes)) |name| {
            const lead = try loader.lead(from.name, name);
            if (lead.every.len == 0 and lead.program.len == 0 and lead.build.len == 0) {
                if (try loader.absent(from.name, name)) {
                    try absent.append(c.a, name);
                } else if (uncompiled and Loader.moduleName(name)) {
                    try absent.append(c.a, name);
                    try unbound.append(c.a, name);
                }
                continue;
            }
            const leads = [_]struct { []const []const u8, ?glint.Project.Compilations }{
                .{ lead.every, null }, .{ lead.program, .program }, .{ lead.build, .build },
            };
            for (leads) |each| {
                const targets, const compilation = each;
                for (targets) |path| {
                    const found = (loader.load(path, false, .production) catch |err| switch (err) {
                        error.ProjectBudgetExceeded => return budget(c),
                        else => return err,
                    }) orelse continue;
                    try imports.append(c.a, .{ .from = cursor, .spelling = name, .target = found, .compilation = compilation });
                }
            }
        }
        loader.inputs.items[cursor].absent = try absent.toOwnedSlice(c.a);
        if (unbound.items.len != 0) c.fail("glint: {s}: no module of this build compiles it, so `{s}` and every module it imports have no binding to read: build it in the package's own graph (its `check`), or leave it out of what glint reads", .{ from.name, unbound.items[0] });
    }
    try loader.compilations(imports.items);
    // The roots of the modules the package exports: the public surface starts there.
    for (build.exported) |root| {
        const path = try normalize(c.a, root);
        for (loader.inputs.items) |*input| if (std.mem.eql(u8, input.name, path)) {
            input.exported = true;
        };
    }
    const project = glint.Project.init(gpa, loader.inputs.items, imports.items, .{ .io = c.io }) catch |err| switch (err) {
        error.ProjectBudgetExceeded => return budget(c),
        error.Canceled => return error.Canceled,
        else => |other| {
            c.fail("glint: the project could not be built ({t})", .{other});
            return null;
        },
    };
    return .{ .project = project, .selected = selected.items };
}

fn budget(c: *src.Context) ?Assembly {
    c.fail("glint: the files this project reads exceed {d} files or {d} MiB: select fewer in `glint_paths`", .{ max_files, max_bytes >> 20 });
    return null;
}

fn parsed(a: std.mem.Allocator, text: []const u8) !src.Value {
    return (try std.json.parseFromSlice(src.Value, a, text, .{ .allocate = .alloc_always })).value;
}

fn write(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.Io.Dir.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

test "default selection is what the package ships and the directories a repository keeps code in, build outputs and caches left out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "src/a.zig", "src/deep/b.zig", "bench/run.zig", "examples/use.zig", "ci/layers.zig", "conformance/run.zig", "build.zig", "src/note.md", "zig-pkg/dep/x.zig", "src/zig-out/y.zig", ".zig-cache/z.zig", "docs/skip.zig", "bench/zig-pkg/q.zig", "bench/emulator/build.zig", "bench/emulator/build.zig.zon", "bench/emulator/main.zig" }) |path| try write(tmp.dir, path, "pub const x = 1;\n");
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    const config = try parsed(c.a, "{}");
    const policy = (try policy_module.parse(&c, config, test_shipped)).?;
    const paths = (try select(&c, policy)).?;
    try std.testing.expectEqual(@as(usize, 7), paths.len);
    for ([_][]const u8{ "bench/run.zig", "build.zig", "ci/layers.zig", "conformance/run.zig", "examples/use.zig", "src/a.zig", "src/deep/b.zig" }, paths) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "a directory with a build.zig of its own is a nested build, left out, its manifest in the tree or written by addNestedBuild under the cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // morse's and visor's conformance builds: a build.zig and its sources, the manifest written
    // from the package's at configure time, the emulator's modules bound only there.
    for ([_][]const u8{ "src/a.zig", "conformance/build.zig", "conformance/main.zig", "conformance/deep/c.zig", "bench/run.zig" }) |path| try write(tmp.dir, path, "pub const x = 1;\n");
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    for ([_][]const u8{ "{}", "{\"glint_paths\":[\"conformance\"]}" }) |text| {
        const config = try parsed(c.a, text);
        const policy = (try policy_module.parse(&c, config, test_shipped)).?;
        const paths = (try select(&c, policy)).?;
        try std.testing.expectEqual(@as(usize, 2), paths.len);
        for ([_][]const u8{ "bench/run.zig", "src/a.zig" }, paths) |want, got| try std.testing.expectEqualStrings(want, got);
    }
}

test "a nested build kept beside what ships is its own package, left out; one inside what ships is linted with it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "src/a.zig", "conformance/build.zig", "conformance/build.zig.zon", "conformance/main.zig", "bench/run.zig", "bench/emulator/build.zig.zon", "bench/emulator/main.zig", "src/vendor/build.zig.zon", "src/vendor/x.zig" }) |path| try write(tmp.dir, path, "pub const x = 1;\n");
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    const config = try parsed(c.a, "{}");
    const policy = (try policy_module.parse(&c, config, test_shipped)).?;
    const paths = (try select(&c, policy)).?;
    // A nested manifest inside `src` ships with it, so its files reach users (review-1029 M6).
    try std.testing.expectEqual(@as(usize, 3), paths.len);
    for ([_][]const u8{ "bench/run.zig", "src/a.zig", "src/vendor/x.zig" }, paths) |want, got| try std.testing.expectEqualStrings(want, got);
}

const test_shipped: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "README.md" };

test "named paths add to what the package ships, never narrow it, and fail when absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "src/a.zig", "bench/run.zig", "docs/skip.zig", "tools/t.zig", "README.md" }) |path| try write(tmp.dir, path, "pub const x = 1;\n");
    var held: std.Io.Writer.Allocating = .init(arena.allocator());
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir, .held = &held };
    var config = try parsed(c.a, "{\"glint_paths\":[\"./tools/t.zig\"]}");
    var policy = (try policy_module.parse(&c, config, test_shipped)).?;
    const paths = (try select(&c, policy)).?;
    try std.testing.expectEqual(@as(usize, 3), paths.len);
    for ([_][]const u8{ "bench/run.zig", "src/a.zig", "tools/t.zig" }, paths) |want, got| try std.testing.expectEqualStrings(want, got);
    for ([_][]const u8{ "{\"glint_paths\":[\"missing\"]}", "{\"glint_paths\":[\"README.md\"]}" }) |text| {
        c.errors = 0;
        config = try parsed(c.a, text);
        policy = (try policy_module.parse(&c, config, test_shipped)).?;
        try std.testing.expectEqual(@as(?[]const []const u8, null), try select(&c, policy));
        try std.testing.expect(c.errors != 0);
    }
    // A selection that finds nothing is an error, not a pass over nothing.
    var bare = std.testing.tmpDir(.{});
    defer bare.cleanup();
    c.dir = bare.dir;
    c.errors = 0;
    config = try parsed(c.a, "{}");
    try bare.dir.createDirPath(std.testing.io, "src");
    policy = (try policy_module.parse(&c, config, test_shipped)).?;
    try std.testing.expectEqual(@as(?[]const []const u8, null), try select(&c, policy));
    try std.testing.expect(c.errors != 0);
    for ([_][]const u8{ "glint_paths: missing: not found", "glint_paths: README.md: not a Zig file", "no Zig file is selected" }) |said| try std.testing.expect(std.mem.find(u8, held.written(), said) != null);
}

test "an import means what the configured build binds it to, in the module that compiles the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/root.zig", "const lib = @import(\"lib\");\nconst helper = @import(\"helper.zig\");\nconst std = @import(\"std\");\nconst kernels = @import(\"kernels\");\nconst builtin = @import(\"builtin\");\n");
    try write(tmp.dir, "src/helper.zig", "const lib = @import(\"lib\");\nconst other = @import(\"other\");\n");
    try write(tmp.dir, "src/shared.zig", "const lib = @import(\"lib\");\n");
    try write(tmp.dir, "dep/lib.zig", "pub const Thing = struct {};\nconst inner = @import(\"inner.zig\");\n");
    try write(tmp.dir, "dep/inner.zig", "pub const x = 1;\n");
    try write(tmp.dir, "dep/other.zig", "pub const y = 2;\n");
    try write(tmp.dir, "dep/other2.zig", "pub const y = 3;\n");
    try write(tmp.dir, "stdlib/std.zig", "pub const mem = @import(\"mem.zig\");\nconst self = @import(\"std\");\n");
    try write(tmp.dir, "stdlib/mem.zig", "pub fn eql() void {}\n");
    try write(tmp.dir, "build.zig.zon", ".{ .name = .pkg, .version = \"0.1.0\", .fingerprint = 0x1c0ffee, .paths = .{\"src\"} }\n");
    try write(tmp.dir, "dep/build.zig.zon", ".{ .name = .lib, .version = \"0.1.0\", .fingerprint = 0x5e23831cba68ccae, .paths = .{\"\"} }\n");
    const bindings = [_]src.BuildModule.Binding{ .{ .name = "lib", .module = 1 }, .{ .name = "other", .module = 2 } };
    const second = [_]src.BuildModule.Binding{ .{ .name = "other", .module = 3 }, .{ .name = "lib", .module = 1 } };
    const modules = [_]src.BuildModule{
        .{ .root = "src/root.zig", .imports = &bindings },
        .{ .root = "dep/lib.zig", .imports = &.{} },
        .{ .root = "dep/other.zig", .imports = &.{} },
        .{ .root = "dep/other2.zig", .imports = &.{} },
        .{ .root = "src/shared.zig", .imports = &second },
        .{ .root = "src/helper.zig", .imports = &second },
        .{ .root = null, .imports = &.{} },
    };
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    const config = try parsed(c.a, "{\"glint_paths\":[\"src\"],\"test_support\":[]}");
    const policy = (try policy_module.parse(&c, config, test_shipped)).?;
    const paths = (try select(&c, policy)).?;
    var assembly = (try assemble(&c, std.testing.allocator, policy, paths, .{ .modules = &modules, .std_dir = "stdlib" })).?;
    defer assembly.deinit();
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    try std.testing.expectEqual(@as(usize, 3), assembly.selected.len);
    const project = &assembly.project;
    // Each file is the package of the nearest manifest above it, by name and fingerprint: the
    // checked package's, a dependency's in its own tree, and none for std's.
    for (project.sources) |source| {
        const input = source.input;
        const name, const fingerprint: ?u64 = if (std.mem.startsWith(u8, input.name, "src/")) .{ "pkg", 0x1c0ffee } else if (std.mem.startsWith(u8, input.name, "dep/")) .{ "lib", 0x5e23831cba68ccae } else .{ "", null };
        try std.testing.expectEqualStrings(name, input.package);
        try std.testing.expectEqual(fingerprint, input.fingerprint);
    }
    var mapped: usize = 0;
    var other: std.EnumSet(enum { first, second }) = .empty;
    for (project.imports) |import| {
        const from = project.at(import.from).input.name;
        const to = project.at(import.target).input.name;
        mapped += 1;
        if (std.mem.eql(u8, from, "src/root.zig") and std.mem.eql(u8, import.spelling, "lib")) try std.testing.expectEqualStrings("dep/lib.zig", to);
        if (std.mem.eql(u8, from, "src/root.zig") and std.mem.eql(u8, import.spelling, "std")) try std.testing.expectEqualStrings("stdlib/std.zig", to);
        // helper.zig is compiled by two modules that bind `other` to different files: an edge
        // to each, a choice glint reads as either.
        if (std.mem.eql(u8, from, "src/helper.zig") and std.mem.eql(u8, import.spelling, "other")) {
            if (std.mem.eql(u8, to, "dep/other.zig")) other.insert(.first) else if (std.mem.eql(u8, to, "dep/other2.zig")) other.insert(.second) else return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), other.count());
    // lib, helper.zig, std and the files they bring: imports are recorded once per file and name.
    try std.testing.expect(mapped >= 8);
    var names: usize = 0;
    for (project.sources) |source| {
        const input = source.input;
        if (std.mem.eql(u8, input.name, "stdlib/mem.zig") or std.mem.eql(u8, input.name, "dep/inner.zig")) names += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), names);
    // A name no module that compiles the file binds is a module this build does not have;
    // Zig's own names and a name bound two ways are not.
    for (project.sources) |source| {
        const input = source.input;
        if (std.mem.eql(u8, input.name, "src/root.zig")) {
            try std.testing.expectEqual(@as(usize, 1), input.absent.len);
            try std.testing.expectEqualStrings("kernels", input.absent[0]);
        }
        if (std.mem.eql(u8, input.name, "src/helper.zig")) try std.testing.expectEqual(@as(usize, 0), input.absent.len);
    }
}

test "a ZON file a Zig file imports is read with it, as ZON: build.zig's build.zig.zon, a module's data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/root.zig", "const Data = struct { a: u8 };\npub const data: Data = @import(\"data.zon\");\n");
    try write(tmp.dir, "src/data.zon", ".{ .a = 1 }\n");
    try write(tmp.dir, "build.zig", "const manifest = @import(\"build.zig.zon\");\npub fn build(b: *@import(\"std\").Build) void {\n    _ = b;\n    _ = manifest.version;\n}\n");
    try write(tmp.dir, "build.zig.zon", ".{ .name = .pkg, .version = \"0.1.0\", .fingerprint = 0x1c0ffee, .paths = .{\"src\"} }\n");
    const modules = [_]src.BuildModule{.{ .root = "src/root.zig", .imports = &.{} }};
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    const config = try parsed(c.a, "{\"test_support\":[]}");
    const policy = (try policy_module.parse(&c, config, test_shipped)).?;
    const paths = (try select(&c, policy)).?;
    var assembly = (try assemble(&c, std.testing.allocator, policy, paths, .{ .modules = &modules })).?;
    defer assembly.deinit();
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    const project = &assembly.project;
    var found: usize = 0;
    for (project.imports) |import| {
        const from = project.at(import.from).input.name;
        const to = project.at(import.target).input;
        const want = if (std.mem.eql(u8, from, "build.zig")) "build.zig.zon" else if (std.mem.eql(u8, from, "src/root.zig")) "src/data.zon" else continue;
        if (!std.mem.endsWith(u8, import.spelling, ".zon")) continue;
        try std.testing.expectEqualStrings(want, to.name);
        // Data, never selected: no rule reads it but through the value the import gives.
        try std.testing.expect(to.kind == .zon);
        try std.testing.expect(!to.selected);
        found += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), found);
}

test "an options module the build generates whole is read as its module's file, beside the package's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/root.zig", "const release = @import(\"release\");\nconst later = @import(\"later\");\npub const version = release.version;\n");
    const bindings = [_]src.BuildModule.Binding{ .{ .name = "release", .module = 1 }, .{ .name = "later", .module = 2 } };
    const modules = [_]src.BuildModule{
        .{ .root = "src/root.zig", .imports = &bindings },
        .{ .root = ".preflight-generated/0/options.zig", .imports = &.{}, .contents = "pub const version: []const u8 = \"1.0.0\";\n" },
        // Written only as the build runs (an option naming a path): no text to read.
        .{ .root = null, .imports = &.{} },
    };
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    const config = try parsed(c.a, "{\"glint_paths\":[\"src\"],\"test_support\":[]}");
    const policy = (try policy_module.parse(&c, config, test_shipped)).?;
    const paths = (try select(&c, policy)).?;
    var assembly = (try assemble(&c, std.testing.allocator, policy, paths, .{ .modules = &modules })).?;
    defer assembly.deinit();
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    const project = &assembly.project;
    var release = false;
    var later = false;
    for (project.imports) |import| {
        // Bytes the build writes only as it runs: an external module, bodiless and never linted.
        if (std.mem.eql(u8, import.spelling, "later")) {
            later = true;
            const input = project.at(import.target).input;
            try std.testing.expectEqualStrings("<external later>", input.name);
            try std.testing.expect(input.external and !input.selected and input.bytes.len == 0);
            continue;
        }
        if (!std.mem.eql(u8, import.spelling, "release")) continue;
        release = true;
        const input = project.at(import.target).input;
        try std.testing.expectEqualStrings(".preflight-generated/0/options.zig", input.name);
        try std.testing.expectEqualStrings("pub const version: []const u8 = \"1.0.0\";\n", input.bytes);
        try std.testing.expect(!input.selected);
    }
    try std.testing.expect(release);
    try std.testing.expect(later);
}

test "a build script reads a dependency's script by the dependency's name, and its manifest as a file, never a module it lacks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/root.zig", "pub const x = @import(\"shared.zig\").x;\n");
    try write(tmp.dir, "src/shared.zig", "pub const x = 1;\n");
    try write(tmp.dir, "build.zig", "const tools = @import(\"tools\");\nconst manifest = @import(\"build.zig.zon\");\nconst gone = @import(\"gone\");\nconst shared = @import(\"src/shared.zig\");\n");
    try write(tmp.dir, "build.zig.zon", ".{ .name = .pkg, .version = \"0.1.0\", .fingerprint = 0x1c0ffee, .paths = .{\"src\"} }\n");
    try write(tmp.dir, "zig-pkg/tools/build.zig", "pub fn addCi() void {}\n");
    const bindings = [_]src.BuildModule.Binding{.{ .name = "tools", .module = 1 }};
    const modules = [_]src.BuildModule{
        .{ .root = "build.zig", .imports = &bindings, .script = true },
        .{ .root = "zig-pkg/tools/build.zig", .imports = &.{}, .script = true },
        .{ .root = "src/root.zig", .imports = &.{} },
    };
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    const config = try parsed(c.a, "{\"glint_paths\":[\"src\"],\"test_support\":[]}");
    const policy = (try policy_module.parse(&c, config, test_shipped)).?;
    const paths = (try select(&c, policy)).?;
    var assembly = (try assemble(&c, std.testing.allocator, policy, paths, .{ .modules = &modules })).?;
    defer assembly.deinit();
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    const project = &assembly.project;
    var tools = false;
    for (project.imports) |import| {
        if (!std.mem.eql(u8, project.at(import.from).input.name, "build.zig") or !std.mem.eql(u8, import.spelling, "tools")) continue;
        tools = true;
        try std.testing.expectEqualStrings("zig-pkg/tools/build.zig", project.at(import.target).input.name);
    }
    try std.testing.expect(tools);
    for (project.sources) |source| if (std.mem.eql(u8, source.input.name, "build.zig")) {
        try std.testing.expectEqual(@as(usize, 1), source.input.absent.len);
        try std.testing.expectEqualStrings("gone", source.input.absent[0]);
    };
    // The scripts are the build runner's alone, the program's root its own, and a file both
    // import both compilations'.
    const compiled = [_]struct { []const u8, glint.Project.Compilations }{
        .{ "build.zig", .build },
        .{ "zig-pkg/tools/build.zig", .build },
        .{ "src/root.zig", .program },
        .{ "src/shared.zig", .both },
    };
    for (compiled) |expected| {
        const source = for (project.sources) |source| {
            if (std.mem.eql(u8, source.input.name, expected[0])) break source;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqual(expected[1], source.input.compilations);
    }
}

test "a build script no selected file imports is read, unselected: bay's root, which binds the package's dev by the package's name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/root.zig", "pub const x = 1;\n");
    try write(tmp.dir, "build.zig", "pub fn dev(b: anytype, tools: type) void {\n    _ = b;\n    _ = tools;\n}\n");
    try write(tmp.dir, "build.zig.zon", ".{ .name = .pkg, .version = \"0.1.0\", .fingerprint = 0x1c0ffee, .paths = .{\"src\"} }\n");
    try write(tmp.dir, ".zig-cache/bay/build.zig", "const package = @import(\"pkg\");\npub fn build(b: anytype) void {\n    package.dev(b, @This());\n}\n");
    const bindings = [_]src.BuildModule.Binding{.{ .name = "pkg", .module = 1 }};
    const modules = [_]src.BuildModule{
        .{ .root = ".zig-cache/bay/build.zig", .imports = &bindings, .script = true },
        .{ .root = "build.zig", .imports = &.{}, .script = true },
        .{ .root = "src/root.zig", .imports = &.{} },
    };
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    const config = try parsed(c.a, "{\"glint_paths\":[\"src\"],\"test_support\":[]}");
    const policy = (try policy_module.parse(&c, config, test_shipped)).?;
    const paths = (try select(&c, policy)).?;
    var assembly = (try assemble(&c, std.testing.allocator, policy, paths, .{ .modules = &modules })).?;
    defer assembly.deinit();
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    const project = &assembly.project;
    var root = false;
    for (project.sources) |source| if (std.mem.eql(u8, source.input.name, ".zig-cache/bay/build.zig")) {
        root = true;
        try std.testing.expect(!source.input.selected);
        try std.testing.expectEqual(glint.Project.Compilations.build, source.input.compilations);
    };
    try std.testing.expect(root);
    var binds = false;
    for (project.imports) |import| {
        if (!std.mem.eql(u8, project.at(import.from).input.name, ".zig-cache/bay/build.zig") or !std.mem.eql(u8, import.spelling, "pkg")) continue;
        binds = true;
        try std.testing.expectEqualStrings("build.zig", project.at(import.target).input.name);
    }
    try std.testing.expect(binds);
}

test "a file both compilations compile reads a name each binds apart as an edge apiece, and one compilation's two bindings as a choice of both" {
    // `src/shared.zig` is the program's (src/root.zig imports it) and the build runner's
    // (build.zig imports it). `lib` is the library's module in the program and the library's
    // build script in the build runner. In the twin a second module of the program compiles the
    // file and binds `lib` elsewhere: the program has an edge to each, a choice glint reads as
    // either, and the build runner's stays one.
    for ([_]bool{ false, true }) |split| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try write(tmp.dir, "src/root.zig", "pub const x = @import(\"shared.zig\").x;\n");
        try write(tmp.dir, "src/other.zig", "pub const x = @import(\"shared.zig\").x;\n");
        try write(tmp.dir, "src/shared.zig", "const lib = @import(\"lib\");\npub const x = 1;\n");
        try write(tmp.dir, "build.zig", "const shared = @import(\"src/shared.zig\");\n");
        try write(tmp.dir, "zig-pkg/lib/build.zig", "pub fn addCi() void {}\n");
        try write(tmp.dir, "zig-pkg/lib/src/lib.zig", "pub fn run() void {}\n");
        try write(tmp.dir, "zig-pkg/fork/lib.zig", "pub fn run() void {}\n");
        const to_script = [_]src.BuildModule.Binding{.{ .name = "lib", .module = 1 }};
        const to_library = [_]src.BuildModule.Binding{.{ .name = "lib", .module = 3 }};
        const to_fork = [_]src.BuildModule.Binding{.{ .name = "lib", .module = 5 }};
        const modules = [_]src.BuildModule{
            .{ .root = "build.zig", .imports = &to_script, .script = true },
            .{ .root = "zig-pkg/lib/build.zig", .imports = &.{}, .script = true },
            .{ .root = "src/root.zig", .imports = &to_library },
            .{ .root = "zig-pkg/lib/src/lib.zig", .imports = &.{} },
            .{ .root = if (split) "src/other.zig" else null, .imports = &to_fork },
            .{ .root = "zig-pkg/fork/lib.zig", .imports = &.{} },
        };
        var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
        const config = try parsed(c.a, "{\"glint_paths\":[\"src\"],\"test_support\":[]}");
        const policy = (try policy_module.parse(&c, config, test_shipped)).?;
        const paths = (try select(&c, policy)).?;
        var assembly = (try assemble(&c, std.testing.allocator, policy, paths, .{ .modules = &modules })).?;
        defer assembly.deinit();
        try std.testing.expectEqual(@as(usize, 0), c.errors);
        const project = &assembly.project;
        var program: std.EnumSet(enum { library, fork }) = .empty;
        var build: ?[]const u8 = null;
        for (project.imports) |import| {
            if (!std.mem.eql(u8, project.at(import.from).input.name, "src/shared.zig")) continue;
            const target = project.at(import.target).input.name;
            switch (import.in) {
                .program => if (std.mem.eql(u8, target, "zig-pkg/lib/src/lib.zig")) program.insert(.library) else if (std.mem.eql(u8, target, "zig-pkg/fork/lib.zig")) program.insert(.fork) else return error.TestUnexpectedResult,
                .build => build = target,
                .both => return error.TestUnexpectedResult,
            }
        }
        try std.testing.expectEqualStrings("zig-pkg/lib/build.zig", build.?);
        try std.testing.expect(program.contains(.library));
        try std.testing.expectEqual(split, program.contains(.fork));
        for (project.sources) |source| {
            if (std.mem.eql(u8, source.input.name, "src/shared.zig")) try std.testing.expectEqual(.both, source.input.compilations);
            if (std.mem.eql(u8, source.input.name, "zig-pkg/lib/build.zig")) try std.testing.expectEqual(.build, source.input.compilations);
            if (std.mem.eql(u8, source.input.name, "zig-pkg/lib/src/lib.zig")) try std.testing.expectEqual(.program, source.input.compilations);
        }
    }
}
