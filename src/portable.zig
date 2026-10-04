//! Export relocatable test executables for Linux compilation and native execution.
const std = @import("std");

pub const Command = struct { argv: []const []const u8, test_runner: bool, timings: ?[]const u8 = null, cwd: ?[]const u8 = null };

pub fn add(b: *std.Build, tests: *std.Build.Step) void {
    const compile = b.step("ci-build", "Compile test executables for execution on another runner");
    var commands: std.ArrayList(Command) = .empty;
    var seen = std.AutoHashMap(*std.Build.Step, void).init(b.allocator);
    collect(b, tests, compile, &commands, &seen);
    const json = std.json.Stringify.valueAlloc(b.allocator, commands.items, .{}) catch @panic("OOM");
    const manifest = b.addWriteFiles().add("tests.json", json);
    compile.dependOn(&b.addInstallFile(manifest, "preflight/tests.json").step);
    const execute = b.step("ci-run", "Run the previously compiled test executables");
    const bytes = b.build_root.handle.readFileAlloc(b.graph.io, "zig-out/preflight/tests.json", b.allocator, .limited(1024 * 1024)) catch {
        execute.dependOn(&b.addFail("portable test manifest missing; run ci-build or download its artifact first").step);
        return;
    };
    const stored = std.json.parseFromSlice([]Command, b.allocator, bytes, .{}) catch @panic("invalid portable test manifest");
    if (stored.value.len == 0) @panic("portable test manifest contains no tests");
    for (stored.value) |command| {
        const argv = b.allocator.dupe([]const u8, command.argv) catch @panic("OOM");
        argv[0] = b.pathFromRoot(argv[0]);
        const run = b.addSystemCommand(argv);
        run.setCwd(b.path(command.cwd orelse "."));
        run.has_side_effects = true;
        if (command.test_runner) run.enableTestRunnerMode();
        if (command.timings) |path| run.setEnvironmentVariable("PREFLIGHT_TIMINGS", path);
        RestorePermissions.original = run.step.makeFn;
        run.step.makeFn = RestorePermissions.make;
        execute.dependOn(&run.step);
    }
}

const RestorePermissions = struct {
    var original: std.Build.Step.MakeFn = undefined;

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        const run = step.cast(std.Build.Step.Run).?;
        const io = step.owner.graph.io;
        const file = try step.owner.build_root.handle.openFile(io, run.argv.items[0].bytes, .{});
        defer file.close(io);
        if (std.Io.File.Permissions.has_executable_bit) try file.setPermissions(io, .executable_file);
        try original(step, options);
    }
};

fn collect(b: *std.Build, step: *std.Build.Step, compile: *std.Build.Step, commands: *std.ArrayList(Command), seen: *std.AutoHashMap(*std.Build.Step, void)) void {
    const entry = seen.getOrPut(step) catch @panic("OOM");
    if (entry.found_existing) return;
    if (step.cast(std.Build.Step.Run)) |run| {
        if (run.environ_map) |env| {
            var iterator = env.iterator();
            while (iterator.next()) |item| {
                if (std.mem.eql(u8, item.key_ptr.*, "PREFLIGHT_TIMINGS")) continue;
                const inherited = b.graph.environ_map.get(item.key_ptr.*) orelse @panic("portable tests must not contain runner-specific environment paths");
                if (!std.mem.eql(u8, inherited, item.value_ptr.*)) @panic("portable tests must not contain runner-specific environment paths");
            }
        }
        if (run.argv.items.len == 0 or run.argv.items[0] != .artifact) @panic("portable tests must run compiled artifacts");
        const artifact = run.argv.items[0].artifact.artifact;
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
        const timings = if (run.environ_map) |env| env.get("PREFLIGHT_TIMINGS") else null;
        const cwd = if (run.cwd) |path| switch (path) {
            .src_path => |source| if (source.owner == b) source.sub_path else @panic("portable tests must use a repository-relative directory"),
            else => @panic("portable tests must use a repository-relative directory"),
        } else null;
        commands.append(b.allocator, .{ .argv = argv.items, .test_runner = run.stdio == .zig_test, .timings = timings, .cwd = cwd }) catch @panic("OOM");
        for (step.dependencies.items) |dependency| {
            if (dependency != &artifact.step) compile.dependOn(dependency);
        }
        return;
    }
    if (step.id == .compile or step.id == .install_artifact) {
        compile.dependOn(step);
        return;
    }
    for (step.dependencies.items) |dependency| collect(b, dependency, compile, commands, seen);
}
