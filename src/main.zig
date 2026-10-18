const std = @import("std");
const builtin = @import("builtin");
const ensign = @import("ensign");
const checks = @import("checks.zig");
const deprecations = @import("deprecations.zig");
const src = checks.source;
const facts = @import("facts.zig");
const watchdog = @import("watchdog.zig");
const Cli = @import("cli.zig").Cli;
const Command = @FieldType(Cli, "command");

pub fn main(init: std.process.Init) !void {
    // Help and mistakes are answered here, and the program exits.
    const cli = ensign.parseOrExit(Cli, init);
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var c: src.Context = .{ .a = a, .io = init.io };
    c.bay = c.bayFor(init.environ_map);
    switch (cli.command) {
        .facts => |args| try exportFacts(&c, args),
        .plan => |args| try planCommand(&c, init, args),
        .version => try stdout(c, try a.print("{f}\n", .{try checks.release.declared(&c)})),
        .release => |args| try releaseCommand(&c, args),
        .surface => |args| try surfaceCommand(&c, args),
        .land => |args| try landCommand(&c, args),
        .ready => |args| try readyCommand(&c, args),
        .gate => |args| try gateCommand(&c, init.environ_map, args),
        .publish => |args| try publishCommand(&c, args),
        .cache => |args| try checks.cache.trim(c, args.path, args.cap),
        .executable => |args| for (args.paths) |path| try executable(c, path),
        .unsharded => |args| if (environment(init.environ_map, "PREFLIGHT_SHARD") != null) {
            c.fail("{s}: a test runner of its own runs every shard's tests; drop the shards or the runner", .{args.name});
        },
        .setup => try setup(c, init.environ_map),
        // The hosted workflow owns the attempt deadlines and retries.
        .prepare => if (try setupStep(c, init.environ_map)) |step| try checks.command.execute(c, try std.mem.concat(a, []const u8, &.{ c.buildCommand(), &.{step} })),
        .profile => |args| try profileCommand(c, args),
        .fetch => for (try checks.command.fetches(a, c.buildCommand(), init.environ_map.get("BUILD_ARGS") orelse "")) |argv| try checks.command.retry(c, argv),
        .fuzz_campaign => |args| {
            c.environ_map = init.environ_map;
            try checks.campaign.run(&c, args.cache, args.cwd, args.build);
        },
        .run => try runGate(c, init.environ_map),
        .skip => |args| try skipCommand(&c, init.environ_map, args),
        .attest => try checks.attest.run(c, init.environ_map),
        .docs => |args| {
            const config = try c.options(args.config);
            if (args.zig_exe) |zig| c.zig = zig;
            const generator = src.get(src.get(config, "docs"), try a.print("zig build docs -- {s}", .{args.region}));
            if (generator == .null) return error.UnknownDocumentationRegion;
            try stdout(c, try checks.docs.generate(c, generator));
        },
        .deprecations => |args| try deprecationsCommand(init.io, a, args),
        .lint => |args| {
            // A passing lint prints nothing; a failing one prints all it found, and a
            // hosted job keeps it in the summary either way.
            var held: std.Io.Writer.Allocating = .init(a);
            c.held = &held;
            const outcome = lintCommand(&c, init, args);
            c.held = null;
            if (c.summary_path) |path| if (held.written().len != 0) {
                // glint-ignore: Z026 -- the summary is a copy for the hosted job; the outcome below is the check's
                append(c, path, try a.print("<details><summary>lint</summary>\n\n```\n{s}```\n</details>\n", .{held.written()})) catch {};
            };
            // A finding reported without failing is shown: it is there to be seen.
            if (std.meta.isError(outcome) or c.errors != 0 or c.notes != 0) c.report("{s}", .{held.written()});
            try outcome;
        },
    }
    if (c.errors != 0) return error.CheckFailed;
}

/// `profile`: the jobs' timing records summarized beside the durations and costs so far.
fn profileCommand(c: src.Context, args: @FieldType(Command, "profile")) !void {
    const previous = if (c.exists(args.durations)) try c.json(args.durations) else .null;
    const summary = try checks.profile.summarize(c, args.input, previous);
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = args.output orelse args.durations, .data = try checks.profile.render(c.a, summary) });
    // The phases the jobs timed, beside the test durations.
    const measured = try checks.profile.measure(c, args.input, if (c.exists(args.costs)) try c.json(args.costs) else .null);
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = args.costs_output orelse args.costs, .data = try checks.profile.renderCosts(c.a, measured) });
}

/// `deprecations`: what this Zig release deprecated, rewritten, or with `--write` applied.
fn deprecationsCommand(io: std.Io, a: std.mem.Allocator, args: @FieldType(Command, "deprecations")) !void {
    var std_dir = try std.Io.Dir.cwd().openDir(io, args.std, .{});
    defer std_dir.close(io);
    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buffer);
    _ = try deprecations.run(a, io, .cwd(), .{ .std_dir = std_dir, .write = args.write, .paths = args.paths }, &out.interface);
    try out.interface.flush();
}

/// `skip`: whether the change is documentation alone, which a fast run does not test.
fn skipCommand(c: *src.Context, env: *std.process.Environ.Map, args: @FieldType(Command, "skip")) !void {
    // A merge or release candidate keeps the whole gate, docs-only or not.
    const only_docs = std.mem.eql(u8, env.get("PREFLIGHT_TIER") orelse "fast", "fast") and try checks.paths.run(c.*, environment(env, "PREFLIGHT_BASE"));
    if (env.get("GITHUB_OUTPUT")) |path| try append(c.*, path, if (only_docs) "docs_only=true\n" else "docs_only=false\n");
    if (only_docs) {
        const config = try c.options(args.config);
        try checks.docs.check(c, config);
    }
}

/// `release`: the version the commit about to be tested carries, written to `build.zig.zon` and `CHANGELOG.md`.
fn releaseCommand(c: *src.Context, args: @FieldType(Command, "release")) !void {
    const date = args.date orelse try checks.release.today(c.a, c.io);
    const outcome = checks.release.run(c, date, try modules(c.a, args.module)) catch |err| switch (err) {
        // Each of these named its fix.
        error.InvalidVersion, error.InvalidManifest, error.NoChangelog, error.NoUnreleasedSection, error.EmptyUnreleased, error.TagExists, error.UndeclaredBreaking => return error.CheckFailed,
        else => return err,
    };
    switch (outcome) {
        .unchanged => |tag| try stdout(c.*, try c.a.print("no release: nothing the package ships changed since {s}\n", .{tag})),
        .prepared => |version| try stdout(c.*, try c.a.print("{f} is released in build.zig.zon and CHANGELOG.md and waits for its tag\n", .{version})),
        .released => |made| try stdout(c.*, try c.a.print("released {f} -> {f}{s}\n", .{ made.from, made.to, if (made.breaking) " (breaking)" else "" })),
    }
}

/// The macOS targets of `config` whose build links a framework, as `sdk_targets`: only their
/// links need a Mac, with Apple's SDK; Zig links any other macOS target on Linux. Each is read
/// from the build in `directory`, where the gate runs, configured for that target, so a
/// framework linked for macOS alone counts.
fn sdkTargets(c: *src.Context, config: *src.Value, directory: []const u8) anyerror!void {
    if (config.* != .object) return;
    var gate = c.*;
    gate.dir = try c.directory().openDir(c.io, directory, .{});
    defer gate.dir.?.close(c.io);
    // The gate's build is developed with bay or not on its own account (preflight's sample is not).
    gate.bay = if (gate.developedWithBay()) c.bay orelse "bay" else null;
    var linking: std.json.Array = .init(c.a);
    for (src.items(src.get(config.*, "targets"))) |target| {
        const options = try checks.matrix.crossOptions(c.a, config.*, target);
        const name = checks.matrix.targetName(target);
        const query = std.Target.Query.parse(.{ .arch_os_abi = name }) catch return error.InvalidCrossTarget;
        if (query.os_tag != .macos) continue;
        const snapshot = try facts.read(gate, c.zig, options);
        if (try facts.linksFramework(c.a, snapshot)) try linking.append(.{ .string = name });
    }
    try config.object.put(c.a, "sdk_targets", .{ .array = linking });
}

/// `land`: the branch checked out, released, through the merge tier and onto main.
fn landCommand(c: *src.Context, args: @FieldType(Command, "land")) !void {
    if (args.zig_exe) |zig| c.zig = zig;
    // `--config` and `--working-directory` as `plan` takes them; by default what the caller's first line says it was planned with.
    var options: checks.land.Options = .{
        .date = args.date orelse try checks.release.today(c.a, c.io),
        .config = args.config,
        .working_directory = args.working_directory,
        .sdk = sdkTargets,
        .modules = try modules(c.a, args.module),
    };
    // `--poll <seconds>`: between two looks at GitHub, for the run and at it.
    if (args.poll) |seconds| {
        const every: std.Io.Duration = .fromSeconds(seconds);
        options.find_every = every;
        options.wait_every = every;
    }
    const outcome = checks.land.run(c, options) catch |err| switch (err) {
        // Reported where it failed.
        error.LandFailed => return error.CheckFailed,
        else => return err,
    };
    switch (outcome) {
        .nothing => |why| try stdout(c.*, try c.a.print("nothing to land: {s}\n", .{why})),
        .landed => |landed| try stdout(c.*, try c.a.print("landed {s} on {s} at {s}{s}\n", .{ landed.name, landed.onto, landed.sha[0..12], if (landed.followed) "" else ", and the branch stays where it was" })),
    }
}

/// `ready`: the landing commit made on the branch checked out, for a landing gated by hand.
fn readyCommand(c: *src.Context, args: @FieldType(Command, "ready")) !void {
    if (args.zig_exe) |zig| c.zig = zig;
    const readied = checks.land.ready(c, .{
        .date = args.date orelse try checks.release.today(c.a, c.io),
        .config = args.config,
        .working_directory = args.working_directory,
        .sdk = sdkTargets,
        .modules = try modules(c.a, args.module),
    }) catch |err| switch (err) {
        // Reported where it failed.
        error.LandFailed => return error.CheckFailed,
        else => return err,
    };
    const what = if (readied.version) |version| try c.a.print("v{f}", .{version}) else "no release";
    try stdout(c.*, try c.a.print("ready: {s} at {s}; gate it on each machine (gate), then publish\n", .{ what, readied.sha[0..12] }));
}

/// `gate`: the release tier's jobs this machine runs, each as the hosted job runs it, all of
/// them, so a red names every job that failed here; what it cannot run is named.
///
/// `--working-directory <dir>` gates a package whose planned jobs run in `dir` while its
/// declared jobs' directories are the repository's, as the hosted caller runs them
/// (preflight's own gate runs its sample there); `--config` defaults to `dir`'s.
fn gateCommand(c: *src.Context, environ: *const std.process.Environ.Map, args: @FieldType(Command, "gate")) !void {
    if (args.zig_exe) |zig| c.zig = zig;
    // A caller other than plan generates would have the hosted runs check another landing
    // than the one gated here.
    checks.land.currentCaller(c, args.working_directory, args.config, sdkTargets) catch |err| switch (err) {
        // Reported where it failed.
        error.LandFailed => return error.CheckFailed,
        else => return err,
    };
    const working = args.working_directory orelse ".";
    const config_path = args.config orelse try std.Io.Dir.path.join(c.a, &.{ working, "ci/workflow.json" });
    const config = try checks.workflow.configuration(c.*, config_path);
    const jobs = try checks.matrix.plan(c.a, config, .release);
    const host: checks.local.Host = .{ .os = builtin.target.os.tag, .arch = builtin.target.cpu.arch, .qemu = onPath(c.*, environ, "qemu-system-riscv64") };
    const decisions = try checks.local.decide(c.a, jobs, host);
    var not_here: std.ArrayList([]const u8) = .empty;
    var failed: std.ArrayList([]const u8) = .empty;
    for (jobs, decisions) |job, decision| switch (decision) {
        .covered => {},
        .elsewhere => |why| try not_here.append(c.a, try c.a.print("{s} ({s})", .{ job.name, why })),
        .run => {
            var env = try environ.clone(c.a);
            try env.put("STEP", checks.local.stepOf(job));
            try env.put("BUILD_ARGS", job.args);
            try env.put("PREFLIGHT_TARGETS", job.targets);
            try env.put("PREFLIGHT_SHARD", job.shard);
            try env.put("PREFLIGHT_SETUP", if (job.setup) "true" else "false");
            try env.put("PREFLIGHT_SETUP_STEP", job.prepare);
            var w = c.*;
            w.environ_map = &env;
            const directory = if (job.directory.len != 0) job.directory else working;
            const moved = !std.mem.eql(u8, directory, ".");
            if (moved) w.dir = try c.directory().openDir(c.io, directory, .{});
            defer if (moved) w.dir.?.close(c.io);
            // The package there builds as it is developed: with bay only if its manifest says so.
            if (moved) w.bay = w.bayFor(&env);
            try stdout(c.*, try c.a.print("gate: {s}\n", .{job.name}));
            runGate(w, &env) catch |err| {
                c.report("gate: {s} failed: {t}\n", .{ job.name, err });
                try failed.append(c.a, job.name);
            };
        },
    };
    const elsewhere = if (not_here.items.len == 0) "" else try c.a.print("; not run here: {s}", .{try std.mem.join(c.a, "; ", not_here.items)});
    if (failed.items.len != 0) {
        c.report("gate: red here: {s}{s}\n", .{ try std.mem.join(c.a, "; ", failed.items), elsewhere });
        return error.CheckFailed;
    }
    try stdout(c.*, try c.a.print("gate: green here{s}\n", .{elsewhere}));
}

/// Whether `name` is a program on the PATH.
fn onPath(c: src.Context, environ: *const std.process.Environ.Map, name: []const u8) bool {
    const path = environ.get("PATH") orelse return false;
    var dirs = std.mem.tokenizeScalar(u8, path, std.Io.Dir.path.delimiter);
    while (dirs.next()) |dir| {
        const candidate = std.Io.Dir.path.join(c.a, &.{ dir, name }) catch return false;
        if (std.Io.Dir.cwd().access(c.io, candidate, .{})) |_| return true else |_| {}
    }
    return false;
}

/// `plan`: the jobs of a tier as the hosted caller's matrices, or with `--workflow <caller>` the
/// caller generated again.
fn planCommand(c: *src.Context, init: std.process.Init, args: @FieldType(Command, "plan")) !void {
    const a = c.a;
    errdefer if (checks.matrix.problem.len != 0) c.report("ci/workflow.json: refused: {s}\n", .{checks.matrix.problem});
    errdefer if (checks.workflow.undeclared.len != 0) c.report("the caller's job {s} is not in ci/workflow.json: declare it in jobs (a build step), or move it to a workflow of its own\n", .{checks.workflow.undeclared});
    if (args.workflow == null and (args.self or args.working_directory != null or args.drop.len != 0)) {
        c.report("plan: --self, --working-directory and --drop are for the caller --workflow generates\n", .{});
        return error.CheckFailed;
    }
    if (args.zig_exe) |zig| c.zig = zig;
    var config = try checks.workflow.configuration(c.*, args.config orelse "ci/workflow.json");
    try sdkTargets(c, &config, args.working_directory orelse ".");
    if (args.workflow) |path| {
        const existing = if (c.exists(path)) try c.read(path) else null;
        const heading = try checks.workflow.heading(a, args.config, path, args.working_directory, args.self);
        const text = try checks.workflow.generate(c.*, config, args.manifest, args.working_directory orelse ".", args.self, heading, existing, args.drop);
        try checks.workflow.write(c.*, path, text);
        return;
    }
    const jobs = try checks.matrix.plan(a, config, args.tier);
    const tiers = try checks.matrix.split(a, config, jobs, args.tier);
    const value = try std.json.Stringify.valueAlloc(a, .{ .include = tiers.native }, .{});
    const output = args.output orelse init.environ_map.get("GITHUB_OUTPUT");
    if (output) |path| {
        try append(c.*, path, try a.print("matrix={s}\n", .{value}));
        try append(c.*, path, try a.print("compile_matrix={s}\nrun_matrix={s}\nportable={s}\n", .{
            try std.json.Stringify.valueAlloc(a, .{ .include = tiers.compile }, .{}),
            try std.json.Stringify.valueAlloc(a, .{ .include = tiers.run }, .{}),
            if (tiers.compile.len > 0) "true" else "false",
        }));
    } else try stdout(c.*, value);
}

/// `publish`: the gated commit onto origin's default branch, with its release's tag.
fn publishCommand(c: *src.Context, args: @FieldType(Command, "publish")) !void {
    if (args.zig_exe) |zig| c.zig = zig;
    const published = checks.land.publish(c) catch |err| switch (err) {
        // Reported where it failed.
        error.LandFailed => return error.CheckFailed,
        else => return err,
    };
    const programs = if (published.programs != 0) try c.a.print(", its GitHub release carrying {d} programs", .{published.programs}) else "";
    try stdout(c.*, try c.a.print("published {s} on {s}{s}{s}{s}\n", .{ published.sha[0..12], published.onto, if (published.tag != null) " as " else "", published.tag orelse "", programs }));
}

/// `lint`: the source checks over the repository's files, then the check on the configured build's revisions.
fn lintCommand(c: *src.Context, init: std.process.Init, args: @FieldType(Command, "lint")) !void {
    const a = c.a;
    var config = try c.options(args.config);
    if (args.zig_exe) |zig| c.zig = zig;
    const snapshot = try facts.read(c.*, c.zig, args.build_option);
    const roots = try facts.testRoots(a, snapshot);
    var root_values: std.ArrayList(src.Value) = .empty;
    const sources = try std.mem.concat(a, src.Source, &.{ try src.collect(c.*, config), try facts.generatedSources(a, snapshot) });
    for (roots) |root| for (sources) |source| if (src.samePath(root, source.path)) {
        try root_values.append(a, .{ .string = source.path });
        break;
    };
    try config.object.put(a, "test_roots", .{ .array = root_values.toManaged(a) });
    c.summary_path = init.environ_map.get("GITHUB_STEP_SUMMARY");
    try lint(c, init.gpa, config, sources, .{ .modules = try facts.buildModules(a, snapshot), .std_dir = args.zig_std }, try checks.phases.Log.init(a, init.environ_map));
    try facts.revisions.check(c, &snapshot.config, snapshot.package, try checks.manifest.name(c), try checks.manifest.coexist(c));
    try checks.manifest.nested(c);
    try checks.lazy_import.check(c);
}

/// `facts`: the configured build's modules, steps and test roots, as JSON.
fn exportFacts(c: *src.Context, args: @FieldType(Command, "facts")) !void {
    if (args.zig_exe) |zig| c.zig = zig;
    const snapshot = try facts.read(c.*, c.zig, try std.mem.concat(c.a, []const u8, &.{ args.build_option, args.options }));
    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(c.io, &buffer);
    try facts.write(c.a, snapshot, &out.interface);
    try out.interface.flush();
}

fn environment(env: *std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const value = env.get(key) orelse return null;
    return if (value.len > 0) value else null;
}

/// The modules the package exports, as the build passes them: `--module <name>=<root>`.
fn modules(a: std.mem.Allocator, pairs: []const []const u8) ![]const checks.surface.Module {
    const list = try a.alloc(checks.surface.Module, pairs.len);
    for (list, pairs) |*module, pair| {
        const equals = std.mem.findScalar(u8, pair, '=') orelse return error.InvalidModule;
        module.* = .{ .name = pair[0..equals], .root = pair[equals + 1 ..] };
    }
    return list;
}

/// `surface`: the public surface of the modules the package exports, a line per declaration;
/// with `--since <revision>`, what changed since it: `-` before a line removed or changed, `+`
/// before one added. A release refuses a removed line without a `### Breaking` entry.
fn surfaceCommand(c: *src.Context, args: @FieldType(Command, "surface")) !void {
    const exported = try modules(c.a, args.module);
    var out: std.Io.Writer.Allocating = .init(c.a);
    if (args.since) |since| {
        const gone = try checks.release.surfaceRemoved(c, since, exported);
        const added = try checks.release.surfaceAdded(c, since, exported);
        for (gone) |line| try out.writer.print("- {s}\n", .{line});
        for (added) |line| try out.writer.print("+ {s}\n", .{line});
    } else for (try checks.release.surfaceOf(c, exported)) |line| try out.writer.print("{s}\n", .{line});
    try stdout(c.*, out.written());
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

fn lint(c: *src.Context, gpa: std.mem.Allocator, config: src.Value, sources: []const src.Source, build: checks.glint.assembly.Build, log: checks.phases.Log) !void {
    for (sources) |s| if (s.tree.errors.len > 0) {
        c.fail("{s}: invalid Zig source", .{s.path});
    };
    if (c.errors != 0) return;
    try checks.quality.summary(c, sources, c.summary_path);
    try checks.fuzz.summary(c, sources, config, c.summary_path);
    var timer = stage(c, "glint");
    try checks.glint.check(c, .{ .gpa = gpa, .config = config, .build = build });
    timer.end(c.*, log);
    if (c.errors != 0) return;
    timer = stage(c, "namespace layout");
    try checks.policy.layout(c, sources, config);
    timer.end(c.*, log);
    if (c.errors != 0) return;
    timer = stage(c, "documentation");
    try checks.docs.check(c, config);
    timer.end(c.*, log);
    if (c.errors != 0) return;
    timer = stage(c, "test imports");
    try checks.imports.check(c, sources, config);
    timer.end(c.*, log);
    if (c.errors != 0) return;
    timer = stage(c, "package paths");
    try checks.manifest.paths(c, config);
    timer.end(c.*, log);
    if (c.errors != 0) return;
    for (src.items(src.get(config, "extra_checks"))) |command| {
        const argv = try checks.docs.zigCommand(c.a, c.buildCommand(), command);
        timer = stage(c, try std.mem.join(c.a, " ", argv));
        try checks.command.execute(c.*, argv);
        timer.end(c.*, log);
    }
}

/// Starts the timer of one source check, which `lint` names in the log.
fn stage(c: *src.Context, label: []const u8) checks.phases.Timer {
    c.report("preflight: {s}\n", .{label});
    return .begin(c.*, label);
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
    if (builtin.target.os.tag == .macos) {
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

/// The step that installs a job's external tools: the job's own (`setup` of a declared job,
/// passed as `PREFLIGHT_SETUP_STEP`), or the package's `setup_step`, or none.
fn setupStep(c: src.Context, env: *const std.process.Environ.Map) !?[]const u8 {
    if (env.get("PREFLIGHT_SETUP_STEP")) |step| if (step.len != 0) return step;
    const config = try c.options("ci/workflow.json");
    const step = src.get(config, "setup_step");
    return if (step == .string) step.string else null;
}

fn runGate(context: src.Context, env: *std.process.Environ.Map) !void {
    var c = context;
    // The test runners end a test that runs when the job's time is up, named,
    // before the host cancels the job and says nothing of what ran.
    if (try watchdog.jobDeadline(env)) |deadline| {
        try env.put("PREFLIGHT_DEADLINE", try c.a.print("{d}", .{deadline}));
        c.environ_map = env;
    }
    const step = env.get("STEP") orelse "ci";
    if (std.mem.eql(u8, step, "ci") or std.mem.eql(u8, step, "ci-run"))
        try checks.profile.reset(c, ".zig-cache/preflight-timings");
    const config = try c.options("ci/workflow.json");
    const log = try checks.phases.Log.init(c.a, env);
    if (std.mem.startsWith(u8, step, "preflight-cross")) return crossCompile(c, env, config, std.mem.eql(u8, step, "preflight-cross-bench"));
    if (std.mem.eql(u8, env.get("PREFLIGHT_SETUP") orelse "false", "true")) {
        if (try setupStep(c, env)) |setup_step| if (!std.mem.eql(u8, env.get("PREFLIGHT_PREPARED") orelse "false", "true")) {
            const timer = checks.phases.Timer.begin(c, "install the external tools");
            defer timer.end(c, log);
            try checks.command.retry(c, try std.mem.concat(c.a, []const u8, &.{ c.buildCommand(), &.{setup_step} }));
        };
        const before = src.get(config, "before_tests_step");
        if (before == .string) {
            const timer = checks.phases.Timer.begin(c, "before the tests");
            defer timer.end(c, log);
            try checks.command.execute(c, try std.mem.concat(c.a, []const u8, &.{ c.buildCommand(), &.{before.string} }));
        }
    }
    try buildStep(c, env, log, step, env.get("BUILD_ARGS") orelse "");
}

/// Runs `zig build <step> <build_args>`, or `bay <step> ...` under bay, as the hosted gate does, timed.
fn buildStep(c: src.Context, env: *std.process.Environ.Map, log: checks.phases.Log, step: []const u8, build_args: []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.a, c.buildCommand());
    try argv.append(c.a, step);
    const first_option = argv.items.len;
    var tokens = std.mem.tokenizeAny(u8, build_args, " \t\r\n");
    while (tokens.next()) |token| {
        // The canonical planner may already specify this hosted control.
        // Repeating a boolean turns it into a Zig list, so emit it once.
        if (std.mem.eql(u8, token, "-Dci-bench-smoke=false")) continue;
        try argv.append(c.a, token);
    }
    // Custom legacy steps may not use addCi. Ask the configured compiler
    // graph whether it declares these controls instead of guessing from source.
    {
        const timer = checks.phases.Timer.begin(c, "configure the build");
        defer timer.end(c, log);
        // A flag of the build runner's own (`-fwine`, `-fqemu`) changes no configuration.
        var options: std.ArrayList([]const u8) = .empty;
        for (argv.items[first_option..]) |option_text| if (std.mem.startsWith(u8, option_text, "-D")) try options.append(c.a, option_text);
        const snapshot = try facts.read(c, c.zig, options.items);
        // A test the step runs outside preflight's runner would pass unwatched.
        const outside = try facts.testsOutsideRunner(c.a, snapshot, step);
        for (outside) |name| c.report("preflight: {s}: `{s}` runs it without preflight's runner, so with no watchdog, shard, timing record or riscv64 machine: it joined the tests after addCi read them; add it to them before addCi\n", .{ name, step });
        if (outside.len != 0) return error.TestOutsideRunner;
        for (snapshot.config.available_options) |available_option| {
            const name = available_option.name.slice(&snapshot.config);
            if (std.mem.eql(u8, name, "ci-bench-smoke")) try argv.append(c.a, "-Dci-bench-smoke=false");
            // This program is the checks the build would compile, built from the same commit.
            if (std.mem.eql(u8, name, "ci-checks")) try argv.append(c.a, try c.a.print("-Dci-checks={s}", .{try std.process.executablePathAlloc(c.io, c.a)}));
            // SDK identity is an explicit build option, so Zig configuration caches
            // cannot retain a different runner's SDKROOT environment. A build that
            // does not declare it (a nested package, a custom step) is not asked: Zig
            // refuses an option a build does not know.
            if (std.mem.eql(u8, name, "ci-sdk") and builtin.target.os.tag == .macos) {
                if (env.get("SDKROOT")) |sdk| try argv.append(c.a, try c.a.print("-Dci-sdk={s}", .{sdk}));
            }
        }
    }
    // PREFLIGHT_SHARD reaches the test runners through the environment.
    const timer = checks.phases.Timer.begin(c, try c.a.print("zig build {s}", .{step}));
    defer timer.end(c, log);
    try checks.command.execute(c, argv.items);
}

/// Compiles the targets this job covers, `PREFLIGHT_TARGETS` by name, to
/// objects: one build each, in Debug, and with `bench` the ReleaseFast
/// benchmarks in a second build, timed apart so that a plan can tell the two
/// costs. A name the configuration lacks fails the job, since
/// the generated workflow no longer matches `ci/workflow.json`.
fn crossCompile(c: src.Context, env: *std.process.Environ.Map, config: src.Value, bench: bool) !void {
    const log = try checks.phases.Log.init(c.a, env);
    const wanted = env.get("PREFLIGHT_TARGETS") orelse "";
    var names = std.mem.tokenizeScalar(u8, wanted, ' ');
    var covered: usize = 0;
    const targets = try checks.matrix.fastTargets(c.a, config);
    while (names.next()) |name| {
        var found = false;
        for (targets) |target| {
            if (!std.mem.eql(u8, checks.matrix.targetName(target), name)) continue;
            found = true;
            covered += 1;
            for ([_]struct { step: []const u8, label: []const u8 }{ .{ .step = "ci-check", .label = "compile" }, .{ .step = "ci-check-bench", .label = "benchmarks" } }, 0..) |kind, index| {
                if (index == 1 and !bench) break;
                const argv = try checks.matrix.crossArgs(c.a, c.buildCommand(), config, target, kind.step);
                const timer = checks.phases.Timer.begin(c, try c.a.print("{s} {s}", .{ kind.label, name }));
                defer timer.end(c, log);
                try checks.command.execute(c, argv);
            }
        }
        if (!found) {
            c.report("preflight: {s} is no target of ci/workflow.json; regenerate the workflow\n", .{name});
            return error.UnknownCrossTarget;
        }
    }
    if (covered == 0) return error.MissingCrossTargets;
}
