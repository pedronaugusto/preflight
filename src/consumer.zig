//! A project that depends on the package by path, built with fetching off and
//! only the packages the package itself needs: the build a consumer gets.
//! The build runs this file as a program to write the project.
const std = @import("std");
const aegis = @import("aegis");
const configure = @import("configure.zig");
const plain = @import("plain.zig");

pub const Options = struct {
    /// The dependency name a consumer gives the package, as in its build.zig.zon.
    package: []const u8,
    /// The consumer's program, importing what a user imports.
    program: std.Build.LazyPath,
    /// Modules the program imports. Empty means the package name alone.
    modules: []const []const u8 = &.{},
    /// Packages the consumer's build may read: the package's own dependencies. Each
    /// brings the packages it depends on in turn, as a fetch would.
    packages: []const *std.Build.Dependency = &.{},
    /// Options the consumer gives the package, as `b.dependency(name, .{ ... })` does: `.http = false`
    /// proves a build without a feature the package makes optional.
    options: []const Option = &.{},
};

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
    const build = b.addRunArtifact(consumer);
    build.addArg(b.graph.zig_exe);
    build.addDirectoryArg2(b.graph.path(.local_cache, "preflight-consumer"), .{});
    build.addDirectoryArg2(packages.getDirectory(), .{});
    build.addDirectoryArg2(package.path("."), .{});
    build.addFileArg(options.program);
    build.addArg(options.package);
    build.addDirectoryArg2(b.graph.path(.global_cache, "."), .{});
    for (options.options) |option| build.addArg(switch (option.value) {
        .flag => |flag| b.fmt("-D{s}=bool:{}", .{ option.name, flag }),
        .number => |number| b.fmt("-D{s}=i64:{d}", .{ option.name, number }),
        .text => |text| b.fmt("-D{s}=str:{s}", .{ option.name, text }),
    });
    const names = if (options.modules.len > 0) options.modules else &.{options.package};
    build.addArgs(names);
    build.has_side_effects = true;
    const step = configure.claim(b, "check-consumer", b.fmt("Build a project that depends on {s}, with only the packages it needs", .{options.package}));
    step.dependOn(&build.step);
    // The program checked against the package's own modules too, which also tells lint what
    // each name it imports is: the configured graph is all lint reads, and the consumer's
    // project is written only when the check runs.
    const program = b.createModule(.{ .root_source_file = options.program, .target = b.graph.host, .optimize = .debug });
    for (names) |name| program.addImport(name, package.modules.get(name) orelse @panic(b.fmt("addConsumerCheck: the package has no module {s}", .{name})));
    step.dependOn(&b.addObject(.{ .name = "consumer-program", .root_module = program }).step);
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
    const relative = try std.Io.Dir.path.relativeAlloc(a, directory, null, directory, root);
    std.mem.replaceScalar(u8, relative, '\\', '/');
    const text = try aegis.own.readFile(io, cwd, args[5], a, .fromRaw(16 * 1024 * 1024));
    var modules: std.ArrayList([]const u8) = .empty;
    var dependency_options: std.ArrayList(Option) = .empty;
    for (args[8..]) |arg| {
        if (std.mem.startsWith(u8, arg, "-D")) try dependency_options.append(a, try parseOption(arg[2..])) else try modules.append(a, arg);
    }
    const shape: Shape = .{ .package = args[6], .modules = modules.items, .options = dependency_options.items };
    // A consumer that builds without bay takes every pin as written: two packages that pin
    // a third at two revisions link both, which bay's one selection hides.
    var global = try cwd.openDir(io, args[7], .{});
    defer global.close(io);
    const package_manifest = try std.Io.Dir.path.join(a, &.{ root, "build.zig.zon" });
    const found = try plain.conflicts(a, io, try aegis.own.readFile(io, cwd, package_manifest, a, .fromRaw(1024 * 1024)), shape.package, .{ .global = .{ .data = global }, .zig = args[1] });
    if (found.len != 0) {
        var buffer: [1024]u8 = undefined;
        var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
        try plain.describe(&stderr.interface, found);
        try stderr.interface.flush();
        std.process.exit(1);
    }
    try dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = text });
    try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = try manifest(a, shape.package, relative) });
    try dir.writeFile(io, .{ .sub_path = "build.zig", .data = try script(a, shape) });
    var env = try init.environ_map.clone(a);
    try env.put("ZIG_GLOBAL_CACHE_DIR", try std.Io.Dir.path.join(a, &.{ directory, ".zig-global-cache" }));
    const packages = try cwd.realPathFileAlloc(io, args[3], a);
    var child = try std.process.spawn(io, .{ .argv = &.{ args[1], "build", "--system", packages }, .cwd = .{ .path = directory }, .environ_map = &env });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) std.process.exit(1);
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

test "a package fetched by hash is copied for the consumer, one reached by path is not" {
    try std.testing.expect(byHash("aegis-0.1.17-rsxouvGhCAD_-g4V2I9sq2lY_uNA5M3zBHIw7uX4WfWt"));
    try std.testing.expect(byHash("N-V-__8AAK2jSwMxK2QTcDLqXDrakaAa7TS3ShXkjIic0xBt"));
    try std.testing.expect(!byHash("../../preflight"));
    try std.testing.expect(!byHash("/p/aegis-0.1.17-rsxouvGhCAD_-g4V2I9sq2lY_uNA5M3zBHIw7uX4WfWt/sub"));
    try std.testing.expect(!byHash("0f3a8c21d4e5b6a79f0e1d2c3b4a59687f6e5d4c3b2a19087f6e5d4c3b2a1908"));
}
