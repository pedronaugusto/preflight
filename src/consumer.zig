//! A project that depends on the package as a fetch gives it (only what its manifest's
//! `.paths` lists), built with fetching off and only the packages the package itself needs:
//! the build a consumer gets.
//! The build runs this file as a program to write the project.
const std = @import("std");
const aegis = @import("aegis");
const configure = @import("configure.zig");
const plain = @import("plain.zig");
const nested = @import("nested.zig");
const zon_text = @import("zon.zig");
const OwnedDir = @import("owned.zig").OwnedDir;

pub const Options = struct {
    /// The dependency name a consumer gives the package, as in its build.zig.zon.
    package: []const u8,
    /// The consumer's program, importing what a user imports.
    program: std.Build.LazyPath,
    /// Modules the program imports. Empty means the package name alone. A configuration
    /// whose options leave one out names its own.
    modules: []const []const u8 = &.{},
    /// Packages the consumer's build may read: the package's own dependencies. Each
    /// brings the packages it depends on in turn, as a fetch would.
    packages: []const *std.Build.Dependency = &.{},
    /// Options the consumer gives the package, as `b.dependency(name, .{ ... })` does: `.http = false`
    /// proves a build without a feature the package makes optional. The base of every configuration.
    options: []const Option = &.{},
    /// Retired: the package's configurations are `configurations` in `ci/workflow.json`, the one
    /// list the consumer check and the ci tier's compile of the package's `check` both read.
    /// Set, the build fails saying so.
    configurations: ?[]const Configuration = null,
};

/// Retired with `Options.configurations`: the entries of `ci/workflow.json`'s `configurations`.
pub const Configuration = struct {
    options: []const Option = &.{},
    modules: ?[]const []const u8 = null,
};

/// One configuration the package promises, as `ci/workflow.json` declares it: a name, the
/// options a build of the package is given (each replacing the base's of its name), and the
/// modules a consumer's program imports in it, where its options leave one out of the package
/// (relic's `relic_lfs` without `lfs`); null takes `Options.modules`. The ci tier compiles the
/// package's `check` in each, and the consumer check builds a consumer in each.
///
///     "configurations": [
///       {"name": "default", "options": {"http": true, "lfs": true}},
///       {"name": "neither", "options": {"http": false, "lfs": false}, "modules": ["relic"]}
///     ]
pub const Declared = struct { name: []const u8, options: []const Option, modules: ?[]const []const u8 = null };

/// The configurations `ci/workflow.json` declares for `package`, each checked against what the
/// build declares: an option it does not declare, a value of another type than its option's (or
/// no tag of its enum), or a module the package does not export fails, naming the entry, so a
/// mistake there never quietly builds the default. None declared is the one default build.
pub fn declared(b: *std.Build, package: *std.Build) union(enum) { ok: []const Declared, problem: []const u8 } {
    const text = configure.read(package, "ci/workflow.json", 16 * 1024 * 1024) orelse return .{ .ok = &.{.{ .name = "default", .options = &.{} }} };
    const config = std.json.parseFromSliceLeaky(std.json.Value, b.allocator, text, .{}) catch return .{ .problem = "ci/workflow.json: not JSON" };
    const list = (if (config == .object) config.object.get("configurations") else null) orelse return .{ .ok = &.{.{ .name = "default", .options = &.{} }} };
    if (list != .array or list.array.items.len == 0) return .{ .problem = "ci/workflow.json: configurations is a list of configurations, each {\"name\", \"options\", \"modules\"}" };
    var out: std.ArrayList(Declared) = .empty;
    for (list.array.items, 0..) |entry, index| {
        const name = if (entry == .object) entry.object.get("name") else null;
        if (name == null or name.? != .string or name.?.string.len == 0) return .{ .problem = b.fmt("ci/workflow.json: configuration {d} has no name", .{index + 1}) };
        const at = name.?.string;
        for (at) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return .{ .problem = b.fmt("ci/workflow.json: configuration {f}: a name is letters, digits, - and _, as a job and a directory take it", .{std.json.fmt(name.?, .{})}) };
        var options: std.ArrayList(Option) = .empty;
        if (entry.object.get("options")) |given| {
            if (given != .object) return .{ .problem = b.fmt("ci/workflow.json: configuration {s}: options is an object of the package's options and their values", .{at}) };
            for (given.object.keys(), given.object.values()) |option, value| {
                const found = package.available_options_map.get(option) orelse b.available_options_map.get(option) orelse
                    return .{ .problem = b.fmt("ci/workflow.json: configuration {s}: the package declares no option {s}", .{ at, option }) };
                const typed: ?Option = switch (found.type_id) {
                    .bool => if (value == .bool) .{ .name = option, .value = .{ .flag = value.bool } } else null,
                    .int => if (value == .integer) .{ .name = option, .value = .{ .number = value.integer } } else null,
                    .string => if (value == .string) .{ .name = option, .value = .{ .text = value.string } } else null,
                    .@"enum" => if (value == .string and tagged(found.enum_options, value.string)) .{ .name = option, .value = .{ .text = value.string } } else null,
                    else => null,
                };
                options.append(b.allocator, typed orelse return .{ .problem = b.fmt("ci/workflow.json: configuration {s}: option {s} is a {t} of the package's, which this value is not", .{ at, option, found.type_id }) }) catch @panic("OOM");
            }
        }
        var modules: ?[]const []const u8 = null;
        if (entry.object.get("modules")) |given| {
            if (given != .array) return .{ .problem = b.fmt("ci/workflow.json: configuration {s}: modules is a list of the package's modules", .{at}) };
            var names: std.ArrayList([]const u8) = .empty;
            for (given.array.items) |module| {
                if (module != .string or !package.modules.contains(module.string)) return .{ .problem = b.fmt("ci/workflow.json: configuration {s}: the package exports no module {f}", .{ at, std.json.fmt(module, .{}) }) };
                names.append(b.allocator, module.string) catch @panic("OOM");
            }
            modules = names.items;
        }
        for (entry.object.keys()) |key| {
            for ([_][]const u8{ "name", "options", "modules" }) |known| {
                if (std.mem.eql(u8, key, known)) break;
            } else return .{ .problem = b.fmt("ci/workflow.json: configuration {s}: no field {s}; a configuration has a name, options and modules", .{ at, key }) };
        }
        out.append(b.allocator, .{ .name = at, .options = options.items, .modules = modules }) catch @panic("OOM");
    }
    return .{ .ok = out.items };
}

fn tagged(tags: ?[]const []const u8, value: []const u8) bool {
    for (tags orelse return false) |tag| if (std.mem.eql(u8, tag, value)) return true;
    return false;
}

/// One option of the dependency.
pub const Option = struct {
    name: []const u8,
    value: union(enum) { flag: bool, number: i64, text: []const u8 },
};

/// What the generated build script depends on and imports.
const Shape = struct {
    package: []const u8,
    modules: []const []const u8,
    options: []const Option = &.{},
};

/// Adds `check-consumer` to `b`, over `package` (as `addCi` takes them). The project
/// is generated under the cache, so the package keeps no consumer files of its own.
pub fn add(b: *std.Build, package: *std.Build, options: Options) void {
    if (b.pkg_hash.len != 0) return;
    const pkg = (b.dependencyLazy("preflight", .{}) catch return).builder;
    const consumer = b.addExecutable(.{ .name = "preflight-consumer", .root_module = b.createModule(.{
        .root_source_file = pkg.path("src/consumer.zig"),
        .target = b.graph.host,
        .optimize = .debug,
        .imports = &.{.{ .name = "aegis", .module = pkg.dependency("aegis", .{ .target = b.graph.host, .optimize = .debug }).module("aegis") }},
    }) });
    const packages = b.addWriteFiles();
    _ = packages.add("README", "No packages.\n");
    var closure: std.array_hash_map.String(void) = .empty;
    for (options.packages) |dependency| gather(b, &closure, dependency.builder.pkg_hash);
    // Without bay the package's own build holds preflight, so a consumer fetches preflight and
    // what it depends on.
    if (package == b) gather(b, &closure, pkg.pkg_hash);
    for (closure.keys()) |hash| {
        if (!byHash(hash)) continue;
        const entry = std.Build.package_map.get(hash) orelse unreachable; // gather puts only hashes it found
        _ = packages.addCopyDirectory(.{ .cwd_relative = entry.build_root }, hash, .{});
    }
    const names = if (options.modules.len > 0) options.modules else &.{options.package};
    const step = configure.claim(b, "check-consumer", b.fmt("Build a project that depends on {s}, with only the packages it needs", .{options.package}));
    if (options.configurations != null) {
        step.dependOn(&b.addFail("addConsumerCheck .configurations: the package's configurations are `configurations` in ci/workflow.json, the one list the consumer check and the ci tier's compile of `check` read: {\"name\": \"no-http\", \"options\": {\"http\": false}, \"modules\": [...]}").step);
        return;
    }
    const configurations = switch (declared(b, package)) {
        .ok => |list| list,
        .problem => |problem| {
            // The package's own `check` in that configuration is the ci tier's: it fails too.
            const fail = b.addFail(problem);
            step.dependOn(&fail.step);
            if (b.top_level_steps.get("check")) |check| check.step.dependOn(&fail.step);
            return;
        },
    };
    const single = configurations.len == 1 and configurations[0].options.len == 0;
    for (configurations) |configuration| {
        const merged = combined(b.allocator, options.options, configuration.options);
        const build = b.addRunArtifact(consumer);
        build.setName(b.fmt("check-consumer {s}", .{configuration.name}));
        build.addArg(b.graph.zig_exe);
        const project = if (single) "preflight-consumer" else b.fmt("preflight-consumer/{s}", .{configuration.name});
        build.addDirectoryArg2(b.graph.path(.local_cache, project), .{});
        build.addDirectoryArg2(packages.getDirectory(), .{});
        build.addDirectoryArg2(package.path("."), .{});
        build.addFileArg(options.program);
        build.addArg(options.package);
        build.addDirectoryArg2(b.graph.path(.global_cache, "."), .{});
        for (merged) |option| build.addArg(switch (option.value) {
            .flag => |flag| b.fmt("-D{s}=bool:{}", .{ option.name, flag }),
            .number => |number| b.fmt("-D{s}=i64:{d}", .{ option.name, number }),
            .text => |text| b.fmt("-D{s}=str:{s}", .{ option.name, text }),
        });
        build.addArgs(configuration.modules orelse names);
        build.has_side_effects = true;
        step.dependOn(&build.step);
    }
    // The program checked against the package's own modules too, which also tells lint what
    // each name it imports is: the configured graph is all lint reads, and the consumer's
    // project is written only when the check runs. A module some configuration leaves out may
    // be one this build's options leave out too.
    const program = b.createModule(.{ .root_source_file = options.program, .target = b.graph.host, .optimize = .debug });
    for (names) |name| {
        if (package.modules.get(name)) |module| {
            program.addImport(name, module);
        } else if (!optional(configurations, name)) @panic(b.fmt("addConsumerCheck: the package has no module {s}", .{name}));
    }
    step.dependOn(&b.addObject(.{ .name = "consumer-program", .root_module = program }).step);
}

/// Whether some configuration's modules leave `name` out.
fn optional(configurations: []const Declared, name: []const u8) bool {
    for (configurations) |configuration| {
        const modules = configuration.modules orelse continue;
        for (modules) |module| {
            if (std.mem.eql(u8, module, name)) break;
        } else return true;
    }
    return false;
}

/// `base` with `variation` on top: a variation's option replaces the base's of the same name.
fn combined(a: std.mem.Allocator, base: []const Option, variation: []const Option) []const Option {
    var out: std.ArrayList(Option) = .empty;
    for (base) |option| {
        const replaced = for (variation) |v| {
            if (std.mem.eql(u8, v.name, option.name)) break true;
        } else false;
        if (!replaced) out.append(a, option) catch @panic("OOM");
    }
    out.appendSlice(a, variation) catch @panic("OOM");
    return out.items;
}

/// Puts `hash` and every package it depends on, transitively, into `closure`: with
/// fetching off, a consumer's build needs each of them on disk, but for one reached by path,
/// which it reads where it is. A lazy package the build never fetched is left out; nothing
/// in this configuration asked for it.
fn gather(b: *std.Build, closure: *std.array_hash_map.String(void), hash: []const u8) void {
    const entry = std.Build.package_map.get(hash) orelse return;
    if (!entry.available) return;
    const found = closure.getOrPut(b.graph.arena, hash) catch @panic("OOM");
    if (found.found_existing) return;
    for (entry.deps) |dependency| gather(b, closure, dependency[1]);
}

/// Whether Zig fetched the package `key` names by hash, which a consumer's build looks up among
/// its packages: `name-version-digest`, the digest 44 characters. A package reached by path is
/// keyed by the path, or by its digest when the path is long, and read where it is.
fn byHash(key: []const u8) bool {
    if (key.len < 44 or std.mem.findAny(u8, key, "/\\") != null) return false;
    return std.mem.countScalar(u8, key[0 .. key.len - 44], '-') >= 2;
}

/// Checks the graph plain `zig build` fetches for the package, then writes the
/// project and builds it: `<zig> <project> <packages> <package root> <program>
/// <package> <global cache> <module>...`.
/// The build has a Zig cache of its own: a consumer has none of the
/// package's cached packages, and Zig 0.17's `--system` asserts on a lazy
/// package it finds only in the global cache.
pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 9) return error.MissingConsumerArguments;
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.createDirPathOpen(io, args[2], .{});
    defer dir.close(io);
    try dir.createDirPath(io, "src");
    const directory = try cwd.realPathFileAlloc(io, args[2], a);
    const root = try cwd.realPathFileAlloc(io, args[4], a);
    const in_place = try std.Io.Dir.path.relativeAlloc(a, directory, null, directory, root);
    std.mem.replaceScalar(u8, in_place, '\\', '/');
    const text = try aegis.own.readFile(io, cwd, args[5], a, .fromRaw(16 * 1024 * 1024));
    var modules: std.ArrayList([]const u8) = .empty;
    var dependency_options: std.ArrayList(Option) = .empty;
    for (args[8..]) |arg| {
        if (std.mem.startsWith(u8, arg, "-D")) try dependency_options.append(a, try parseOption(arg[2..])) else try modules.append(a, arg);
    }
    const shape: Shape = .{ .package = args[6], .modules = modules.items, .options = dependency_options.items };
    // A consumer that builds without bay takes every pin as written: two packages that pin
    // a third at two revisions link both, which bay's one selection hides.
    var global: OwnedDir = .init(try cwd.openDir(io, args[7], .{}));
    defer global.deinit(io);
    const package_manifest = try aegis.own.readFile(io, cwd, try std.Io.Dir.path.join(a, &.{ root, "build.zig.zon" }), a, .fromRaw(1024 * 1024));
    const found = try plain.conflicts(a, io, package_manifest, shape.package, .{ .global = global.borrow().*, .zig = args[1] });
    if (found.len != 0) {
        var buffer: [1024]u8 = undefined;
        var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
        try plain.describe(&stderr.interface, found);
        try stderr.interface.flush();
        std.process.exit(1);
    }
    try dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = text });
    const relative = if (try fetched(a, io, root, dir, directory, package_manifest)) fetched_name else in_place;
    try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = try manifest(a, shape.package, relative) });
    try dir.writeFile(io, .{ .sub_path = "build.zig", .data = try script(a, shape) });
    var env = try init.environ_map.clone(a);
    try env.put("ZIG_GLOBAL_CACHE_DIR", try std.Io.Dir.path.join(a, &.{ directory, ".zig-global-cache" }));
    const packages = try cwd.realPathFileAlloc(io, args[3], a);
    var child = try std.process.spawn(io, .{ .argv = &.{ args[1], "build", "--system", packages }, .cwd = .{ .path = directory }, .environ_map = &env });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) {
        // Which configuration failed: its options, as the dependency took them.
        var buffer: [1024]u8 = undefined;
        var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
        try stderr.interface.print("check-consumer: {s} failed to build with", .{shape.package});
        if (shape.options.len == 0) try stderr.interface.writeAll(" no options");
        for (shape.options) |option| switch (option.value) {
            .flag => |flag| try stderr.interface.print(" .{s} = {}", .{ option.name, flag }),
            .number => |number| try stderr.interface.print(" .{s} = {d}", .{ option.name, number }),
            .text => |value| try stderr.interface.print(" .{s} = \"{s}\"", .{ option.name, value }),
        };
        try stderr.interface.writeAll("\n");
        try stderr.interface.flush();
        std.process.exit(1);
    }
}

/// Where the project keeps the package as a fetch gives it.
const fetched_name = "package";

/// The package as a consumer's fetch gives it, written to `fetched_name` under the project
/// (`project`, at `directory`): only what `manifest`'s `.paths` lists of `root`, so a file the
/// build reads and the manifest leaves out fails here as it fails for a consumer. The path
/// dependencies of the manifest are written relative to where it now is. False, and nothing
/// written, where `.paths` ships the whole directory (`""`) or the manifest does not parse,
/// which Zig then reports reading the package where it is.
fn fetched(a: std.mem.Allocator, io: std.Io, root: []const u8, project: std.Io.Dir, directory: []const u8, manifest_text: []const u8) !bool {
    const listed = (try shippedPaths(a, manifest_text)) orelse return false;
    for (listed) |path| if (path.len == 0) return false;
    try project.deleteTree(io, fetched_name);
    var to = try project.createDirPathOpen(io, fetched_name, .{});
    defer to.close(io);
    var from = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer from.close(io);
    for (listed) |path| {
        if (std.mem.eql(u8, path, "build.zig.zon")) continue;
        // A path the manifest names and the package lacks is the paths check's to report.
        nested.copy(io, a, from, to, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |other| return other,
        };
    }
    const placed = try std.Io.Dir.path.join(a, &.{ directory, fetched_name });
    try to.writeFile(io, .{ .sub_path = "build.zig.zon", .data = try nested.relocate(a, manifest_text, root, placed) });
    return true;
}

/// The manifest's `.paths`, or null where it does not parse or names none.
fn shippedPaths(a: std.mem.Allocator, manifest_text: []const u8) !?[]const []const u8 {
    const source = (try zon_text.source(a, manifest_text)) orelse return null;
    var diagnostics: std.zon.parse.Diagnostics = .{ .errors = &.{} };
    const parsed = std.zon.parse.fromSlice(struct { paths: []const []const u8 }, .{ .gpa = a, .arena = a, .source = source, .diagnostics = &diagnostics, .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return null,
    };
    return parsed.paths;
}

/// `name=bool:false`, `name=i64:3` or `name=str:text`.
fn parseOption(text: []const u8) !Option {
    const equals = std.mem.findScalar(u8, text, '=') orelse return error.InvalidDependencyOption;
    const name = text[0..equals];
    const kind, const value = std.mem.cutScalar(u8, text[equals + 1 ..], ':') orelse return error.InvalidDependencyOption;
    if (name.len == 0) return error.InvalidDependencyOption;
    if (std.mem.eql(u8, kind, "bool")) return .{ .name = name, .value = .{ .flag = std.mem.eql(u8, value, "true") } };
    if (std.mem.eql(u8, kind, "i64")) return .{ .name = name, .value = .{ .number = try std.fmt.parseInt(i64, value, 10) } };
    if (std.mem.eql(u8, kind, "str")) return .{ .name = name, .value = .{ .text = value } };
    return error.InvalidDependencyOption;
}

fn manifest(a: std.mem.Allocator, package: []const u8, path: []const u8) ![]const u8 {
    return a.print(
        \\.{{
        \\    .name = .consumer,
        \\    .version = "0.0.0",
        \\    .fingerprint = 0x705b37272f017aed,
        \\    .minimum_zig_version = "0.17.0",
        \\    .dependencies = .{{ .{f} = .{{ .path = "{f}" }} }},
        \\    .paths = .{{""}},
        \\}}
        \\
    , .{ std.zig.fmtId(package), std.zig.fmtString(path) });
}

fn script(a: std.mem.Allocator, shape: Shape) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll(
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
    );
    try w.print("    const package = b.dependency(\"{f}\", .{{ .target = target, .optimize = optimize", .{std.zig.fmtString(shape.package)});
    for (shape.options) |option| switch (option.value) {
        .flag => |flag| try w.print(", .{f} = {}", .{ std.zig.fmtIdPU(option.name), flag }),
        .number => |number| try w.print(", .{f} = {d}", .{ std.zig.fmtIdPU(option.name), number }),
        .text => |text| try w.print(", .{f} = \"{f}\"", .{ std.zig.fmtIdPU(option.name), std.zig.fmtString(text) }),
    };
    try w.writeAll(" });\n");
    try w.writeAll("    const exe = b.addExecutable(.{ .name = \"consumer\", ");
    try w.writeAll(".root_module = b.createModule(.{\n        .root_source_file = b.path(\"src/main.zig\"),\n        .target = target,\n        .optimize = optimize,\n        .imports = &.{\n");
    for (shape.modules) |module| try w.print("            .{{ .name = \"{f}\", .module = package.module(\"{f}\") }},\n", .{ std.zig.fmtString(module), std.zig.fmtString(module) });
    try w.writeAll("        },\n    }) });\n    b.installArtifact(exe);\n}\n");
    return out.written();
}

test "the generated consumer imports each named module from the package" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try script(a, .{ .package = "conduit", .modules = &.{ "conduit", "conduit.tty" } });
    try std.testing.expect(std.mem.find(u8, text, "b.dependency(\"conduit\"") != null);
    try std.testing.expect(std.mem.find(u8, text, ".{ .name = \"conduit.tty\", .module = package.module(\"conduit.tty\") }") != null);
    const single = try script(a, .{ .package = "strand", .modules = &.{"strand"} });
    try std.testing.expect(std.mem.find(u8, single, ".{ .name = \"strand\", .module = package.module(\"strand\") }") != null);
    const optioned = try script(a, .{ .package = "relic", .modules = &.{"relic"}, .options = &.{ .{ .name = "http", .value = .{ .flag = false } }, .{ .name = "level", .value = .{ .number = 2 } }, .{ .name = "mode", .value = .{ .text = "lazy" } } } });
    try std.testing.expect(std.mem.find(u8, optioned, "b.dependency(\"relic\", .{ .target = target, .optimize = optimize, .http = false, .level = 2, .mode = \"lazy\" })") != null);
    const parsed = try parseOption("http=bool:false");
    try std.testing.expectEqualStrings("http", parsed.name);
    try std.testing.expect(!parsed.value.flag);
    try std.testing.expectError(error.InvalidDependencyOption, parseOption("http"));
    try std.testing.expectError(error.InvalidDependencyOption, parseOption("http=float:1"));
    const zon = try manifest(a, "strand", "../..");
    try std.testing.expect(std.mem.find(u8, zon, ".dependencies = .{ .strand = .{ .path = \"../..\" } }") != null);
}

test "the consumer's package is what .paths lists: a file the manifest leaves out is not there, a path dependency still resolves" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pkg/src");
    try tmp.dir.createDirPath(io, "pkg/ci");
    try tmp.dir.createDirPath(io, "project");
    const text = ".{ .name = .p, .dependencies = .{ .near = .{ .path = \"../near\" } }, .paths = .{ \"build.zig\", \"build.zig.zon\", \"src\", \"ci/lists.zig\", \"README.md\" } }";
    for ([_][]const u8{ "pkg/build.zig", "pkg/src/root.zig", "pkg/ci/lists.zig", "pkg/ci/other.zig" }) |path| try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, "pkg", a);
    const directory = try tmp.dir.realPathFileAlloc(io, "project", a);
    var project = try tmp.dir.openDir(io, "project", .{});
    defer project.close(io);
    try std.testing.expect(try fetched(a, io, root, project, directory, text));
    for ([_][]const u8{ "package/build.zig", "package/src/root.zig", "package/ci/lists.zig" }) |path| _ = try project.statFile(io, path, .{});
    try std.testing.expectError(error.FileNotFound, project.statFile(io, "package/ci/other.zig", .{}));
    const written = try aegis.own.readFile(io, project, "package/build.zig.zon", a, .fromRaw(4096));
    try std.testing.expect(std.mem.find(u8, written, ".path = \"../../near\"") != null);
    // The whole directory shipped, or a manifest that does not parse: read where it is.
    try std.testing.expect(!try fetched(a, io, root, project, directory, ".{ .paths = .{\"\"} }"));
    try std.testing.expect(!try fetched(a, io, root, project, directory, ".{ .paths = "));
}

test "a configuration is the base with its variation on top" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_]Option{ .{ .name = "http", .value = .{ .flag = true } }, .{ .name = "level", .value = .{ .number = 2 } } };
    const none = combined(a, &base, &.{});
    try std.testing.expectEqual(@as(usize, 2), none.len);
    const varied = combined(a, &base, &.{ .{ .name = "http", .value = .{ .flag = false } }, .{ .name = "lfs", .value = .{ .flag = false } } });
    try std.testing.expectEqual(@as(usize, 3), varied.len);
    try std.testing.expectEqualStrings("level", varied[0].name);
    try std.testing.expectEqualStrings("http", varied[1].name);
    try std.testing.expect(!varied[1].value.flag);
    try std.testing.expectEqualStrings("lfs", varied[2].name);
}

test "a module is optional where a configuration leaves it out" {
    const both: Declared = .{ .name = "both", .options = &.{} };
    const without: Declared = .{ .name = "no-lfs", .options = &.{.{ .name = "lfs", .value = .{ .flag = false } }}, .modules = &.{"relic"} };
    try std.testing.expect(!optional(&.{both}, "relic_lfs"));
    try std.testing.expect(optional(&.{ both, without }, "relic_lfs"));
    try std.testing.expect(!optional(&.{ both, without }, "relic"));
}

test "a package fetched by hash is copied for the consumer, one reached by path is not" {
    try std.testing.expect(byHash("aegis-0.1.17-rsxouvGhCAD_-g4V2I9sq2lY_uNA5M3zBHIw7uX4WfWt"));
    try std.testing.expect(byHash("N-V-__8AAK2jSwMxK2QTcDLqXDrakaAa7TS3ShXkjIic0xBt"));
    try std.testing.expect(!byHash("../../preflight"));
    try std.testing.expect(!byHash("/p/aegis-0.1.17-rsxouvGhCAD_-g4V2I9sq2lY_uNA5M3zBHIw7uX4WfWt/sub"));
    try std.testing.expect(!byHash("0f3a8c21d4e5b6a79f0e1d2c3b4a59687f6e5d4c3b2a19087f6e5d4c3b2a1908"));
}
