const std = @import("std");
const builtin = @import("builtin");
const checks = @import("checks.zig");
const deprecations = @import("deprecations.zig");
const src = checks.source;
const facts = @import("facts.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c: src.Context = .{ .a = a, .io = init.io };
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) return error.MissingCommand;
    const command = args[1];
    if (std.mem.eql(u8, command, "facts")) {
        try exportFacts(c, args);
    } else if (std.mem.eql(u8, command, "plan")) {
        try planOptions(args[2..]);
        const config = try c.json(option(args, "--config") orelse "ci/workflow.json");
        if (option(args, "--full") != null) return error.FullReplacedByTier;
        const tier = std.meta.stringToEnum(checks.matrix.Tier, option(args, "--tier") orelse "fast") orelse return error.UnknownTier;
        if (option(args, "--workflow")) |path| {
            const own = hasFlag(args, "--self");
            const pin = if (own) "" else try checks.workflow.pinned(c, option(args, "--manifest") orelse "build.zig.zon");
            const text = try checks.workflow.render(a, config, pin, option(args, "--working-directory") orelse ".", own);
            try checks.workflow.write(c, path, text);
            return;
        }
        const jobs = try checks.matrix.plan(a, config, tier);
        const tiers = try checks.matrix.split(a, config, jobs, tier);
        const value = try std.json.Stringify.valueAlloc(a, .{ .include = tiers.native }, .{});
        const output = option(args, "--output") orelse init.environ_map.get("GITHUB_OUTPUT");
        if (output) |path| {
            try append(c, path, try a.print("matrix={s}\n", .{value}));
            try append(c, path, try a.print("compile_matrix={s}\nrun_matrix={s}\nportable={s}\n", .{
                try std.json.Stringify.valueAlloc(a, .{ .include = tiers.compile }, .{}),
                try std.json.Stringify.valueAlloc(a, .{ .include = tiers.run }, .{}),
                if (tiers.compile.len > 0) "true" else "false",
            }));
        } else try stdout(c, value);
    } else if (std.mem.eql(u8, command, "cache")) {
        try checks.cache.trim(c, option(args, "--path") orelse ".zig-cache", try std.fmt.parseInt(usize, option(args, "--cap") orelse "1048576", 10));
    } else if (std.mem.eql(u8, command, "executable")) {
        for (args[2..]) |path| try executable(c, path);
    } else if (std.mem.eql(u8, command, "unsharded")) {
        if (environment(init.environ_map, "PREFLIGHT_SHARD") != null) {
            c.fail("{s}: a test runner of its own runs every shard's tests; drop the shards or the runner", .{if (args.len > 2) args[2] else "test"});
        }
    } else if (std.mem.eql(u8, command, "setup")) {
        try setup(c, init.environ_map);
    } else if (std.mem.eql(u8, command, "prepare")) {
        const config = if (c.exists("ci/workflow.json")) try c.json("ci/workflow.json") else .null;
        const step = src.get(config, "setup_step");
        // The hosted workflow owns the attempt deadlines and retries.
        if (step == .string) try checks.command.execute(c, &.{ "zig", "build", step.string });
    } else if (std.mem.eql(u8, command, "profile")) {
        const durations = option(args, "--durations") orelse "ci/durations.json";
        const previous = if (c.exists(durations)) try c.json(durations) else .null;
        const summary = try checks.profile.summarize(c, option(args, "--input") orelse ".preflight-timings", previous);
        try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = option(args, "--output") orelse durations, .data = try checks.profile.render(a, summary) });
    } else if (std.mem.eql(u8, command, "fetch")) {
        for (try checks.command.fetches(a, init.environ_map.get("BUILD_ARGS") orelse "")) |argv| try checks.command.retry(c, argv);
    } else if (std.mem.eql(u8, command, "run")) {
        try runGate(c, init.environ_map);
    } else if (std.mem.eql(u8, command, "skip")) {
        // A merge or release candidate keeps the whole gate, docs-only or not.
        const only_docs = std.mem.eql(u8, init.environ_map.get("PREFLIGHT_TIER") orelse "fast", "fast") and try checks.paths.run(c, environment(init.environ_map, "PREFLIGHT_BASE"));
        if (init.environ_map.get("GITHUB_OUTPUT")) |path| try append(c, path, if (only_docs) "docs_only=true\n" else "docs_only=false\n");
        if (only_docs) {
            const config = try c.json(option(args, "--config") orelse "ci/preflight.json");
            try checks.docs.check(&c, config);
        }
    } else if (std.mem.eql(u8, command, "attest")) {
        try checks.attest.run(c, init.environ_map);
    } else if (std.mem.eql(u8, command, "docs")) {
        const config = try c.json(option(args, "--config") orelse "ci/preflight.json");
        if (option(args, "--zig-exe")) |zig| c.zig = zig;
        const label = try a.print("zig build docs -- {s}", .{checks.docs.region(args[2..])});
        const generator = src.get(src.get(config, "docs"), label);
        if (generator == .null) return error.UnknownDocumentationRegion;
        try stdout(c, try checks.docs.generate(c, generator));
    } else if (std.mem.eql(u8, command, "deprecations")) {
        var std_dir = try std.Io.Dir.cwd().openDir(init.io, option(args, "--std") orelse return error.MissingStd, .{});
        defer std_dir.close(init.io);
        var paths: std.ArrayList([]const u8) = .empty;
        var index: usize = 2;
        while (index < args.len) : (index += 1) {
            if (std.mem.eql(u8, args[index], "--std")) {
                index += 1;
            } else if (!std.mem.eql(u8, args[index], "--write")) try paths.append(a, args[index]);
        }
        var buffer: [4096]u8 = undefined;
        var out = std.Io.File.stdout().writer(init.io, &buffer);
        _ = try deprecations.run(a, init.io, .cwd(), .{ .std_dir = std_dir, .write = hasFlag(args, "--write"), .paths = paths.items }, &out.interface);
        try out.interface.flush();
    } else if (std.mem.eql(u8, command, "lint")) {
        var config = try c.json(option(args, "--config") orelse "ci/preflight.json");
        if (option(args, "--zig-exe")) |zig| c.zig = zig;
        var build_options: std.ArrayList([]const u8) = .empty;
        for (args, 0..) |arg, i| if (std.mem.eql(u8, arg, "--build-option")) {
            if (i + 1 == args.len) return error.MissingConfigurationOption;
            try build_options.append(a, args[i + 1]);
        };
        const snapshot = try facts.read(c, option(args, "--zig-exe") orelse "zig", build_options.items);
        const roots = try facts.testRoots(a, snapshot);
        var root_values: std.ArrayList(src.Value) = .empty;
        const sources = try std.mem.concat(a, src.Source, &.{ try src.collect(c, config), try facts.generatedSources(a, snapshot) });
        for (roots) |root| for (sources) |source| if (std.mem.eql(u8, root, source.path)) {
            try root_values.append(a, .{ .string = root });
            break;
        };
        try config.object.put(a, "test_roots", .{ .array = root_values.toManaged(a) });
        c.summary_path = init.environ_map.get("GITHUB_STEP_SUMMARY");
        try lint(&c, init.gpa, config, sources, .{ .modules = try facts.buildModules(a, snapshot), .std_dir = option(args, "--zig-std") });
    } else return error.UnknownCommand;
    if (c.errors != 0) return error.CheckFailed;
}

fn exportFacts(c: src.Context, args: []const []const u8) !void {
    const a = c.a;
    var options: std.ArrayList([]const u8) = .empty;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--zig-exe")) {
            i += 1;
            if (i == args.len) return error.MissingCompiler;
        } else if (std.mem.eql(u8, args[i], "--build-option")) {
            i += 1;
            if (i == args.len) return error.MissingConfigurationOption;
            try options.append(a, args[i]);
        } else try options.append(a, args[i]);
    }
    const snapshot = try facts.read(c, option(args, "--zig-exe") orelse "zig", options.items);
    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(c.io, &buffer);
    try facts.write(a, snapshot, &out.interface);
    try out.interface.flush();
}

fn environment(env: *std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const value = env.get(key) orelse return null;
    return if (value.len > 0) value else null;
}

fn hasFlag(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, name)) return true;
    return false;
}

fn planOptions(args: []const []const u8) !void {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const flag = args[index];
        if (std.mem.eql(u8, flag, "--self")) continue;
        var known = false;
        for ([_][]const u8{ "--config", "--tier", "--output", "--workflow", "--manifest", "--working-directory", "--full" }) |name| {
            if (std.mem.eql(u8, name, flag)) known = true;
        }
        if (!known) return error.UnknownPlanOption;
        index += 1;
        if (index == args.len or std.mem.startsWith(u8, args[index], "--")) return error.MissingPlanOptionValue;
    }
    if (hasFlag(args, "--workflow") and hasFlag(args, "--output")) return error.ConflictingPlanOutputs;
    if (!hasFlag(args, "--workflow") and (hasFlag(args, "--self") or hasFlag(args, "--manifest") or hasFlag(args, "--working-directory"))) return error.WorkflowOptionWithoutOutput;
}

fn option(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |arg, i| if (std.mem.eql(u8, arg, name) and i + 1 < args.len) return args[i + 1];
    return null;
}

/// Gives a downloaded test executable back the permission to run that an
/// artifact upload drops.
fn executable(c: src.Context, path: []const u8) !void {
    if (std.Io.File.Permissions.has_executable_bit) {
        const file = try std.Io.Dir.cwd().openFile(c.io, path, .{});
        defer file.close(c.io);
        // Whoever may read it may run it, as `chmod +x` gives.
        const mode = (try file.stat(c.io)).permissions.toMode();
        try file.setPermissions(c.io, .fromMode(mode | (mode & 0o444) >> 2));
    }
}

fn lint(c: *src.Context, gpa: std.mem.Allocator, config: src.Value, sources: []const src.Source, build: checks.glint.assembly.Build) !void {
    for (sources) |s| if (s.tree.errors.len > 0) {
        c.fail("{s}: invalid Zig source", .{s.path});
    };
    if (c.errors != 0) return;
    try checks.quality.summary(c, sources, c.summary_path);
    c.report("preflight: glint\n", .{});
    try checks.glint.check(c, .{ .gpa = gpa, .config = config, .build = build });
    if (c.errors != 0) return;
    c.report("preflight: namespace layout\n", .{});
    try checks.policy.layout(c, sources, config);
    if (c.errors != 0) return;
    c.report("preflight: documentation\n", .{});
    try checks.docs.check(c, config);
    if (c.errors != 0) return;
    c.report("preflight: test imports\n", .{});
    try checks.imports.check(c, sources, config);
    if (c.errors != 0) return;
    c.report("preflight: package paths\n", .{});
    try checks.manifest.paths(c, config);
    if (c.errors != 0) return;
    for (src.items(src.get(config, "extra_checks"))) |command| try checks.command.execute(c.*, try checks.docs.zigCommand(c.a, c.zig, command));
}

fn stdout(c: src.Context, text: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(c.io, &buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

fn append(c: src.Context, path: []const u8, text: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(c.io, path, .{ .truncate = false, .read = true });
    defer file.close(c.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(c.io, &buffer);
    writer.pos = (try file.stat(c.io)).size;
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

fn setup(c: src.Context, env: *std.process.Environ.Map) !void {
    if (builtin.os.tag == .macos) {
        const sdk = try std.process.run(c.a, c.io, .{ .argv = &.{ "xcrun", "--no-cache", "--sdk", "macosx", "--show-sdk-path" } });
        if (sdk.term != .exited or sdk.term.exited != 0) return error.NativeSdkUnavailable;
        const path = std.mem.trim(u8, sdk.stdout, " \t\r\n");
        if (!std.Io.Dir.path.isAbsolute(path) or std.mem.findScalar(u8, path, '\n') != null) return error.InvalidSdkPath;
        if (env.get("GITHUB_ENV")) |output| try append(c, output, try c.a.print("SDKROOT={s}\n", .{path}));
    }
    const result = try std.process.run(c.a, c.io, .{ .argv = &.{ "zig", "env" } });
    if (result.term != .exited or result.term.exited != 0) return error.ZigEnvironmentFailed;
    const Env = struct { global_cache_dir: []const u8 };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const zig_env = try std.zon.parse.fromSlice(Env, .{
        .gpa = c.a,
        .arena = c.a,
        .source = try c.a.dupeSentinel(u8, result.stdout, 0),
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    });
    if (env.get("GITHUB_OUTPUT")) |path| try append(c, path, try c.a.print("global={s}\n", .{zig_env.global_cache_dir}));
    if (env.get("GITHUB_STEP_SUMMARY")) |path| {
        if (env.get("PREFLIGHT_PACKAGE_HIT")) |hit| try append(c, path, try c.a.print("Zig package cache hit: {s}; compiled build cache hit: {s}\n", .{ hit, env.get("PREFLIGHT_BUILD_HIT") orelse "false" }));
    }
}

fn runGate(c: src.Context, env: *std.process.Environ.Map) !void {
    const step = env.get("STEP") orelse "ci";
    if (std.mem.eql(u8, step, "ci") or std.mem.eql(u8, step, "ci-run"))
        try checks.profile.reset(c, ".zig-cache/preflight-timings");
    const config = if (c.exists("ci/workflow.json")) try c.json("ci/workflow.json") else .null;
    if (std.mem.eql(u8, step, "preflight-fast")) {
        var fast_env = try env.clone(c.a);
        defer fast_env.deinit();
        try fast_env.put("STEP", "ci");
        try runGate(c, &fast_env);
        if (std.mem.eql(u8, env.get("FAST_COMPILE") orelse "true", "true")) {
            for (try checks.matrix.fastTargets(c.a, config)) |target| {
                const argv = try checks.matrix.fastCrossArgs(c.a, config, target);
                c.report("preflight fast compile: {s}\n", .{argv[4]});
                try checks.command.execute(c, argv);
            }
        }
        return;
    }
    if (std.mem.eql(u8, step, "preflight-cross")) {
        const targets = src.items(src.get(config, "targets"));
        if (targets.len == 0) return error.MissingCrossTargets;
        for (targets) |target| {
            const argv = try checks.matrix.crossArgs(c.a, config, target);
            c.report("preflight cross: {s}\n", .{argv[4]});
            try checks.command.execute(c, argv);
        }
        return;
    }
    if (std.mem.eql(u8, env.get("PREFLIGHT_SETUP") orelse "false", "true")) {
        const setup_step = src.get(config, "setup_step");
        if (setup_step == .string and !std.mem.eql(u8, env.get("PREFLIGHT_PREPARED") orelse "false", "true"))
            try checks.command.retry(c, &.{ "zig", "build", setup_step.string });
        const before = src.get(config, "before_tests_step");
        if (before == .string) try checks.command.execute(c, &.{ "zig", "build", before.string });
    }
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.a, &.{ "zig", "build", env.get("STEP") orelse "ci" });
    var tokens = std.mem.tokenizeAny(u8, env.get("BUILD_ARGS") orelse "", " \t\r\n");
    while (tokens.next()) |token| {
        // The canonical planner may already specify this hosted control.
        // Repeating a boolean turns it into a Zig list, so emit it once.
        if (std.mem.eql(u8, token, "-Dci-bench-smoke=false")) continue;
        try argv.append(c.a, token);
    }
    // SDK identity is an explicit build option, so Zig configuration caches
    // cannot retain a different runner's SDKROOT environment.
    if (builtin.os.tag == .macos) {
        if (env.get("SDKROOT")) |sdk| try argv.append(c.a, try c.a.print("-Dci-sdk={s}", .{sdk}));
    }
    // Custom legacy steps may not use addCi. Ask the configured compiler
    // graph whether it declares this control instead of guessing from source.
    const snapshot = try facts.read(c, "zig", argv.items[3..]);
    for (snapshot.config.available_options) |available_option| {
        if (std.mem.eql(u8, available_option.name.slice(&snapshot.config), "ci-bench-smoke")) {
            try argv.append(c.a, "-Dci-bench-smoke=false");
            break;
        }
    }
    // PREFLIGHT_SHARD reaches the test runners through the environment.
    try checks.command.execute(c, argv.items);
}
