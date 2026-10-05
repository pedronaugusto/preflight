const std = @import("std");
const checks = @import("checks.zig");
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
        var config = try c.json(option(args, "--config") orelse "ci/workflow.json");
        const measurements = option(args, "--measurements") orelse ".preflight-timings/summary.json";
        if (c.exists(measurements)) config = try checks.profile.apply(a, config, try c.json(measurements));
        const full = std.mem.eql(u8, option(args, "--full") orelse "false", "true");
        const jobs = try checks.matrix.plan(a, config, full);
        const tiers = try checks.matrix.split(a, config, jobs, full);
        const value = try std.json.Stringify.valueAlloc(a, .{ .include = tiers.native }, .{});
        const output = option(args, "--output") orelse init.environ_map.get("GITHUB_OUTPUT");
        if (output) |path| {
            try append(c, path, try std.fmt.allocPrint(a, "matrix={s}\n", .{value}));
            try append(c, path, try std.fmt.allocPrint(a, "compile_matrix={s}\nrun_matrix={s}\nportable={s}\n", .{
                try std.json.Stringify.valueAlloc(a, .{ .include = tiers.compile }, .{}),
                try std.json.Stringify.valueAlloc(a, .{ .include = tiers.run }, .{}),
                if (tiers.compile.len > 0) "true" else "false",
            }));
        } else try stdout(c, value);
    } else if (std.mem.eql(u8, command, "cache")) {
        try checks.cache.trim(c, option(args, "--path") orelse ".zig-cache", try std.fmt.parseInt(usize, option(args, "--cap") orelse "1048576", 10));
    } else if (std.mem.eql(u8, command, "container")) {
        try checks.container.run(c, try c.json("ci/workflow.json"), try checks.container.options(args[2..]));
    } else if (std.mem.eql(u8, command, "setup")) {
        try setup(c, init.environ_map);
    } else if (std.mem.eql(u8, command, "profile")) {
        const config = try c.json(option(args, "--config") orelse "ci/workflow.json");
        const summary = try checks.profile.summarize(c, config, option(args, "--input") orelse ".preflight-timings");
        try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = option(args, "--output") orelse ".preflight-timings/summary.json", .data = try std.json.Stringify.valueAlloc(a, summary, .{}) });
    } else if (std.mem.eql(u8, command, "fetch")) {
        try retry(c, &.{ "zig", "build", "--fetch=all" });
    } else if (std.mem.eql(u8, command, "run")) {
        try runGate(c, init.environ_map);
    } else if (std.mem.eql(u8, command, "skip")) {
        const only_docs = !std.mem.eql(u8, init.environ_map.get("PREFLIGHT_FULL") orelse "false", "true") and try checks.paths.run(c, init.environ_map.get("PREFLIGHT_BASE") orelse "HEAD^");
        if (init.environ_map.get("GITHUB_OUTPUT")) |path| try append(c, path, if (only_docs) "docs_only=true\n" else "docs_only=false\n");
        if (only_docs) {
            const config = try c.json(option(args, "--config") orelse "ci/preflight.json");
            try checks.docs.check(&c, config);
        }
    } else if (std.mem.eql(u8, command, "attest")) {
        try checks.attest.run(c, init.environ_map);
    } else if (std.mem.eql(u8, command, "docs")) {
        const config = try c.json(option(args, "--config") orelse "ci/preflight.json");
        const label = try std.fmt.allocPrint(a, "zig build docs -- {s}", .{option(args, "--region") orelse "usage"});
        const generator = src.get(src.get(config, "docs"), label);
        if (generator == .null) return error.UnknownDocumentationRegion;
        try stdout(c, try checks.docs.generate(c, generator));
    } else if (std.mem.eql(u8, command, "findings")) {
        const config = try c.json(option(args, "--config") orelse "ci/preflight.json");
        const sources = try qualitySources(&c, try src.collect(c, config), config);
        try stdout(c, try std.json.Stringify.valueAlloc(a, try checks.quality.findings(a, sources), .{}));
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

fn option(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |arg, i| if (std.mem.eql(u8, arg, name) and i + 1 < args.len) return args[i + 1];
    return null;
}

fn lint(c: *src.Context, config: src.Value, ziglint: []const u8) !void {
    const sources = try src.collect(c.*, config);
    for (sources) |s| if (s.tree.errors.len > 0) {
        c.fail("{s}: invalid Zig source", .{s.path});
    };
    if (c.errors != 0) return;
    const cast_sources = try qualitySources(c, sources, config);
    try checks.quality.summary(c, sources, c.summary_path);
    std.debug.print("preflight: source quality\n", .{});
    try checks.quality.check(c, cast_sources, config);
    std.debug.print("preflight: ziglint\n", .{});
    try checks.ziglint.check(c, ziglint, config);
    if (c.errors != 0) return;
    std.debug.print("preflight: namespace layout\n", .{});
    try checks.policy.layout(c, sources, config);
    if (c.errors != 0) return;
    std.debug.print("preflight: cast reasons\n", .{});
    checks.policy.casts(c, cast_sources, config);
    if (c.errors != 0) return;
    std.debug.print("preflight: function length\n", .{});
    try checks.policy.lengths(c, sources, config);
    if (c.errors != 0) return;
    std.debug.print("preflight: documentation\n", .{});
    try checks.docs.check(c, config);
    if (c.errors != 0) return;
    std.debug.print("preflight: test imports\n", .{});
    try checks.imports.check(c, sources, config);
    if (c.errors != 0) return;
    for (src.items(src.get(config, "extra_checks"))) |command| try execute(c.*, try checks.docs.zigCommand(c.a, command));
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

pub fn execute(c: src.Context, argv: []const []const u8) !void {
    var child = try std.process.spawn(c.io, .{ .argv = argv });
    const term = try child.wait(c.io);
    if (term != .exited or term.exited != 0) return error.CommandFailed;
}

fn retry(c: src.Context, argv: []const []const u8) !void {
    for (0..3) |attempt| {
        execute(c, argv) catch |err| {
            if (attempt == 2) return err;
            std.debug.print("preflight: fetch failed; retry {d}/3\n", .{attempt + 2});
            try std.Io.sleep(c.io, .fromSeconds(@as(i64, 5) << @intCast(attempt)), .awake);
            continue;
        };
        return;
    }
}

fn setup(c: src.Context, env: *std.process.Environ.Map) !void {
    const result = try std.process.run(c.a, c.io, .{ .argv = &.{ "zig", "env" } });
    if (result.term != .exited or result.term.exited != 0) return error.ZigEnvironmentFailed;
    const Env = struct { global_cache_dir: []const u8 };
    const zig_env = try std.zon.parse.fromSliceAlloc(Env, c.a, try c.a.dupeZ(u8, result.stdout), null, .{ .ignore_unknown_fields = true });
    if (env.get("GITHUB_OUTPUT")) |path| try append(c, path, try std.fmt.allocPrint(c.a, "global={s}\n", .{zig_env.global_cache_dir}));
    if (env.get("GITHUB_STEP_SUMMARY")) |path| {
        if (env.get("PREFLIGHT_PACKAGE_HIT")) |hit| try append(c, path, try std.fmt.allocPrint(c.a, "Zig package cache hit: {s}; compiled build cache hit: {s}\n", .{ hit, env.get("PREFLIGHT_BUILD_HIT") orelse "false" }));
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
                std.debug.print("preflight fast compile: {s}\n", .{argv[4]});
                try execute(c, argv);
            }
        }
        return;
    }
    if (std.mem.eql(u8, step, "preflight-cross")) {
        const targets = src.items(src.get(config, "targets"));
        if (targets.len == 0) return error.MissingCrossTargets;
        for (targets) |target| {
            const argv = try checks.matrix.crossArgs(c.a, config, target);
            std.debug.print("preflight cross: {s}\n", .{argv[4]});
            try execute(c, argv);
        }
        return;
    }
    if (std.mem.eql(u8, env.get("PREFLIGHT_SETUP") orelse "false", "true")) {
        const setup_step = src.get(config, "setup_step");
        if (setup_step == .string) try retry(c, &.{ "zig", "build", setup_step.string });
        const before = src.get(config, "before_tests_step");
        if (before == .string) try execute(c, &.{ "zig", "build", before.string });
    }
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.a, &.{ "zig", "build", env.get("STEP") orelse "ci" });
    for ([_][]const u8{ "BUILD_ARGS", "TEST_TIMEOUT" }) |name| {
        var tokens = std.mem.tokenizeAny(u8, env.get(name) orelse "", " \t\r\n");
        while (tokens.next()) |token| try argv.append(c.a, token);
    }
    const length = argv.items.len;
    var cases = std.mem.tokenizeAny(u8, env.get("CASES") orelse "", " \t\r\n");
    var count: usize = 0;
    while (cases.next()) |case| {
        argv.shrinkRetainingCapacity(length);
        try argv.append(c.a, try std.fmt.allocPrint(c.a, "-Dtest-case={s}", .{case}));
        var case_env = try env.clone(c.a);
        defer case_env.deinit();
        try case_env.put("PREFLIGHT_SHARD", case);
        var child = try std.process.spawn(c.io, .{ .argv = argv.items, .environ_map = &case_env });
        const term = try child.wait(c.io);
        if (term != .exited or term.exited != 0) return error.CommandFailed;
        count += 1;
    }
    if (count == 0) try execute(c, argv.items);
}
