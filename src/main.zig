const std = @import("std");
const checks = @import("checks.zig");
const deprecations = @import("deprecations.zig");
const src = checks.source;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c: src.Context = .{ .a = a, .io = init.io };
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) return error.MissingCommand;
    const command = args[1];
    if (std.mem.eql(u8, command, "plan")) {
        const config = try c.json(option(args, "--config") orelse "ci/workflow.json");
        if (option(args, "--full") != null) return error.FullReplacedByTier;
        const tier = std.meta.stringToEnum(checks.matrix.Tier, option(args, "--tier") orelse "fast") orelse return error.UnknownTier;
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
    } else if (std.mem.eql(u8, command, "profile")) {
        const durations = option(args, "--durations") orelse "ci/durations.json";
        const previous = if (c.exists(durations)) try c.json(durations) else .null;
        const summary = try checks.profile.summarize(c, option(args, "--input") orelse ".preflight-timings", previous);
        try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = option(args, "--output") orelse durations, .data = try checks.profile.render(a, summary) });
    } else if (std.mem.eql(u8, command, "fetch")) {
        try checks.command.retry(c, try checks.command.fetchArgs(a, init.environ_map.get("BUILD_ARGS") orelse ""));
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
        const label = try a.print("zig build docs -- {s}", .{checks.docs.region(args[2..])});
        const generator = src.get(src.get(config, "docs"), label);
        if (generator == .null) return error.UnknownDocumentationRegion;
        try stdout(c, try checks.docs.generate(c, generator));
    } else if (std.mem.eql(u8, command, "findings")) {
        const config = try c.json(option(args, "--config") orelse "ci/preflight.json");
        const sources = try qualitySources(&c, try src.collect(c, config), config);
        try stdout(c, try std.json.Stringify.valueAlloc(a, try checks.quality.findings(a, sources, config), .{}));
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
        const config = try c.json(option(args, "--config") orelse "ci/preflight.json");
        c.summary_path = init.environ_map.get("GITHUB_STEP_SUMMARY");
        c.adopt = std.mem.eql(u8, environment(init.environ_map, "PREFLIGHT_ADOPT") orelse "false", "true");
        const branch = try checks.ledger.git(&c, &.{ "branch", "--show-current" });
        const name = environment(init.environ_map, "GITHUB_HEAD_REF") orelse environment(init.environ_map, "GITHUB_REF_NAME") orelse std.mem.trim(u8, branch.stdout, "\r\n");
        if (!std.mem.eql(u8, name, "main")) c.ledger_base = environment(init.environ_map, "PREFLIGHT_LEDGER_BASE") orelse environment(init.environ_map, "GITHUB_BASE_REF") orelse "main";
        try lint(&c, config, option(args, "--ziglint") orelse return error.MissingZiglint);
    } else return error.UnknownCommand;
    if (c.errors != 0) return error.CheckFailed;
}

fn environment(env: *std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const value = env.get(key) orelse return null;
    return if (value.len > 0) value else null;
}

fn hasFlag(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, name)) return true;
    return false;
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

fn lint(c: *src.Context, config: src.Value, ziglint: []const u8) !void {
    const sources = try src.collect(c.*, config);
    for (sources) |s| if (s.tree.errors.len > 0) {
        c.fail("{s}: invalid Zig source", .{s.path});
    };
    if (c.errors != 0) return;
    const cast_sources = try qualitySources(c, sources, config);
    try checks.quality.summary(c, sources, c.summary_path);
    c.report("preflight: source quality\n", .{});
    try checks.quality.check(c, cast_sources, config);
    c.report("preflight: ziglint\n", .{});
    try checks.ziglint.check(c, ziglint, config);
    if (c.errors != 0) return;
    c.report("preflight: namespace layout\n", .{});
    try checks.policy.layout(c, sources, config);
    if (c.errors != 0) return;
    c.report("preflight: cast reasons\n", .{});
    checks.policy.casts(c, cast_sources, config);
    if (c.errors != 0) return;
    c.report("preflight: function length\n", .{});
    try checks.policy.lengths(c, sources, config);
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
    for (src.items(src.get(config, "extra_checks"))) |command| try checks.command.execute(c.*, try checks.docs.zigCommand(c.a, command));
}

fn qualitySources(c: *src.Context, sources: []const src.Source, config: src.Value) ![]src.Source {
    var cast_sources: std.ArrayList(src.Source) = .empty;
    try cast_sources.appendSlice(c.a, sources);
    for ([_][]const u8{ "examples", "ci", "conformance", "bench" }) |path| {
        if (!c.exists(path)) continue;
        var collected = false;
        for (src.items(src.get(config, "sources"))) |configured| {
            if (std.mem.eql(u8, src.string(configured, ""), path)) collected = true;
        }
        if (!collected) try src.collectRoot(c.*, path, &cast_sources);
    }
    if (c.exists("build.zig")) try cast_sources.append(c.a, try src.Source.parse(c.a, "build.zig", try c.read("build.zig")));
    return cast_sources.items;
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
        if (setup_step == .string) try checks.command.retry(c, &.{ "zig", "build", setup_step.string });
        const before = src.get(config, "before_tests_step");
        if (before == .string) try checks.command.execute(c, &.{ "zig", "build", before.string });
    }
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.a, &.{ "zig", "build", env.get("STEP") orelse "ci" });
    var tokens = std.mem.tokenizeAny(u8, env.get("BUILD_ARGS") orelse "", " \t\r\n");
    while (tokens.next()) |token| try argv.append(c.a, token);
    // PREFLIGHT_SHARD reaches the test runners through the environment.
    try checks.command.execute(c, argv.items);
}
