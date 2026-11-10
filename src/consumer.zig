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
    /// Modules the program imports. Empty means the package name alone. A configuration
    /// whose options leave one out names its own.
    modules: []const []const u8 = &.{},
    /// Packages the consumer's build may read: the package's own dependencies. Each
    /// brings the packages it depends on in turn, as a fetch would.
    packages: []const *std.Build.Dependency = &.{},
    /// Options the consumer gives the package, as `b.dependency(name, .{ ... })` does: `.http = false`
    /// proves a build without a feature the package makes optional. The base of every configuration.
    options: []const Option = &.{},
    /// The builds checked: each is `options` with its configuration's variation on top (a
    /// variation's option replaces the base's of the same name), built in a project directory of
    /// its own. One empty configuration, the default, is the one build of `options` alone. A
    /// package with optional features lists each combination it promises, so each is compiled.
    configurations: []const Configuration = &.{.{}},
};

/// One build the consumer check makes.
pub const Configuration = struct {
    /// The variation on `Options.options`.
    options: []const Option = &.{},
    /// The modules this build's program imports, where its options leave one of
    /// `Options.modules` out of the package (relic's `relic_lfs` without `.lfs`); null is
    /// `Options.modules`.
    modules: ?[]const []const u8 = null,
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
    const names = if (options.modules.len > 0) options.modules else &.{options.package};
    const step = configure.claim(b, "check-consumer", b.fmt("Build a project that depends on {s}, with only the packages it needs", .{options.package}));
    const single = options.configurations.len == 1 and options.configurations[0].options.len == 0;
    for (options.configurations, 0..) |configuration, index| {
        const merged = combined(b.allocator, options.options, configuration.options);
        const build = b.addRunArtifact(consumer);
        build.setName(b.fmt("check-consumer {s}", .{label(b, index, merged)}));
        build.addArg(b.graph.zig_exe);
        const project = if (single) "preflight-consumer" else b.fmt("preflight-consumer/{s}", .{label(b, index, merged)});
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
        } else if (!optional(options.configurations, name)) @panic(b.fmt("addConsumerCheck: the package has no module {s}", .{name}));
    }
    step.dependOn(&b.addObject(.{ .name = "consumer-program", .root_module = program }).step);
}

/// Whether some configuration's modules leave `name` out.
fn optional(configurations: []const Configuration, name: []const u8) bool {
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

/// A configuration's name, which its project directory and step take: its index and options,
/// as `1-http=false-lfs=true`, so a failure says which build it was.
fn label(b: *std.Build, index: usize, merged: []const Option) []const u8 {
    var out: std.Io.Writer.Allocating = .init(b.allocator);
    out.writer.print("{d}", .{index}) catch @panic("OOM");
    for (merged) |option| switch (option.value) {
        .flag => |flag| out.writer.print("-{s}={}", .{ option.name, flag }),
        .number => |number| out.writer.print("-{s}={d}", .{ option.name, number }),
        .text => |text| out.writer.print("-{s}={s}", .{ option.name, text }),
    } catch @panic("OOM");
    return out.written();
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
    const found = try plain.conflicts(a, io, try aegis.own.readFile(io, cwd, package_manifest, a, .fromRaw(1024 * 1024)), shape.package, .{ .global = global, .zig = args[1] });
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
    const both: Configuration = .{};
    const without: Configuration = .{ .options = &.{.{ .name = "lfs", .value = .{ .flag = false } }}, .modules = &.{"relic"} };
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
