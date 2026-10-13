//! Export relocatable test executables for Linux compilation and native execution.
const std = @import("std");
const configure = @import("configure.zig");
const Tool = @import("tool.zig").Tool;

pub const Command = struct {
    argv: []const []const u8,
    test_runner: bool,
    cwd: ?[]const u8 = null,
    /// The run had a fresh temporary directory (`b.tmpPath()`) as its working
    /// directory, and gets a fresh one where it replays.
    scratch: bool = false,
};

const manifest_path = "zig-out/preflight/tests.json";

/// `checker` is preflight's command program, which restores the executables'
/// permission to run that an artifact upload drops.
pub fn add(b: *std.Build, package: *std.Build, tests: *std.Build.Step, checker: Tool) void {
    const compile = configure.claim(b, "ci-build", "Compile test executables for execution on another runner");
    var commands: std.ArrayList(Command) = .empty;
    var seen = std.AutoHashMap(*std.Build.Step, void).init(b.allocator);
    collect(b, package, tests, compile, &commands, &seen);
    const json = std.json.Stringify.valueAlloc(b.allocator, commands.items, .{}) catch @panic("OOM");
    const manifest = b.addWriteFiles().add("tests.json", json);
    compile.dependOn(&b.addInstallFile(manifest, "preflight/tests.json").step);
    const execute = configure.claim(b, "ci-run", "Run the previously compiled test executables");
    const bytes = configure.read(package, manifest_path, .limited(1024 * 1024)) orelse {
        execute.dependOn(&b.addFail("portable test manifest missing; run ci-build or download its artifact first").step);
        return;
    };
    const stored = std.json.parseFromSlice([]Command, b.allocator, bytes, .{}) catch @panic("invalid portable test manifest");
    if (stored.value.len == 0) @panic("portable test manifest contains no tests");
    const executable = checker.run(b);
    executable.addArg("executable");
    executable.setCwd(package.path("."));
    executable.has_side_effects = true;
    for (stored.value) |command| {
        executable.addArg(command.argv[0]);
        const run = b.addRunFile(package.path(command.argv[0]));
        run.addArgs(command.argv[1..]);
        run.setCwd(if (command.scratch) b.tmpPath() else package.path(command.cwd orelse "."));
        run.has_side_effects = true;
        // glint-ignore: Z011 -- the deprecation names enableProtocolMode, which sets .protocol; the recorded command needs .zig_test
        if (command.test_runner) run.enableTestRunnerMode();
        run.step.dependOn(&executable.step);
        execute.dependOn(&run.step);
    }
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
        const name = b.fmt("test-{d}{s}", .{ commands.items.len, if (artifact.root_module.resolved_target.?.result.os.tag == .windows) ".exe" else "" });
        const install = b.addInstallArtifact(artifact, .{ .dest_dir = .{ .override = .{ .custom = "preflight/bin" } }, .dest_sub_path = name });
        compile.dependOn(&install.step);
        var argv: std.ArrayList([]const u8) = .empty;
        argv.append(b.allocator, b.fmt("zig-out/preflight/bin/{s}", .{name})) catch @panic("OOM");
        for (run.argv.items[1..]) |arg| switch (arg) {
            .bytes => |bytes| {
                if (!std.mem.eql(u8, bytes, "--listen=-") and !std.mem.startsWith(u8, bytes, "--seed=")) argv.append(b.allocator, bytes) catch @panic("OOM");
            },
            .lazy_path => |path| {
                if (!std.mem.eql(u8, path.prefix, "--cache-dir=")) @panic("portable tests must not contain absolute arguments");
            },
            .decorated_directory => |path| {
                if (!std.mem.eql(u8, path.prefix, "--cache-dir=")) @panic("portable tests must not contain absolute arguments");
            },
            else => @panic("portable tests must not contain generated arguments"),
        };
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
        commands.append(b.allocator, .{ .argv = argv.items, .test_runner = run.stdio == .zig_test or run.stdio == .protocol, .cwd = cwd, .scratch = scratch }) catch @panic("OOM");
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
