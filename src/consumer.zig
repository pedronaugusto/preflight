//! A project that depends on the package by path, built with fetching off and
//! only the packages the package itself needs: the build a consumer gets.
//! The build runs this file as a program to write the project.
const std = @import("std");

pub const Options = struct {
    /// The dependency name a consumer gives the package, as in its build.zig.zon.
    package: []const u8,
    /// The consumer's program, importing what a user imports.
    program: std.Build.LazyPath,
    /// Modules the program imports. Empty means the package name alone.
    modules: []const []const u8 = &.{},
    /// Packages the consumer's build may read: what the package needs to build.
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

/// Adds `check-consumer`. The project is generated under the cache, so the
/// package keeps no consumer files of its own.
pub fn add(b: *std.Build, options: Options) void {
    if (b.pkg_hash.len != 0) return;
    const pkg = (b.dependencyLazy("preflight", .{}) catch return).builder;
    const consumer = b.addExecutable(.{ .name = "preflight-consumer", .root_module = b.createModule(.{
        .root_source_file = pkg.path("src/consumer.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    }) });
    const packages = b.addWriteFiles();
    _ = packages.add("README", "No packages.\n");
    for (options.packages) |dependency| _ = packages.addCopyDirectory(dependency.path(""), dependency.builder.pkg_hash, .{});
    const build = b.addRunArtifact(consumer);
    build.addArg(b.graph.zig_exe);
    build.addDirectoryArg2(b.graph.path(.local_cache, "preflight-consumer"), .{});
    build.addDirectoryArg2(packages.getDirectory(), .{});
    build.addDirectoryArg2(b.path("."), .{});
    build.addFileArg(options.program);
    build.addArg(options.package);
    for (options.options) |option| build.addArg(switch (option.value) {
        .flag => |flag| b.fmt("-D{s}=bool:{}", .{ option.name, flag }),
        .number => |number| b.fmt("-D{s}=i64:{d}", .{ option.name, number }),
        .text => |text| b.fmt("-D{s}=str:{s}", .{ option.name, text }),
    });
    build.addArgs(if (options.modules.len > 0) options.modules else &.{options.package});
    build.has_side_effects = true;
    b.step("check-consumer", b.fmt("Build a project that depends on {s}, with only the packages it needs", .{options.package})).dependOn(&build.step);
}

/// Writes the project and builds it: `<zig> <project> <packages> <package
/// root> <program> <package> <module>...`.
/// The build has a Zig cache of its own: a consumer has none of the
/// package's cached packages, and Zig 0.17's `--system` asserts on a lazy
/// package it finds only in the global cache.
pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 8) return error.MissingConsumerArguments;
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.createDirPathOpen(io, args[2], .{});
    defer dir.close(io);
    try dir.createDirPath(io, "src");
    const directory = try cwd.realPathFileAlloc(io, args[2], a);
    const root = try cwd.realPathFileAlloc(io, args[4], a);
    const relative = try std.Io.Dir.path.relativeAlloc(a, directory, null, directory, root);
    std.mem.replaceScalar(u8, relative, '\\', '/');
    const text = try cwd.readFileAlloc(io, args[5], a, .limited(16 * 1024 * 1024));
    var modules: std.ArrayList([]const u8) = .empty;
    var dependency_options: std.ArrayList(Option) = .empty;
    for (args[7..]) |arg| {
        if (std.mem.startsWith(u8, arg, "-D")) try dependency_options.append(a, try parseOption(arg[2..])) else try modules.append(a, arg);
    }
    const shape: Shape = .{ .package = args[6], .modules = modules.items, .options = dependency_options.items };
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
