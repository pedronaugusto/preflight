const std = @import("std");
const src = @import("source.zig");
const keys = @import("keys.zig");
const heldgit = @import("heldgit.zig");
const family = @import("../family.zig");

pub const hosts = [_][]const u8{ "ubuntu-latest", "macos-latest", "windows-latest" };
/// The `shards` keys of `ci/workflow.json`, in `hosts` order.
const host_names = [_][]const u8{ "linux", "macos", "windows" };
/// The runners on ARM the release tier adds, Linux and Windows on aarch64 (the macOS runner is
/// one already), and their `shards` keys.
pub const arm_hosts = [_][]const u8{ "ubuntu-24.04-arm", "windows-11-arm" };
const arm_host_names = [_][]const u8{ "linux_arm", "windows_arm" };
/// The `shards` key of the riscv64 job on its emulated kernel.
const emulated_host_name = "riscv64";
/// The `shards` key of the x86_64 FreeBSD job on its kernel under KVM.
const freebsd_host_name = "freebsd";
/// The `shards` key of the hardened ThreadSanitizer run, several times slower than the suite;
/// the hardened run without it takes the Linux key.
const tsan_name = "tsan";
/// Every `shards` key: a host whose suites run in that many jobs.
pub const shard_hosts = host_names ++ arm_host_names ++ .{ emulated_host_name, freebsd_host_name, tsan_name };
/// Every runner a job may name.
const every_host = hosts ++ arm_hosts;

/// What the last refused configuration got wrong, for the command to print beside the error: the
/// planner is a library, and a test that expects the refusal must not see it logged as a failure.
/// It is the planning thread's own, as the refusal is.
pub threadlocal var problem: []const u8 = "";

/// How much of the gate a run executes, and when. The matrix is fixed: each tier's jobs are
/// what this file names, each suite in the jobs `shards` gives its host, every job within its
/// tier's minutes (`jobMinutes`), and each run within its tier's share of the account's runners
/// (`limits`): a plan past it is refused by name.
pub const Tier = enum {
    /// Every push to main and to a `land/` branch and every pull request, on that exact commit:
    /// the source checks, the Debug suite on Linux, macOS and Windows, an object compile of
    /// every configured target and the package's own jobs that name it, each job within ten
    /// minutes. A `land/` branch fast-forwards main only when it is green.
    ci,
    /// The release tier, on a head a release is cut from, by dispatch: the ci tier's jobs, its
    /// cross job also compiling the ReleaseFast benchmarks and every target in ReleaseSmall, the
    /// ReleaseSafe suite on Linux, macOS and Windows and the ReleaseFast one on Linux, the links
    /// in one job per system, the hardened run and the package's own jobs that name it, each job
    /// within fifteen minutes. A tag needs it green on its commit, and the last nightly run too.
    release,
    /// The heavy legs and the extra runners, nightly: the riscv64 suite on its kernel under QEMU,
    /// FreeBSD's under KVM, ThreadSanitizer, the hardened fuzz run, the fuzz job, the ReleaseFast
    /// suite on macOS and Windows, the Debug suite on the ARM runners and each configured
    /// target's on its runner, the package's own jobs that name it and Zig master, each job
    /// within fifteen minutes.
    nightly,
    /// The fuzz job alone, by dispatch: a session fuzzes a package on GitHub's runners and not on
    /// the machine at hand, for as many minutes as the dispatch says.
    fuzz,
};

/// The minutes a job of `tier` is given, its bound on GitHub.
pub fn jobMinutes(tier: Tier) usize {
    return switch (tier) {
        .ci => 10,
        .release, .nightly, .fuzz => 15,
    };
}

/// The account's runners: twenty jobs at once, five of them on macOS (GitHub Free).
pub const max_jobs = 20;
pub const max_macos_jobs = 5;

/// The most jobs, and macOS jobs, one run of `tier` may ask for. bay keeps six jobs and two
/// macOS ones for landings' ci runs, which a release run must leave them; a ci run is a
/// landing's; the nightly run takes the account when nothing else runs, its Zig master job
/// (zig.yml's `master`) among its twenty.
pub fn limits(tier: Tier) struct { jobs: usize, macos: usize } {
    return switch (tier) {
        .ci => .{ .jobs = 8, .macos = 2 },
        .release => .{ .jobs = max_jobs - 6, .macos = max_macos_jobs - 2 },
        .nightly => .{ .jobs = max_jobs - 1, .macos = max_macos_jobs },
        .fuzz => .{ .jobs = 1, .macos = 0 },
    };
}

/// The most minutes an advisory job's steps but its run take, as zig.yml's gate job budgets
/// them: the two checkouts, the setup, the held git's restore, build and save, the three tools
/// attempts and the report (workflow_test sums them from the workflow). An advisory job never
/// blocks, so it is not held to its tier's minutes.
pub const advisory_overhead_minutes = 115;

pub const Job = struct {
    os: []const u8,
    name: []const u8,
    /// The tests alone (`ci-test`): the source checks run once, in their own job.
    step: []const u8 = "ci-test",
    args: []const u8 = "",
    /// `i/n` when the job runs one shard of its tests.
    shard: []const u8 = "",
    setup: bool = false,
    job_timeout: usize = 15,
    cache_key: []const u8 = "",
    operation: enum { execute, objects, link } = .execute,
    /// The cross targets a compile job covers, by name, space-separated.
    targets: []const u8 = "",
    /// Where a declared job builds, relative to the repository; empty is the package.
    directory: []const u8 = "",
    /// The step that sets up a declared job's external tools, when not the package's `setup_step`.
    prepare: []const u8 = "",
    /// A job of the package's own (`jobs`), which runs as declared.
    declared: bool = false,
    /// A declared job whose result the run shows and does not take (`advisory`): the gate runs
    /// it with `continue-on-error`, and its name says `non-blocking`, as Zig master's does, so
    /// the `runners` job names its failure. Null, and so absent from the matrix, for the rest.
    advisory: ?bool = null,
    /// An advisory job's run step's budget: its declared `timeout`. Its job has that and
    /// `advisory_overhead_minutes` more, so a stalled step ends before the job's bound would
    /// cancel it and conclude the run "failure". Null, and absent from the matrix, for the rest.
    run_timeout: ?usize = null,
    /// The machine the job's tests run on (`-Dci-vm`), whose tools the runner installs.
    machine: Machine = .none,
    /// A job of the package's own that names no runner: the package's on any machine, which
    /// the hosted gate runs on Linux and a gate at hand runs wherever it is.
    any_host: bool = false,
    /// The configured target a test job builds and runs on its runner, when it is not the
    /// runner's own (`ownTargetJobs`); null for the runner's own.
    target: ?[]const u8 = null,
    /// The toolchain the job's runner takes, by its name (`toolchain_names`): the gate downloads
    /// that runner's artifact alone. The caller's matrix sets it (`include`); the plan, whose
    /// jobs are keyed without it, leaves it null.
    toolchain: ?[]const u8 = null,
};

/// A target no hosted runner is, whose tests run on its own kernel under QEMU.
pub const Machine = enum {
    none,
    /// riscv64 Linux, emulated: `qemu-system-riscv64`.
    riscv64,
    /// x86_64 FreeBSD under KVM: `qemu-system-x86_64` and the runner's /dev/kvm.
    freebsd,
};

/// The options of `ci/workflow.json` (keys.zig). Any other key is refused, so a misspelt one
/// cannot quietly change nothing.
const workflow_options = keys.workflow;

/// The minutes the fuzz job fuzzes for, `fuzz_minutes` in the configuration: `max_fuzz_minutes`
/// unless it says, 0 for no fuzz job.
pub fn fuzzMinutes(config: src.Value) !usize {
    const value = src.get(config, "fuzz_minutes");
    if (value == .null) return max_fuzz_minutes;
    if (value != .integer or value.integer < 0 or value.integer > max_fuzz_minutes) {
        problem = comptime std.fmt.comptimePrint("fuzz_minutes: a whole number of minutes from 0 (no fuzz job) to {d}, which leaves a nightly job's {d} minutes room for its build; a longer campaign is a dispatched fuzz run's (`fuzz-minutes`)", .{ max_fuzz_minutes, jobMinutes(.nightly) });
        return error.InvalidFuzzMinutes;
    }
    return @intCast(value.integer);
}

/// The most minutes the planned fuzz job fuzzes for: a nightly job's, less five for its build.
pub const max_fuzz_minutes = jobMinutes(.nightly) - 5;
/// The most minutes a dispatched fuzz run fuzzes for: GitHub's 360, less the 20 its build and
/// last session are given and 10 to spare.
pub const max_dispatched_fuzz_minutes = 330;

/// The fuzz job: the package's properties under the fuzzer for its minutes (`ci-fuzz`), where
/// the build has the step, which it has when the package declares shakedown, and its minutes
/// are not 0. The nightly tier runs it, and a dispatched fuzz run runs it alone. It shares no
/// job: its corpora are its job's.
fn fuzzJob(a: std.mem.Allocator, config: src.Value, tier: Tier) !?Job {
    const budget = try fuzzMinutes(config);
    const fuzzed = src.get(config, "fuzzed");
    if (fuzzed != .null and fuzzed != .bool) return error.InvalidWorkflowConfig;
    if (budget == 0 or fuzzed != .bool or !fuzzed.bool) return null;
    return single(tier, .{
        .os = hosts[0],
        .name = "fuzz",
        .step = "ci-fuzz",
        .args = try a.print("-Dci-lint=false -Dci-bench-smoke=false{s}", .{try buildArgs(a, src.get(config, "build_args"))}),
        .setup = true,
    });
}

fn shardCount(value: src.Value) !usize {
    if (value == .null) return 1;
    if (value != .integer or value.integer < 1) return error.InvalidShardCount;
    return std.math.cast(usize, value.integer) orelse error.InvalidShardCount;
}

fn shardName(a: std.mem.Allocator, index: usize, count: usize) ![]const u8 {
    return if (count > 1) a.print("{d}/{d}", .{ index + 1, count }) else "";
}

/// A field left at null is no field, so a job that sets none is written, and keyed, as it
/// was before the field was.
const job_json: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };

/// `jobs` as a hosted caller's matrix, each naming the toolchain its runner takes.
pub fn include(a: std.mem.Allocator, jobs: []const Job) ![]const u8 {
    const named = try a.dupe(Job, jobs);
    for (named) |*job| job.toolchain = try toolchainName(job.os);
    return std.json.Stringify.valueAlloc(a, .{ .include = named }, job_json);
}

/// The toolchain's names for the hosted runners (`zig build toolchain`'s), in its order.
const toolchain_names = [_]struct { host: []const u8, name: []const u8 }{
    .{ .host = hosts[0], .name = "linux" },
    .{ .host = arm_hosts[0], .name = "linux-arm" },
    .{ .host = hosts[1], .name = "macos" },
    .{ .host = hosts[2], .name = "windows" },
    .{ .host = arm_hosts[1], .name = "windows-arm" },
};

/// The toolchain's name for the runner `host`, which every job's is (`every_host`).
fn toolchainName(host: []const u8) error{UnknownHost}![]const u8 {
    for (toolchain_names) |runner| if (std.mem.eql(u8, runner.host, host)) return runner.name;
    return error.UnknownHost;
}

/// The runners a run of `jobs` takes the toolchain for, as a JSON list in the toolchain's
/// order, which the caller hands the toolchain job's matrix: one job per runner, so the run
/// waits for the slowest build and not for their sum. Those its jobs run on, and Linux, where
/// the run's own jobs run. The ci tier has no ARM job, and builds no ARM toolchain.
pub fn toolchainRunners(a: std.mem.Allocator, jobs: []const Job) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (toolchain_names, 0..) |runner, index| {
        const taken = index == 0 or for (jobs) |job| {
            if (std.mem.eql(u8, job.os, runner.host)) break true;
        } else false;
        if (taken) try names.append(a, runner.name);
    }
    return std.json.Stringify.valueAlloc(a, names.items, .{});
}

/// A job's cache scope: everything that changes what it builds and runs.
fn key(a: std.mem.Allocator, job: Job) ![]const u8 {
    var plain = job;
    plain.cache_key = "";
    const text = try std.json.Stringify.valueAlloc(a, plain, job_json);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
    return a.print("{x}", .{hash[0..8]});
}

/// The optimize modes the gate runs, spelled as `-Doptimize` takes them.
const Mode = std.lang.Optimize;

/// The name a job shows for `mode`.
fn title(mode: Mode) []const u8 {
    return switch (mode) {
        .debug => "Debug",
        .safe => "ReleaseSafe",
        .fast => "ReleaseFast",
        .small => "ReleaseSmall",
    };
}

/// The jobs of `tier`, as the hosted caller's matrix, each as it runs, within the run's bounds
/// (`bounded`).
pub fn plan(a: std.mem.Allocator, config: src.Value, tier: Tier) ![]Job {
    try validate(a, config);
    var jobs: std.ArrayList(Job) = .empty;
    if (tier == .fuzz) {
        if (try fuzzJob(a, config, tier)) |job| try jobs.append(a, job);
    } else try tierJobs(a, config, tier, &jobs);
    for (jobs.items) |*job| job.cache_key = try key(a, job.*);
    if (tier != .fuzz) try bounded(a, tier, jobs.items);
    return jobs.toOwnedSlice(a);
}

/// The jobs of a tier that runs on its own account: ci, release or nightly.
fn tierJobs(a: std.mem.Allocator, config: src.Value, tier: Tier, out: *std.ArrayList(Job)) !void {
    const policy = family.of(src.get(config, family.key)) catch {
        problem = family.refusal;
        return error.UnknownPolicy;
    };
    // Under the family's policy the hardened profile is every package's (aegis's design §7):
    // there is no opting out, and a package with nothing to fuzz says so in its build's
    // profile. Without it a package runs the profile when it says `"hardened": true`.
    const hardened = src.get(config, "hardened");
    if (hardened != .null and hardened != .bool) return error.InvalidHardenedProfile;
    const profiled = switch (policy) {
        .family => if (hardened == .null or hardened.bool) true else return error.InvalidHardenedProfile,
        .adapt => hardened == .bool and hardened.bool,
    };
    switch (tier) {
        .ci => try ciJobs(a, config, out, .ci),
        .release => {
            try ciJobs(a, config, out, .release);
            try releaseJobs(a, config, out);
            if (profiled) try hardenedJobs(a, config, out, .release);
        },
        .nightly => {
            for (hosts[1..], host_names[1..]) |host, host_name| try hostJobs(a, config, out, .nightly, host, host_name, &.{.fast});
            for (arm_hosts, arm_host_names) |host, host_name| try hostJobs(a, config, out, .nightly, host, host_name, &.{.debug});
            try ownTargetJobs(a, config, out);
            try emulatedJobs(a, config, out);
            try freebsdJobs(a, config, out);
            if (profiled) try hardenedJobs(a, config, out, .nightly);
            if (try fuzzJob(a, config, tier)) |job| try out.append(a, job);
        },
        .fuzz => unreachable,
    }
    try declaredJobs(a, config, tier, out);
}

/// The source checks, the Debug suite on Linux, macOS and Windows, an object compile of every
/// configured target and the package's compile in each configuration: what every push and pull
/// request runs, and what the release tier runs first, its source checks at the release bar and
/// its cross job compiling the benchmarks and ReleaseSmall too.
fn ciJobs(a: std.mem.Allocator, config: src.Value, out: *std.ArrayList(Job), tier: Tier) !void {
    try out.append(a, try lintJob(a, config, tier));
    try out.append(a, try snippetsJob(a, config, tier));
    for (hosts, host_names) |host, host_name| try hostJobs(a, config, out, tier, host, host_name, &.{.debug});
    try crossJobs(a, config, out, tier, try src.items(src.get(config, "targets")), tier == .release);
    try configurationJobs(a, config, out, tier);
}

/// What the release tier adds to the ci tier's: the ReleaseSafe suite on Linux, macOS and
/// Windows, so that a gate at hand on any of them proves its own system in the mode a package
/// releases in, the ReleaseFast suite on Linux, and the links.
fn releaseJobs(a: std.mem.Allocator, config: src.Value, out: *std.ArrayList(Job)) !void {
    for (hosts, host_names) |host, host_name| try hostJobs(a, config, out, .release, host, host_name, &.{.safe});
    try hostJobs(a, config, out, .release, hosts[0], host_names[0], &.{.fast});
    try linkJobs(a, config, out);
}

/// The hardened profile's runs, each the suite as the Linux test jobs run it: the safety-on run
/// in the release tier, and the ThreadSanitizer run and the native fuzz campaign, the heavy ones,
/// in the nightly tier. The fuzz campaign is a job of its own: its corpora are its job's.
fn hardenedJobs(a: std.mem.Allocator, config: src.Value, out: *std.ArrayList(Job), tier: Tier) !void {
    const args = try a.print("-Dci-lint=false -Dci-bench-smoke=false{s}", .{try buildArgs(a, src.get(config, "build_args"))});
    const base: Job = .{ .os = hosts[0], .name = "", .args = args, .setup = true };
    if (tier == .release) {
        var job = base;
        job.step = "hardened";
        try suiteJobs(a, out, tier, job, "hardened", try shardsOf(a, config, host_names[0]));
        return;
    }
    var tsan = base;
    tsan.step = "hardened-tsan";
    try suiteJobs(a, out, tier, tsan, "hardened-tsan", try shardsOf(a, config, tsan_name));
    var fuzz = base;
    fuzz.name = "hardened-fuzz";
    fuzz.step = "hardened-fuzz";
    try out.append(a, single(tier, fuzz));
}

/// A suite's jobs, `count` of them, each running its share (`PREFLIGHT_SHARD`) of `base`.
fn suiteJobs(a: std.mem.Allocator, out: *std.ArrayList(Job), tier: Tier, base: Job, name: []const u8, count: usize) !void {
    for (0..count) |i| {
        const shard = try shardName(a, i, count);
        var job = base;
        job.name = try a.print("{s}{s}{s}", .{ name, if (count > 1) " shard " else "", shard });
        job.shard = shard;
        job.job_timeout = jobMinutes(tier);
        try out.append(a, job);
    }
}

/// One job that runs whole, held to its tier's minutes.
fn single(tier: Tier, job: Job) Job {
    var each = job;
    each.job_timeout = jobMinutes(tier);
    return each;
}

/// Refuses a run of more jobs, or macOS jobs, than its tier's `limits`, naming each runner's.
fn bounded(a: std.mem.Allocator, tier: Tier, jobs: []const Job) !void {
    const limit = limits(tier);
    var macos: usize = 0;
    for (jobs) |job| if (std.mem.eql(u8, job.os, hosts[1])) {
        macos += 1;
    };
    if (jobs.len <= limit.jobs and macos <= limit.macos) return;
    var each: std.Io.Writer.Allocating = .init(a);
    for (every_host) |host| {
        var count: usize = 0;
        for (jobs) |job| if (std.mem.eql(u8, job.os, host)) {
            count += 1;
        };
        if (count != 0) try each.writer.print("{s}{s} {d}", .{ if (each.written().len == 0) "" else ", ", host, count });
    }
    problem = if (jobs.len > limit.jobs)
        try a.print("the {t} tier asks for {d} jobs ({s}), more than the {d} a {t} run may of the account's {d}; lower a host's `shards`, or move a job of the package's own to another tier", .{ tier, jobs.len, each.written(), limit.jobs, tier, max_jobs })
    else
        try a.print("the {t} tier asks for {d} macOS jobs, more than the {d} a {t} run may of the account's {d}; lower `shards.macos`, or move a macOS job of the package's own to another tier", .{ tier, macos, limit.macos, tier, max_macos_jobs });
    return error.TooManyJobs;
}

/// The package's own jobs, `jobs` in `ci/workflow.json`: each a build step run on the
/// hosts and in the tiers it names (Linux, and the ci and release tiers, unless it says),
/// with the gate's setup, caches and toolchain, so a run waits for it like any other job
/// of the gate.
///
///     {"name": "conformance", "step": "test", "directory": "conformance",
///      "os": ["ubuntu-latest", "macos-latest"], "tiers": ["ci", "release"],
///      "args": ["-Dsuite=full"], "setup": true, "timeout": 10, "shards": 2}
///
/// `shards` splits a test step over that many jobs per host, as the hosts' own test jobs are
/// split: each runs the share `PREFLIGHT_SHARD` names, by its tests' names. `timeout` is at
/// most the minutes of each tier it runs in (its own, when shorter).
fn declaredJobs(a: std.mem.Allocator, config: src.Value, tier: Tier, out: *std.ArrayList(Job)) !void {
    const declared = src.get(config, "jobs");
    if (declared == .null) return;
    if (declared != .array) return error.InvalidDeclaredJob;
    var names: std.ArrayList([]const u8) = .empty;
    for (declared.array.items) |entry| {
        if (entry != .object) return error.InvalidDeclaredJob;
        for (entry.object.keys()) |key_name| {
            for ([_][]const u8{ "name", "step", "os", "tiers", "args", "directory", "setup", "timeout", "shards", "advisory" }) |known| {
                if (std.mem.eql(u8, key_name, known)) break;
            } else {
                problem = key_name;
                return error.InvalidDeclaredJob;
            }
        }
        const name = try field(entry, "name", null);
        const step = try field(entry, "step", null);
        for (names.items) |known| if (std.mem.eql(u8, known, name)) return error.DuplicateDeclaredJob;
        try names.append(a, name);
        const directory = try field(entry, "directory", "");
        if (directory.len != 0) try relativeDirectory(directory);
        const marked = src.get(entry, "advisory");
        if (marked != .null and marked != .bool) {
            problem = try a.print("jobs: {s}: advisory is true or false", .{name});
            return error.InvalidDeclaredJob;
        }
        const advisory = marked == .bool and marked.bool;
        var wanted = false;
        var tiers_named: std.ArrayList(Tier) = .empty;
        const tiers = src.get(entry, "tiers");
        if (tiers == .null) {
            try tiers_named.appendSlice(a, &.{ .ci, .release });
        } else {
            if (tiers != .array or tiers.array.items.len == 0) return error.InvalidDeclaredJob;
            for (tiers.array.items) |item| {
                const text = try src.string(item, "");
                const each = std.meta.stringToEnum(Tier, text) orelse .fuzz;
                // The fuzz tier is the fuzz job's alone.
                if (each == .fuzz) {
                    problem = try a.print("jobs: {s}: `{s}` is no tier a job of the package's own runs in: ci, release or nightly", .{ name, text });
                    return error.InvalidDeclaredJob;
                }
                try tiers_named.append(a, each);
            }
        }
        for (tiers_named.items) |each| wanted = wanted or each == tier;
        const setup = src.get(entry, "setup");
        if (setup != .null and setup != .bool and setup != .string) return error.InvalidDeclaredJob;
        const count = shardCount(src.get(entry, "shards")) catch return error.InvalidDeclaredJob;
        const given = src.get(entry, "timeout");
        if (given != .null and (given != .integer or given.integer < 1 or given.integer > 360)) return error.InvalidJobTimeout;
        const declared_timeout: ?usize = if (given == .integer) @intCast(given.integer) else null;
        // An advisory job's run is held to its own timeout, its tier's minutes unless it says.
        const advisory_timeout = declared_timeout orelse jobMinutes(tier);
        if (advisory and advisory_timeout + advisory_overhead_minutes > 360) {
            problem = try a.print("jobs: {s}: an advisory job's timeout is at most {d} minutes, which leaves its other steps' {d} within GitHub's 360", .{ name, 360 - advisory_overhead_minutes, advisory_overhead_minutes });
            return error.InvalidDeclaredJob;
        }
        if (!advisory) if (declared_timeout) |minutes_given| for (tiers_named.items) |each| if (minutes_given > jobMinutes(each)) {
            problem = try a.print("jobs: {s}: its timeout, {d} minutes, is more than a {t} job's {d}: raise its shards, or name another tier", .{ name, minutes_given, each, jobMinutes(each) });
            return error.InvalidJobTimeout;
        };
        const hosted = src.get(entry, "os");
        const systems: []const src.Value = if (hosted == .null) &.{.{ .string = hosts[0] }} else if (hosted == .array and hosted.array.items.len != 0) hosted.array.items else return error.InvalidDeclaredJob;
        for (systems) |system| {
            const os = try src.string(system, "");
            for (every_host) |known| {
                if (std.mem.eql(u8, known, os)) break;
            } else return error.InvalidDeclaredJob;
            if (!wanted) continue;
            const hosted_name = if (systems.len > 1) try a.print("{s} ({s})", .{ name, os }) else name;
            for (0..count) |i| {
                const shard = try shardName(a, i, count);
                const named = if (count > 1) try a.print("{s} shard {s}", .{ hosted_name, shard }) else hosted_name;
                const job: Job = .{
                    .os = os,
                    .name = if (advisory) try a.print("{s} (non-blocking)", .{named}) else named,
                    .advisory = if (advisory) true else null,
                    .step = step,
                    .args = std.mem.trimStart(u8, try buildArgs(a, src.get(entry, "args")), " "),
                    .shard = shard,
                    .setup = setup != .bool or setup.bool,
                    .prepare = if (setup == .string) setup.string else "",
                    .job_timeout = if (advisory) advisory_timeout + advisory_overhead_minutes else @min(declared_timeout orelse jobMinutes(tier), jobMinutes(tier)),
                    .run_timeout = if (advisory) advisory_timeout else null,
                    .directory = directory,
                    .declared = true,
                    .any_host = hosted == .null,
                };
                try out.append(a, job);
            }
        }
    }
}

/// The string `field` of `entry`: `fallback` when absent, or an error when it is
/// required (null fallback), empty, or holds a space or control byte.
fn field(entry: src.Value, name: []const u8, fallback: ?[]const u8) ![]const u8 {
    const value = src.get(entry, name);
    if (value == .null) return fallback orelse error.InvalidDeclaredJob;
    if (value != .string or value.string.len == 0) return error.InvalidDeclaredJob;
    for (value.string) |byte| if (byte < 32 or byte == 127 or (byte == ' ' and !std.mem.eql(u8, name, "name"))) return error.InvalidDeclaredJob;
    return value.string;
}

/// A directory below the repository root, written with `/`.
fn relativeDirectory(path: []const u8) !void {
    if (std.mem.eql(u8, path, ".")) return;
    if (std.Io.Dir.path.isAbsolute(path) or std.mem.findScalar(u8, path, '\\') != null) return error.InvalidDeclaredJob;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".git")) return error.InvalidDeclaredJob;
    }
}

/// The package's own compile (`compile_step`, `check` by default) in each configuration
/// `configurations` declares, by its name: a configuration's options reach the package's
/// tests, helpers and benchmarks only in a build of the package given them, so each is
/// compiled once, as the consumer check builds a consumer in each. The build checks each
/// entry against the options it declares; here each is read as the job's arguments.
fn configurationJobs(a: std.mem.Allocator, config: src.Value, out: *std.ArrayList(Job), tier: Tier) !void {
    const declared = src.get(config, "configurations");
    if (declared == .null) return;
    if (declared != .array or declared.array.items.len == 0) return error.InvalidConfigurations;
    const compile = try src.string(src.get(config, "compile_step"), "check");
    for (declared.array.items) |entry| {
        const name = src.get(entry, "name");
        if (name != .string or name.string.len == 0) return error.InvalidConfigurations;
        for (name.string) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') {
            problem = name.string;
            return error.InvalidConfigurations;
        };
        var args: std.Io.Writer.Allocating = .init(a);
        const options = src.get(entry, "options");
        if (options != .null and options != .object) return error.InvalidConfigurations;
        if (options == .object) for (options.object.keys(), options.object.values()) |option, value| {
            switch (value) {
                .bool => |flag| try args.writer.print(" -D{s}={}", .{ option, flag }),
                .integer => |count| try args.writer.print(" -D{s}={d}", .{ option, count }),
                .string => |text| {
                    // The job's arguments are split at whitespace.
                    if (text.len == 0 or std.mem.findAny(u8, text, " \t\r\n") != null) return error.InvalidConfigurations;
                    try args.writer.print(" -D{s}={s}", .{ option, text });
                },
                else => return error.InvalidConfigurations,
            }
        };
        try out.append(a, single(tier, .{
            .os = hosts[0],
            .name = try a.print("{s} ({s})", .{ compile, name.string }),
            .step = compile,
            .args = std.mem.trimStart(u8, try a.print("-Dci-lint=false{s}{s}", .{ args.written(), try buildArgs(a, src.get(config, "build_args")) }), " "),
        }));
    }
}

/// The test jobs of one host: each mode's suite, in the jobs `shards.<host>` gives it.
fn hostJobs(a: std.mem.Allocator, config: src.Value, out: *std.ArrayList(Job), tier: Tier, host: []const u8, host_name: []const u8, modes: []const Mode) !void {
    for (modes) |mode| {
        const name = try a.print("test ({s}, {s})", .{ host, title(mode) });
        const base: Job = .{
            .os = host,
            .name = name,
            .args = try a.print("-Doptimize={t} -Dci-lint=false{s}", .{ mode, try buildArgs(a, src.get(config, "build_args")) }),
            .setup = true,
        };
        try suiteJobs(a, out, tier, base, name, try shardsOf(a, config, host_name));
    }
}

/// The Debug suite on riscv64 Linux, which no hosted runner is: built for it on the Linux
/// runner, static with musl, and run on a riscv64 Linux kernel QEMU emulates (`-Dci-vm`), so
/// that what a kernel does (reaping, pidfds, io_uring, file maps) is a kernel's, not a
/// user-mode emulator's. Emulated, a suite takes several times as long as on a runner:
/// `shards.riscv64` splits it.
fn emulatedJobs(a: std.mem.Allocator, config: src.Value, out: *std.ArrayList(Job)) !void {
    const name = "test (riscv64-linux on its kernel under QEMU, Debug)";
    const base: Job = .{
        .os = hosts[0],
        .name = name,
        .args = try a.print("-Doptimize=debug -Dci-lint=false -Dtarget=riscv64-linux-musl -Dci-vm{s}", .{try buildArgs(a, src.get(config, "build_args"))}),
        .setup = true,
        .machine = .riscv64,
    };
    try suiteJobs(a, out, .nightly, base, name, try shardsOf(a, config, emulated_host_name));
}

/// The jobs a host's suites run in: `shards.<host>`, a count of at least one, or one where the
/// package says none. preflight 0.20.0 removed the floor and cap objects, with the record that
/// sized a count between them.
fn shardsOf(a: std.mem.Allocator, config: src.Value, host: []const u8) !usize {
    const value = src.get(src.get(config, "shards"), host);
    if (value == .object) {
        problem = try a.print("shards.{s}: preflight 0.20.0 removed the floor and cap objects (CHANGELOG): the count is a number of jobs, `\"{s}\": 2`", .{ host, host });
        return error.InvalidShardCount;
    }
    return shardCount(value) catch {
        problem = try a.print("shards.{s}: a number of jobs, at least 1", .{host});
        return error.InvalidShardCount;
    };
}

/// The Debug suite on x86_64 FreeBSD, which no hosted runner is: built for it on the Linux
/// runner and run on FreeBSD's own kernel under KVM (`-Dci-vm`), so that what a package
/// claims of FreeBSD (kqueue, its sockets and kernel TLS) has a kernel's evidence, not a
/// cross-compile's.
fn freebsdJobs(a: std.mem.Allocator, config: src.Value, out: *std.ArrayList(Job)) !void {
    const name = "test (x86_64-freebsd on its kernel under KVM, Debug)";
    const base: Job = .{
        .os = hosts[0],
        .name = name,
        .args = try a.print("-Doptimize=debug -Dci-lint=false -Dtarget=x86_64-freebsd -Dci-vm{s}", .{try buildArgs(a, src.get(config, "build_args"))}),
        .setup = true,
        .machine = .freebsd,
    };
    try suiteJobs(a, out, .nightly, base, name, try shardsOf(a, config, freebsd_host_name));
}

/// The hosted runners by the system and architecture each one is, and its `shards` key.
const runners = [_]struct { os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch, host: []const u8, name: []const u8 }{
    .{ .os = .linux, .arch = .x86_64, .host = hosts[0], .name = host_names[0] },
    .{ .os = .macos, .arch = .aarch64, .host = hosts[1], .name = host_names[1] },
    .{ .os = .windows, .arch = .x86_64, .host = hosts[2], .name = host_names[2] },
    .{ .os = .linux, .arch = .aarch64, .host = arm_hosts[0], .name = arm_host_names[0] },
    .{ .os = .windows, .arch = .aarch64, .host = arm_hosts[1], .name = arm_host_names[1] },
};

/// The Debug suite of each configured target a hosted runner executes as it is, but whose
/// ABI is not the runner's own: msvc on the Windows runners, musl on the Linux ones. Built
/// and run there (`-Dtarget`), in the runner's shards, so a target a package ships on is a
/// suite's evidence, not only a link's. The runner's own ABI (gnu, and macOS's one) is its
/// test jobs'. The nightly tier's, as the ARM runners are.
fn ownTargetJobs(a: std.mem.Allocator, config: src.Value, out: *std.ArrayList(Job)) !void {
    for (try src.items(src.get(config, "targets"))) |target| {
        const name = try targetName(target);
        const query = std.Target.Query.parse(.{ .arch_os_abi = name }) catch return error.InvalidCrossTarget;
        const abi = query.abi orelse continue;
        const runner = for (runners) |runner| {
            if (query.os_tag == runner.os and query.cpu_arch == runner.arch) break runner;
        } else continue;
        if (runner.os == .macos or abi == .gnu) continue;
        var options: std.Io.Writer.Allocating = .init(a);
        defer options.deinit();
        for (try crossOptions(a, config, target)) |arg| try options.writer.print(" {s}", .{arg});
        const suite = try a.print("test ({s} on {s}, Debug)", .{ name, runner.host });
        const base: Job = .{
            .os = runner.host,
            .name = suite,
            .args = try a.print("-Doptimize=debug{s}", .{options.written()}),
            .setup = true,
            .target = name,
        };
        try suiteJobs(a, out, .nightly, base, suite, try shardsOf(a, config, runner.name));
    }
}

/// The source checks: format, structure, the code rules, layout and the package's own extra
/// checks. Nothing in them runs a test, so they need neither the external tools nor a test
/// build. The release tier's (`-Dci-release`) fail on every aegis-pack finding; a landing's
/// report the flow rules'.
fn lintJob(a: std.mem.Allocator, config: src.Value, tier: Tier) !Job {
    return single(tier, .{
        .os = hosts[0],
        .name = "source checks",
        .step = "lint",
        .args = std.mem.trimStart(u8, try a.print("{s}{s}", .{ if (tier == .release) " -Dci-release" else "", try buildArgs(a, src.get(config, "build_args")) }), " "),
    });
}

/// The documented snippets, a leg of their own: a red lint, or one that refuses its
/// configuration, never hides a broken snippet.
fn snippetsJob(a: std.mem.Allocator, config: src.Value, tier: Tier) !Job {
    return single(tier, .{
        .os = hosts[0],
        .name = "documented snippets",
        .step = "snippets",
        .args = std.mem.trimStart(u8, try buildArgs(a, src.get(config, "build_args")), " "),
    });
}

/// The target a `targets` entry names: a triple, or an object's `target`.
pub fn targetName(target: src.Value) src.TypeError![]const u8 {
    return if (target == .string) target.string else try src.string(src.get(target, "target"), "");
}

/// The object compile of `targets`, in as many jobs as `cross_jobs` asks for, one where it says
/// nothing: the targets dealt in their order, the first to the first job. With `release`, each
/// job also compiles the ReleaseFast benchmarks and the targets in ReleaseSmall.
fn crossJobs(a: std.mem.Allocator, config: src.Value, out: *std.ArrayList(Job), tier: Tier, targets: []const src.Value, release: bool) !void {
    if (targets.len == 0) return;
    const wanted = src.get(config, "cross_jobs");
    if (wanted != .null and (wanted != .integer or wanted.integer < 1)) return error.InvalidCrossJobs;
    const count = if (wanted == .null) 1 else @min(std.math.cast(usize, wanted.integer) orelse return error.InvalidCrossJobs, targets.len);
    for (0..count) |group| {
        var names: std.ArrayList(u8) = .empty;
        for (targets, 0..) |target, index| if (index % count == group) {
            if (names.items.len > 0) try names.append(a, ' ');
            try names.appendSlice(a, try targetName(target));
        };
        try out.append(a, single(tier, .{
            .os = hosts[0],
            .name = try a.print("Cross compile{s}{s}", .{ if (count > 1) " " else "", try shardName(a, group, count) }),
            .step = if (release) "preflight-cross-release" else "preflight-cross",
            .operation = .objects,
            .targets = names.items,
        }));
    }
}

/// The targets a cross-compile job may name: the configured ones, and
/// the macOS and Windows targets, which `zig build check` compiles on any host.
pub fn fastTargets(a: std.mem.Allocator, config: src.Value) ![]src.Value {
    try validate(a, config);
    var targets: std.ArrayList(src.Value) = .empty;
    try targets.appendSlice(a, try src.items(src.get(config, "targets")));
    for ([_][]const u8{ "aarch64-macos", "x86_64-windows-gnu" }) |native| {
        var found = false;
        for (targets.items) |target| {
            if (std.mem.eql(u8, try targetName(target), native)) found = true;
        }
        if (!found) try targets.append(a, .{ .string = native });
    }
    return targets.items;
}

fn validate(a: std.mem.Allocator, config: src.Value) !void {
    if (config != .object) return error.InvalidWorkflowConfig;
    _ = heldgit.parse(config) catch |err| {
        problem = heldgit.problem;
        return err;
    };
    for (config.object.keys()) |name| {
        for (workflow_options) |known| {
            if (std.mem.eql(u8, name, known)) break;
        } else {
            problem = try a.print("`{s}` is not a key of this file{s}", .{ name, try keys.hint(a, .workflow, name) });
            return error.UnknownWorkflowOption;
        }
    }
    _ = try fuzzMinutes(config);
    for ([_][]const u8{ "compile_step", "setup_step", "before_tests_step" }) |name| {
        const value = src.get(config, name);
        if (value != .null and (value != .string or value.string.len == 0 or std.mem.findAny(u8, value.string, " \t\r\n") != null)) return error.InvalidWorkflowStep;
    }
    const targets = src.get(config, "targets");
    if (targets != .null and targets != .array) return error.InvalidCrossTargets;
    for (try src.items(targets)) |target| _ = try crossOptions(a, config, target);
    _ = try validatedArgs(a, src.get(config, "build_args"));
    const shards = src.get(config, "shards");
    if (shards != .null and shards != .object) return error.InvalidShardCount;
    for (shard_hosts) |host| _ = try shardsOf(a, config, host);
    if (shards == .object) for (shards.object.keys()) |host| {
        for (shard_hosts) |known| {
            if (std.mem.eql(u8, known, host)) break;
        } else {
            problem = try a.print("shards: `{s}` is no host", .{host});
            return error.InvalidShardCount;
        }
    };
}

/// The links of the configured targets that need a system's SDK or linker, one job per system:
/// Windows' on the Windows runner, and macOS's on a Mac when one of them links a framework, else
/// on Linux (Zig links any other macOS program there with the libSystem it ships).
fn linkJobs(a: std.mem.Allocator, config: src.Value, out: *std.ArrayList(Job)) !void {
    var windows: std.ArrayList(u8) = .empty;
    var macos: std.ArrayList(u8) = .empty;
    var framework = false;
    for (try src.items(src.get(config, "targets"))) |target| {
        const name = try targetName(target);
        _ = try crossOptions(a, config, target);
        const query = std.Target.Query.parse(.{ .arch_os_abi = name }) catch return error.InvalidCrossTarget;
        const list = switch (query.os_tag orelse return error.InvalidCrossTarget) {
            .macos => list: {
                framework = framework or try linksFramework(a, config, name);
                break :list &macos;
            },
            .windows => &windows,
            else => continue,
        };
        if (list.items.len != 0) try list.append(a, ' ');
        try list.appendSlice(a, name);
    }
    if (windows.items.len != 0) try out.append(a, single(.release, .{ .os = hosts[2], .name = "SDK link (Windows)", .step = "preflight-link", .targets = windows.items, .setup = true, .operation = .link }));
    if (macos.items.len != 0) {
        const host = if (framework) hosts[1] else hosts[0];
        try out.append(a, single(.release, .{ .os = host, .name = if (framework) "SDK link (macOS)" else "link (macOS)", .step = "preflight-link", .targets = macos.items, .setup = true, .operation = .link }));
    }
}

/// Whether the build for the macOS target `name` links a framework, as `sdk_targets` says.
/// A configuration that does not say, one not read with its build, keeps the link on a Mac.
fn linksFramework(a: std.mem.Allocator, config: src.Value, name: []const u8) !bool {
    const listed = src.get(config, "sdk_targets");
    if (listed == .null) return true;
    if (listed != .array) return error.InvalidSdkTargets;
    for (try src.strings(a, listed)) |target| if (std.mem.eql(u8, target, name)) return true;
    return false;
}

fn validatedArgs(a: std.mem.Allocator, value: src.Value) ![]const []const u8 {
    if (value == .null) return &.{};
    if (value != .array) return error.InvalidBuildArgs;
    const args = try src.strings(a, value);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-Dci-timings") or std.mem.startsWith(u8, arg, "-Dci-timings=")) {
            problem = "-Dci-timings: preflight 0.20.0 removed it (CHANGELOG): a hosted job asks its tests' timings itself (`PREFLIGHT_TIMINGS`), and a build that is passed it refuses it; drop it";
            return error.InvalidBuildArgs;
        }
        if (!std.mem.startsWith(u8, arg, "-D") or std.mem.startsWith(u8, arg, "-Dtarget=") or std.mem.startsWith(u8, arg, "-Dcpu=")) return error.InvalidBuildArgs;
        for (arg) |byte| if (std.ascii.isWhitespace(byte) or byte < 32) return error.InvalidBuildArgs;
    }
    return args;
}

fn buildArgs(a: std.mem.Allocator, value: src.Value) ![]const u8 {
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    for (try validatedArgs(a, value)) |arg| try text.writer.print(" {s}", .{arg});
    return text.toOwnedSlice();
}

/// The command that makes the objects of `target` in `optimize` (`debug`, or `small` for the
/// release tier's ReleaseSmall compile): the build's `step`, `ci-check`, or `ci-check-bench`
/// for the ReleaseFast benchmarks.
pub fn crossArgs(a: std.mem.Allocator, command: []const []const u8, config: src.Value, target: src.Value, step: []const u8, optimize: []const u8, jobs: ?u32) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, command);
    try args.append(a, step);
    try args.appendSlice(a, try crossOptions(a, config, target));
    try args.append(a, try a.print("-Doptimize={s}", .{optimize}));
    // The build that runs this one may be held to fewer jobs than the machine has cores, and
    // Zig reads `-j` after the build script, so it reaches no step: `PREFLIGHT_JOBS` carries it.
    if (jobs) |count| try args.append(a, try a.print("-j{d}", .{count}));
    return args.toOwnedSlice(a);
}

/// The jobs a build preflight starts may run at once, as `PREFLIGHT_JOBS` says: a positive
/// count, or null for Zig's own default when it is unset. Anything else is refused.
pub fn jobsFrom(environ: *const std.process.Environ.Map) error{InvalidJobs}!?u32 {
    const text = environ.get("PREFLIGHT_JOBS") orelse return null;
    // A job the plan sizes none for is given the variable empty.
    if (text.len == 0) return null;
    const count = std.fmt.parseUnsigned(u32, text, 10) catch return error.InvalidJobs;
    if (count == 0) return error.InvalidJobs;
    return count;
}

/// The build options that make a build target `target`: lint off, the target
/// and CPU, and the caller's flags.
pub fn crossOptions(a: std.mem.Allocator, config: src.Value, target: src.Value) ![]const []const u8 {
    const name = try targetName(target);
    if (name.len == 0) return error.InvalidCrossTarget;
    const cpu = src.get(target, "cpu");
    _ = std.Target.Query.parse(.{ .arch_os_abi = name, .cpu_features = if (cpu == .string) cpu.string else null }) catch return error.InvalidCrossTarget;
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(a, "-Dci-lint=false");
    try args.append(a, try a.print("-Dtarget={s}", .{name}));
    if (cpu != .null and cpu != .string) return error.InvalidCrossCpu;
    if (cpu == .string) {
        if (cpu.string.len == 0) return error.InvalidCrossCpu;
        for (cpu.string) |byte| if (std.ascii.isWhitespace(byte) or byte < 32) return error.InvalidCrossCpu;
        try args.append(a, try a.print("-Dcpu={s}", .{cpu.string}));
    }
    for ([_]src.Value{ src.get(config, "build_args"), src.get(target, "args") }) |values| {
        try args.appendSlice(a, try validatedArgs(a, values));
    }
    return args.toOwnedSlice(a);
}

fn parseJson(a: std.mem.Allocator, text: []const u8) !src.Value {
    return (try std.json.parseFromSlice(src.Value, a, text, .{})).value;
}

/// A job's name without its shard.
fn baseName(name: []const u8) []const u8 {
    return name[0 .. std.mem.find(u8, name, " shard ") orelse name.len];
}

/// The names of `jobs` without their shards, each once, sorted.
fn baseNames(a: std.mem.Allocator, jobs: []const Job) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (jobs) |job| {
        const name = baseName(job.name);
        for (out.items) |seen| {
            if (std.mem.eql(u8, seen, name)) break;
        } else try out.append(a, name);
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn before(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.before);
    return out.items;
}

fn expectNames(a: std.mem.Allocator, jobs: []const Job, want: []const []const u8) !void {
    const sorted = try a.dupe([]const u8, want);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn before(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.before);
    const got = try baseNames(a, jobs);
    try std.testing.expectEqual(sorted.len, got.len);
    for (sorted, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

/// How many of `jobs` are named `name` less their shard.
fn jobsNamed(jobs: []const Job, name: []const u8) usize {
    var n: usize = 0;
    for (jobs) |job| n += @intFromBool(std.mem.eql(u8, baseName(job.name), name));
    return n;
}

test "every job of a tier ends within its minutes: ten in ci, fifteen in release and nightly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a, "{\"policy\":\"family\",\"fuzzed\":true,\"targets\":[\"aarch64-linux-gnu\",\"x86_64-windows-msvc\",\"x86_64-linux-musl\"],\"configurations\":[{\"name\":\"plain\"}],\"jobs\":[{\"name\":\"own\",\"step\":\"own\",\"tiers\":[\"ci\",\"release\",\"nightly\"]}]}");
    for ([_]Tier{ .ci, .release, .nightly, .fuzz }) |tier| {
        for (try plan(a, config, tier)) |job| try std.testing.expectEqual(jobMinutes(tier), job.job_timeout);
    }
    try std.testing.expectEqual(@as(usize, 10), jobMinutes(.ci));
    try std.testing.expectEqual(@as(usize, 15), jobMinutes(.release));
    // No job passes a test timeout: the watchdog bounds each test.
    for (try plan(a, config, .release)) |job| try std.testing.expect(std.mem.find(u8, job.args, "test-timeout") == null);
}

test "the ci tier is the source checks, the Debug suite on Linux, macOS and Windows, the targets' objects and the configurations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a, "{\"cross_jobs\":1,\"targets\":[\"aarch64-linux-gnu\"],\"hardened\":true,\"fuzzed\":true,\"configurations\":[{\"name\":\"plain\"}]}");
    const jobs = try plan(a, config, .ci);
    try expectNames(a, jobs, &.{ "source checks", "documented snippets", "test (ubuntu-latest, Debug)", "test (macos-latest, Debug)", "test (windows-latest, Debug)", "Cross compile", "check (plain)" });
    for (jobs) |job| {
        if (std.mem.startsWith(u8, job.name, "test (")) {
            try std.testing.expectEqualStrings("ci-test", job.step);
            try std.testing.expectEqualStrings("-Doptimize=debug -Dci-lint=false", job.args);
            try std.testing.expect(job.operation == .execute);
        }
        if (std.mem.eql(u8, job.name, "Cross compile")) {
            try std.testing.expectEqualStrings("preflight-cross", job.step);
            try std.testing.expectEqualStrings("aarch64-linux-gnu", job.targets);
        }
        // SDK links, benchmarks, the hardened runs and the fuzz job are the other tiers'.
        try std.testing.expect(!std.mem.startsWith(u8, job.step, "hardened"));
        try std.testing.expect(!std.mem.eql(u8, job.step, "ci-link"));
        try std.testing.expect(!std.mem.eql(u8, job.step, "ci-fuzz"));
        try std.testing.expect(job.machine == .none);
        // The source checks job owns lint; no other job repeats it.
        if (!std.mem.eql(u8, job.step, "lint") and job.setup) try std.testing.expect(std.mem.find(u8, job.args, "-Dci-lint=false") != null);
    }
    for (jobs, 0..) |x, i| for (jobs[i + 1 ..]) |y| try std.testing.expect(!std.mem.eql(u8, x.cache_key, y.cache_key));
    // The ci tier's Linux Debug and the release tier's are one suite, as one job runs it.
    for (try plan(a, config, .release)) |job| if (std.mem.eql(u8, baseName(job.name), "test (ubuntu-latest, Debug)")) {
        try std.testing.expectEqualStrings(jobs[2].args, job.args);
    };
}

test "the release tier is the ci tier's jobs, ReleaseSafe on every runner, ReleaseFast on Linux, the links and the hardened run, and none of the heavy legs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a, "{\"targets\":[\"aarch64-linux-gnu\",\"x86_64-windows-gnu\"],\"sdk_targets\":[],\"policy\":\"family\",\"fuzzed\":true}");
    const jobs = try plan(a, config, .release);
    try expectNames(a, jobs, &.{
        "source checks",                      "documented snippets",
        "test (ubuntu-latest, Debug)",        "test (macos-latest, Debug)",
        "test (windows-latest, Debug)",       "Cross compile",
        "test (ubuntu-latest, ReleaseSafe)",  "test (macos-latest, ReleaseSafe)",
        "test (windows-latest, ReleaseSafe)", "test (ubuntu-latest, ReleaseFast)",
        "SDK link (Windows)",
        // Under the family's policy the hardened profile is every package's: its safety-on run here.
                        "hardened",
    });
    try std.testing.expectEqual(@as(usize, 12), jobs.len);
    for (jobs) |job| try std.testing.expect(job.machine == .none);
    const cross = for (jobs) |job| {
        if (std.mem.eql(u8, job.name, "Cross compile")) break job;
    } else return error.NoCrossJob;
    // The release cross job compiles the benchmarks and ReleaseSmall too (main.zig's crossCompile).
    try std.testing.expectEqualStrings("preflight-cross-release", cross.step);
    try std.testing.expectEqualStrings("aarch64-linux-gnu x86_64-windows-gnu", cross.targets);
    // Its source checks hold the release bar.
    for (jobs) |job| if (std.mem.eql(u8, job.step, "lint")) try std.testing.expect(std.mem.find(u8, job.args, "-Dci-release") != null);
}

test "the toolchain is built for the runners a tier's jobs run on, and Linux, one job each, and each job takes its runner's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("[\"linux\"]", try toolchainRunners(a, &.{}));
    try std.testing.expectEqualStrings("[\"linux\",\"macos\",\"windows-arm\"]", try toolchainRunners(a, &.{
        .{ .os = arm_hosts[1], .name = "on Windows ARM" },
        .{ .os = hosts[1], .name = "on macOS" },
        .{ .os = hosts[1], .name = "on macOS again" },
    }));
    const config = try parseJson(a, "{\"targets\":[\"aarch64-linux-gnu\",\"x86_64-linux-musl\"],\"policy\":\"family\",\"fuzzed\":true}");
    // The ci tier runs nothing on ARM, so its run builds no ARM toolchain; the nightly takes all.
    try std.testing.expect(std.mem.find(u8, try toolchainRunners(a, try plan(a, config, .ci)), "arm") == null);
    try std.testing.expectEqualStrings("[\"linux\",\"linux-arm\",\"macos\",\"windows\",\"windows-arm\"]", try toolchainRunners(a, try plan(a, config, .nightly)));
    // Each job of the caller's matrix names its runner's toolchain, which the gate downloads.
    const written = try include(a, try plan(a, config, .nightly));
    try std.testing.expect(std.mem.find(u8, written, "\"os\":\"windows-11-arm\"") != null);
    try std.testing.expect(std.mem.find(u8, written, "\"toolchain\":\"windows-arm\"") != null);
    for (try plan(a, config, .nightly)) |job| try std.testing.expect(job.toolchain == null);
}

test "the nightly tier is the heavy legs: ReleaseFast on macOS and Windows, the ARM runners, riscv64 and FreeBSD on their kernels, ThreadSanitizer, the fuzz runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a, "{\"targets\":[\"aarch64-linux-gnu\",\"x86_64-linux-musl\"],\"policy\":\"family\",\"fuzzed\":true}");
    const jobs = try plan(a, config, .nightly);
    try expectNames(a, jobs, &.{
        "test (macos-latest, ReleaseFast)",                     "test (windows-latest, ReleaseFast)",
        "test (ubuntu-24.04-arm, Debug)",                       "test (windows-11-arm, Debug)",
        "test (x86_64-linux-musl on ubuntu-latest, Debug)",     "test (riscv64-linux on its kernel under QEMU, Debug)",
        "test (x86_64-freebsd on its kernel under KVM, Debug)", "hardened-tsan",
        "hardened-fuzz",                                        "fuzz",
    });
    for (jobs) |job| switch (job.machine) {
        .none => {},
        .riscv64 => try std.testing.expect(std.mem.find(u8, job.args, "-Doptimize=debug -Dci-lint=false -Dtarget=riscv64-linux-musl -Dci-vm") != null),
        .freebsd => {
            try std.testing.expectEqualStrings(hosts[0], job.os);
            try std.testing.expect(std.mem.find(u8, job.args, "-Doptimize=debug -Dci-lint=false -Dtarget=x86_64-freebsd -Dci-vm") != null);
        },
    };
}

test "each tier is held to its share of the account's runners, its macOS jobs too, refused by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    problem = "";
    // The ci tier, at most 8 and 2 on macOS: the source checks, the snippets, macOS, Windows
    // and Linux's shards.
    try std.testing.expectError(error.TooManyJobs, plan(a, try parseJson(a, "{\"shards\":{\"linux\":5}}"), .ci));
    try std.testing.expect(std.mem.find(u8, problem, "the ci tier asks for 9 jobs (ubuntu-latest 7, macos-latest 1, windows-latest 1), more than the 8 a ci run may of the account's 20") != null);
    _ = try plan(a, try parseJson(a, "{\"shards\":{\"linux\":4}}"), .ci);
    try std.testing.expectError(error.TooManyJobs, plan(a, try parseJson(a, "{\"shards\":{\"macos\":3}}"), .ci));
    try std.testing.expect(std.mem.find(u8, problem, "the ci tier asks for 3 macOS jobs, more than the 2 a ci run may of the account's 5") != null);
    _ = try plan(a, try parseJson(a, "{\"shards\":{\"macos\":2}}"), .ci);
    // The release tier, at most 14 and 3 on macOS: Linux's Debug, ReleaseSafe and ReleaseFast
    // each take its shards.
    try std.testing.expectError(error.TooManyJobs, plan(a, try parseJson(a, "{\"shards\":{\"linux\":3}}"), .release));
    _ = try plan(a, try parseJson(a, "{\"shards\":{\"linux\":2}}"), .release);
    try std.testing.expectError(error.TooManyJobs, plan(a, try parseJson(a, "{\"shards\":{\"macos\":2}}"), .release));
    // The nightly tier, at most 20 with Zig master's job, and 5 on macOS.
    try std.testing.expectError(error.TooManyJobs, plan(a, try parseJson(a, "{\"shards\":{\"riscv64\":15}}"), .nightly));
    _ = try plan(a, try parseJson(a, "{\"shards\":{\"riscv64\":14}}"), .nightly);
    try std.testing.expectError(error.TooManyJobs, plan(a, try parseJson(a, "{\"shards\":{\"macos\":6}}"), .nightly));
    _ = try plan(a, try parseJson(a, "{\"shards\":{\"macos\":5}}"), .nightly);
    // A run holds no more than the account's twenty and five, whatever its tier.
    for ([_]Tier{ .ci, .release, .nightly }) |tier| {
        try std.testing.expect(limits(tier).jobs <= max_jobs);
        try std.testing.expect(limits(tier).macos <= max_macos_jobs);
    }
}

test "a host's suites run in the jobs `shards` gives it, and a floor or cap object is refused by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const jobs = try plan(a, try parseJson(a, "{\"shards\":{\"windows\":3}}"), .release);
    try std.testing.expectEqual(@as(usize, 3), jobsNamed(jobs, "test (windows-latest, Debug)"));
    try std.testing.expectEqual(@as(usize, 3), jobsNamed(jobs, "test (windows-latest, ReleaseSafe)"));
    try std.testing.expectEqual(@as(usize, 1), jobsNamed(jobs, "test (ubuntu-latest, Debug)"));
    for (jobs) |job| if (std.mem.eql(u8, baseName(job.name), "test (windows-latest, Debug)")) {
        try std.testing.expectEqualStrings(job.name, try a.print("test (windows-latest, Debug) shard {s}", .{job.shard}));
    };
    problem = "";
    try std.testing.expectError(error.InvalidShardCount, plan(a, try parseJson(a, "{\"shards\":{\"windows\":{\"max\":4}}}"), .ci));
    try std.testing.expect(std.mem.find(u8, problem, "shards.windows: preflight 0.20.0 removed the floor and cap objects") != null);
    for ([_][]const u8{ "{\"shards\":{\"windows\":0}}", "{\"shards\":{\"plan9\":2}}", "{\"shards\":2}" }) |text| {
        try std.testing.expectError(error.InvalidShardCount, plan(a, try parseJson(a, text), .ci));
    }
}
test "the cross bundle retains every target, CPU and caller compile step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a,
        \\{"compile_step":"install","targets":["x86_64-windows-gnu",{"target":"aarch64-linux-gnu","cpu":"cortex_a72"}]}
    );
    var bundles: usize = 0;
    for (try plan(a, config, .release)) |job| if (std.mem.eql(u8, job.step, "preflight-cross-release")) {
        bundles += 1;
        try std.testing.expectEqualStrings("x86_64-windows-gnu aarch64-linux-gnu", job.targets);
    };
    try std.testing.expectEqual(@as(usize, 1), bundles);
    const targets = try src.items(src.get(config, "targets"));
    const first = try crossArgs(a, &.{ "zig", "build" }, config, targets[0], "ci-check", "debug", null);
    const second = try crossArgs(a, &.{ "zig", "build" }, config, targets[1], "ci-check-bench", "debug", null);
    try std.testing.expectEqualStrings("ci-check", first[2]);
    try std.testing.expectEqualStrings("-Dtarget=x86_64-windows-gnu", first[4]);
    try std.testing.expectEqualStrings("ci-check-bench", second[2]);
    try std.testing.expectEqualStrings("-Dtarget=aarch64-linux-gnu", second[4]);
    try std.testing.expectEqualStrings("-Dcpu=cortex_a72", second[5]);
    try std.testing.expectError(error.InvalidCrossTarget, crossArgs(a, &.{ "zig", "build" }, config, .null, "ci-check", "debug", null));
}

test "a cross-compile job names the configured targets and the macOS and Windows ones, each with its own arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a,
        \\{"compile_step":"install","cross_jobs":1,"targets":[{"target":"aarch64-linux-gnu","cpu":"cortex_a72"}]}
    );
    const targets = try fastTargets(a, config);
    try std.testing.expectEqual(@as(usize, 3), targets.len);
    const args = try crossArgs(a, &.{ "zig", "build" }, config, targets[0], "ci-check", "debug", null);
    try std.testing.expectEqualStrings("ci-check", args[2]);
    try std.testing.expectEqualStrings("-Dcpu=cortex_a72", args[5]);
    try std.testing.expectEqualStrings("-Doptimize=debug", args[6]);
    const bench = try crossArgs(a, &.{ "zig", "build" }, config, targets[0], "ci-check-bench", "debug", null);
    try std.testing.expectEqualStrings("ci-check-bench", bench[2]);
    const small = try crossArgs(a, &.{ "zig", "build" }, config, targets[0], "ci-check", "small", null);
    try std.testing.expectEqualStrings("-Doptimize=small", small[6]);
}

test "the cross targets compile in one job, or in the `cross_jobs` asked for, dealt in their order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var jobs: std.ArrayList(Job) = .empty;
    const one = try parseJson(a, "{\"targets\":[\"a\",\"b\",\"c\"]}");
    try crossJobs(a, one, &jobs, .ci, try src.items(src.get(one, "targets")), false);
    try std.testing.expectEqual(@as(usize, 1), jobs.items.len);
    try std.testing.expectEqualStrings("Cross compile", jobs.items[0].name);
    try std.testing.expectEqualStrings("a b c", jobs.items[0].targets);
    try std.testing.expectEqual(@as(usize, 10), jobs.items[0].job_timeout);
    const asked = try parseJson(a, "{\"cross_jobs\":2,\"targets\":[\"a\",\"b\",\"c\"]}");
    jobs.clearRetainingCapacity();
    try crossJobs(a, asked, &jobs, .release, try src.items(src.get(asked, "targets")), true);
    try std.testing.expectEqual(@as(usize, 2), jobs.items.len);
    try std.testing.expectEqualStrings("preflight-cross-release", jobs.items[0].step);
    try std.testing.expectEqualStrings("Cross compile 1/2", jobs.items[0].name);
    try std.testing.expectEqualStrings("a c", jobs.items[0].targets);
    try std.testing.expectEqualStrings("b", jobs.items[1].targets);
    try std.testing.expectEqual(@as(usize, 15), jobs.items[0].job_timeout);
    // More jobs than targets is a job each.
    const many = try parseJson(a, "{\"cross_jobs\":5,\"targets\":[\"a\",\"b\"]}");
    jobs.clearRetainingCapacity();
    try crossJobs(a, many, &jobs, .ci, try src.items(src.get(many, "targets")), false);
    try std.testing.expectEqual(@as(usize, 2), jobs.items.len);
    const bad = try parseJson(a, "{\"cross_jobs\":0,\"targets\":[\"a\"]}");
    try std.testing.expectError(error.InvalidCrossJobs, crossJobs(a, bad, &jobs, .ci, try src.items(src.get(bad, "targets")), false));
}
test "a cross compile's build runs with the jobs PREFLIGHT_JOBS allows, and with Zig's default without it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a, "{\"targets\":[\"aarch64-linux-gnu\"]}");
    const target = (try src.items(src.get(config, "targets")))[0];
    var environ: std.process.Environ.Map = .init(a);
    try std.testing.expectEqual(@as(?u32, null), try jobsFrom(&environ));
    for (try crossArgs(a, &.{ "zig", "build" }, config, target, "ci-check", "debug", try jobsFrom(&environ))) |arg| try std.testing.expect(!std.mem.startsWith(u8, arg, "-j"));
    try environ.put("PREFLIGHT_JOBS", "1");
    const held = try crossArgs(a, &.{ "zig", "build" }, config, target, "ci-check", "debug", try jobsFrom(&environ));
    try std.testing.expectEqualStrings("-j1", held[held.len - 1]);
    for ([_][]const u8{ "0", "many", "-2" }) |bad| {
        try environ.put("PREFLIGHT_JOBS", bad);
        try std.testing.expectError(error.InvalidJobs, jobsFrom(&environ));
    }
    // A job the plan sizes none for has the variable empty: Zig's default.
    try environ.put("PREFLIGHT_JOBS", "");
    try std.testing.expectEqual(@as(?u32, null), try jobsFrom(&environ));
}

test "a configured target a runner executes, on an ABI not its own, runs its Debug suite there in the nightly tier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a,
        \\{"shards":{"windows":2},"build_args":["-Dfeature=true"],"targets":[
        \\"x86_64-windows-msvc",{"target":"aarch64-windows-msvc","args":["-Dsdk=true"]},"x86_64-linux-musl",
        \\"x86_64-windows-gnu","x86_64-windows",{"target":"aarch64-linux-gnu","cpu":"cortex_a72"},"aarch64-macos","x86_64-macos","riscv64-linux-musl"]}
    );
    var planned: std.ArrayList(Job) = .empty;
    try ownTargetJobs(a, config, &planned);
    const jobs = planned.items;
    var suites: std.ArrayList([]const u8) = .empty;
    for (jobs) |job| if (job.target) |target| {
        try suites.append(a, job.name);
        try std.testing.expectEqualStrings("ci-test", job.step);
        try std.testing.expect(job.setup);
        try std.testing.expect(std.mem.find(u8, job.args, try a.print("-Dtarget={s}", .{target})) != null);
        try std.testing.expect(std.mem.startsWith(u8, job.args, "-Doptimize=debug -Dci-lint=false"));
        try std.testing.expect(std.mem.find(u8, job.args, "-Dfeature=true") != null);
    };
    try std.testing.expectEqual(@as(usize, 2), jobsNamed(jobs, "test (x86_64-windows-msvc on windows-latest, Debug)"));
    try std.testing.expectEqual(@as(usize, 1), jobsNamed(jobs, "test (aarch64-windows-msvc on windows-11-arm, Debug)"));
    try std.testing.expectEqual(@as(usize, 1), jobsNamed(jobs, "test (x86_64-linux-musl on ubuntu-latest, Debug)"));
    for (jobs) |job| if (std.mem.eql(u8, baseName(job.name), "test (aarch64-windows-msvc on windows-11-arm, Debug)")) {
        try std.testing.expectEqualStrings(arm_hosts[1], job.os);
        try std.testing.expect(std.mem.endsWith(u8, job.args, "-Dsdk=true"));
    };
    // Only the nightly tier runs them, and a job that sets no target is written, and keyed, as before.
    for (try plan(a, config, .ci)) |job| try std.testing.expect(job.target == null);
    for (try plan(a, config, .release)) |job| try std.testing.expect(job.target == null);
    try std.testing.expect(std.mem.find(u8, try include(a, &.{.{ .os = hosts[0], .name = "x" }}), "\"target\"") == null);
}

test "owner SDK link jobs retain configured targets CPUs and feature arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a,
        \\{"build_args":["-Dfeature=true"],"targets":[{"target":"x86_64-macos","cpu":"baseline","args":["-Dtrust-store=true"]},"aarch64-macos","aarch64-windows-gnu","aarch64-linux-gnu"]}
    );
    const cross = try fastTargets(a, config);
    try std.testing.expectEqual(@as(usize, 5), cross.len);
    const argv = try crossArgs(a, &.{ "zig", "build" }, config, cross[0], "ci-check", "debug", null);
    try std.testing.expectEqualStrings("ci-check", argv[2]);
    try std.testing.expectEqualStrings("-Dcpu=baseline", argv[5]);
    try std.testing.expectEqualStrings("-Dfeature=true", argv[6]);
    try std.testing.expectEqualStrings("-Dtrust-store=true", argv[7]);
    // One link job per system, naming its targets; each link is configured for its target
    // (crossOptions, as main.zig's linkTargets builds it), its CPU and arguments with it.
    var linked: usize = 0;
    for (try plan(a, config, .release)) |job| if (std.mem.eql(u8, job.step, "preflight-link")) {
        linked += 1;
        try std.testing.expect(job.operation == .link);
        try std.testing.expect(job.setup);
        try std.testing.expect(!std.mem.eql(u8, job.os, hosts[0]));
        if (std.mem.eql(u8, job.os, hosts[1])) try std.testing.expectEqualStrings("x86_64-macos aarch64-macos", job.targets);
        if (std.mem.eql(u8, job.os, hosts[2])) try std.testing.expectEqualStrings("aarch64-windows-gnu", job.targets);
    };
    try std.testing.expectEqual(@as(usize, 2), linked);
    const options = try crossOptions(a, config, cross[0]);
    try std.testing.expectEqualStrings("-Dtarget=x86_64-macos", options[1]);
    try std.testing.expectEqualStrings("-Dcpu=baseline", options[2]);
    try std.testing.expectEqualStrings("-Dtrust-store=true", options[4]);
    try std.testing.expectError(error.InvalidBuildArgs, plan(a, try parseJson(a, "{\"build_args\":[\"-Dtarget=x86_64-macos\"]}"), .ci));
    try std.testing.expectError(error.InvalidBuildArgs, plan(a, try parseJson(a, "{\"jobs\":[{\"name\":\"tsan\",\"step\":\"test\",\"args\":[\"-Dci-tsan=true\",\"-Dci-timings=true\"],\"tiers\":[\"release\"]}]}"), .release));
    try std.testing.expect(std.mem.find(u8, problem, "-Dci-timings: preflight 0.20.0 removed it") != null);
}

test "the macOS links run on Linux when none links a framework, and on a Mac when one does; Windows' on Windows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { sdk: []const u8, os: []const u8, name: []const u8 }{
        .{ .sdk = "[]", .os = hosts[0], .name = "link (macOS)" },
        .{ .sdk = "[\"aarch64-macos\"]", .os = hosts[1], .name = "SDK link (macOS)" },
    }) |case| {
        const config = try parseJson(a, try a.print("{{\"targets\":[\"x86_64-macos\",\"aarch64-macos\",\"x86_64-windows-gnu\",\"aarch64-linux-gnu\"],\"sdk_targets\":{s}}}", .{case.sdk}));
        var seen: usize = 0;
        for (try plan(a, config, .release)) |job| {
            if (!std.mem.eql(u8, job.step, "preflight-link")) continue;
            seen += 1;
            if (std.mem.eql(u8, job.targets, "x86_64-windows-gnu")) {
                try std.testing.expectEqualStrings(hosts[2], job.os);
                try std.testing.expectEqualStrings("SDK link (Windows)", job.name);
            } else {
                try std.testing.expectEqualStrings("x86_64-macos aarch64-macos", job.targets);
                try std.testing.expectEqualStrings(case.os, job.os);
                try std.testing.expectEqualStrings(case.name, job.name);
            }
        }
        try std.testing.expectEqual(@as(usize, 2), seen);
    }
    // No target that needs a system's linker, no link job.
    for (try plan(a, try parseJson(a, "{\"targets\":[\"aarch64-linux-gnu\"]}"), .release)) |job| try std.testing.expect(!std.mem.eql(u8, job.step, "preflight-link"));
    try std.testing.expectError(error.InvalidSdkTargets, plan(a, try parseJson(a, "{\"targets\":[\"x86_64-macos\"],\"sdk_targets\":\"x86_64-macos\"}"), .release));
}

test "the hardened runs are every package's under the family's policy, and without it a package's that says hardened" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { []const u8, ?bool };
    for ([_]Case{
        // The family's: planned with or without the key, and no opting out.
        .{ "{\"policy\":\"family\"}", true },
        .{ "{\"policy\":\"family\",\"hardened\":true}", true },
        .{ "{\"policy\":\"family\",\"hardened\":false}", null },
        // A stranger's: only when asked for.
        .{ "{}", false },
        .{ "{\"hardened\":false}", false },
        .{ "{\"hardened\":true}", true },
        .{ "{\"hardened\":\"yes\"}", null },
    }) |case| {
        const config = try parseJson(a, case[0]);
        const want = case[1] orelse {
            try std.testing.expectError(error.InvalidHardenedProfile, plan(a, config, .release));
            continue;
        };
        // The safety-on run in the release tier; ThreadSanitizer and the native fuzz campaign nightly.
        const released = try plan(a, config, .release);
        const nightly = try plan(a, config, .nightly);
        try std.testing.expectEqual(want, jobsNamed(released, "hardened") > 0);
        try std.testing.expectEqual(want, jobsNamed(nightly, "hardened-tsan") > 0);
        try std.testing.expectEqual(@as(usize, @intFromBool(want)), jobsNamed(nightly, "hardened-fuzz"));
        for (released) |job| try std.testing.expect(!std.mem.eql(u8, job.step, "hardened-tsan") and !std.mem.eql(u8, job.step, "hardened-fuzz"));
        for (nightly) |job| try std.testing.expect(!std.mem.eql(u8, job.step, "hardened"));
        for ([_][]const Job{ released, nightly }) |jobs| for (jobs) |job| if (std.mem.startsWith(u8, job.step, "hardened")) {
            try std.testing.expectEqualStrings(hosts[0], job.os);
            try std.testing.expectEqual(.execute, job.operation);
        };
    }
    try std.testing.expectError(error.UnknownPolicy, plan(a, try parseJson(a, "{\"policy\":\"famliy\"}"), .release));
}

test "a package's own jobs join the tiers they name, on the hosts they name, with the gate's setup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a,
        \\{"build_args":["-Dsimd=false"],"jobs":[
        \\ {"name":"conformance","step":"ci","directory":"conformance","os":["ubuntu-latest","macos-latest"]},
        \\ {"name":"contracts (values)","step":"contracts-values","tiers":["ci"],"args":["-Dgroup=values"],"setup":false,"timeout":8},
        \\ {"name":"reports","step":"check-reports","setup":"reports-setup","tiers":["release"]},
        \\ {"name":"soak","step":"soak","tiers":["nightly"],"shards":3}]}
    );
    const ci = try plan(a, config, .ci);
    const released = try plan(a, config, .release);
    const nightly = try plan(a, config, .nightly);
    for (released) |job| try std.testing.expect(!std.mem.eql(u8, job.step, "contracts-values"));
    // Unless it names its tiers, a job runs in ci and release.
    try std.testing.expectEqual(@as(usize, 2), jobsNamed(ci, "conformance (ubuntu-latest)") + jobsNamed(ci, "conformance (macos-latest)"));
    try std.testing.expectEqual(@as(usize, 2), jobsNamed(released, "conformance (ubuntu-latest)") + jobsNamed(released, "conformance (macos-latest)"));
    try std.testing.expectEqual(@as(usize, 0), jobsNamed(nightly, "conformance (ubuntu-latest)"));
    for (ci) |job| {
        if (std.mem.eql(u8, job.directory, "conformance")) {
            try std.testing.expectEqualStrings("ci", job.step);
            try std.testing.expect(job.setup);
            // The package's build options are its own builds'; a declared job takes only its own.
            try std.testing.expectEqualStrings("", job.args);
        }
        if (std.mem.eql(u8, job.step, "contracts-values")) {
            try std.testing.expect(!job.setup);
            // Its own timeout, shorter than the tier's minutes.
            try std.testing.expectEqual(@as(usize, 8), job.job_timeout);
            try std.testing.expectEqualStrings("-Dgroup=values", job.args);
        }
        try std.testing.expect(!std.mem.eql(u8, job.step, "check-reports"));
    }
    for (released) |job| if (std.mem.eql(u8, job.step, "check-reports")) try std.testing.expectEqualStrings("reports-setup", job.prepare);
    // A declared test step split in shards is one job per shard, each naming its share.
    var shards: std.ArrayList([]const u8) = .empty;
    for (nightly) |job| if (job.declared) {
        try std.testing.expectEqualStrings("soak", job.step);
        try std.testing.expectEqualStrings(try a.print("soak shard {s}", .{job.shard}), job.name);
        try shards.append(a, job.shard);
    };
    for (shards.items, [_][]const u8{ "1/3", "2/3", "3/3" }) |got, want| try std.testing.expectEqualStrings(want, got);
    for (ci, 0..) |x, i| for (ci[i + 1 ..]) |y| try std.testing.expect(!std.mem.eql(u8, x.cache_key, y.cache_key));
    // A timeout past a tier's minutes, a tier that is none, and the fuzz tier, which is the fuzz
    // job's, are refused by name.
    problem = "";
    try std.testing.expectError(error.InvalidJobTimeout, plan(a, try parseJson(a, "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"timeout\":12}]}"), .release));
    try std.testing.expectEqualStrings("jobs: x: its timeout, 12 minutes, is more than a ci job's 10: raise its shards, or name another tier", problem);
    _ = try plan(a, try parseJson(a, "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"timeout\":12,\"tiers\":[\"release\"]}]}"), .release);
    try std.testing.expectError(error.InvalidDeclaredJob, plan(a, try parseJson(a, "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"tiers\":[\"released\"]}]}"), .release));
    try std.testing.expectEqualStrings("jobs: x: `released` is no tier a job of the package's own runs in: ci, release or nightly", problem);
    try std.testing.expectError(error.InvalidDeclaredJob, plan(a, try parseJson(a, "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"tiers\":[\"fuzz\"]}]}"), .release));
    // `shards` is the job's count of jobs on each host.
    try std.testing.expectEqual(@as(usize, 2), jobsNamed(try plan(a, try parseJson(a, "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"shards\":2}]}"), .release), "x"));
    for ([_][]const u8{
        "{\"jobs\":{}}",
        "{\"jobs\":[{\"step\":\"test\"}]}",
        "{\"jobs\":[{\"name\":\"x\"}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"a b\"}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"os\":[\"plan9\"]}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"tiers\":[\"weekly\"]}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"directory\":\"../up\"}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"timeout\":0}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"shards\":0}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"shards\":\"2\"}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"needs\":\"gate\"}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\"},{\"name\":\"x\",\"step\":\"u\"}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"advisory\":\"yes\"}]}",
    }) |bad| try std.testing.expect(std.meta.isError(plan(a, try parseJson(a, bad), .ci)));
}

test "an advisory job runs as declared, alone, says non-blocking in its name and carries its flag in the matrix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // relic's git-master leg: its tests against git's unreleased head, shown and not taken.
    const config = try parseJson(a,
        \\{"jobs":[
        \\ {"name":"git master","step":"ci-git-master","advisory":true,"shards":2,"timeout":30},
        \\ {"name":"conformance","step":"test","advisory":false}]}
    );
    var advisory: usize = 0;
    for (try plan(a, config, .ci)) |job| if (job.declared) {
        if (std.mem.eql(u8, job.step, "ci-git-master")) {
            advisory += 1;
            try std.testing.expectEqual(@as(?bool, true), job.advisory);
            try std.testing.expectEqualStrings(try a.print("git master shard {s} (non-blocking)", .{job.shard}), job.name);
            // Its run has its declared timeout, its job that and its other steps' budgets: it
            // never blocks, so its tier's minutes are not its bound.
            try std.testing.expectEqual(@as(?usize, 30), job.run_timeout);
            try std.testing.expectEqual(30 + advisory_overhead_minutes, job.job_timeout);
        } else {
            // One that says false is any declared job: its result is the run's.
            try std.testing.expectEqual(@as(?bool, null), job.advisory);
            try std.testing.expectEqual(@as(?usize, null), job.run_timeout);
            try std.testing.expectEqual(@as(usize, 10), job.job_timeout);
            try std.testing.expectEqualStrings("conformance", job.name);
        }
    };
    try std.testing.expectEqual(@as(usize, 2), advisory);
    const listed = try include(a, try plan(a, config, .ci));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, listed, "\"advisory\":true"));
    try std.testing.expect(std.mem.find(u8, listed, "\"advisory\":false") == null);
    // A timeout that leaves no room for the other steps' budgets within GitHub's 360 is refused.
    problem = "";
    try std.testing.expectError(error.InvalidDeclaredJob, plan(a, try parseJson(a, "{\"jobs\":[{\"name\":\"git master\",\"step\":\"t\",\"advisory\":true,\"timeout\":246}]}"), .ci));
    try std.testing.expectEqualStrings("jobs: git master: an advisory job's timeout is at most 245 minutes, which leaves its other steps' 115 within GitHub's 360", problem);
    // An advisory macOS job runs alone, a job of its own, and counts among the run's.
    const mac = try parseJson(a,
        \\{"jobs":[
        \\ {"name":"git master","step":"ci-git-master","advisory":true,"os":["macos-latest"],"tiers":["nightly"]},
        \\ {"name":"conformance","step":"test","os":["macos-latest"],"tiers":["nightly"]}]}
    );
    var alone = false;
    for (try plan(a, mac, .nightly)) |job| {
        if (job.advisory == true) alone = std.mem.eql(u8, job.step, "ci-git-master");
    }
    try std.testing.expect(alone);
    problem = "";
    try std.testing.expectError(error.InvalidDeclaredJob, plan(a, try parseJson(a, "{\"jobs\":[{\"name\":\"git master\",\"step\":\"t\",\"advisory\":1}]}"), .ci));
    try std.testing.expectEqualStrings("jobs: git master: advisory is true or false", problem);
}

test "an option the planner does not know, one 0.20.0 removed, or a malformed step, is refused rather than ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "{\"lnad\":true}", "{\"package\":\"x\"}", "{\"portable_tests\":true}", "{\"compile_step\":3}", "{\"setup_step\":\"a b\"}" }) |bad|
        try std.testing.expect(std.meta.isError(plan(a, try parseJson(a, bad), .ci)));
    for ([_][]const u8{ "test_job_timeout", "windows_job_timeout", "source_job_timeout", "cross_job_timeout", "riscv64_seconds", "portable_hosts" }) |gone| {
        problem = "";
        try std.testing.expectError(error.UnknownWorkflowOption, plan(a, try parseJson(a, try a.print("{{\"{s}\":30}}", .{gone})), .ci));
        try std.testing.expect(std.mem.find(u8, problem, "preflight 0.20.0 removed it") != null);
    }
}

test "only the release tier's source checks hold every aegis-pack finding to the bar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a, "{}");
    for ([_]Tier{ .ci, .release }) |tier| {
        const lint = for (try plan(a, config, tier)) |job| {
            if (std.mem.eql(u8, job.step, "lint")) break job;
        } else return error.NoLintJob;
        try std.testing.expectEqual(tier == .release, std.mem.find(u8, lint.args, "-Dci-release") != null);
    }
}

test "the fuzz job: the nightly tier's and a dispatched fuzz run's alone, where the build has its step, within fifteen minutes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fuzzed = try parseJson(a, "{\"fuzzed\":true,\"build_args\":[\"-Dsuite=released\"]}");
    const found = struct {
        fn job(jobs: []const Job) ?Job {
            for (jobs) |each| if (std.mem.eql(u8, each.step, "ci-fuzz")) return each;
            return null;
        }
    }.job;
    try std.testing.expect(found(try plan(a, fuzzed, .ci)) == null);
    try std.testing.expect(found(try plan(a, fuzzed, .release)) == null);
    const nightly = found(try plan(a, fuzzed, .nightly)).?;
    try std.testing.expectEqualStrings("fuzz", nightly.name);
    try std.testing.expectEqualStrings(hosts[0], nightly.os);
    try std.testing.expectEqual(@as(usize, 15), nightly.job_timeout);
    try std.testing.expect(nightly.setup);
    try std.testing.expectEqualStrings("-Dci-lint=false -Dci-bench-smoke=false -Dsuite=released", nightly.args);
    // A dispatched fuzz run is that job alone, the same job.
    const alone = try plan(a, fuzzed, .fuzz);
    try std.testing.expectEqual(@as(usize, 1), alone.len);
    try std.testing.expectEqualStrings(nightly.cache_key, alone[0].cache_key);
    // Ten minutes unless the configuration says; none where the build has no fuzz step (it
    // declares no shakedown), or its minutes are 0.
    try std.testing.expectEqual(@as(usize, 10), try fuzzMinutes(fuzzed));
    for ([_][]const u8{ "{}", "{\"fuzzed\":false}", "{\"fuzzed\":true,\"fuzz_minutes\":0}" }) |text| {
        const config = try parseJson(a, text);
        try std.testing.expect(found(try plan(a, config, .nightly)) == null);
        try std.testing.expectEqual(@as(usize, 0), (try plan(a, config, .fuzz)).len);
    }
    // Minutes a nightly job cannot hold beside its build, or none, are refused: a longer
    // campaign is a dispatched run's.
    for ([_][]const u8{ "{\"fuzz_minutes\":11}", "{\"fuzz_minutes\":-1}", "{\"fuzz_minutes\":\"10\"}" }) |text| {
        try std.testing.expectError(error.InvalidFuzzMinutes, plan(a, try parseJson(a, text), .nightly));
        try std.testing.expectError(error.InvalidFuzzMinutes, plan(a, try parseJson(a, text), .fuzz));
    }
}

test "the ci tier compiles the package's check in each configuration it declares, by its name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a, "{\"configurations\": [{\"name\": \"default\", \"options\": {\"http\": true, \"lfs\": true}}, {\"name\": \"neither\", \"options\": {\"http\": false, \"lfs\": false}, \"modules\": [\"relic\"]}, {\"name\": \"level-3\", \"options\": {\"level\": 3, \"mode\": \"fast\"}}]}");
    var found: usize = 0;
    for (try plan(a, config, .ci)) |job| {
        if (!std.mem.startsWith(u8, job.name, "check (")) continue;
        found += 1;
        try std.testing.expectEqualStrings("check", job.step);
        if (std.mem.eql(u8, baseName(job.name), "check (neither)")) try std.testing.expectEqualStrings("-Dci-lint=false -Dhttp=false -Dlfs=false", job.args);
        if (std.mem.eql(u8, baseName(job.name), "check (level-3)")) try std.testing.expectEqualStrings("-Dci-lint=false -Dlevel=3 -Dmode=fast", job.args);
    }
    try std.testing.expectEqual(@as(usize, 3), found);
    // None declared, none planned; the release tier, the ci tier's jobs and more, plans them too.
    for (try plan(a, try parseJson(a, "{}"), .ci)) |job| try std.testing.expect(!std.mem.startsWith(u8, job.name, "check ("));
    try std.testing.expectEqual(@as(usize, 1), jobsNamed(try plan(a, config, .release), "check (neither)"));
    // A name a job and a directory cannot take, or a value the job's arguments cannot carry, is refused.
    for ([_][]const u8{ "{\"configurations\": [{\"name\": \"no http\"}]}", "{\"configurations\": []}", "{\"configurations\": [{\"name\": \"x\", \"options\": {\"mode\": \"a b\"}}]}", "{\"configurations\": [{\"name\": \"x\", \"options\": {\"f\": 1.5}}]}" }) |text| {
        try std.testing.expectError(error.InvalidConfigurations, plan(a, try parseJson(a, text), .ci));
    }
}
