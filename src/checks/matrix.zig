const std = @import("std");
const aegis = @import("aegis");
const src = @import("source.zig");
const keys = @import("keys.zig");
const heldgit = @import("heldgit.zig");
const family = @import("../family.zig");
const preflight_order = @import("preflight_order");

pub const hosts = [_][]const u8{ "ubuntu-latest", "macos-latest", "windows-latest" };
/// What each of `hosts` holds, as GitHub gives a public repository's standard runner: its
/// memory, in `hosts` order, which a cross job's compiles share (`crossBuildJobs`).
pub const host_memory = [_]u64{ 16 << 30, 7 << 30, 16 << 30 };
/// Each of `hosts`' CPUs, in `hosts` order: more jobs at once than these only wait.
pub const host_cpus = [_]u32{ 4, 3, 4 };
/// The share of a runner's memory, in percent, a cross job's compiles may hold at once: the
/// rest is the system's and the build runner's.
const memory_share_percent = 75;
/// The `shards` keys of `ci/workflow.json`, in `hosts` order.
const host_names = [_][]const u8{ "linux", "macos", "windows" };
/// The runners on ARM the full tier adds, Linux and Windows on aarch64 (the macOS runner is
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
/// Every `shards` key: a host whose job count the record makes, within the bounds it sets.
pub const shard_hosts = host_names ++ arm_host_names ++ .{ emulated_host_name, freebsd_host_name, tsan_name };
/// Every runner a job may name.
const every_host = hosts ++ arm_hosts;

/// What the last refused configuration got wrong, for the command to print beside the error: the
/// planner is a library, and a test that expects the refusal must not see it logged as a failure.
/// It is the planning thread's own, as the refusal is.
pub threadlocal var problem: []const u8 = "";

/// How much of the gate a run executes, and when. Every job of a tier ends within its minutes
/// (`jobMinutes`), and a run asks for at most `max_jobs` jobs, `max_macos_jobs` of them on macOS:
/// the plan sizes each job's work from what the last runs recorded (`ci/durations.json`), deals a
/// runner's work into as few jobs as hold it, and refuses a plan past either bound by name.
pub const Tier = enum {
    /// Every push to main and every pull request, on that exact commit: the source checks, the
    /// Debug suite on Linux, macOS and Windows, an object compile of every configured target and
    /// the package's own jobs that name it, each job within ten minutes. Its status is main's: a
    /// red one is fixed forward at once.
    ci,
    /// The full matrix, on the head a release batch is cut from, by dispatch: every mode on every
    /// runner, each configured target's suite on its runner, the SDK links, the ReleaseFast
    /// benchmarks and ReleaseSmall compiles, the hardened run and the package's own jobs that name
    /// it, each job within fifteen minutes. A tag needs it green on its commit, and the nightly
    /// tier too.
    full,
    /// The heavy legs, nightly and on the head a release batch is cut from: the riscv64 suite on
    /// its kernel under QEMU, FreeBSD's under KVM, ThreadSanitizer, the hardened fuzz run, the fuzz
    /// job, the package's own jobs that name it and Zig master, each job within fifteen minutes.
    nightly,
    /// The fuzz job alone, by dispatch: a session fuzzes a package on GitHub's runners and not on
    /// the machine at hand, for as many minutes as the dispatch says.
    fuzz,
};

/// The minutes a job of `tier` is given, its bound on GitHub: the tier's, which the plan sizes
/// every job's work to.
pub fn jobMinutes(tier: Tier) usize {
    return switch (tier) {
        .ci => 10,
        .full, .nightly, .fuzz => 15,
    };
}

/// The most jobs one run may ask for: the account runs twenty at once (GitHub Free), and bay
/// paces a release batch's runs within them, which it can only do for runs that fit.
pub const max_jobs = 20;
/// The most macOS jobs one run may ask for, of the account's five: a second run's have room. A
/// run that asked for each macOS mode and shard at once lost runners GitHub never gave it
/// (almanac 44324896023, strand 44137916154).
pub const max_macos_jobs = 3;
/// The jobs a nightly run holds beside its matrix: Zig master's (zig.yml's `master`).
const nightly_extra_jobs = 1;

/// How much of a job's minutes its recorded work may fill: the rest is its setup and a margin
/// of a quarter.
const margin = 1.25;

/// The seconds of recorded work one job of `tier` holds.
fn capacity(tier: Tier) f64 {
    return @as(f64, @floatFromInt(jobMinutes(tier) * 60)) / margin;
}

/// The minutes the plan before the tiers gave a suite's job, by which a suite no run has
/// measured is seeded: its jobs are as many as that time, scaled by its kind's slowdown and the
/// margin, takes in jobs of its tier's minutes, each a job of its own. The run that executes
/// them records them, and the next plan is sized by the record.
const seed_minutes = 20;

/// How much slower than a native runner a kind of job runs its tests, by which a suite no run
/// has measured is seeded.
const Slowdown = enum(u8) {
    native = 1,
    /// A FreeBSD guest under KVM: native code, with its boot and the host's files over 9p.
    kvm = 2,
    /// LLVM's ThreadSanitizer, which instruments every memory access and synchronization.
    tsan = 3,
    /// A riscv64 guest under QEMU's TCG, which translates every instruction.
    qemu = 4,
};

/// The most minutes an advisory job's steps but its run take, as zig.yml's gate job budgets
/// them: the two checkouts, the setup, the held git's restore, build and save, the three tools
/// attempts, the timings upload and the report (workflow_test sums them from the workflow). An
/// advisory job never blocks, so it is not held to its tier's minutes.
pub const advisory_overhead_minutes = 120;

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
    /// runner's own (`ownTargetLegs`); null for the runner's own.
    target: ?[]const u8 = null,
    /// The jobs this one runs in sequence on its one runner, as JSON (`pack`); null for a job
    /// that is one job.
    legs: ?[]const u8 = null,
    /// The jobs its builds run at once (`-j`, `PREFLIGHT_JOBS`), where the plan sizes them by
    /// memory (`crossBuildJobs`); null for Zig's default.
    build_jobs: ?u32 = null,
};

/// A target no hosted runner is, whose tests run on its own kernel under QEMU.
pub const Machine = enum {
    none,
    /// riscv64 Linux, emulated: `qemu-system-riscv64`.
    riscv64,
    /// x86_64 FreeBSD under KVM: `qemu-system-x86_64` and the runner's /dev/kvm.
    freebsd,
};

/// A job as the plan makes it, before `pack` deals each runner's into as few jobs as hold them:
/// the seconds of work the last runs recorded of it, null where none has measured it (a job of
/// its own, named for it, that the bounds on a run do not count, since nothing says what it
/// holds), and whether it may share a job with others.
const Leg = struct {
    job: Job,
    seconds: ?f64,
    packable: bool = true,
};

/// The mark on the name of a job no run has measured.
const unmeasured_mark = ", unmeasured";

/// The name a job's record is kept by (`legs` in `ci/durations.json`): its name without its
/// shard or its `unmeasured` mark, the same in every tier and every plan.
pub fn recordName(name: []const u8) []const u8 {
    var end = name.len;
    for ([_][]const u8{ " shard ", unmeasured_mark }) |mark| {
        if (std.mem.find(u8, name, mark)) |at| end = @min(end, at);
    }
    return name[0..end];
}

/// What the last runs recorded of a job (`legs` in `ci/durations.json`, by `recordName`): the
/// most any of its shards spent besides its tests (its setup, configuring and building), the
/// seconds of tests its shards ran together, the shards it ran in, and whether every shard
/// finished within its job's minutes.
const Record = struct { overhead: f64, tests: f64, shards: usize, finished: bool };

fn recordOf(config: src.Value, name: []const u8) !?Record {
    const legs = src.get(src.get(config, "durations"), "legs");
    if (legs == .null) return null;
    if (legs != .object) return error.InvalidDurations;
    const entry = legs.object.get(recordName(name)) orelse return null;
    const overhead = number(src.get(entry, "overhead")) orelse return error.InvalidDurations;
    const tests = number(src.get(entry, "tests")) orelse return error.InvalidDurations;
    const shards = src.get(entry, "shards");
    const finished = src.get(entry, "finished");
    if (overhead < 0 or tests < 0 or shards != .integer or shards.integer < 1 or finished != .bool) return error.InvalidDurations;
    return .{ .overhead = overhead, .tests = tests, .shards = std.math.cast(usize, shards.integer) orelse return error.InvalidDurations, .finished = finished.bool };
}

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
fn fuzzLeg(a: std.mem.Allocator, config: src.Value, tier: Tier) !?Leg {
    const budget = try fuzzMinutes(config);
    const fuzzed = src.get(config, "fuzzed");
    if (fuzzed != .null and fuzzed != .bool) return error.InvalidWorkflowConfig;
    if (budget == 0 or fuzzed != .bool or !fuzzed.bool) return null;
    return try single(a, config, tier, .{
        .os = hosts[0],
        .name = "fuzz",
        .step = "ci-fuzz",
        .args = try a.print("-Dci-lint=false -Dci-bench-smoke=false{s}", .{try buildArgs(a, src.get(config, "build_args"))}),
        .setup = true,
    }, false);
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

/// `jobs` as a hosted caller's matrix.
pub fn include(a: std.mem.Allocator, jobs: []const Job) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{ .include = jobs }, job_json);
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

/// The jobs of `tier`, as the hosted caller's matrix: each runner's work dealt into as few jobs
/// as hold it (`pack`).
pub fn plan(a: std.mem.Allocator, config: src.Value, tier: Tier) ![]Job {
    return pack(a, tier, try planLegs(a, config, tier));
}

/// The jobs of `tier` one by one, as each runs, before `pack` deals them into the run's jobs:
/// what a reader of the steps a tier runs needs.
pub fn planned(a: std.mem.Allocator, config: src.Value, tier: Tier) ![]Job {
    const legs = try planLegs(a, config, tier);
    const jobs = try a.alloc(Job, legs.len);
    for (jobs, legs) |*job, leg| job.* = leg.job;
    return jobs;
}

fn planLegs(a: std.mem.Allocator, config: src.Value, tier: Tier) ![]Leg {
    try validate(a, config);
    var legs: std.ArrayList(Leg) = .empty;
    if (tier == .fuzz) {
        if (try fuzzLeg(a, config, tier)) |leg| try legs.append(a, leg);
    } else try tierLegs(a, config, tier, &legs);
    for (legs.items) |*leg| leg.job.cache_key = try key(a, leg.job);
    return legs.toOwnedSlice(a);
}

/// The jobs of a tier that runs on its own account: ci, full or nightly.
fn tierLegs(a: std.mem.Allocator, config: src.Value, tier: Tier, legs: *std.ArrayList(Leg)) !void {
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
        .ci => try ciLegs(a, config, legs),
        .full => {
            try fullLegs(a, config, legs);
            if (profiled) try hardenedLegs(a, config, legs, .full);
        },
        .nightly => {
            try emulatedLegs(a, config, legs);
            try freebsdLegs(a, config, legs);
            if (profiled) try hardenedLegs(a, config, legs, .nightly);
            if (try fuzzLeg(a, config, tier)) |leg| try legs.append(a, leg);
        },
        .fuzz => unreachable,
    }
    try declaredLegs(a, config, tier, legs);
}

/// The source checks, the Debug suite on Linux, macOS and Windows, each recording its durations,
/// an object compile of every configured target and the package's compile in each configuration:
/// what every push and pull request runs. The other modes and runners and the benchmarks'
/// optimizing compiles are the full tier's.
fn ciLegs(a: std.mem.Allocator, config: src.Value, legs: *std.ArrayList(Leg)) !void {
    try legs.append(a, try lintLeg(a, config, .ci));
    try legs.append(a, try snippetsLeg(a, config, .ci));
    for (hosts, host_names) |host, host_name| try hostLegs(a, config, legs, .ci, host, host_name, &.{.debug});
    try crossLegs(a, config, legs, .ci, try src.items(src.get(config, "targets")), false);
    try configurationLegs(a, config, legs);
}

/// Every mode on every runner, so that a gate at hand on any of them proves its own system at
/// each mode a package releases in; each configured target's suite on its runner; the source
/// checks at the full tier's bar; the snippets; the ReleaseSmall compiles, the benchmarks'
/// ReleaseFast compile of every target and the SDK links.
fn fullLegs(a: std.mem.Allocator, config: src.Value, legs: *std.ArrayList(Leg)) !void {
    for (hosts ++ arm_hosts, host_names ++ arm_host_names) |host, host_name| try hostLegs(a, config, legs, .full, host, host_name, &.{ .debug, .safe, .fast });
    try ownTargetLegs(a, config, legs);
    try legs.append(a, try lintLeg(a, config, .full));
    try legs.append(a, try snippetsLeg(a, config, .full));
    const compile = try src.string(src.get(config, "compile_step"), "check");
    for (hosts) |host| try legs.append(a, try single(a, config, .full, .{ .os = host, .name = try a.print("compile ({s}, ReleaseSmall)", .{host}), .step = compile, .args = "-Doptimize=small" }, true));
    try crossLegs(a, config, legs, .full, try src.items(src.get(config, "targets")), true);
    try sdkLegs(a, config, legs);
}

/// The hardened profile's runs, each the suite as the Linux test jobs run it: the safety-on run
/// in the full tier, and the ThreadSanitizer run and the native fuzz campaign, the heavy ones,
/// in the nightly tier. The fuzz campaign shares no job: its corpora are its job's.
fn hardenedLegs(a: std.mem.Allocator, config: src.Value, legs: *std.ArrayList(Leg), tier: Tier) !void {
    const args = try a.print("-Dci-lint=false -Dci-bench-smoke=false{s}", .{try buildArgs(a, src.get(config, "build_args"))});
    const base: Job = .{ .os = hosts[0], .name = "", .args = args, .setup = true };
    if (tier == .full) {
        var job = base;
        job.step = "hardened";
        try suiteLegs(a, legs, tier, job, "hardened", try sizing(a, config, tier, "hardened", host_names[0], &.{"linux-debug"}, .native));
        return;
    }
    var tsan = base;
    tsan.step = "hardened-tsan";
    try suiteLegs(a, legs, tier, tsan, "hardened-tsan", try sizing(a, config, tier, "hardened-tsan", tsan_name, &.{"linux-debug-tsan"}, .tsan));
    var fuzz = base;
    fuzz.name = "hardened-fuzz";
    fuzz.step = "hardened-fuzz";
    try legs.append(a, try single(a, config, tier, fuzz, false));
}

/// How many jobs a suite takes in `tier`, and the seconds each holds. A suite the last runs
/// recorded (`legs` in `ci/durations.json`) takes as few jobs as hold its tests beside the most
/// any job of it spent on the rest; one whose jobs ran out of their minutes takes twice as many.
/// One with only its tests' seconds (`columns`, by which the shards are balanced) takes as few as
/// hold twice those, its setup and build the other half. One with neither is seeded: one job in
/// the ci tier, else from `seed_minutes`. Within `shards.<bounds>`, where a package sets bounds.
fn sizing(a: std.mem.Allocator, config: src.Value, tier: Tier, name: []const u8, bounds_key: []const u8, columns: []const []const u8, slowdown: Slowdown) !Sizing {
    const bounds = try shardBounds(a, src.get(config, "shards"), bounds_key);
    const room = capacity(tier);
    var size: Sizing = undefined;
    if (try recordOf(config, name)) |record| {
        if (!record.finished) return .{ .count = std.math.clamp(record.shards * 2, bounds.min, bounds.max), .seconds = room };
        if (record.overhead >= room) {
            problem = try a.print("{s}: its setup and build took {f} in the last run, more than the {f} of work a {t} job of {d} minutes holds", .{ name, wholeSeconds(record.overhead), wholeSeconds(room), tier, jobMinutes(tier) });
            return error.JobPastTierLimit;
        }
        const count = std.math.clamp(@max(1, std.math.lossyCast(usize, @ceil(record.tests / (room - record.overhead)))), bounds.min, bounds.max);
        size = .{ .count = count, .seconds = record.overhead + record.tests / @as(f64, @floatFromInt(count)) };
    } else {
        var tests: ?f64 = null;
        for (columns) |column| if (try columnSeconds(a, config, column)) |seconds| {
            tests = @max(tests orelse 0, seconds);
        };
        if (tests) |seconds| {
            const count = std.math.clamp(@max(1, std.math.lossyCast(usize, @ceil(2 * seconds / room))), bounds.min, bounds.max);
            size = .{ .count = count, .seconds = 2 * seconds / @as(f64, @floatFromInt(count)) };
        } else {
            // The ci tier takes one job a suite, so a push runs a handful of jobs before any
            // run has measured them: the first full and nightly runs record them.
            const seeded = if (tier == .ci) 1 else try std.math.divCeil(usize, seed_minutes * @as(usize, @backingInt(slowdown)) * 5, jobMinutes(tier) * 4); // the margin, 5/4
            return .{ .count = std.math.clamp(seeded, bounds.min, bounds.max), .seconds = null };
        }
    }
    if (size.seconds.? > room) {
        problem = try a.print("{s}: shards.{s} holds it to {d} jobs, each of {f} of work, more than the {f} a {t} job of {d} minutes holds: raise the cap", .{ name, bounds_key, size.count, wholeSeconds(size.seconds.?), wholeSeconds(room), tier, jobMinutes(tier) });
        return error.JobPastTierLimit;
    }
    return size;
}

/// A suite's job count and the seconds of work each holds, null where no run has measured it.
const Sizing = struct { count: usize, seconds: ?f64 };

/// A suite's jobs, as `size` says, each running its share (`PREFLIGHT_SHARD`) of `base`.
fn suiteLegs(a: std.mem.Allocator, legs: *std.ArrayList(Leg), tier: Tier, base: Job, name: []const u8, size: Sizing) !void {
    for (0..size.count) |i| {
        const shard = try shardName(a, i, size.count);
        var job = base;
        job.name = try a.print("{s}{s}{s}{s}", .{ name, if (size.count > 1) " shard " else "", shard, if (size.seconds == null) unmeasured_mark else "" });
        job.shard = shard;
        job.job_timeout = jobMinutes(tier);
        try legs.append(a, .{ .job = job, .seconds = size.seconds });
    }
}

/// One job that runs whole, held to its tier's minutes: its seconds, as the last runs recorded
/// it, or none, and then its name says so. A job the record puts past its tier's work is refused
/// by name, as one that ran out of its minutes is: nothing splits it.
fn single(a: std.mem.Allocator, config: src.Value, tier: Tier, job: Job, packable: bool) !Leg {
    var each = job;
    each.job_timeout = jobMinutes(tier);
    const record = try recordOf(config, job.name) orelse {
        each.name = try a.print("{s}{s}", .{ job.name, unmeasured_mark });
        return .{ .job = each, .seconds = null, .packable = packable };
    };
    const seconds = record.overhead + record.tests;
    if (!record.finished or seconds > capacity(tier)) {
        problem = try a.print("{s}: {s} in the last run, more than the {f} of work a {t} job of {d} minutes holds", .{
            job.name,
            if (record.finished) try a.print("took {f}", .{wholeSeconds(seconds)}) else "ran out of its minutes",
            wholeSeconds(capacity(tier)),
            tier,
            jobMinutes(tier),
        });
        return error.JobPastTierLimit;
    }
    return .{ .job = each, .seconds = seconds, .packable = packable };
}

/// Deals each runner's jobs into as few jobs as hold them: those the record measures, on one
/// runner and machine, by the longest first into the first job with room for it (`capacity`),
/// each job of several running them in sequence (`legs`, `preflight run` with `PREFLIGHT_LEGS`),
/// each with its own build, shard and records, every one whatever another's outcome. A job no
/// run has measured, and one that shares no job, is a job of its own. A run asks for at most
/// `max_jobs` jobs and `max_macos_jobs` on macOS of what the record measures; a plan past either
/// is refused by name. What no run has measured is not counted: nothing says what it holds, and
/// its run records it.
fn pack(a: std.mem.Allocator, tier: Tier, legs: []const Leg) ![]Job {
    const room = capacity(tier);
    var jobs: std.ArrayList(Job) = .empty;
    const placed = try a.alloc(bool, legs.len);
    @memset(placed, false);
    var counted: std.ArrayList(Job) = .empty;
    for (legs, 0..) |leg, first| {
        if (placed[first]) continue;
        if (!leg.packable or leg.seconds == null) {
            placed[first] = true;
            try jobs.append(a, leg.job);
            if (leg.seconds != null) try counted.append(a, leg.job);
            continue;
        }
        var group: std.ArrayList(usize) = .empty;
        for (legs[first..], first..) |other, index| {
            if (placed[index] or !other.packable or other.seconds == null) continue;
            if (!std.mem.eql(u8, other.job.os, leg.job.os) or other.job.machine != leg.job.machine) continue;
            try group.append(a, index);
        }
        // The longest first, each into the first job it fits; ties in the plan's order.
        std.mem.sort(usize, group.items, legs, struct {
            fn longer(all: []const Leg, x: usize, y: usize) bool {
                return all[x].seconds.? > all[y].seconds.? or (all[x].seconds.? == all[y].seconds.? and x < y);
            }
        }.longer);
        var bins: std.ArrayList(std.ArrayList(usize)) = .empty;
        var loads: std.ArrayList(f64) = .empty;
        for (group.items) |index| {
            placed[index] = true;
            const seconds = legs[index].seconds.?;
            const fitted = for (bins.items, loads.items) |*bin, *load| {
                if (load.* + seconds > room) continue;
                try bin.append(a, index);
                load.* += seconds;
                break true;
            } else false;
            if (!fitted) {
                var bin: std.ArrayList(usize) = .empty;
                try bin.append(a, index);
                try bins.append(a, bin);
                try loads.append(a, seconds);
            }
        }
        for (bins.items, 1..) |bin, part| {
            std.mem.sort(usize, bin.items, {}, std.sort.asc(usize));
            const members = try a.alloc(Job, bin.items.len);
            for (members, bin.items) |*member, index| member.* = legs[index].job;
            var job = try legJob(a, tier, members);
            if (bins.items.len > 1 and members.len > 1) {
                job.name = try a.print("{s} ({d}/{d})", .{ job.name, part, bins.items.len });
                job.cache_key = try key(a, job);
            }
            try jobs.append(a, job);
            try counted.append(a, job);
        }
    }
    try bounded(a, tier, counted.items);
    return jobs.toOwnedSlice(a);
}

/// Refuses a run of more than `max_jobs` jobs, or `max_macos_jobs` on macOS, of those `jobs`
/// counts, naming each runner's.
fn bounded(a: std.mem.Allocator, tier: Tier, jobs: []const Job) !void {
    const limit: usize = if (tier == .nightly) max_jobs - nightly_extra_jobs else max_jobs;
    var macos: usize = 0;
    for (jobs) |job| if (std.mem.eql(u8, job.os, hosts[1])) {
        macos += 1;
    };
    if (jobs.len <= limit and macos <= max_macos_jobs) return;
    var each: std.Io.Writer.Allocating = .init(a);
    for (every_host) |host| {
        var count: usize = 0;
        for (jobs) |job| if (std.mem.eql(u8, job.os, host)) {
            count += 1;
        };
        if (count != 0) try each.writer.print("{s}{s} {d}", .{ if (each.written().len == 0) "" else ", ", host, count });
    }
    problem = if (jobs.len > limit)
        try a.print("the {t} tier asks for {d} jobs ({s}), more than the {d} one run may: GitHub runs the account's {d} at once, which bay paces a batch's runs within; move a job of the package's own to another tier, or shorten what the record measures", .{ tier, jobs.len, each.written(), limit, max_jobs })
    else
        try a.print("the {t} tier asks for {d} macOS jobs, more than the {d} one run may of the account's 5: move a macOS job of the package's own to another tier, or shorten what the record measures", .{ tier, macos, max_macos_jobs });
    return error.TooManyJobs;
}

/// One job that runs `legs`, on one runner and machine, in sequence (`preflight run` with
/// `PREFLIGHT_LEGS`), within its tier's minutes, the legs sharing its deadline.
fn legJob(a: std.mem.Allocator, tier: Tier, legs: []const Job) !Job {
    if (legs.len == 1) return legs[0];
    var setup = false;
    for (legs) |leg| setup = setup or leg.setup;
    var job: Job = .{
        .os = legs[0].os,
        .machine = legs[0].machine,
        .name = try a.print("{s}, {d} legs", .{ legs[0].os, legs.len }),
        .step = "legs",
        .setup = setup,
        .job_timeout = jobMinutes(tier),
        .legs = try std.json.Stringify.valueAlloc(a, legs, job_json),
    };
    job.cache_key = try key(a, job);
    return job;
}

/// The package's own jobs, `jobs` in `ci/workflow.json`: each a build step run on the
/// hosts and in the tiers it names (Linux, and the ci and full tiers, unless it says),
/// with the gate's setup, caches and toolchain, so a run waits for it like any other job
/// of the gate.
///
///     {"name": "conformance", "step": "test", "directory": "conformance",
///      "os": ["ubuntu-latest", "macos-latest"], "tiers": ["ci", "full"],
///      "args": ["-Dsuite=full"], "setup": true, "timeout": 10, "shards": 2}
///
/// `shards` splits a test step over that many jobs per host, as the hosts' own test
/// jobs are split: each runs the share `PREFLIGHT_SHARD` names, balanced by the durations
/// the package records. `timeout` is at most the minutes of each tier it runs in (its own,
/// when shorter); what the record measures of a shard must fit a job of each, or the plan is
/// refused by name: raise its shards.
fn declaredLegs(a: std.mem.Allocator, config: src.Value, tier: Tier, legs: *std.ArrayList(Leg)) !void {
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
            try tiers_named.appendSlice(a, &.{ .ci, .full });
        } else {
            if (tiers != .array or tiers.array.items.len == 0) return error.InvalidDeclaredJob;
            for (tiers.array.items) |item| {
                const text = try src.string(item, "");
                const each = std.meta.stringToEnum(Tier, text) orelse .fuzz;
                // The fuzz tier is the fuzz job's alone.
                if (each == .fuzz) {
                    problem = try a.print("jobs: {s}: `{s}` is no tier a job of the package's own runs in: ci, full or nightly", .{ name, text });
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
            var seconds: ?f64 = null;
            if (!advisory) if (try recordOf(config, hosted_name)) |record| {
                const each = record.overhead + record.tests / @as(f64, @floatFromInt(count));
                if (!record.finished or each > capacity(tier)) {
                    problem = try a.print("jobs: {s}: {s} in the last run, more than the {f} of work a {t} job of {d} minutes holds: raise its shards", .{
                        hosted_name,
                        if (record.finished) try a.print("a shard of {d} takes {f}", .{ count, wholeSeconds(each) }) else "a shard ran out of its minutes",
                        wholeSeconds(capacity(tier)),
                        tier,
                        jobMinutes(tier),
                    });
                    return error.JobPastTierLimit;
                }
                seconds = each;
            };
            for (0..count) |i| {
                const shard = try shardName(a, i, count);
                const named = if (count > 1) try a.print("{s} shard {s}", .{ hosted_name, shard }) else hosted_name;
                const job: Job = .{
                    .os = os,
                    .name = if (advisory) try a.print("{s} (non-blocking)", .{named}) else if (seconds == null) try a.print("{s}{s}", .{ named, unmeasured_mark }) else named,
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
                // An advisory job runs alone, counted: in a leg its failure would be the legs job's.
                try legs.append(a, .{ .job = job, .seconds = if (advisory) 0 else seconds, .packable = !advisory });
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
fn configurationLegs(a: std.mem.Allocator, config: src.Value, legs: *std.ArrayList(Leg)) !void {
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
        try legs.append(a, try single(a, config, .ci, .{
            .os = hosts[0],
            .name = try a.print("{s} ({s})", .{ compile, name.string }),
            .step = compile,
            .args = std.mem.trimStart(u8, try a.print("-Dci-lint=false{s}{s}", .{ args.written(), try buildArgs(a, src.get(config, "build_args")) }), " "),
        }, true));
    }
}

/// The test jobs of one host: each mode's suite, sized by its record (`sizing`).
fn hostLegs(a: std.mem.Allocator, config: src.Value, legs: *std.ArrayList(Leg), tier: Tier, host: []const u8, host_name: []const u8, modes: []const Mode) !void {
    for (modes) |mode| {
        const name = try a.print("test ({s}, {s})", .{ host, title(mode) });
        const base: Job = .{
            .os = host,
            .name = name,
            .args = try a.print("-Doptimize={t} -Dci-lint=false -Dci-timings=true{s}", .{ mode, try buildArgs(a, src.get(config, "build_args")) }),
            .setup = true,
        };
        try suiteLegs(a, legs, tier, base, name, try sizing(a, config, tier, name, host_name, try columnsOf(a, stemOf(host_name), &.{mode}), .native));
    }
}

/// The Debug suite on riscv64 Linux, which no hosted runner is: built for it on the Linux
/// runner, static with musl, and run on a riscv64 Linux kernel QEMU emulates (`-Dci-vm`), so
/// that what a kernel does (reaping, pidfds, io_uring, file maps) is a kernel's, not a
/// user-mode emulator's. Emulated, a suite takes several times as long as on a runner; its
/// durations, QEMU's, are a column of their own, which balances its shards.
fn emulatedLegs(a: std.mem.Allocator, config: src.Value, legs: *std.ArrayList(Leg)) !void {
    const name = "test (riscv64-linux on its kernel under QEMU, Debug)";
    const base: Job = .{
        .os = hosts[0],
        .name = name,
        .args = try a.print("-Doptimize=debug -Dci-lint=false -Dci-timings=true -Dtarget=riscv64-linux-musl -Dci-vm{s}", .{try buildArgs(a, src.get(config, "build_args"))}),
        .setup = true,
        .machine = .riscv64,
    };
    try suiteLegs(a, legs, .nightly, base, name, try sizing(a, config, .nightly, name, emulated_host_name, &.{emulated_column}, .qemu));
}

/// The `ci/durations.json` column the riscv64 suite records, as its test runner names it.
const emulated_column = "linux-riscv64-debug";

/// A floor and a cap on a suite's job count, which `shards.<host>` sets where a package means
/// one beside its record: `{"min": 2}` keeps two jobs whatever the record says, `{"max": 4}`
/// holds it to four.
const Bounds = struct { min: usize = 1, max: usize = std.math.maxInt(usize) };

/// `shards.<host>`, read: an object of `min`, `max` or both, each a count of at least one.
fn shardBounds(a: std.mem.Allocator, shards: src.Value, host: []const u8) !Bounds {
    const value = src.get(shards, host);
    if (value == .null) return .{};
    if (value != .object or value.object.count() == 0) {
        problem = try a.print("shards.{s}: {{\"min\": n}}, {{\"max\": n}} or both, a floor or a cap on the jobs its record makes", .{host});
        return error.InvalidShardCount;
    }
    var bounds: Bounds = .{};
    for (value.object.keys(), value.object.values()) |bound, count| {
        if (count == .null) return error.InvalidShardCount;
        if (std.mem.eql(u8, bound, "min")) {
            bounds.min = try shardCount(count);
        } else if (std.mem.eql(u8, bound, "max")) {
            bounds.max = try shardCount(count);
        } else return error.InvalidShardCount;
    }
    if (bounds.min > bounds.max) return error.InvalidShardCount;
    return bounds;
}

/// The seconds of tests one column holds, by `ci/durations.json`: null where it records none.
/// A column a finished run measured (`complete`) holds every test that job runs, and only those
/// are weighed: a test it lacks does not run there (an end-to-end suite the emulated build leaves
/// out). Any other column weighs every test, one it has none of at its Linux Debug time scaled
/// as the tests both recorded ran (`order.estimate`), so a suite whose run never finished is
/// still sized by what it did run.
fn columnSeconds(a: std.mem.Allocator, config: src.Value, column: []const u8) !?f64 {
    const durations = src.get(config, "durations");
    if (durations == .null) return null;
    const tests = src.get(durations, "tests");
    if (tests == .null) return null;
    if (tests != .object) return error.InvalidDurations;
    const names = if (try completeColumn(durations, column)) try recordedIn(a, durations, column) else tests.object.keys();
    if (names.len == 0) return null;
    const estimate = preflight_order.estimate(a, durations, names, column) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidDurations => return error.InvalidDurations,
    };
    if (estimate.recorded == 0) return null;
    var total: f64 = 0;
    for (estimate.weights) |seconds| total += seconds;
    return total;
}

/// A host's columns in `modes`: `<stem>-<mode>`, as its test runner names them (`order.key`).
fn columnsOf(a: std.mem.Allocator, stem: []const u8, modes: []const Mode) ![]const []const u8 {
    const out = try a.alloc([]const u8, modes.len);
    for (out, modes) |*column, mode| column.* = try a.print("{s}-{t}", .{ stem, mode });
    return out;
}

/// The stem of a `shards` host's columns: its system, and its architecture where a system's
/// runners have two.
fn stemOf(host: []const u8) []const u8 {
    for (host_names ++ arm_host_names, [_][]const u8{ "linux", "macos", "windows", "linux-aarch64", "windows-aarch64" }) |name, stem| {
        if (std.mem.eql(u8, name, host)) return stem;
    }
    unreachable; // every caller names a host of `host_names` or `arm_host_names`
}

/// Whether a finished run measured `column` last (`complete` in `ci/durations.json`): it holds
/// every test that job runs.
fn completeColumn(durations: src.Value, column: []const u8) !bool {
    for (try src.items(src.get(durations, "complete"))) |each| {
        if (each != .string) return error.InvalidDurations;
        if (std.mem.eql(u8, each.string, column)) return true;
    }
    return false;
}

/// The tests `column` records a time of.
fn recordedIn(a: std.mem.Allocator, durations: src.Value, column: []const u8) ![]const []const u8 {
    const columns = try src.items(src.get(durations, "keys"));
    const index = for (columns, 0..) |named, i| {
        if (named == .string and std.mem.eql(u8, named.string, column)) break i;
    } else return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var rows = src.get(durations, "tests").object.iterator();
    while (rows.next()) |row| {
        const cells = try src.items(row.value_ptr.*);
        if (cells.len != columns.len) return error.InvalidDurations;
        if (cells[index] != .null) try out.append(a, row.key_ptr.*);
    }
    return out.items;
}

/// The Debug suite on x86_64 FreeBSD, which no hosted runner is: built for it on the Linux
/// runner and run on FreeBSD's own kernel under KVM (`-Dci-vm`), so that what a package
/// claims of FreeBSD (kqueue, its sockets and kernel TLS) has a kernel's evidence, not a
/// cross-compile's. Its durations are a column of their own.
fn freebsdLegs(a: std.mem.Allocator, config: src.Value, legs: *std.ArrayList(Leg)) !void {
    const name = "test (x86_64-freebsd on its kernel under KVM, Debug)";
    const base: Job = .{
        .os = hosts[0],
        .name = name,
        .args = try a.print("-Doptimize=debug -Dci-lint=false -Dci-timings=true -Dtarget=x86_64-freebsd -Dci-vm{s}", .{try buildArgs(a, src.get(config, "build_args"))}),
        .setup = true,
        .machine = .freebsd,
    };
    try suiteLegs(a, legs, .nightly, base, name, try sizing(a, config, .nightly, name, freebsd_host_name, &.{"freebsd-debug"}, .kvm));
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
/// test jobs'. A target's tests' durations share its runner's column: its system,
/// architecture and mode are the runner's, and a column keeps each test's longest time.
fn ownTargetLegs(a: std.mem.Allocator, config: src.Value, legs: *std.ArrayList(Leg)) !void {
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
            .args = try a.print("-Doptimize=debug -Dci-timings=true{s}", .{options.written()}),
            .setup = true,
            .target = name,
        };
        try suiteLegs(a, legs, .full, base, suite, try sizing(a, config, .full, suite, runner.name, try columnsOf(a, stemOf(runner.name), &.{.debug}), .native));
    }
}

/// The source checks: format, structure, the code rules, layout and the package's own extra
/// checks. Nothing in them runs a test, so they need neither the external tools nor a test
/// build. The full tier's (`-Dci-release`) fail on every aegis-pack finding; a landing's
/// report the flow rules'.
fn lintLeg(a: std.mem.Allocator, config: src.Value, tier: Tier) !Leg {
    return single(a, config, tier, .{
        .os = hosts[0],
        .name = "source checks",
        .step = "lint",
        .args = std.mem.trimStart(u8, try a.print("{s}{s}", .{ if (tier == .full) " -Dci-release" else "", try buildArgs(a, src.get(config, "build_args")) }), " "),
    }, true);
}

/// The documented snippets, a leg of their own: a red lint, or one that refuses its
/// configuration, never hides a broken snippet.
fn snippetsLeg(a: std.mem.Allocator, config: src.Value, tier: Tier) !Leg {
    return single(a, config, tier, .{
        .os = hosts[0],
        .name = "documented snippets",
        .step = "snippets",
        .args = std.mem.trimStart(u8, try buildArgs(a, src.get(config, "build_args")), " "),
    }, true);
}

/// The target a `targets` entry names: a triple, or an object's `target`.
pub fn targetName(target: src.Value) src.TypeError![]const u8 {
    return if (target == .string) target.string else try src.string(src.get(target, "target"), "");
}

/// The seconds of compiling one cross job is given, when `cross_seconds` does not say.
const default_cross_seconds = 200;
/// What a cross job spends before it compiles (checkout, Zig, caches, the toolchain), which
/// its tier's minutes must leave room for: relic's jobs took about four minutes.
const cross_setup_seconds = 300;

/// `seconds`, to the nearest second, as a duration prints.
fn wholeSeconds(seconds: f64) aegis.units.Duration(.second, i64) {
    return .fromRaw(std.math.lossyCast(i64, @round(seconds)));
}

/// The seconds `name` takes to compile, as the last full run
/// measured them (`ci/costs.json`, which the plan reads as `measured`), the
/// benchmarks too when `bench` is set; null when nothing was measured.
fn targetSeconds(a: std.mem.Allocator, config: src.Value, name: []const u8, bench: bool) !?f64 {
    const phases = src.get(src.get(config, "measured"), "phases");
    if (phases != .object) return null;
    const compiled = number(phases.object.get(try a.print("compile {s}", .{name})) orelse return null) orelse return null;
    if (!bench) return compiled;
    const benchmarks = number(phases.object.get(try a.print("benchmarks {s}", .{name})) orelse return null) orelse return null;
    return compiled + benchmarks;
}

/// The jobs at once a cross job of `names` runs its builds with on `hosts[0]`: as many of its
/// targets' largest single compiles as fit `memory_share_percent` of its memory (the most one
/// process held, as `ci/costs.json` records each phase), at most its CPUs; the fewest any of its
/// targets allows. Compiles run at once do not each hold a share of the tree's peak: one may
/// hold most of it. A target whose compile no run measured allows one: one compile at a time
/// is the floor, which always fits, and the run that compiles it records it. relic's
/// x86_64-windows-gnu held 15 GiB at -j4 on a 16 GB runner, 8.6 GB of it in one compile.
fn crossBuildJobs(a: std.mem.Allocator, config: src.Value, names: []const []const u8, bench: bool) !u32 {
    const room = host_memory[0] / 100 * memory_share_percent;
    var jobs: u32 = host_cpus[0];
    for (names) |name| for ([_][]const u8{ "compile", "benchmarks" }, 0..) |label, index| {
        if (index == 1 and !bench) break;
        const one = try singlePeak(config, try a.print("{s} {s}", .{ label, name })) orelse return 1;
        jobs = @min(jobs, std.math.cast(u32, room / @max(one, 1)) orelse jobs);
    };
    return @max(jobs, 1);
}

/// The most one process of a phase held, in bytes, as `ci/costs.json`'s `peaks` records the
/// phase; null where it records none.
fn singlePeak(config: src.Value, phase: []const u8) !?u64 {
    const peaks = src.get(src.get(config, "measured"), "peaks");
    if (peaks != .object) return null;
    const entry = peaks.object.get(phase) orelse return null;
    const one = src.get(entry, "single");
    if (one != .integer or one.integer < 0) return error.InvalidPeak;
    return @intCast(one.integer); // safe: not negative, checked above
}

fn number(value: src.Value) ?f64 {
    return switch (value) {
        .float => |seconds| seconds,
        .integer => |seconds| @floatFromInt(seconds),
        else => null,
    };
}

/// The object compile of `targets`, in as many jobs as `cross_jobs` asks for, or as few as hold
/// `cross_seconds` (200) of compiling each, by what the last run measured of every target
/// (`ci/costs.json`); a target it has not measured has a job of its own, named for it. The
/// longest target goes first onto the job with the least, so the jobs end together. With
/// `bench`, each job also compiles the ReleaseFast benchmarks. A cross job shares no job: its
/// work is sized by its targets' costs, not by a record of its own.
fn crossLegs(a: std.mem.Allocator, config: src.Value, legs: *std.ArrayList(Leg), tier: Tier, targets: []const src.Value, bench: bool) !void {
    if (targets.len == 0) return;
    const wanted = src.get(config, "cross_jobs");
    if (wanted != .null and (wanted != .integer or wanted.integer < 1)) return error.InvalidCrossJobs;
    const budget = src.get(config, "cross_seconds");
    if (budget != .null and !((number(budget) orelse 0) > 0)) return error.InvalidCrossSeconds;
    // A target no run has measured is packed with nothing: no guess of its cost can be trusted
    // to fit a bound (strand's x86_64-windows-gnu, costed at a guess of 90 s with no
    // ci/costs.json, outran its 20 minutes, run 43777274923). Its job measures it, and from then
    // on the bound below holds it, or refuses it by name.
    var unmeasured: std.ArrayList(usize) = .empty;
    var kept: std.ArrayList(usize) = .empty;
    const cost = try a.alloc(f64, targets.len);
    for (targets, cost, 0..) |target, *seconds, index| {
        if (try targetSeconds(a, config, try targetName(target), bench)) |measured| {
            seconds.* = measured;
            try kept.append(a, index);
        } else {
            seconds.* = 0;
            try unmeasured.append(a, index);
        }
    }
    const order = kept.items;
    std.mem.sort(usize, order, cost, struct {
        fn longer(costs: []const f64, x: usize, y: usize) bool {
            return costs[x] > costs[y];
        }
    }.longer);
    // A job holds at most what its tier's minutes leave after its setup, so no plan deals a job
    // more compiling than it can finish (relic's 975 s target in 20 minutes ended two jobs at
    // their bound, run 43737703239); a target past that is refused.
    const room = @as(f64, @floatFromInt(jobMinutes(tier) * 60)) - cross_setup_seconds;
    var heaviest: f64 = 0;
    for (order) |index| if (cost[index] > room) {
        problem = try a.print("{s} takes {f} to compile, more than the {f} a {t} job of {d} minutes leaves after its setup", .{ try targetName(targets[index]), wholeSeconds(cost[index]), wholeSeconds(room), tier, jobMinutes(tier) });
        return error.CrossTargetPastTimeout;
    } else {
        heaviest = @max(heaviest, cost[index]);
    };
    // A job cannot be shorter than the longest target, so more jobs stop helping there.
    const limit = @min(@max(number(budget) orelse default_cross_seconds, heaviest), room);
    const assignment = try a.alloc(usize, targets.len);
    const load = try a.alloc(f64, @max(order.len, 1));
    var count: usize = 0;
    if (order.len > 0) {
        // `cross_jobs` counts every job, an unmeasured target's among them.
        count = if (wanted == .null) 1 else std.math.clamp((std.math.cast(usize, wanted.integer) orelse return error.InvalidCrossJobs) -| unmeasured.items.len, 1, order.len);
        var longest: f64 = 0;
        while (true) : (count += 1) {
            @memset(load[0..count], 0);
            longest = 0;
            for (order) |index| {
                var least: usize = 0;
                for (load[0..count], 0..) |seconds, group| if (seconds < load[least]) {
                    least = group;
                };
                assignment[index] = least;
                load[least] += cost[index];
                longest = @max(longest, load[least]);
            }
            if (wanted != .null or count == order.len or longest <= limit) break;
        }
        if (longest > room) {
            problem = try a.print("cross_jobs {d} puts {f} of compiling in one job, more than the {f} a {t} job of {d} minutes leaves after its setup: raise cross_jobs", .{ count + unmeasured.items.len, wholeSeconds(longest), wholeSeconds(room), tier, jobMinutes(tier) });
            return error.CrossJobPastTimeout;
        }
    }
    for (unmeasured.items, 0..) |index, nth| assignment[index] = count + nth;
    const total = count + unmeasured.items.len;
    for (0..total) |group| {
        var names: std.ArrayList(u8) = .empty;
        var named: std.ArrayList([]const u8) = .empty;
        for (targets, assignment) |target, owner| if (owner == group) {
            if (names.items.len > 0) try names.append(a, ' ');
            try names.appendSlice(a, try targetName(target));
            try named.append(a, try targetName(target));
        };
        const alone = group >= count;
        try legs.append(a, .{
            .job = .{
                .os = hosts[0],
                .name = if (alone)
                    try a.print("Cross compile {s}{s}", .{ names.items, unmeasured_mark })
                else
                    try a.print("Cross compile{s}{s}", .{ if (total > 1) " " else "", try shardName(a, group, total) }),
                .step = if (bench) "preflight-cross-bench" else "preflight-cross",
                .operation = .objects,
                .job_timeout = jobMinutes(tier),
                .targets = names.items,
                .build_jobs = try crossBuildJobs(a, config, named.items, bench),
            },
            .seconds = if (alone) null else load[group] + cross_setup_seconds,
            .packable = false,
        });
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
    for (shard_hosts) |host| _ = try shardBounds(a, shards, host);
    if (shards == .object) for (shards.object.keys()) |host| {
        for (shard_hosts) |known| {
            if (std.mem.eql(u8, known, host)) break;
        } else {
            problem = try a.print("shards: `{s}` is no host", .{host});
            return error.InvalidShardCount;
        }
    };
}

/// The links of each configured target that needs a system's SDK or linker: Windows' on the
/// Windows runner, and macOS's that link a framework on a Mac (Zig links any other macOS
/// program on Linux with the libSystem it ships).
fn sdkLegs(a: std.mem.Allocator, config: src.Value, legs: *std.ArrayList(Leg)) !void {
    for (try src.items(src.get(config, "targets"))) |target| {
        const options = try crossOptions(a, config, target);
        const name = options[1]["-Dtarget=".len..];
        const query = try std.Target.Query.parse(.{ .arch_os_abi = name });
        // Zig links a macOS program on Linux with the libSystem it ships; a framework needs
        // Apple's SDK, which only a Mac holds.
        const host = switch (query.os_tag orelse return error.InvalidCrossTarget) {
            .macos => if (try linksFramework(a, config, name)) hosts[1] else hosts[0],
            .windows => hosts[2],
            else => continue,
        };
        var text: std.Io.Writer.Allocating = .init(a);
        defer text.deinit();
        for (options) |arg| try text.writer.print("{s}{s}", .{ if (text.written().len == 0) "" else " ", arg });
        try legs.append(a, try single(a, config, .full, .{ .os = host, .name = try a.print("{s}link ({s})", .{ if (std.mem.eql(u8, host, hosts[0])) "" else "SDK ", name }), .step = "ci-link", .args = try text.toOwnedSlice(), .setup = true, .operation = .link }, true));
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

/// The command that makes the objects of `target` in Debug: the build's `step`,
/// `ci-check`, or `ci-check-bench` for the ReleaseFast benchmarks.
pub fn crossArgs(a: std.mem.Allocator, command: []const []const u8, config: src.Value, target: src.Value, step: []const u8, jobs: ?u32) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, command);
    try args.append(a, step);
    try args.appendSlice(a, try crossOptions(a, config, target));
    try args.append(a, "-Doptimize=debug");
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

/// `config` with a record of each of `names` (`legs` in `ci/durations.json`): `seconds` of
/// work, one shard, finished.
fn withRecords(a: std.mem.Allocator, config: []const u8, names: []const []const u8, seconds: f64) !src.Value {
    var legs: std.Io.Writer.Allocating = .init(a);
    for (names, 0..) |name, i| try legs.writer.print("{s}\"{s}\":{{\"overhead\":{d},\"tests\":0,\"shards\":1,\"finished\":true}}", .{ if (i == 0) "" else ",", name, seconds });
    var value = try parseJson(a, config);
    try value.object.put(a, "durations", try parseJson(a, try a.print("{{\"legs\":{{{s}}}}}", .{legs.written()})));
    return value;
}

/// The record names of `jobs`, sorted.
fn recordNames(a: std.mem.Allocator, jobs: []const Job) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (jobs) |job| {
        const name = recordName(job.name);
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

fn expectRecords(a: std.mem.Allocator, jobs: []const Job, want: []const []const u8) !void {
    const sorted = try a.dupe([]const u8, want);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn before(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.before);
    const got = try recordNames(a, jobs);
    try std.testing.expectEqual(sorted.len, got.len);
    for (sorted, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

/// How many of `jobs` are named `name` less shard and mark.
fn jobsNamed(jobs: []const Job, name: []const u8) usize {
    var n: usize = 0;
    for (jobs) |job| n += @intFromBool(std.mem.eql(u8, recordName(job.name), name));
    return n;
}

test "a job's record name is its name without its shard or its unmeasured mark" {
    try std.testing.expectEqualStrings("test (ubuntu-latest, Debug)", recordName("test (ubuntu-latest, Debug) shard 2/3, unmeasured"));
    try std.testing.expectEqualStrings("test (ubuntu-latest, Debug)", recordName("test (ubuntu-latest, Debug) shard 2/3"));
    try std.testing.expectEqualStrings("source checks", recordName("source checks, unmeasured"));
    try std.testing.expectEqualStrings("Cross compile 1/2", recordName("Cross compile 1/2"));
    try std.testing.expectEqualStrings("git master", recordName("git master shard 1/2 (non-blocking)"));
}

test "every job of a tier ends within its minutes: ten in ci, fifteen in full and nightly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a, "{\"policy\":\"family\",\"fuzzed\":true,\"targets\":[\"aarch64-linux-gnu\",\"x86_64-windows-msvc\",\"x86_64-linux-musl\"],\"configurations\":[{\"name\":\"plain\"}],\"jobs\":[{\"name\":\"own\",\"step\":\"own\",\"tiers\":[\"ci\",\"full\",\"nightly\"]}]}");
    for ([_]Tier{ .ci, .full, .nightly, .fuzz }) |tier| {
        for (try planned(a, config, tier)) |job| try std.testing.expectEqual(jobMinutes(tier), job.job_timeout);
        for (try plan(a, config, tier)) |job| try std.testing.expectEqual(jobMinutes(tier), job.job_timeout);
    }
    try std.testing.expectEqual(@as(usize, 10), jobMinutes(.ci));
    try std.testing.expectEqual(@as(usize, 15), jobMinutes(.full));
    // No job passes a test timeout: the watchdog bounds each test.
    for (try planned(a, config, .full)) |job| try std.testing.expect(std.mem.find(u8, job.args, "test-timeout") == null);
}

test "the ci tier is the source checks, the Debug suite on Linux, macOS and Windows, the targets' objects and the configurations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a, "{\"cross_jobs\":1,\"targets\":[\"aarch64-linux-gnu\"],\"hardened\":true,\"fuzzed\":true,\"measured\":{\"phases\":{\"compile aarch64-linux-gnu\":30}},\"configurations\":[{\"name\":\"plain\"}]}");
    const jobs = try planned(a, config, .ci);
    try expectRecords(a, jobs, &.{ "source checks", "documented snippets", "test (ubuntu-latest, Debug)", "test (macos-latest, Debug)", "test (windows-latest, Debug)", "Cross compile", "check (plain)" });
    for (jobs) |job| {
        if (std.mem.startsWith(u8, job.name, "test (")) {
            try std.testing.expectEqualStrings("ci-test", job.step);
            try std.testing.expectEqualStrings("-Doptimize=debug -Dci-lint=false -Dci-timings=true", job.args);
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
    // The ci tier's Linux Debug and the full tier's are one suite, one record.
    for (try planned(a, config, .full)) |job| if (std.mem.eql(u8, recordName(job.name), "test (ubuntu-latest, Debug)")) {
        try std.testing.expectEqualStrings(jobs[2].args, job.args);
    };
}

test "the full tier is every mode on every runner, the targets' suites, links and compiles, and none of the heavy legs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a, "{\"targets\":[\"aarch64-linux-gnu\"],\"policy\":\"family\",\"fuzzed\":true,\"measured\":{\"phases\":{\"compile aarch64-linux-gnu\":30,\"benchmarks aarch64-linux-gnu\":5}}}");
    const jobs = try planned(a, config, .full);
    try expectRecords(a, jobs, &.{
        "test (ubuntu-latest, Debug)",          "test (ubuntu-latest, ReleaseSafe)",      "test (ubuntu-latest, ReleaseFast)",
        "test (macos-latest, Debug)",           "test (macos-latest, ReleaseSafe)",       "test (macos-latest, ReleaseFast)",
        "test (windows-latest, Debug)",         "test (windows-latest, ReleaseSafe)",     "test (windows-latest, ReleaseFast)",
        "test (ubuntu-24.04-arm, Debug)",       "test (ubuntu-24.04-arm, ReleaseSafe)",   "test (ubuntu-24.04-arm, ReleaseFast)",
        "test (windows-11-arm, Debug)",         "test (windows-11-arm, ReleaseSafe)",     "test (windows-11-arm, ReleaseFast)",
        "source checks",                        "documented snippets",                    "compile (ubuntu-latest, ReleaseSmall)",
        "compile (macos-latest, ReleaseSmall)", "compile (windows-latest, ReleaseSmall)", "Cross compile",
        // Under the family's policy the hardened profile is every package's: its safety-on run here.
        "hardened",
    });
    for (jobs) |job| {
        try std.testing.expect(job.machine == .none);
        if (std.mem.eql(u8, job.step, "ci-test")) try std.testing.expect(std.mem.find(u8, job.args, "-Dci-timings=true") != null);
    }
    try std.testing.expect(std.mem.find(u8, (for (jobs) |job| {
        if (std.mem.eql(u8, job.step, "preflight-cross-bench")) break job;
    } else return error.NoCrossJob).targets, "aarch64-linux-gnu") != null);
}

test "the nightly tier is the heavy legs: riscv64 and FreeBSD on their kernels, ThreadSanitizer, the fuzz runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a, "{\"targets\":[\"aarch64-linux-gnu\"],\"policy\":\"family\",\"fuzzed\":true}");
    const jobs = try planned(a, config, .nightly);
    try expectRecords(a, jobs, &.{ "test (riscv64-linux on its kernel under QEMU, Debug)", "test (x86_64-freebsd on its kernel under KVM, Debug)", "hardened-tsan", "hardened-fuzz", "fuzz" });
    for (jobs) |job| switch (job.machine) {
        .none => try std.testing.expectEqualStrings(hosts[0], job.os),
        .riscv64 => try std.testing.expect(std.mem.find(u8, job.args, "-Dci-timings=true -Dtarget=riscv64-linux-musl -Dci-vm") != null),
        .freebsd => {
            try std.testing.expectEqualStrings(hosts[0], job.os);
            try std.testing.expect(std.mem.find(u8, job.args, "-Dci-timings=true -Dtarget=x86_64-freebsd -Dci-vm") != null);
        },
    };
    // The fuzz runs share no job: their corpora are their jobs'.
    for (try plan(a, config, .nightly)) |job| if (job.legs) |text| {
        try std.testing.expect(std.mem.find(u8, text, "ci-fuzz") == null and std.mem.find(u8, text, "hardened-fuzz") == null);
    };
}

test "a suite no run has measured is seeded: one job in the ci tier, else the old plan's twenty minutes, scaled, in jobs of their own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a, "{\"policy\":\"family\"}");
    // One job a suite in the ci tier, so a push runs a handful; in the others, 20 minutes x
    // slowdown x 5/4 in jobs of the tier's minutes.
    for ([_]struct { Tier, []const u8, usize }{
        .{ .ci, "test (ubuntu-latest, Debug)", 1 },
        .{ .ci, "test (windows-latest, Debug)", 1 },
        .{ .full, "test (ubuntu-latest, Debug)", 2 },
        .{ .full, "test (macos-latest, ReleaseFast)", 2 },
        .{ .full, "hardened", 2 },
        .{ .nightly, "test (riscv64-linux on its kernel under QEMU, Debug)", 7 },
        .{ .nightly, "test (x86_64-freebsd on its kernel under KVM, Debug)", 4 },
        .{ .nightly, "hardened-tsan", 5 },
    }) |case| {
        const tier, const name, const want = case;
        const jobs = try plan(a, config, tier);
        try std.testing.expectEqual(want, jobsNamed(jobs, name));
        for (jobs) |job| if (std.mem.eql(u8, recordName(job.name), name)) {
            try std.testing.expect(std.mem.endsWith(u8, job.name, ", unmeasured"));
            try std.testing.expect(job.legs == null);
        };
    }
    // What no run measured is no bound's to count: the unmeasured full tier asks for more
    // than twenty jobs, and its run records what the next plan is sized by.
    try std.testing.expect((try plan(a, config, .full)).len > max_jobs);
    // `shards` floors and caps a seed as it does a record.
    const floored = try parseJson(a, "{\"shards\":{\"riscv64\":{\"max\":3},\"linux\":{\"min\":4}}}");
    try std.testing.expectEqual(@as(usize, 3), jobsNamed(try plan(a, floored, .nightly), "test (riscv64-linux on its kernel under QEMU, Debug)"));
    try std.testing.expectEqual(@as(usize, 4), jobsNamed(try plan(a, floored, .ci), "test (ubuntu-latest, Debug)"));
    for ([_][]const u8{ "{\"shards\":{\"windows\":6}}", "{\"shards\":{\"windows\":{\"min\":3,\"max\":2}}}", "{\"shards\":{\"windows\":{}}}", "{\"shards\":{\"windows\":{\"most\":2}}}", "{\"shards\":{\"solaris\":{\"min\":2}}}", "{\"shards\":{\"tsan\":{\"min\":0}}}" }) |text| {
        try std.testing.expectError(error.InvalidShardCount, plan(a, try parseJson(a, text), .full));
    }
}

test "a suite the record measures takes as few jobs as hold its tests beside what its setup and build took" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const name = "test (windows-latest, Debug)";
    const record = struct {
        fn of(allocator: std.mem.Allocator, overhead: f64, tests: f64, shards: usize, finished: bool, extra: []const u8) !src.Value {
            return parseJson(allocator, try allocator.print("{{{s}\"durations\":{{\"legs\":{{\"test (windows-latest, Debug)\":{{\"overhead\":{d},\"tests\":{d},\"shards\":{d},\"finished\":{}}}}}}}}}", .{ extra, overhead, tests, shards, finished }));
        }
    }.of;
    // A full job holds 720 s of work: 100 s of setup leaves 620 s of tests, 2000 s in four.
    try std.testing.expectEqual(@as(usize, 4), jobsNamed(try planned(a, try record(a, 100, 2000, 3, true, ""), .full), name));
    // A ci job holds 480 s: 380 s of tests a job, six.
    try std.testing.expectEqual(@as(usize, 6), jobsNamed(try planned(a, try record(a, 100, 2000, 3, true, ""), .ci), name));
    // A suite whose jobs ran out of their minutes takes twice as many.
    try std.testing.expectEqual(@as(usize, 6), jobsNamed(try planned(a, try record(a, 100, 2000, 3, false, ""), .full), name));
    for (try planned(a, try record(a, 100, 2000, 3, true, ""), .full)) |job| if (std.mem.eql(u8, recordName(job.name), name)) {
        try std.testing.expect(std.mem.find(u8, job.name, "unmeasured") == null);
    };
    // A setup and build past a job's work, or a cap that leaves a job more than it holds, is
    // refused by name: nothing splits it.
    problem = "";
    try std.testing.expectError(error.JobPastTierLimit, planned(a, try record(a, 800, 100, 1, true, ""), .full));
    try std.testing.expect(std.mem.startsWith(u8, problem, name));
    try std.testing.expectError(error.JobPastTierLimit, planned(a, try record(a, 100, 2000, 1, true, "\"shards\":{\"windows\":{\"max\":2}},"), .full));
    try std.testing.expect(std.mem.find(u8, problem, "shards.windows holds it to 2 jobs") != null);
    // A malformed record is refused, never read as none.
    try std.testing.expectError(error.InvalidDurations, planned(a, try parseJson(a, "{\"durations\":{\"legs\":{\"test (windows-latest, Debug)\":{\"overhead\":-1,\"tests\":0,\"shards\":1,\"finished\":true}}}}"), .full));
}

test "a suite with only its tests' seconds takes as many jobs as hold twice those, a finished column's tests alone weighed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Linux Debug records 1300 s: 2600 s of work in ci jobs of 480 s, six; in full jobs of 720 s, four.
    const config = try parseJson(a, "{\"durations\":{\"keys\":[\"linux-debug\"],\"complete\":[\"linux-debug\"],\"tests\":{\"a\":[500],\"b\":[400],\"c\":[400]}}}");
    try std.testing.expectEqual(@as(usize, 6), jobsNamed(try planned(a, config, .ci), "test (ubuntu-latest, Debug)"));
    try std.testing.expectEqual(@as(usize, 4), jobsNamed(try planned(a, config, .full), "test (ubuntu-latest, Debug)"));
    // bay's shape: unit tests the emulated job runs, and end-to-end tests it never runs. A
    // finished column weighs only the tests that job runs: one job.
    const tests =
        \\"unit.a":[0.5,4],"unit.b":[0.2,2],"unit.c":[0.1,1],"e2e.resolve":[100,null],"e2e.release":[110,null],"e2e.prebuilt":[95,null]
    ;
    const riscv64 = "test (riscv64-linux on its kernel under QEMU, Debug)";
    const finished = try parseJson(a, "{\"durations\":{\"keys\":[\"linux-debug\",\"linux-riscv64-debug\"],\"complete\":[\"linux-riscv64-debug\"],\"tests\":{" ++ tests ++ "}}}");
    try std.testing.expectEqual(@as(usize, 1), jobsNamed(try planned(a, finished, .nightly), riscv64));
    // Before any finished run an end-to-end test the column lacks weighs its Linux time
    // scaled, as a cut job may never have reached it: more jobs.
    const cut = try parseJson(a, "{\"durations\":{\"keys\":[\"linux-debug\",\"linux-riscv64-debug\"],\"tests\":{" ++ tests ++ "}}}");
    try std.testing.expect(jobsNamed(try planned(a, cut, .nightly), riscv64) > 1);
}

test "pack deals a runner's measured work into as few jobs as hold it, the longest first, each of several a job of legs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const leg = struct {
        fn of(os: []const u8, name: []const u8, seconds: ?f64, packable: bool) Leg {
            return .{ .job = .{ .os = os, .name = name, .job_timeout = 15, .cache_key = name }, .seconds = seconds, .packable = packable };
        }
    }.of;
    // 400, 300, 300 and 200 s on macOS in jobs of 720 s: 400 + 300, then 300 + 200.
    const jobs = try pack(a, .full, &.{
        leg(hosts[1], "m1", 300, true),   leg(hosts[0], "l1", 100, true), leg(hosts[1], "m2", 400, true),
        leg(hosts[1], "m3", 200, true),   leg(hosts[1], "m4", 300, true), leg(hosts[0], "fuzz", 500, false),
        leg(hosts[0], "new", null, true),
    });
    try std.testing.expectEqual(@as(usize, 5), jobs.len);
    try std.testing.expectEqualStrings("macos-latest, 2 legs (1/2)", jobs[0].name);
    try std.testing.expectEqualStrings("legs", jobs[0].step);
    try std.testing.expectEqual(@as(usize, 15), jobs[0].job_timeout);
    // A job's legs run in the plan's order.
    const first = try std.json.parseFromSliceLeaky([]const Job, a, jobs[0].legs.?, .{});
    try std.testing.expectEqualStrings("m1", first[0].name);
    try std.testing.expectEqualStrings("m2", first[1].name);
    try std.testing.expectEqualStrings("macos-latest, 2 legs (2/2)", jobs[1].name);
    // One leg alone is a job as it was; one that shares no job, and one no run measured, too.
    try std.testing.expectEqualStrings("l1", jobs[2].name);
    try std.testing.expectEqualStrings("fuzz", jobs[3].name);
    try std.testing.expectEqualStrings("new", jobs[4].name);
    // Machines are never mixed: a riscv64 job installs its emulator alone.
    var vm = leg(hosts[0], "vm", 100, true);
    vm.job.machine = .riscv64;
    const mixed = try pack(a, .nightly, &.{ leg(hosts[0], "plain", 100, true), vm });
    try std.testing.expectEqual(@as(usize, 2), mixed.len);
    try std.testing.expect(mixed[1].machine == .riscv64);
}

test "a run past twenty jobs, or three on macOS, of what the record measures, is refused by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var legs: std.ArrayList(Leg) = .empty;
    for (0..4) |i| try legs.append(a, .{ .job = .{ .os = hosts[1], .name = try a.print("mac {d}", .{i}) }, .seconds = 700 });
    problem = "";
    try std.testing.expectError(error.TooManyJobs, pack(a, .full, legs.items));
    try std.testing.expect(std.mem.find(u8, problem, "4 macOS jobs, more than the 3") != null);
    legs.clearRetainingCapacity();
    for (0..21) |i| try legs.append(a, .{ .job = .{ .os = hosts[0], .name = try a.print("linux {d}", .{i}) }, .seconds = 1, .packable = false });
    try std.testing.expectError(error.TooManyJobs, pack(a, .full, legs.items));
    try std.testing.expect(std.mem.find(u8, problem, "asks for 21 jobs (ubuntu-latest 21), more than the 20") != null);
    // The nightly run's Zig master job counts among its twenty.
    try std.testing.expectError(error.TooManyJobs, pack(a, .nightly, legs.items[0..20]));
    _ = try pack(a, .full, legs.items[0..20]);
    // What no run measured is not counted.
    for (legs.items) |*each| each.seconds = null;
    _ = try pack(a, .full, legs.items);
}

test "a job that runs whole and that the record measures past its tier is refused by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    problem = "";
    try std.testing.expectError(error.JobPastTierLimit, planned(a, try withRecords(a, "{}", &.{"source checks"}, 500), .ci));
    try std.testing.expectEqualStrings("source checks: took 8m20s in the last run, more than the 8m of work a ci job of 10 minutes holds", problem);
    _ = try planned(a, try withRecords(a, "{}", &.{"source checks"}, 500), .full);
    try std.testing.expectError(error.JobPastTierLimit, planned(a, try parseJson(a, "{\"durations\":{\"legs\":{\"documented snippets\":{\"overhead\":10,\"tests\":0,\"shards\":1,\"finished\":false}}}}"), .ci));
    try std.testing.expect(std.mem.find(u8, problem, "ran out of its minutes") != null);
}

test "measured, the full tier deals each runner's modes into a few jobs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var all: std.ArrayList([]const u8) = .empty;
    for (try planned(a, try parseJson(a, "{}"), .full)) |job| {
        const name = recordName(job.name);
        for (all.items) |seen| {
            if (std.mem.eql(u8, seen, name)) break;
        } else try all.append(a, name);
    }
    // Each of the fifteen suites and the rest at 200 s: three suites a job on each runner.
    const jobs = try plan(a, try withRecords(a, "{}", all.items, 200), .full);
    try std.testing.expect(jobs.len <= max_jobs);
    var macos: usize = 0;
    for (jobs) |job| {
        macos += @intFromBool(std.mem.eql(u8, job.os, hosts[1]));
        try std.testing.expect(std.mem.find(u8, job.name, "unmeasured") == null);
    }
    try std.testing.expect(macos <= max_macos_jobs);
    try std.testing.expectEqual(all.items.len, (try planned(a, try withRecords(a, "{}", all.items, 200), .full)).len);
}

test "the cross bundle retains every target, CPU and caller compile step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a,
        \\{"compile_step":"install","targets":["x86_64-windows-gnu",{"target":"aarch64-linux-gnu","cpu":"cortex_a72"}],"measured":{"phases":{"compile x86_64-windows-gnu":20,"benchmarks x86_64-windows-gnu":5,"compile aarch64-linux-gnu":20,"benchmarks aarch64-linux-gnu":5}}}
    );
    var bundles: usize = 0;
    for (try planned(a, config, .full)) |job| if (std.mem.eql(u8, job.step, "preflight-cross-bench")) {
        bundles += 1;
        try std.testing.expectEqualStrings("x86_64-windows-gnu aarch64-linux-gnu", job.targets);
    };
    try std.testing.expectEqual(@as(usize, 1), bundles);
    const targets = try src.items(src.get(config, "targets"));
    const first = try crossArgs(a, &.{ "zig", "build" }, config, targets[0], "ci-check", null);
    const second = try crossArgs(a, &.{ "zig", "build" }, config, targets[1], "ci-check-bench", null);
    try std.testing.expectEqualStrings("ci-check", first[2]);
    try std.testing.expectEqualStrings("-Dtarget=x86_64-windows-gnu", first[4]);
    try std.testing.expectEqualStrings("ci-check-bench", second[2]);
    try std.testing.expectEqualStrings("-Dtarget=aarch64-linux-gnu", second[4]);
    try std.testing.expectEqualStrings("-Dcpu=cortex_a72", second[5]);
    try std.testing.expectError(error.InvalidCrossTarget, crossArgs(a, &.{ "zig", "build" }, config, .null, "ci-check", null));
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
    const args = try crossArgs(a, &.{ "zig", "build" }, config, targets[0], "ci-check", null);
    try std.testing.expectEqualStrings("ci-check", args[2]);
    try std.testing.expectEqualStrings("-Dcpu=cortex_a72", args[5]);
    try std.testing.expectEqualStrings("-Doptimize=debug", args[6]);
    const bench = try crossArgs(a, &.{ "zig", "build" }, config, targets[0], "ci-check-bench", null);
    try std.testing.expectEqualStrings("ci-check-bench", bench[2]);
}

fn allTargets(legs: []const Leg, a: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (legs) |leg| {
        var each = std.mem.tokenizeScalar(u8, leg.job.targets, ' ');
        while (each.next()) |name| try out.append(a, name);
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn before(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.before);
    return std.mem.join(a, " ", out.items);
}

test "a cross target no run has measured has a job of its own, of its tier's minutes, named for it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // strand's 8155bf9: no ci/costs.json, and x86_64-windows-gnu outran the 20 minutes a guess
    // of 90 s had packed it into (run 43777274923).
    const many = try parseJson(a, "{\"targets\":[\"a-linux-gnu\",\"b\",\"c\",\"x86_64-windows-gnu\"]}");
    var legs: std.ArrayList(Leg) = .empty;
    try crossLegs(a, many, &legs, .ci, try src.items(src.get(many, "targets")), false);
    try std.testing.expectEqual(@as(usize, 4), legs.items.len);
    try std.testing.expectEqualStrings("a-linux-gnu b c x86_64-windows-gnu", try allTargets(legs.items, a));
    try std.testing.expectEqualStrings("Cross compile x86_64-windows-gnu, unmeasured", legs.items[3].job.name);
    for (legs.items) |leg| {
        try std.testing.expectEqual(@as(usize, 10), leg.job.job_timeout);
        try std.testing.expect(leg.seconds == null and !leg.packable);
    }
    // cross_jobs counts them among its jobs, and the measured share what is left.
    const asked = try parseJson(a, "{\"cross_jobs\":2,\"targets\":[\"a\",\"b\",\"c\"],\"measured\":{\"phases\":{\"compile a\":10,\"compile b\":10,\"benchmarks a\":1,\"benchmarks b\":1}}}");
    legs.clearRetainingCapacity();
    try crossLegs(a, asked, &legs, .full, try src.items(src.get(asked, "targets")), true);
    try std.testing.expectEqual(@as(usize, 2), legs.items.len);
    try std.testing.expectEqualStrings("preflight-cross-bench", legs.items[0].job.step);
    try std.testing.expectEqualStrings("Cross compile 1/2", legs.items[0].job.name);
    try std.testing.expectEqualStrings("a b", legs.items[0].job.targets);
    try std.testing.expectEqual(@as(usize, 15), legs.items[0].job.job_timeout);
    try std.testing.expectEqualStrings("Cross compile c, unmeasured", legs.items[1].job.name);
    for ([_][]const u8{ "{\"cross_jobs\":0,\"targets\":[\"a\"]}", "{\"cross_seconds\":0,\"targets\":[\"a\"]}" }) |text| {
        const bad = try parseJson(a, text);
        try std.testing.expect(std.meta.isError(crossLegs(a, bad, &legs, .ci, try src.items(src.get(bad, "targets")), false)));
    }
}

test "cross targets a run measured are balanced by their seconds, the benchmarks counted in the full tier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a,
        \\{"targets":["a","b","c","d","e"],"measured":{"phases":{"compile a":150,"compile b":40.5,"compile c":40,"compile d":30,"benchmarks a":100,"benchmarks b":10,"benchmarks c":10,"benchmarks d":10}}}
    );
    const targets = try src.items(src.get(config, "targets"));
    var fast: std.ArrayList(Leg) = .empty;
    try crossLegs(a, config, &fast, .ci, targets, false);
    // 260.5 s of the measured four in jobs of 200 s, and e, unmeasured, alone.
    try std.testing.expectEqual(@as(usize, 3), fast.items.len);
    try std.testing.expectEqualStrings("a", fast.items[0].job.targets);
    try std.testing.expectEqualStrings("b c d", fast.items[1].job.targets);
    try std.testing.expectEqualStrings("e", fast.items[2].job.targets);
    var full: std.ArrayList(Leg) = .empty;
    try crossLegs(a, config, &full, .full, targets, true);
    // The benchmarks lengthen a to 250 s, which no job of 200 s holds alone: it has one to itself.
    try std.testing.expectEqual(@as(usize, 3), full.items.len);
    try std.testing.expectEqualStrings("a", full.items[0].job.targets);
    try std.testing.expectEqualStrings("b c d", full.items[1].job.targets);
    try std.testing.expectEqualStrings("e", full.items[2].job.targets);
}

test "no cross job is dealt more compiling than its tier's minutes leave, and a target that cannot fit is refused by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // relic's run 43737703239: aarch64-windows-gnu measured 975 s.
    const measured_phases = "\"measured\":{\"phases\":{\"compile aarch64-windows-gnu\":975,\"compile x86_64-linux-gnu\":400,\"compile aarch64-linux-gnu\":400}}";
    var legs: std.ArrayList(Leg) = .empty;
    // 15 minutes less 300 s of setup leaves 600 s: the 975 s target fits no job.
    const tight = try parseJson(a, try a.print("{{\"targets\":[\"aarch64-windows-gnu\",\"x86_64-linux-gnu\"],{s}}}", .{measured_phases}));
    problem = "";
    try std.testing.expectError(error.CrossTargetPastTimeout, crossLegs(a, tight, &legs, .full, try src.items(src.get(tight, "targets")), false));
    try std.testing.expect(std.mem.find(u8, problem, "aarch64-windows-gnu takes 16m15s to compile, more than the 10m a full job of 15 minutes leaves after its setup") != null);
    // The two 400 s targets fit a full job each, not one together.
    const fits = try parseJson(a, try a.print("{{\"targets\":[\"x86_64-linux-gnu\",\"aarch64-linux-gnu\"],\"cross_seconds\":2000,{s}}}", .{measured_phases}));
    try crossLegs(a, fits, &legs, .full, try src.items(src.get(fits, "targets")), false);
    try std.testing.expectEqual(@as(usize, 2), legs.items.len);
    const fixed = try parseJson(a, try a.print("{{\"targets\":[\"x86_64-linux-gnu\",\"aarch64-linux-gnu\"],\"cross_jobs\":1,{s}}}", .{measured_phases}));
    legs.clearRetainingCapacity();
    try std.testing.expectError(error.CrossJobPastTimeout, crossLegs(a, fixed, &legs, .full, try src.items(src.get(fixed, "targets")), false));
}

test "a cross compile's build runs with the jobs PREFLIGHT_JOBS allows, and with Zig's default without it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a, "{\"targets\":[\"aarch64-linux-gnu\"]}");
    const target = (try src.items(src.get(config, "targets")))[0];
    var environ: std.process.Environ.Map = .init(a);
    try std.testing.expectEqual(@as(?u32, null), try jobsFrom(&environ));
    for (try crossArgs(a, &.{ "zig", "build" }, config, target, "ci-check", try jobsFrom(&environ))) |arg| try std.testing.expect(!std.mem.startsWith(u8, arg, "-j"));
    try environ.put("PREFLIGHT_JOBS", "1");
    const held = try crossArgs(a, &.{ "zig", "build" }, config, target, "ci-check", try jobsFrom(&environ));
    try std.testing.expectEqualStrings("-j1", held[held.len - 1]);
    for ([_][]const u8{ "0", "many", "-2" }) |bad| {
        try environ.put("PREFLIGHT_JOBS", bad);
        try std.testing.expectError(error.InvalidJobs, jobsFrom(&environ));
    }
    // A job the plan sizes none for has the variable empty: Zig's default.
    try environ.put("PREFLIGHT_JOBS", "");
    try std.testing.expectEqual(@as(?u32, null), try jobsFrom(&environ));
}

test "a cross job runs as many of its targets' largest single compiles at once as its runner's memory holds, one where a target has none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // relic's measured cross compiles: x86_64-windows-gnu held 15 GiB at -j4 on a 16 GB runner,
    // 8.6 GB of it in one compile; aarch64-linux-gnu is timed and its memory not read.
    const gib: u64 = 1 << 30;
    const gb: u64 = 1_000_000_000;
    const config = try parseJson(a, try a.print(
        \\{{"targets":["aarch64-windows-gnu","x86_64-linux-musl","x86_64-windows-gnu","aarch64-linux-gnu"],"cross_jobs":4,
        \\"measured":{{"phases":{{"compile aarch64-windows-gnu":500,"compile x86_64-linux-musl":268.2,"compile x86_64-windows-gnu":400,"compile aarch64-linux-gnu":200}},
        \\"peaks":{{"compile aarch64-windows-gnu":{{"bytes":{d},"single":{d},"jobs":4}},"compile x86_64-linux-musl":{{"bytes":{d},"single":{d},"jobs":4}},"compile x86_64-windows-gnu":{{"bytes":{d},"single":{d},"jobs":4}}}}}}}}
    , .{ 11 * gib, 5 * gib, 3 * gib, 1 * gib, 15 * gib, 86 * gb / 10 }));
    var legs: std.ArrayList(Leg) = .empty;
    try crossLegs(a, config, &legs, .full, try src.items(src.get(config, "targets")), false);
    try std.testing.expectEqual(@as(usize, 4), legs.items.len);
    // 75% of 16 GiB is 12 GiB: one 8.6 GB compile fits once, 5 GiB twice, 1 GiB more often
    // than the runner's 4 CPUs.
    const want = [_]struct { []const u8, u32 }{ .{ "x86_64-windows-gnu", 1 }, .{ "aarch64-windows-gnu", 2 }, .{ "x86_64-linux-musl", 4 }, .{ "aarch64-linux-gnu", 1 } };
    for (want) |w| {
        const job = for (legs.items) |leg| {
            if (std.mem.eql(u8, leg.job.targets, w[0])) break leg.job;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(?u32, w[1]), job.build_jobs);
    }
    // A job of several targets takes the fewest any of them allows.
    const shared = try parseJson(a, try a.print(
        \\{{"targets":["aarch64-windows-gnu","x86_64-linux-musl"],"cross_jobs":1,
        \\"measured":{{"phases":{{"compile aarch64-windows-gnu":300,"compile x86_64-linux-musl":200}},
        \\"peaks":{{"compile aarch64-windows-gnu":{{"bytes":{d},"single":{d},"jobs":4}},"compile x86_64-linux-musl":{{"bytes":{d},"single":{d},"jobs":4}}}}}}}}
    , .{ 11 * gib, 5 * gib, 3 * gib, 1 * gib }));
    legs.clearRetainingCapacity();
    try crossLegs(a, shared, &legs, .full, try src.items(src.get(shared, "targets")), false);
    try std.testing.expectEqual(@as(usize, 1), legs.items.len);
    try std.testing.expectEqual(@as(?u32, 2), legs.items[0].job.build_jobs);
    var json: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(legs.items[0].job, job_json, &json.writer);
    try std.testing.expect(std.mem.find(u8, json.written(), "\"build_jobs\":2") != null);
}

test "a configured target a runner executes, on an ABI not its own, runs its Debug suite there in the full tier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a,
        \\{"shards":{"windows":{"min":2}},"build_args":["-Dfeature=true"],"targets":[
        \\"x86_64-windows-msvc",{"target":"aarch64-windows-msvc","args":["-Dsdk=true"]},"x86_64-linux-musl",
        \\"x86_64-windows-gnu","x86_64-windows",{"target":"aarch64-linux-gnu","cpu":"cortex_a72"},"aarch64-macos","x86_64-macos","riscv64-linux-musl"]}
    );
    const jobs = try planned(a, config, .full);
    var suites: std.ArrayList([]const u8) = .empty;
    for (jobs) |job| if (job.target) |target| {
        try suites.append(a, job.name);
        try std.testing.expectEqualStrings("ci-test", job.step);
        try std.testing.expect(job.setup);
        try std.testing.expect(std.mem.find(u8, job.args, try a.print("-Dtarget={s}", .{target})) != null);
        try std.testing.expect(std.mem.startsWith(u8, job.args, "-Doptimize=debug -Dci-timings=true -Dci-lint=false"));
        try std.testing.expect(std.mem.find(u8, job.args, "-Dfeature=true") != null);
    };
    try std.testing.expectEqual(@as(usize, 2), jobsNamed(jobs, "test (x86_64-windows-msvc on windows-latest, Debug)"));
    try std.testing.expectEqual(@as(usize, 2), jobsNamed(jobs, "test (aarch64-windows-msvc on windows-11-arm, Debug)"));
    try std.testing.expectEqual(@as(usize, 2), jobsNamed(jobs, "test (x86_64-linux-musl on ubuntu-latest, Debug)"));
    for (jobs) |job| if (std.mem.eql(u8, recordName(job.name), "test (aarch64-windows-msvc on windows-11-arm, Debug)")) {
        try std.testing.expectEqualStrings(arm_hosts[1], job.os);
        try std.testing.expect(std.mem.endsWith(u8, job.args, "-Dsdk=true"));
    };
    // Only the full tier runs them, and a job that sets no target is written, and keyed, as before.
    for (try planned(a, config, .ci)) |job| try std.testing.expect(job.target == null);
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
    const argv = try crossArgs(a, &.{ "zig", "build" }, config, cross[0], "ci-check", null);
    try std.testing.expectEqualStrings("ci-check", argv[2]);
    try std.testing.expectEqualStrings("-Dcpu=baseline", argv[5]);
    try std.testing.expectEqualStrings("-Dfeature=true", argv[6]);
    try std.testing.expectEqualStrings("-Dtrust-store=true", argv[7]);
    var linked: usize = 0;
    for (try planned(a, config, .full)) |job| if (std.mem.eql(u8, job.step, "ci-link")) {
        linked += 1;
        try std.testing.expect(job.operation == .link);
        try std.testing.expect(!std.mem.eql(u8, job.os, hosts[0]));
        try std.testing.expect(std.mem.find(u8, job.args, "-Dfeature=true") != null);
        if (std.mem.find(u8, job.args, "x86_64-macos") != null) {
            try std.testing.expect(std.mem.find(u8, job.args, "-Dcpu=baseline") != null);
            try std.testing.expect(std.mem.find(u8, job.args, "-Dtrust-store=true") != null);
        }
    };
    try std.testing.expectEqual(@as(usize, 3), linked);
    try std.testing.expectError(error.InvalidBuildArgs, plan(a, try parseJson(a, "{\"build_args\":[\"-Dtarget=x86_64-macos\"]}"), .ci));
}

test "a macOS link that needs no framework runs on Linux; one that links a framework keeps the Mac" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a,
        \\{"targets":["x86_64-macos","aarch64-macos","x86_64-windows-gnu"],"sdk_targets":["aarch64-macos"]}
    );
    var seen: usize = 0;
    for (try planned(a, config, .full)) |job| {
        if (!std.mem.eql(u8, job.step, "ci-link")) continue;
        seen += 1;
        if (std.mem.find(u8, job.args, "x86_64-macos") != null) {
            try std.testing.expectEqualStrings(hosts[0], job.os);
            try std.testing.expectEqualStrings("link (x86_64-macos)", recordName(job.name));
        } else if (std.mem.find(u8, job.args, "aarch64-macos") != null) {
            try std.testing.expectEqualStrings(hosts[1], job.os);
            try std.testing.expectEqualStrings("SDK link (aarch64-macos)", recordName(job.name));
        } else try std.testing.expectEqualStrings(hosts[2], job.os);
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
    try std.testing.expectError(error.InvalidSdkTargets, plan(a, try parseJson(a, "{\"targets\":[\"x86_64-macos\"],\"sdk_targets\":\"x86_64-macos\"}"), .full));
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
            try std.testing.expectError(error.InvalidHardenedProfile, plan(a, config, .full));
            continue;
        };
        // The safety-on run in the full tier; ThreadSanitizer and the native fuzz campaign nightly.
        const full = try planned(a, config, .full);
        const nightly = try planned(a, config, .nightly);
        try std.testing.expectEqual(want, jobsNamed(full, "hardened") > 0);
        try std.testing.expectEqual(want, jobsNamed(nightly, "hardened-tsan") > 0);
        try std.testing.expectEqual(@as(usize, @intFromBool(want)), jobsNamed(nightly, "hardened-fuzz"));
        for (full) |job| try std.testing.expect(!std.mem.eql(u8, job.step, "hardened-tsan") and !std.mem.eql(u8, job.step, "hardened-fuzz"));
        for (nightly) |job| try std.testing.expect(!std.mem.eql(u8, job.step, "hardened"));
        for ([_][]const Job{ full, nightly }) |jobs| for (jobs) |job| if (std.mem.startsWith(u8, job.step, "hardened")) {
            try std.testing.expectEqualStrings(hosts[0], job.os);
            try std.testing.expectEqual(.execute, job.operation);
        };
    }
    try std.testing.expectError(error.UnknownPolicy, plan(a, try parseJson(a, "{\"policy\":\"famliy\"}"), .full));
}

test "a package's own jobs join the tiers they name, on the hosts they name, with the gate's setup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a,
        \\{"build_args":["-Dsimd=false"],"jobs":[
        \\ {"name":"conformance","step":"ci","directory":"conformance","os":["ubuntu-latest","macos-latest"]},
        \\ {"name":"contracts (values)","step":"contracts-values","tiers":["ci"],"args":["-Dgroup=values"],"setup":false,"timeout":8},
        \\ {"name":"reports","step":"check-reports","setup":"reports-setup","tiers":["full"]},
        \\ {"name":"soak","step":"soak","tiers":["nightly"],"shards":3}]}
    );
    const ci = try planned(a, config, .ci);
    const full = try planned(a, config, .full);
    const nightly = try planned(a, config, .nightly);
    for (full) |job| try std.testing.expect(!std.mem.eql(u8, job.step, "contracts-values"));
    // Unless it names its tiers, a job runs in ci and full.
    try std.testing.expectEqual(@as(usize, 2), jobsNamed(ci, "conformance (ubuntu-latest)") + jobsNamed(ci, "conformance (macos-latest)"));
    try std.testing.expectEqual(@as(usize, 2), jobsNamed(full, "conformance (ubuntu-latest)") + jobsNamed(full, "conformance (macos-latest)"));
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
    for (full) |job| if (std.mem.eql(u8, job.step, "check-reports")) try std.testing.expectEqualStrings("reports-setup", job.prepare);
    // A declared test step split in shards is one job per shard, each naming its share.
    var shards: std.ArrayList([]const u8) = .empty;
    for (nightly) |job| if (job.declared) {
        try std.testing.expectEqualStrings("soak", job.step);
        try std.testing.expectEqualStrings(try a.print("soak shard {s}, unmeasured", .{job.shard}), job.name);
        try shards.append(a, job.shard);
    };
    for (shards.items, [_][]const u8{ "1/3", "2/3", "3/3" }) |got, want| try std.testing.expectEqualStrings(want, got);
    for (ci, 0..) |x, i| for (ci[i + 1 ..]) |y| try std.testing.expect(!std.mem.eql(u8, x.cache_key, y.cache_key));
    // A timeout past a tier's minutes, a tier that is none (the release tier was the full one
    // until 0.20.0), and the fuzz tier, which is the fuzz job's, are refused by name.
    problem = "";
    try std.testing.expectError(error.InvalidJobTimeout, plan(a, try parseJson(a, "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"timeout\":12}]}"), .full));
    try std.testing.expectEqualStrings("jobs: x: its timeout, 12 minutes, is more than a ci job's 10: raise its shards, or name another tier", problem);
    _ = try plan(a, try parseJson(a, "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"timeout\":12,\"tiers\":[\"full\"]}]}"), .full);
    try std.testing.expectError(error.InvalidDeclaredJob, plan(a, try parseJson(a, "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"tiers\":[\"release\"]}]}"), .full));
    try std.testing.expectEqualStrings("jobs: x: `release` is no tier a job of the package's own runs in: ci, full or nightly", problem);
    try std.testing.expectError(error.InvalidDeclaredJob, plan(a, try parseJson(a, "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"tiers\":[\"fuzz\"]}]}"), .full));
    // What the record measures of a shard must fit a job of its tier.
    const heavy = try parseJson(a, "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"shards\":2}],\"durations\":{\"legs\":{\"x\":{\"overhead\":100,\"tests\":1600,\"shards\":2,\"finished\":true}}}}");
    try std.testing.expectError(error.JobPastTierLimit, plan(a, heavy, .full));
    try std.testing.expect(std.mem.find(u8, problem, "jobs: x: a shard of 2 takes 15m") != null);
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
            try std.testing.expectEqualStrings("conformance, unmeasured", job.name);
        }
    };
    try std.testing.expectEqual(@as(usize, 2), advisory);
    const listed = try include(a, try plan(a, config, .ci));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, listed, "\"advisory\":true"));
    try std.testing.expect(std.mem.find(u8, listed, "\"advisory\":false") == null);
    // A timeout that leaves no room for the other steps' budgets within GitHub's 360 is refused.
    problem = "";
    try std.testing.expectError(error.InvalidDeclaredJob, plan(a, try parseJson(a, "{\"jobs\":[{\"name\":\"git master\",\"step\":\"t\",\"advisory\":true,\"timeout\":241}]}"), .ci));
    try std.testing.expectEqualStrings("jobs: git master: an advisory job's timeout is at most 240 minutes, which leaves its other steps' 120 within GitHub's 360", problem);
    // An advisory macOS job runs alone, never a leg of a blocking job, and counts among the run's.
    const mac = try withRecords(a,
        \\{"jobs":[
        \\ {"name":"git master","step":"ci-git-master","advisory":true,"os":["macos-latest"],"tiers":["full"]},
        \\ {"name":"conformance","step":"test","os":["macos-latest"],"tiers":["full"]}]}
    , &.{ "conformance", "test (macos-latest, Debug)" }, 100);
    var alone = false;
    for (try plan(a, mac, .full)) |job| {
        if (job.advisory == true) alone = std.mem.eql(u8, job.step, "ci-git-master");
        if (job.legs) |sequence| try std.testing.expect(std.mem.find(u8, sequence, "ci-git-master") == null);
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

test "only the full tier's source checks hold every aegis-pack finding to the bar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = try parseJson(a, "{}");
    for ([_]Tier{ .ci, .full }) |tier| {
        const lint = for (try planned(a, config, tier)) |job| {
            if (std.mem.eql(u8, job.step, "lint")) break job;
        } else return error.NoLintJob;
        try std.testing.expectEqual(tier == .full, std.mem.find(u8, lint.args, "-Dci-release") != null);
    }
}

test "the fuzz job: the nightly tier's and a dispatched fuzz run's alone, where the build has its step, within fifteen minutes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fuzzed = try parseJson(a, "{\"fuzzed\":true,\"build_args\":[\"-Dsuite=full\"]}");
    const found = struct {
        fn job(jobs: []const Job) ?Job {
            for (jobs) |each| if (std.mem.eql(u8, each.step, "ci-fuzz")) return each;
            return null;
        }
    }.job;
    try std.testing.expect(found(try planned(a, fuzzed, .ci)) == null);
    try std.testing.expect(found(try planned(a, fuzzed, .full)) == null);
    const nightly = found(try plan(a, fuzzed, .nightly)).?;
    try std.testing.expectEqualStrings("fuzz, unmeasured", nightly.name);
    try std.testing.expectEqualStrings(hosts[0], nightly.os);
    try std.testing.expectEqual(@as(usize, 15), nightly.job_timeout);
    try std.testing.expect(nightly.setup);
    try std.testing.expectEqualStrings("-Dci-lint=false -Dci-bench-smoke=false -Dsuite=full", nightly.args);
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
    for (try planned(a, config, .ci)) |job| {
        if (!std.mem.startsWith(u8, job.name, "check (")) continue;
        found += 1;
        try std.testing.expectEqualStrings("check", job.step);
        if (std.mem.eql(u8, recordName(job.name), "check (neither)")) try std.testing.expectEqualStrings("-Dci-lint=false -Dhttp=false -Dlfs=false", job.args);
        if (std.mem.eql(u8, recordName(job.name), "check (level-3)")) try std.testing.expectEqualStrings("-Dci-lint=false -Dlevel=3 -Dmode=fast", job.args);
    }
    try std.testing.expectEqual(@as(usize, 3), found);
    // None declared, none planned; the full tier plans none of its own.
    for (try planned(a, try parseJson(a, "{}"), .ci)) |job| try std.testing.expect(!std.mem.startsWith(u8, job.name, "check ("));
    for (try planned(a, config, .full)) |job| try std.testing.expect(!std.mem.startsWith(u8, job.name, "check ("));
    // A name a job and a directory cannot take, or a value the job's arguments cannot carry, is refused.
    for ([_][]const u8{ "{\"configurations\": [{\"name\": \"no http\"}]}", "{\"configurations\": []}", "{\"configurations\": [{\"name\": \"x\", \"options\": {\"mode\": \"a b\"}}]}", "{\"configurations\": [{\"name\": \"x\", \"options\": {\"f\": 1.5}}]}" }) |text| {
        try std.testing.expectError(error.InvalidConfigurations, plan(a, try parseJson(a, text), .ci));
    }
}
