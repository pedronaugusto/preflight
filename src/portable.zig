//! Export relocatable test executables for Linux compilation and native execution.
const std = @import("std");
const configure = @import("configure.zig");
const record = @import("record.zig");
const Tool = @import("tool.zig").Tool;

pub const Command = struct {
    argv: []const []const u8,
    test_runner: bool,
    cwd: ?[]const u8 = null,
    /// The run had a fresh temporary directory (`b.tmpPath()`) as its working
    /// directory, and gets a fresh one where it replays.
    scratch: bool = false,
    /// The programs the tests run (`addProgram`), from the package root: an
    /// artifact upload drops their permission to run as it drops the tests'.
    programs: []const []const u8 = &.{},
    /// The arguments (positions in `argv`) that are paths in Zig's library, each its path from
    /// the library: the replaying runner's own Zig names them in its own.
    zig_lib: []const ZigLib = &.{},
};

/// A path argument in Zig's library: `argv[index]`, a directory (`addDirectoryArg`) or a file.
pub const ZigLib = struct { index: usize, directory: bool };

const manifest_path = "zig-out/preflight/tests.json";
/// Where `addProgram` installs, under the install prefix: inside what a
/// replaying runner downloads.
const programs_dir = "preflight/programs";

/// A program the tests run, named to them as `name` in `options` by its path
/// from the package root: every test run's working directory, here and where
/// portable tests replay, and the path is the same on both runners.
pub fn addProgram(b: *std.Build, options: *std.Build.Step.Options, name: []const u8, program: *std.Build.Step.Compile) void {
    const install = b.addInstallArtifact(program, .{ .dest_dir = .{ .override = .{ .custom = programs_dir } }, .pdb_dir = .disabled, .implib_dir = .disabled });
    options.addOption([]const u8, name, b.fmt("zig-out/{s}/{s}", .{ programs_dir, program.out_filename }));
    options.step.dependOn(&install.step);
}

/// `checker` is preflight's command program, which restores the executables'
/// permission to run that an artifact upload drops, and counts the replayed tests per root
/// as the tests step counts its own: `counted` names their records.
pub fn add(b: *std.Build, package: *std.Build, tests: *std.Build.Step, checker: Tool, counted: []const []const u8) void {
    const compile = configure.claim(b, "ci-build", "Compile test executables for execution on another runner");
    var commands: std.ArrayList(Command) = .empty;
    var seen = std.AutoHashMap(*std.Build.Step, void).init(b.allocator);
    collect(b, package, tests, compile, &commands, &seen);
    const json = std.json.Stringify.valueAlloc(b.allocator, commands.items, .{}) catch @panic("OOM");
    const manifest = b.addWriteFiles().add("tests.json", json);
    compile.dependOn(&b.addInstallFile(manifest, "preflight/tests.json").step);
    const execute = configure.claim(b, "ci-run", "Run the previously compiled test executables");
    const bytes = configure.read(package, manifest_path, 1024 * 1024) orelse {
        execute.dependOn(&b.addFail("portable test manifest missing; run ci-build or download its artifact first").step);
        return;
    };
    const stored = std.json.parseFromSlice([]Command, b.allocator, bytes, .{}) catch @panic("invalid portable test manifest");
    if (stored.value.len == 0) @panic("portable test manifest contains no tests");
    const executable = checker.run(b);
    executable.addArg("executable");
    executable.setCwd(package.path("."));
    executable.has_side_effects = true;
    var replayed: std.ArrayList(*std.Build.Step) = .empty;
    for (stored.value) |command| {
        executable.addArg(command.argv[0]);
        for (command.programs) |program| executable.addArg(program);
        const run = b.addRunFile(package.path(command.argv[0]));
        for (command.argv[1..], 1..) |arg, index| {
            const library = for (command.zig_lib) |path| {
                if (path.index == index) break path;
            } else null;
            const lib = library orelse {
                run.addArg(arg);
                continue;
            };
            if (lib.directory) run.addDirectoryArg2(b.graph.path(.zig_lib, arg), .{}) else run.addFileArg2(b.graph.path(.zig_lib, arg), .{});
        }
        run.setCwd(if (command.scratch) b.tmpPath() else package.path(command.cwd orelse "."));
        run.has_side_effects = true;
        // glint-ignore: Z011 -- the deprecation names enableProtocolMode, which sets .protocol; the recorded command needs .zig_test
        if (command.test_runner) run.enableTestRunnerMode();
        run.step.dependOn(&executable.step);
        execute.dependOn(&run.step);
        if (command.test_runner) replayed.append(b.allocator, &run.step) catch @panic("OOM");
    }
    record.counts(b, execute, checker, .{ .names = counted, .runs = replayed.items });
}

/// A replayed program runs on another runner than the one that built it, whose CPU may be
/// another model: built for the building runner's own CPU, as a program the build makes for
/// the host (`b.graph.host`) is whatever `-Dcpu` says, it dies there on the first
/// instruction the other lacks. Every module of `artifact` that asks for the native CPU asks
/// for that architecture's baseline instead, in `artifact`'s graph alone: such a module, and
/// each that imports one, is copied for it, so another artifact sharing them keeps its CPU.
fn baseline(b: *std.Build, artifact: *std.Build.Step.Compile) void {
    const Module = std.Build.Module;
    var graph: std.array_hash_map.Auto(*Module, ?*Module) = .empty;
    graph.put(b.allocator, artifact.root_module, null) catch @panic("OOM");
    var next: usize = 0;
    while (next < graph.count()) : (next += 1) {
        for (graph.keys()[next].import_table.values()) |imported| graph.put(b.allocator, imported, null) catch @panic("OOM");
    }
    // A module is copied when it asks for the native CPU or imports one that is copied; the
    // graph may be cyclic, so the marks spread until nothing changes.
    const marked = b.allocator.alloc(bool, graph.count()) catch @panic("OOM");
    for (graph.keys(), marked) |module, *mark| mark.* = native(module);
    var changed = true;
    while (changed) {
        changed = false;
        for (graph.keys(), marked) |module, *mark| {
            if (mark.*) continue;
            for (module.import_table.values()) |imported| if (marked[graph.getIndex(imported).?]) {
                mark.* = true;
                changed = true;
                break;
            };
        }
    }
    for (graph.keys(), graph.values(), marked) |module, *copy, mark| {
        if (!mark) continue;
        const made = b.allocator.create(Module) catch @panic("OOM");
        made.* = module.*;
        made.cached_graph = .{ .modules = &.{}, .names = &.{} };
        if (native(module)) {
            var query = module.resolved_target.?.query;
            query.cpu_model = .baseline;
            query.cpu_features_add = .empty;
            query.cpu_features_sub = .empty;
            made.resolved_target = b.resolveTargetQuery(query);
        }
        copy.* = made;
    }
    for (graph.values()) |copy| {
        const made = copy orelse continue;
        made.import_table = made.import_table.clone(b.allocator) catch @panic("OOM");
        for (made.import_table.values()) |*imported| {
            if (graph.get(imported.*).?) |replacement| imported.* = replacement;
        }
    }
    if (graph.values()[0]) |root| artifact.root_module = root;
}

fn native(module: *const std.Build.Module) bool {
    const target = module.resolved_target orelse return false;
    return target.query.cpu_model == .native or target.query.isNativeCpu();
}

/// The programs `artifact` runs, as `addProgram` named them, from the package
/// root. A path given to its options by `addOptionPath` (or its directory and
/// untracked kinds) is refused: it is the building runner's, absolute, and
/// the runner replaying the tests has no such path.
fn runs(b: *std.Build, artifact: *std.Build.Step.Compile) []const []const u8 {
    var programs: std.ArrayList([]const u8) = .empty;
    // Options reach the artifact as modules, each the generated file of its step.
    var graph: std.array_hash_map.Auto(*std.Build.Module, void) = .empty;
    graph.put(b.allocator, artifact.root_module, {}) catch @panic("OOM");
    var next: usize = 0;
    while (next < graph.count()) : (next += 1) {
        for (graph.keys()[next].import_table.values()) |imported| graph.put(b.allocator, imported, {}) catch @panic("OOM");
    }
    for (graph.keys()) |module| {
        const root = module.root_source_file orelse continue;
        const generated = switch (root) {
            .generated => |generated| generated,
            else => continue,
        };
        const options = b.graph.generated_files.items[@backingInt(generated.index)].cast(std.Build.Step.Options) orelse continue;
        if (options.files.items.len + options.directories.items.len + options.untracked_paths.items.len != 0)
            @panic("portable tests must not be given a path by addOptionPath: it is the building runner's own, which the runner replaying them has not; name a program the tests run with preflight.addTestProgram");
        for (options.step.dependencies.items) |installing| {
            const install = installing.cast(std.Build.Step.InstallArtifact) orelse continue;
            programs.append(b.allocator, b.fmt("zig-out/{s}/{s}", .{ programs_dir, install.dest_sub_path orelse install.artifact.out_filename })) catch @panic("OOM");
        }
    }
    return programs.items;
}

/// A path argument as the replaying runner names its own copy of it: from the run's working
/// directory `cwd` (from the package root; null for a fresh temporary one) where it is in the
/// package or a dependency the package fetches into it, or from Zig's library. Any other path
/// is the building runner's own.
fn portablePath(b: *std.Build, package: *std.Build, path: std.Build.LazyPath, cwd: ?[]const u8) union(enum) { relative: []const u8, zig_lib: []const u8 } {
    const absolute = switch (path) {
        .relative => |relative| {
            if (relative.base == .zig_lib) return .{ .zig_lib = relative.sub_path };
            @panic("portable tests must not name a path the building runner has alone: one in the package, a dependency in it, or Zig's library");
        },
        .src_path => |source| source.owner.root.joinString(b.allocator, source.sub_path) catch @panic("OOM"),
        .dependency => |dependency| dependency.dependency.builder.root.joinString(b.allocator, dependency.sub_path) catch @panic("OOM"),
        else => @panic("portable tests must not name a path the building runner has alone: one in the package, a dependency in it, or Zig's library"),
    };
    const from = cwd orelse @panic("portable tests in a fresh temporary directory must not name a path in the package");
    const io = b.graph.io;
    const base = std.Io.Dir.cwd().realPathFileAlloc(io, package.root.joinString(b.allocator, from) catch @panic("OOM"), b.allocator) catch |err| std.debug.panic("portable tests: the run's directory: {t}", .{err});
    const target = std.Io.Dir.cwd().realPathFileAlloc(io, absolute, b.allocator) catch |err| std.debug.panic("portable tests: {s}: {t}", .{ absolute, err });
    const root = std.Io.Dir.cwd().realPathFileAlloc(io, package.root.joinString(b.allocator, ".") catch @panic("OOM"), b.allocator) catch |err| std.debug.panic("portable tests: the package root: {t}", .{err});
    const inside = std.Io.Dir.path.relativeAlloc(b.allocator, root, null, root, target) catch @panic("OOM");
    if (std.mem.startsWith(u8, inside, "..") or std.Io.Dir.path.isAbsolute(inside))
        @panic("portable tests must not name a path the building runner has alone: one in the package, a dependency in it, or Zig's library");
    const relative = std.Io.Dir.path.relativeAlloc(b.allocator, base, null, base, target) catch @panic("OOM");
    return .{ .relative = if (relative.len == 0) "." else relative };
}

/// Whether `step` makes a fresh temporary directory, as `b.tmpPath()` does.
fn temporary(step: *std.Build.Step) bool {
    const write = step.cast(std.Build.Step.WriteFile) orelse return false;
    return write.mode == .tmp;
}

fn collect(b: *std.Build, package: *std.Build, step: *std.Build.Step, compile: *std.Build.Step, commands: *std.ArrayList(Command), seen: *std.AutoHashMap(*std.Build.Step, void)) void {
    const entry = seen.getOrPut(step) catch @panic("OOM");
    if (entry.found_existing) return;
    if (step.cast(std.Build.Step.Run)) |run| {
        if (run.argv.items.len == 0 or run.argv.items[0] != .artifact) @panic("portable tests must run compiled artifacts");
        const artifact = run.argv.items[0].artifact.artifact;
        // A test run with an environment fails by name (record.zig); any
        // other run would replay without it.
        if (run.environ_map != null and artifact.kind != .@"test") @panic("portable tests must not carry an environment");
        baseline(b, artifact);
        const programs = runs(b, artifact);
        const name = b.fmt("test-{d}{s}", .{ commands.items.len, if (artifact.root_module.resolved_target.?.result.os.tag == .windows) ".exe" else "" });
        const install = b.addInstallArtifact(artifact, .{ .dest_dir = .{ .override = .{ .custom = "preflight/bin" } }, .dest_sub_path = name });
        compile.dependOn(&install.step);
        var scratch = false;
        const cwd = if (run.cwd) |path| switch (path) {
            .src_path => |source| if (source.owner == package) source.sub_path else @panic("portable tests must use a repository-relative directory"),
            .generated => |generated| blk: {
                if (!temporary(b.graph.generated_files.items[@backingInt(generated.index)])) @panic("portable tests must use a repository-relative or a fresh temporary directory");
                scratch = true;
                break :blk null;
            },
            else => @panic("portable tests must use a repository-relative directory"),
        } else null;
        var argv: std.ArrayList([]const u8) = .empty;
        var zig_lib: std.ArrayList(ZigLib) = .empty;
        argv.append(b.allocator, b.fmt("zig-out/preflight/bin/{s}", .{name})) catch @panic("OOM");
        for (run.argv.items[1..]) |arg| switch (arg) {
            .bytes => |bytes| {
                if (!std.mem.eql(u8, bytes, "--listen=-") and !std.mem.startsWith(u8, bytes, "--seed=")) argv.append(b.allocator, bytes) catch @panic("OOM");
            },
            inline .lazy_path, .decorated_directory => |path, kind| {
                // The test runner's cache, which the replaying runner gives it anew.
                if (std.mem.eql(u8, path.prefix, "--cache-dir=")) continue;
                if (path.prefix.len != 0 or path.suffix.len != 0) @panic("portable tests must not decorate a path argument");
                const directory = kind == .decorated_directory;
                switch (portablePath(b, package, path.lazy_path, if (scratch) null else cwd orelse ".")) {
                    .relative => |relative| argv.append(b.allocator, relative) catch @panic("OOM"),
                    .zig_lib => |sub_path| {
                        zig_lib.append(b.allocator, .{ .index = argv.items.len, .directory = directory }) catch @panic("OOM");
                        argv.append(b.allocator, sub_path) catch @panic("OOM");
                    },
                }
            },
            else => @panic("portable tests must not contain generated arguments"),
        };
        commands.append(b.allocator, .{ .argv = argv.items, .test_runner = run.stdio == .zig_test or run.stdio == .protocol, .cwd = cwd, .scratch = scratch, .programs = programs, .zig_lib = zig_lib.items }) catch @panic("OOM");
        for (step.dependencies.items) |dependency| {
            if (dependency != &artifact.step) compile.dependOn(dependency);
        }
        return;
    }
    if (step.tag == .compile or step.tag == .install_artifact) {
        compile.dependOn(step);
        return;
    }
    for (step.dependencies.items) |dependency| collect(b, package, dependency, compile, commands, seen);
}
