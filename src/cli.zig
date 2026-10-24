//! preflight's command line: each command, what it takes and its help, read from
//! this declaration by ensign. The build's steps and the generated workflows call
//! these commands with fixed forms (the tests below hold each); a command's own
//! defaults are the hosted job's paths.
const std = @import("std");
const ensign = @import("ensign");
const matrix = @import("checks/matrix.zig");

pub const Cli = struct {
    command: union(enum) {
        plan: Plan,
        generate: Generate,
        facts: Facts,
        lint: Lint,
        surface: Surface,
        gate: Gate,
        setup,
        prepare,
        fetch,
        run,
        skip: Skip,
        attest,
        profile: Profile,
        fuzz_campaign: Campaign,
        unsharded: Unsharded,
        counts: Counts,
        executable: Executable,
        cache: Cache,
        docs: Docs,
        deprecations: Deprecations,
    },

    pub const spec: ensign.Spec(@This()) = .{
        .name = "preflight",
        .about = "CI and checks for Zig packages: the hosted jobs and what a release must pass",
        .description = "A package runs these through its build (bay generate, bay gate, ...), which passes the Zig and the modules it exports; the hosted workflows call the rest.",
        .commands = .{
            .setup = .{ .help = "A hosted job's setup: the macOS SDK and Zig's global cache, written to the job's environment" },
            .prepare = .{ .help = "Run the step that installs the job's external tools, when it has one" },
            .fetch = .{ .help = "Fetch the package's dependencies, retried, for the build arguments in BUILD_ARGS" },
            .run = .{ .help = "Run a hosted job: STEP with BUILD_ARGS, its setup first, timed" },
            .attest = .{ .help = "Record the tier's proof for the commit the job tested" },
        },
    };
};

/// The Zig the build runs, which a command builds and reads the package with.
const zig_exe: ensign.Option = .{ .value_name = "PATH", .hint = .command, .help = "The Zig the package builds with; zig on the path by default" };
/// A module the package exports, as the build passes them, and its `build.zig`.
const module: ensign.Option = .{ .value_name = "NAME=ROOT", .help = "A module the package exports and its root file, repeated: the public surface a release must not break unannounced" };
const working_directory: ensign.Option = .{ .value_name = "DIR", .hint = .directory, .help = "Where the planned jobs run, when not the repository's root (preflight's own gate runs its sample there)" };
const workflow_config: ensign.Option = .{ .value_name = "FILE", .hint = .file, .help = "The workflow configuration; ci/workflow.json of the working directory by default" };
const build_option: ensign.Option = .{ .value_name = "-DNAME=VALUE", .help = "An option the build was configured with, repeated, so the configured graph is the build's" };

const Plan = struct {
    zig_exe: ?[]const u8 = null,
    config: ?[]const u8 = null,
    tier: matrix.Tier = .fast,
    output: ?[]const u8 = null,
    pub const spec: ensign.Spec(@This()) = .{
        .about = "The jobs of a tier as the hosted caller's matrices",
        .options = .{
            .zig_exe = zig_exe,
            .config = .{ .value_name = "FILE", .hint = .file, .help = "The workflow configuration; ci/workflow.json by default" },
            .tier = .{ .help = "The tier whose jobs are planned" },
            .output = .{ .value_name = "FILE", .hint = .file, .help = "Append the matrices to this file; GITHUB_OUTPUT, else standard output, by default" },
        },
    };
};

const Generate = struct {
    zig_exe: ?[]const u8 = null,
    config: ?[]const u8 = null,
    manifest: []const u8 = "build.zig.zon",
    working_directory: ?[]const u8 = null,
    self: bool = false,
    drop: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{
        .about = "The caller workflow made again for the package's pins and configuration, where it is; .github/workflows/ci.yml when there is none",
        .options = .{
            .zig_exe = zig_exe,
            .config = .{ .value_name = "FILE", .hint = .file, .help = "The workflow configuration; the caller's, else ci/workflow.json, by default" },
            .manifest = .{ .value_name = "FILE", .hint = .file, .help = "The manifest whose preflight pin the caller names" },
            .working_directory = working_directory,
            .self = .{ .negatable = false, .help = "preflight's own caller: pinned to the commit under test" },
            .drop = .{ .value_name = "JOB", .help = "A job of the old caller to let go, repeated" },
        },
    };
};

const Facts = struct {
    zig_exe: ?[]const u8 = null,
    build_option: []const []const u8 = &.{},
    options: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{
        .about = "The configured build's modules, steps and test roots, as JSON",
        .options = .{
            .zig_exe = zig_exe,
            .build_option = build_option,
            .options = .{ .positional = true, .raw = true, .value_name = "-DNAME=VALUE", .help = "Further options to configure the build with" },
        },
    };
};

const Lint = struct {
    config: []const u8 = "ci/preflight.json",
    zig_exe: ?[]const u8 = null,
    zig_std: ?[]const u8 = null,
    build_option: []const []const u8 = &.{},
    test_step: []const []const u8 = &.{},
    module: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{
        .about = "The source checks over the repository's files, then the check on the configured build's revisions",
        .options = .{
            .config = .{ .value_name = "FILE", .hint = .file, .help = "The source checks' configuration" },
            .zig_exe = zig_exe,
            .zig_std = .{ .value_name = "DIR", .hint = .directory, .help = "The standard library the package builds with, for the lint's types" },
            .build_option = build_option,
            .module = module,
            .test_step = .{ .value_name = "STEP", .help = "A top-level step CI runs tests under, repeated: a test root is a root file a run under one of them runs; ci by default" },
        },
    };
};

const Surface = struct {
    since: ?[]const u8 = null,
    module: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{
        .about = "The public declarations of the modules the package exports, a line per declaration",
        .options = .{
            .since = .{ .value_name = "REVISION", .help = "What changed since this revision: - before a line removed or changed, + before one added" },
            .module = module,
        },
    };
};

const Gate = struct {
    zig_exe: ?[]const u8 = null,
    config: ?[]const u8 = null,
    working_directory: ?[]const u8 = null,
    module: []const []const u8 = &.{},
    jobs: ?u16 = null,
    pub const spec: ensign.Spec(@This()) = .{
        .about = "What a release needs, then the release tier's jobs this machine runs, each as the hosted job runs it; what it cannot run is named",
        .options = .{ .zig_exe = zig_exe, .config = workflow_config, .working_directory = working_directory, .module = module, .jobs = .{ .short = 'j', .value_name = "N", .help = "Run at most N of the machine's shares of jobs at once, a job under QEMU or ThreadSanitizer taking two; one runs them one after another, streaming each. By default one a core, no more than one for each 4 GiB of memory" } },
    };
};

const Skip = struct {
    config: []const u8 = "ci/preflight.json",
    pub const spec: ensign.Spec(@This()) = .{
        .about = "Whether the change is documentation alone, which a fast run does not test",
        .options = .{ .config = .{ .value_name = "FILE", .hint = .file, .help = "The source checks' configuration, whose documentation a docs-only change is checked against" } },
    };
};

const Profile = struct {
    input: []const u8 = ".preflight-timings",
    durations: []const u8 = "ci/durations.json",
    output: ?[]const u8 = null,
    costs: []const u8 = "ci/costs.json",
    costs_output: ?[]const u8 = null,
    pub const spec: ensign.Spec(@This()) = .{
        .about = "The jobs' timing records summarized: the tests' durations and the phases' costs",
        .options = .{
            .input = .{ .value_name = "DIR", .hint = .directory, .help = "The timing records the jobs left" },
            .durations = .{ .value_name = "FILE", .hint = .file, .help = "The durations so far" },
            .output = .{ .value_name = "FILE", .hint = .file, .help = "Where the durations go; over --durations by default" },
            .costs = .{ .value_name = "FILE", .hint = .file, .help = "The phases' costs so far" },
            .costs_output = .{ .value_name = "FILE", .hint = .file, .help = "Where the costs go; over --costs by default" },
        },
    };
};

const Campaign = struct {
    cache: []const u8,
    cwd: []const u8 = ".",
    build: []const []const u8,
    pub const spec: ensign.Spec(@This()) = .{
        .about = "A fuzzing campaign run and judged on what the fuzzer leaves in the cache",
        .options = .{
            .cache = .{ .value_name = "DIR", .hint = .directory, .help = "The build cache the campaign runs on" },
            .cwd = .{ .value_name = "DIR", .hint = .directory, .help = "Where the campaign's build runs" },
            .build = .{ .positional = true, .raw = true, .value_name = "BUILD", .help = "The campaign's build command, after --: the build, its step and --fuzz=<limit>" },
        },
    };
};

const Unsharded = struct {
    name: []const u8 = "test",
    pub const spec: ensign.Spec(@This()) = .{
        .about = "Fail when the job runs one shard of the tests, which a test runner of the package's own cannot",
        .options = .{ .name = .{ .positional = true, .help = "The test artifact named in the failure" } },
    };
};

const Counts = struct {
    records: []const u8 = ".zig-cache/preflight-counts",
    expect: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{
        .about = "Count the tests per root after the tests' runs, from the records preflight's runner wrote; fail a run with no record or a binary with no test",
        .options = .{
            .records = .{ .value_name = "DIR", .hint = .directory, .help = "Where the runner wrote the records" },
            .expect = .{ .value_name = "NAME", .help = "The record of a root module the tests ran, repeated" },
        },
    };
};

const Executable = struct {
    paths: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{
        .about = "Give downloaded test executables back the permission to run that an artifact upload drops",
        .options = .{ .paths = .{ .positional = true, .value_name = "FILE", .hint = .file } },
    };
};

const Cache = struct {
    path: []const u8 = ".zig-cache",
    cap: usize = 1 << 20,
    pub const spec: ensign.Spec(@This()) = .{
        .about = "Prune compiled products, keeping packages and tools",
        .options = .{
            .path = .{ .value_name = "DIR", .hint = .directory, .help = "The cache pruned" },
            .cap = .{ .value_name = "BYTES", .help = "The size the compiled products are pruned to" },
        },
    };
};

const Docs = struct {
    config: []const u8 = "ci/preflight.json",
    zig_exe: ?[]const u8 = null,
    region: []const u8 = "usage",
    pub const spec: ensign.Spec(@This()) = .{
        .about = "Render a documentation region its configuration names",
        .options = .{
            .config = .{ .value_name = "FILE", .hint = .file, .help = "The configuration naming each region's generator" },
            .zig_exe = zig_exe,
            .region = .{ .positional = true, .help = "The region, as zig build docs -- <region> names it" },
        },
    };
};

const Deprecations = struct {
    std: []const u8,
    write: bool = false,
    paths: []const []const u8 = &.{},
    pub const spec: ensign.Spec(@This()) = .{
        .about = "What this Zig release deprecated, rewritten",
        .options = .{
            .std = .{ .value_name = "DIR", .hint = .directory, .help = "The standard library whose deprecations are read" },
            .write = .{ .negatable = false, .help = "Apply the rewrites" },
            .paths = .{ .positional = true, .value_name = "PATH", .hint = .file, .help = "The files or directories rewritten; the package's sources by default" },
        },
    };
};

/// The command line `args` (after the program's name) as preflight reads it.
fn parsed(arena: std.mem.Allocator, args: []const []const u8) !Cli {
    return switch (try ensign.parse(Cli, arena, args, .{})) {
        .parsed => |cli| cli,
        .help, .version => error.NotACommand,
    };
}

// Each form the build's steps and the generated workflows call, as they call it.
test "plan and generate as the build's steps call them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const generate = (try parsed(arena.allocator(), &.{ "generate", "--zig-exe", "/z/zig", "--self", "--config", "sample/ci/workflow.json", "--working-directory", "sample", "--drop", "a", "--drop", "b" })).command.generate;
    try std.testing.expectEqualStrings("/z/zig", generate.zig_exe.?);
    try std.testing.expect(generate.self);
    try std.testing.expectEqualStrings("sample", generate.working_directory.?);
    try std.testing.expectEqual(2, generate.drop.len);
    try std.testing.expectEqual(.merge, (try parsed(arena.allocator(), &.{ "plan", "--zig-exe", "/z/zig", "--tier", "merge" })).command.plan.tier);
    // The caller is generate's alone.
    try std.testing.expectError(error.UnknownOption, parsed(arena.allocator(), &.{ "plan", "--workflow", ".github/workflows/ci.yml" }));
}

test "facts and lint take the build's configuration, the options keeping their dashes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const facts = (try parsed(arena.allocator(), &.{ "facts", "--zig-exe", "/z/zig", "--build-option", "-Dci-timings=true", "--build-option", "-Dx", "-Dtarget=x86_64-linux" })).command.facts;
    try std.testing.expectEqualStrings("-Dci-timings=true", facts.build_option[0]);
    try std.testing.expectEqualStrings("-Dx", facts.build_option[1]);
    try std.testing.expectEqualStrings("-Dtarget=x86_64-linux", facts.options[0]);
    const lint = (try parsed(arena.allocator(), &.{ "lint", "--config", "ci/preflight.json", "--zig-exe", "/z/zig", "--zig-std", "/z/lib/std", "--test-step", "ci", "--test-step", "profile-tests", "--build-option", "-Doptimize=Debug" })).command.lint;
    try std.testing.expectEqualStrings("/z/lib/std", lint.zig_std.?);
    try std.testing.expectEqualStrings("profile-tests", lint.test_step[1]);
    try std.testing.expectEqualStrings("-Doptimize=Debug", lint.build_option[0]);
}

test "gate, lint and surface take the build's modules before what the user passes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gate = (try parsed(a, &.{ "gate", "--zig-exe", "/z/zig", "--module", "build.zig=build.zig", "--module", "pkg=src/root.zig", "--working-directory", "sample" })).command.gate;
    try std.testing.expectEqual(2, gate.module.len);
    try std.testing.expectEqualStrings("sample", gate.working_directory.?);
    try std.testing.expectEqual(1, (try parsed(a, &.{ "lint", "--zig-exe", "/z/zig", "--module", "build.zig=build.zig" })).command.lint.module.len);
    try std.testing.expectEqualStrings("v0.1.0", (try parsed(a, &.{ "surface", "--module", "build.zig=build.zig", "--since", "v0.1.0" })).command.surface.since.?);
    // Releasing is bay's: preflight only verifies.
    for ([_][]const u8{ "release", "land", "ready", "publish", "version" }) |gone| try std.testing.expectError(error.UnknownCommand, parsed(a, &.{gone}));
}

test "the hosted workflows' commands" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "skip", "attest", "prepare", "run", "fetch", "setup" }) |name| _ = try parsed(a, &.{name});
    const profile = (try parsed(a, &.{ "profile", "--durations", "pkg/ci/durations.json", "--output", ".preflight-timings/durations.json", "--costs", "pkg/ci/costs.json", "--costs-output", ".preflight-timings/costs.json" })).command.profile;
    try std.testing.expectEqualStrings(".preflight-timings", profile.input);
    try std.testing.expectEqualStrings(".preflight-timings/costs.json", profile.costs_output.?);
}

test "the build's helper commands" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const campaign = (try parsed(a, &.{ "fuzz-campaign", "--cache", "/c", "--cwd", "/p", "--", "/z/zig", "build", "unit", "-Dci-hardened=true", "--fuzz=1000" })).command.fuzz_campaign;
    try std.testing.expectEqualStrings("/c", campaign.cache);
    try std.testing.expectEqual(5, campaign.build.len);
    try std.testing.expectEqualStrings("--fuzz=1000", campaign.build[4]);
    try std.testing.expectEqualStrings("tests", (try parsed(a, &.{ "unsharded", "tests" })).command.unsharded.name);
    const counts = (try parsed(a, &.{ "counts", "--records=.zig-cache/preflight-counts", "--expect", "test-macos-Debug", "--expect", "test-macos-Debug-2" })).command.counts;
    try std.testing.expectEqualStrings(".zig-cache/preflight-counts", counts.records);
    try std.testing.expectEqualStrings("test-macos-Debug-2", counts.expect[1]);
    try std.testing.expectEqual(2, (try parsed(a, &.{ "executable", "zig-out/a", "zig-out/b" })).command.executable.paths.len);
    try std.testing.expectEqual(1 << 20, (try parsed(a, &.{ "cache", "--path", ".zig-cache" })).command.cache.cap);
    try std.testing.expectEqualStrings("api", (try parsed(a, &.{ "docs", "--config", "ci/preflight.json", "--zig-exe", "/z/zig", "api" })).command.docs.region);
    try std.testing.expectEqualStrings("usage", (try parsed(a, &.{ "docs", "--config", "ci/preflight.json", "--zig-exe", "/z/zig" })).command.docs.region);
    const deprecations = (try parsed(a, &.{ "deprecations", "--std", "/z/lib/std", "--write", "src" })).command.deprecations;
    try std.testing.expect(deprecations.write);
    try std.testing.expectEqualStrings("src", deprecations.paths[0]);
}
