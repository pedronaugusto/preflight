//! A project that depends on the package by path, built with fetching off and
//! only the packages the package itself needs: the build a consumer gets.
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
    /// A public function of the package's `build.zig` that decides
    /// `use_llvm` for a target and mode, `fn (std.Build.ResolvedTarget,
    /// std.builtin.OptimizeMode) ?bool`, for code Zig's own backend cannot
    /// build. The consumer's build calls it with the target and mode it
    /// builds for, as a user's build does.
    use_llvm: ?[]const u8 = null,
};

/// Adds `check-consumer`. The project is generated under the cache, so the
/// package keeps no consumer files of its own.
pub fn add(b: *std.Build, options: Options) void {
    if (b.pkg_hash.len != 0) return;
    const project = b.allocator.create(Project) catch @panic("OOM");
    project.* = .{
        .step = .init(.{ .id = .custom, .name = "generate consumer project", .owner = b, .makeFn = Project.make }),
        .options = options,
        .directory = .{ .step = &project.step },
    };
    options.program.addStepDependencies(&project.step);
    const packages = b.addWriteFiles();
    _ = packages.add("README", "No packages.\n");
    for (options.packages) |dependency| _ = packages.addCopyDirectory(dependency.path(""), dependency.builder.pkg_hash, .{});
    const build = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "--system" });
    build.addDirectoryArg(packages.getDirectory());
    build.setCwd(.{ .generated = .{ .file = &project.directory } });
    build.has_side_effects = true;
    build.expectExitCode(0);
    b.step("check-consumer", b.fmt("Build a project that depends on {s}, with only the packages it needs", .{options.package})).dependOn(&build.step);
}

const Project = struct {
    step: std.Build.Step,
    options: Options,
    directory: std.Build.GeneratedFile,

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const project: *Project = @fieldParentPtr("step", step);
        const b = step.owner;
        const io = b.graph.io;
        const a = b.allocator;
        const sub_path = "preflight-consumer";
        try b.cache_root.handle.createDirPath(io, sub_path ++ "/src");
        const directory = try b.cache_root.handle.realPathFileAlloc(io, sub_path, a);
        const root = try b.build_root.handle.realPathFileAlloc(io, ".", a);
        const relative = try std.fs.path.relative(a, directory, null, directory, root);
        std.mem.replaceScalar(u8, relative, '\\', '/');
        var dir = try b.cache_root.handle.openDir(io, sub_path, .{});
        defer dir.close(io);
        const program = project.options.program.getPath3(b, step);
        const text = try program.root_dir.handle.readFileAlloc(io, program.sub_path, a, .limited(16 * 1024 * 1024));
        try dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = text });
        try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = try manifest(a, project.options.package, relative) });
        try dir.writeFile(io, .{ .sub_path = "build.zig", .data = try script(a, project.options) });
        project.directory.path = directory;
    }
};

fn manifest(a: std.mem.Allocator, package: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\.{{
        \\    .name = .consumer,
        \\    .version = "0.0.0",
        \\    .fingerprint = 0x705b37272f017aed,
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{{ .{f} = .{{ .path = "{f}" }} }},
        \\    .paths = .{{""}},
        \\}}
        \\
    , .{ std.zig.fmtId(package), std.zig.fmtString(path) });
}

fn script(a: std.mem.Allocator, options: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll(
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
    );
    try w.print("    const package = b.dependency(\"{f}\", .{{ .target = target, .optimize = optimize }});\n", .{std.zig.fmtString(options.package)});
    try w.writeAll("    const exe = b.addExecutable(.{ .name = \"consumer\", ");
    if (options.use_llvm) |decide| try w.print(".use_llvm = @import(\"{f}\").{f}(target, optimize), ", .{ std.zig.fmtString(options.package), std.zig.fmtId(decide) });
    try w.writeAll(".root_module = b.createModule(.{\n        .root_source_file = b.path(\"src/main.zig\"),\n        .target = target,\n        .optimize = optimize,\n        .imports = &.{\n");
    const modules: []const []const u8 = if (options.modules.len > 0) options.modules else &.{options.package};
    for (modules) |module| try w.print("            .{{ .name = \"{f}\", .module = package.module(\"{f}\") }},\n", .{ std.zig.fmtString(module), std.zig.fmtString(module) });
    try w.writeAll("        },\n    }) });\n    b.installArtifact(exe);\n}\n");
    return out.written();
}

test "the generated consumer imports each named module from the package" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const program: std.Build.LazyPath = .{ .cwd_relative = "unused" };
    const text = try script(a, .{ .package = "conduit", .program = program, .modules = &.{ "conduit", "conduit.tty" }, .use_llvm = "needsLlvm" });
    try std.testing.expect(std.mem.indexOf(u8, text, "b.dependency(\"conduit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".{ .name = \"conduit.tty\", .module = package.module(\"conduit.tty\") }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".use_llvm = @import(\"conduit\").needsLlvm(target, optimize)") != null);
    const single = try script(a, .{ .package = "strand", .program = program });
    try std.testing.expect(std.mem.indexOf(u8, single, ".{ .name = \"strand\", .module = package.module(\"strand\") }") != null);
    try std.testing.expect(std.mem.indexOf(u8, single, "use_llvm") == null);
    const zon = try manifest(a, "strand", "../..");
    try std.testing.expect(std.mem.indexOf(u8, zon, ".dependencies = .{ .strand = .{ .path = \"../..\" } }") != null);
}
