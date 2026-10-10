//! The files glint reads, and how each import in them resolves: the
//! selection the repository names, and the import of every file taken from
//! the build's own configuration, so that a name means what the compiler
//! will take it to mean.
const std = @import("std");
const builtin = @import("builtin");
const glint = @import("glint");
const configure = @import("../../configure.zig");
const src = @import("../source.zig");
const policy_module = @import("policy.zig");
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

/// The Zig files to check: `glint_paths`, or `sources` and the directories a
/// repository keeps code in beside them. An explicit path that is not there is
/// an error; a default one that is not is not part of this repository.
pub fn select(c: *src.Context, policy: Policy, config: src.Value) !?[]const []const u8 {
    var found: std.array_hash_map.String(void) = .empty;
    const before = c.errors;
    if (policy.paths) |explicit| {
        for (explicit) |path| {
            const clean = try normalize(c.a, path);
            const stat = c.directory().statFile(c.io, clean, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    c.fail("glint: glint_paths: {s}: not found", .{path});
                    continue;
                },
                else => return err,
            };
            if (stat.kind == .directory) {
                try collect(c, clean, &found);
            } else if (std.mem.endsWith(u8, clean, ".zig")) {
                try found.put(c.a, clean, {});
            } else c.fail("glint: glint_paths: {s}: not a Zig file or a directory", .{path});
        }
    } else {
        for (try src.roots(c.a, config)) |root| try collect(c, root, &found);
        for ([_][]const u8{ "examples", "ci", "conformance", "bench" }) |root| if (c.exists(root)) try collect(c, root, &found);
        if (c.exists("build.zig")) try found.put(c.a, "build.zig", {});
    }
    if (c.errors != before) return null;
    if (found.count() == 0) {
        c.fail("glint: no Zig file is selected: name them in `glint_paths`", .{});
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

fn collect(c: *src.Context, root: []const u8, found: *std.array_hash_map.String(void)) !void {
    var dir = try c.directory().openDir(c.io, root, .{ .iterate = true });
    defer dir.close(c.io);
    var walker = try dir.walkSelectively(c.a);
    defer walker.deinit();
    while (try walker.next(c.io)) |entry| {
        if (entry.kind == .directory) {
            if (!configure.generated(entry.basename)) try walker.enter(c.io, entry);
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        try found.put(c.a, try normalize(c.a, try std.Io.Dir.path.join(c.a, &.{ root, entry.path })), {});
    }
}

/// A path in one lexical form: `/` separators, no `.` or `..` components
/// where they can be removed.
pub fn normalize(a: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]const u8 {
    const resolved = try std.Io.Dir.path.resolveAlloc(a, &.{path});
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, resolved, '\\', '/');
    return resolved;
}

fn join(a: std.mem.Allocator, directory: []const u8, name: []const u8) std.mem.Allocator.Error![]const u8 {
    return normalize(a, try std.Io.Dir.path.join(a, &.{ directory, name }));
}

const Source = struct { bytes: []const u8 };

const Loader = struct {
    c: *src.Context,
    gpa: std.mem.Allocator,
    build: Build,
    std_file: ?[]const u8,
    /// A file's bytes, once read; null for a file that is not there.
    bytes: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    /// The configured modules whose sources reach a file through relative imports.
    modules_of: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    /// What a file imports, by name, scanned once.
    names: std.StringHashMapUnmanaged([]const []const u8) = .empty,
    inputs: std.ArrayList(glint.Project.Input) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,
    total: usize = 0,

    fn read(self: *Loader, path: []const u8) !?[]const u8 {
        const entry = try self.bytes.getOrPut(self.c.a, path);
        if (entry.found_existing) return entry.value_ptr.*;
        entry.value_ptr.* = self.c.directory().readFileAlloc(self.c.io, path, self.c.a, .limited(max_file)) catch |err| switch (err) {
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
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const facts = glint.token.scan(scratch.allocator(), bytes, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return entry.value_ptr.*,
        };
        var out: std.ArrayList([]const u8) = .empty;
        for (facts.imports) |import| {
            var seen = false;
            for (out.items) |name| seen = seen or std.mem.eql(u8, name, import.name);
            if (!seen) try out.append(self.c.a, try self.c.a.dupe(u8, import.name));
        }
        entry.value_ptr.* = out.items;
        return out.items;
    }

    /// Which configured modules compile each file their roots reach.
    fn membership(self: *Loader) !void {
        for (self.build.modules, 0..) |module, which| {
            const root = module.root orelse continue;
            var pending: std.ArrayList([]const u8) = .empty;
            const start = try normalize(self.c.a, root);
            if (try self.mark(start, @intCast(which))) try pending.append(self.c.a, start);
            while (pending.pop()) |path| {
                const bytes = (try self.read(path)) orelse continue;
                for (try self.importsOf(path, bytes)) |name| {
                    if (!std.mem.endsWith(u8, name, ".zig")) continue;
                    const target = try join(self.c.a, std.Io.Dir.path.dirname(path) orelse "", name);
                    if (try self.mark(target, @intCast(which))) try pending.append(self.c.a, target);
                }
            }
        }
    }

    fn mark(self: *Loader, path: []const u8, module: u32) !bool {
        const entry = try self.modules_of.getOrPut(self.c.a, path);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        for (entry.value_ptr.items) |earlier| if (earlier == module) return false;
        try entry.value_ptr.append(self.c.a, module);
        return true;
    }

    fn insideStd(self: *Loader, path: []const u8) bool {
        const dir = self.build.std_dir orelse return false;
        return std.mem.startsWith(u8, path, dir) and path.len > dir.len and path[dir.len] == '/';
    }

    /// Adds a file to the project, once; null when it is not there.
    fn load(self: *Loader, path: []const u8, selected: bool, kind: Policy.Kind) !?u32 {
        if (self.index.get(path)) |known| {
            if (selected) self.inputs.items[known].selected = true;
            return known;
        }
        const bytes = (try self.read(path)) orelse return null;
        if (self.inputs.items.len >= max_files or bytes.len > max_bytes - self.total) return error.ProjectBudgetExceeded;
        self.total += bytes.len;
        const id: u32 = @intCast(self.inputs.items.len);
        const base = std.Io.Dir.path.basename(path);
        try self.inputs.append(self.c.a, .{
            .name = path,
            .bytes = bytes,
            .stem = if (std.mem.endsWith(u8, base, ".zig")) base[0 .. base.len - 4] else base,
            .selected = selected,
            .classification = if (kind == .production) .production else .@"test",
        });
        try self.index.put(self.c.a, path, id);
        return id;
    }

    /// Where an import written in `from` leads, when the build says: `std`, a
    /// module the configuration binds the name to (whatever the name ends
    /// with: gantry's Zig frontend is the module `gantry.zig`), or else a
    /// relative file. A name two modules that both compile the file bind
    /// differently leads nowhere.
    fn lead(self: *Loader, from: []const u8, name: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, name, "std")) return self.std_file;
        switch (try self.bound(from, name)) {
            .path => |path| return path,
            .ambiguous => return null,
            .unbound => {},
        }
        if (!std.mem.endsWith(u8, name, ".zig")) return null;
        const path = try join(self.c.a, std.Io.Dir.path.dirname(from) orelse "", name);
        const outside = std.mem.startsWith(u8, path, "..") or std.Io.Dir.path.isAbsolute(path);
        if (outside and !self.insideStd(path) and !self.modules_of.contains(path)) return null;
        return path;
    }

    const Bound = union(enum) { unbound, ambiguous, path: []const u8 };

    fn bound(self: *Loader, from: []const u8, name: []const u8) !Bound {
        const modules = self.modules_of.get(from) orelse return .unbound;
        var found: ?[]const u8 = null;
        for (modules.items) |which| {
            for (self.build.modules[which].imports) |binding| {
                if (!std.mem.eql(u8, binding.name, name)) continue;
                const root = self.build.modules[binding.module].root orelse return .ambiguous;
                const path = try normalize(self.c.a, root);
                if (found) |earlier| {
                    if (!std.mem.eql(u8, earlier, path)) return .ambiguous;
                } else found = path;
            }
        }
        return if (found) |path| .{ .path = path } else .unbound;
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
    try loader.membership();

    var imports: std.ArrayList(glint.Project.Import) = .empty;
    var cursor: usize = 0;
    while (cursor < loader.inputs.items.len) : (cursor += 1) {
        const from = loader.inputs.items[cursor];
        for (try loader.importsOf(from.name, from.bytes)) |name| {
            const path = (try loader.lead(from.name, name)) orelse continue;
            const found = (loader.load(path, false, .production) catch |err| switch (err) {
                error.ProjectBudgetExceeded => return budget(c),
                else => return err,
            }) orelse continue;
            try imports.append(c.a, .{ .from = .fromRaw(@intCast(cursor)), .spelling = name, .target = .fromRaw(found) });
        }
    }
    const project = glint.Project.init(gpa, loader.inputs.items, imports.items, .{}) catch |err| switch (err) {
        error.ProjectBudgetExceeded => return budget(c),
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

test "default selection is the sources and the directories a repository keeps code in, build outputs and caches left out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "src/a.zig", "src/deep/b.zig", "bench/run.zig", "examples/use.zig", "ci/layers.zig", "conformance/build.zig", "build.zig", "src/note.md", "zig-pkg/dep/x.zig", "src/zig-out/y.zig", ".zig-cache/z.zig", "docs/skip.zig", "bench/zig-pkg/q.zig" }) |path| try write(tmp.dir, path, "pub const x = 1;\n");
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    const config = try parsed(c.a, "{}");
    const policy = (try policy_module.parse(&c, config)).?;
    const paths = (try select(&c, policy, config)).?;
    try std.testing.expectEqual(@as(usize, 7), paths.len);
    for ([_][]const u8{ "bench/run.zig", "build.zig", "ci/layers.zig", "conformance/build.zig", "examples/use.zig", "src/a.zig", "src/deep/b.zig" }, paths) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "named paths replace the default, accept files and directories and fail when absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "src/a.zig", "bench/run.zig", "docs/skip.zig", "tools/t.zig", "README.md" }) |path| try write(tmp.dir, path, "pub const x = 1;\n");
    var c: src.Context = .{ .a = arena.allocator(), .io = std.testing.io, .dir = tmp.dir };
    var config = try parsed(c.a, "{\"glint_paths\":[\"bench\",\"./tools/t.zig\"]}");
    var policy = (try policy_module.parse(&c, config)).?;
    const paths = (try select(&c, policy, config)).?;
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("bench/run.zig", paths[0]);
    try std.testing.expectEqualStrings("tools/t.zig", paths[1]);
    for ([_][]const u8{ "{\"glint_paths\":[\"missing\"]}", "{\"glint_paths\":[\"README.md\"]}" }) |text| {
        c.errors = 0;
        config = try parsed(c.a, text);
        policy = (try policy_module.parse(&c, config)).?;
        try std.testing.expectEqual(@as(?[]const []const u8, null), try select(&c, policy, config));
        try std.testing.expect(c.errors != 0);
    }
    // A selection that finds nothing is an error, not a pass over nothing.
    var bare = std.testing.tmpDir(.{});
    defer bare.cleanup();
    c.dir = bare.dir;
    c.errors = 0;
    config = try parsed(c.a, "{\"sources\":[\"empty\"]}");
    try bare.dir.createDirPath(std.testing.io, "empty");
    policy = (try policy_module.parse(&c, config)).?;
    try std.testing.expectEqual(@as(?[]const []const u8, null), try select(&c, policy, config));
    try std.testing.expect(c.errors != 0);
}

test "an import means what the configured build binds it to, in the module that compiles the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try write(tmp.dir, "src/root.zig", "const lib = @import(\"lib\");\nconst helper = @import(\"helper.zig\");\nconst std = @import(\"std\");\n");
    try write(tmp.dir, "src/helper.zig", "const lib = @import(\"lib\");\nconst other = @import(\"other\");\n");
    try write(tmp.dir, "src/shared.zig", "const lib = @import(\"lib\");\n");
    try write(tmp.dir, "dep/lib.zig", "pub const Thing = struct {};\nconst inner = @import(\"inner.zig\");\n");
    try write(tmp.dir, "dep/inner.zig", "pub const x = 1;\n");
    try write(tmp.dir, "dep/other.zig", "pub const y = 2;\n");
    try write(tmp.dir, "dep/other2.zig", "pub const y = 3;\n");
    try write(tmp.dir, "stdlib/std.zig", "pub const mem = @import(\"mem.zig\");\nconst self = @import(\"std\");\n");
    try write(tmp.dir, "stdlib/mem.zig", "pub fn eql() void {}\n");
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
    const policy = (try policy_module.parse(&c, config)).?;
    const paths = (try select(&c, policy, config)).?;
    var assembly = (try assemble(&c, std.testing.allocator, policy, paths, .{ .modules = &modules, .std_dir = "stdlib" })).?;
    defer assembly.deinit();
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    try std.testing.expectEqual(@as(usize, 3), assembly.selected.len);
    const project = &assembly.project;
    var mapped: usize = 0;
    var other_mapped = false;
    for (project.imports) |import| {
        const from = project.inputs[import.from.raw()].name;
        const to = project.inputs[import.target.raw()].name;
        mapped += 1;
        if (std.mem.eql(u8, from, "src/root.zig") and std.mem.eql(u8, import.spelling, "lib")) try std.testing.expectEqualStrings("dep/lib.zig", to);
        if (std.mem.eql(u8, from, "src/root.zig") and std.mem.eql(u8, import.spelling, "std")) try std.testing.expectEqualStrings("stdlib/std.zig", to);
        // helper.zig is compiled by two modules that bind `other` to different files.
        if (std.mem.eql(u8, from, "src/helper.zig") and std.mem.eql(u8, import.spelling, "other")) other_mapped = true;
    }
    try std.testing.expect(!other_mapped);
    // lib, helper.zig, std and the files they bring: imports are recorded once per file and name.
    try std.testing.expect(mapped >= 8);
    var names: usize = 0;
    for (project.inputs) |input| {
        if (std.mem.eql(u8, input.name, "stdlib/mem.zig") or std.mem.eql(u8, input.name, "dep/inner.zig")) names += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), names);
}
