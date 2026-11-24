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
/// The runners on ARM the release tier adds, Linux and Windows on aarch64 (the macOS runner is
/// one already), and their `shards` keys.
pub const arm_hosts = [_][]const u8{ "ubuntu-24.04-arm", "windows-11-arm" };
const arm_host_names = [_][]const u8{ "linux_arm", "windows_arm" };
/// The `shards` key of the riscv64 job on its emulated kernel.
const emulated_host_name = "riscv64";
/// The `shards` key of the x86_64 FreeBSD job on its kernel under KVM.
const freebsd_host_name = "freebsd";
/// The `shards` key of the hardened ThreadSanitizer run, several times slower than the suite;
/// the hardened run without it takes the Linux count.
const tsan_name = "tsan";
/// Every `shards` key: a host whose job count the record makes, within the bounds it sets.
pub const shard_hosts = host_names ++ arm_host_names ++ .{ emulated_host_name, freebsd_host_name, tsan_name };
/// Every runner a job may name.
const every_host = hosts ++ arm_hosts;

/// What the last refused configuration got wrong, for the command to print beside the error: the
/// planner is a library, and a test that expects the refusal must not see it logged as a failure.
/// It is the planning thread's own, as the refusal is.
pub threadlocal var problem: []const u8 = "";

/// A job's time limit in minutes: `name` in the configuration, or 20. GitHub ends any job at 360.
/// The most minutes an advisory job's steps but its run take, as zig.yml's gate job budgets
/// them: the two checkouts, the setup, the held git's restore, build and save, the three tools
/// attempts, the timings upload and the report (workflow_test sums them from the workflow).
pub const advisory_overhead_minutes = 120;

fn minutes(config: src.Value, name: []const u8) !usize {
    const value = src.get(config, name);
    if (value == .null) return 20;
    if (value != .integer or value.integer < 1 or value.integer > 360) return error.InvalidJobTimeout;
    return @intCast(value.integer);
}

/// How much slower than a native runner a kind of job runs its tests: preflight's measure, the
/// same for every package, so a package names one budget per kind (`test_job_timeout` and the
/// rest) and a slower job takes it scaled, never a budget of its own.
const Slowdown = enum(u8) {
    native = 1,
    /// A FreeBSD guest under KVM: native code, with its boot and the host's files over 9p.
    kvm = 2,
    /// LLVM's ThreadSanitizer, which instruments every memory access and synchronization.
    tsan = 3,
    /// A riscv64 guest under QEMU's TCG, which translates every instruction.
    qemu = 4,
};

/// `name`'s minutes for a job that runs `slowdown` times slower, at most GitHub's 360.
fn scaled(config: src.Value, name: []const u8, slowdown: Slowdown) !usize {
    return @min(360, try minutes(config, name) * @backingInt(slowdown));
}

pub const Job = struct {
    os: []const u8,
    name: []const u8,
    /// The tests alone (`ci-test`): the source checks run once, in their own job.
    step: []const u8 = "ci-test",
    args: []const u8 = "",
    /// `i/n` when the job runs one shard of its tests.
    shard: []const u8 = "",
    setup: bool = false,
    job_timeout: usize = 20,
    cache_key: []const u8 = "",
    artifact: []const u8 = "",
    operation: enum { execute, objects, link, replay } = .execute,
    /// The cross targets a compile job covers, by name, space-separated.
    targets: []const u8 = "",
    /// Where a declared job builds, relative to the repository; empty is the package.
    directory: []const u8 = "",
    /// The step that sets up a declared job's external tools, when not the package's `setup_step`.
    prepare: []const u8 = "",
    /// A job of the package's own (`jobs`), which runs as declared: never split into a link and a replay.
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
    /// The jobs this one runs in sequence on its one runner, as JSON (`macosLegs`); null for a
    /// job that is one job.
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

/// The options of `ci/workflow.json` (keys.zig). Any other key is refused, so a misspelt one
/// cannot quietly change nothing.
const workflow_options = keys.workflow;

/// The minutes the fuzz job fuzzes for, `fuzz_minutes` in the configuration: 15 unless it
/// says, 0 for no fuzz job. The job's own limit is these and 20 more, for the build that comes
/// first and the session that ends last; GitHub ends a job at 360.
pub fn fuzzMinutes(config: src.Value) !usize {
    const value = src.get(config, "fuzz_minutes");
    if (value == .null) return 15;
    if (value != .integer or value.integer < 0 or value.integer > max_fuzz_minutes) {
        problem = "fuzz_minutes: a whole number of minutes from 0 (no fuzz job) to 330";
        return error.InvalidFuzzMinutes;
    }
    return @intCast(value.integer);
}

/// The most minutes a fuzz job fuzzes for: GitHub's 360, less the 20 its build and last
/// session are given and 10 to spare.
pub const max_fuzz_minutes = 330;

/// The fuzz job: the package's properties under the fuzzer for its minutes (`ci-fuzz`), where
/// the build has the step, which it has when the package declares shakedown, and its minutes
/// are not 0. The release tier runs it, and a dispatched fuzz run runs it alone.
fn fuzzJob(a: std.mem.Allocator, config: src.Value) !?Job {
    const budget = try fuzzMinutes(config);
    const fuzzed = src.get(config, "fuzzed");
    if (fuzzed != .null and fuzzed != .bool) return error.InvalidWorkflowConfig;
    if (budget == 0 or fuzzed != .bool or !fuzzed.bool) return null;
    var job: Job = .{
        .os = hosts[0],
        .name = "fuzz",
        .step = "ci-fuzz",
        .args = try a.print("-Dci-lint=false -Dci-bench-smoke=false{s}", .{try buildArgs(a, src.get(config, "build_args"))}),
        .setup = true,
        .job_timeout = budget + 20,
    };
    job.cache_key = try key(a, job);
    return job;
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
    plain.artifact = "";
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

/// How much of the gate a run executes.
pub const Tier = enum {
    /// Every push to main and every pull request, on that exact commit: the source checks, the Debug suite on Linux
    /// with an object compile of every configured target, and the Debug suite on Windows and on macOS. Its status is
    /// main's: a red one is fixed forward at once.
    ci,
    /// The full matrix, by dispatch and on a weekly schedule, and the run a tag requires: every mode on every host,
    /// the ReleaseFast benchmarks and every cross target, the SDK links, ThreadSanitizer and the opt-in hardened
    /// checks; the run on Zig master joins it.
    release,
    /// The fuzz job alone, by dispatch: a session fuzzes a package on GitHub's runners and not on
    /// the machine at hand. The release tier runs it too.
    fuzz,
};

/// The sole planner also owns opt-in native safety execution jobs, which only the release tier runs.
pub fn plan(a: std.mem.Allocator, config: src.Value, tier: Tier) ![]Job {
    var jobs: std.ArrayList(Job) = .empty;
    if (tier == .fuzz) {
        try validate(a, config);
        if (try fuzzJob(a, config)) |job| try jobs.append(a, job);
        return jobs.toOwnedSlice(a);
    }
    try jobs.appendSlice(a, try basePlan(a, config, tier));
    const policy = family.of(src.get(config, family.key)) catch {
        problem = family.refusal;
        return error.UnknownPolicy;
    };
    // Under the family's policy the hardened profile is every package's (aegis's design §7):
    // there is no opting out, and a package with nothing to fuzz says so in its build's
    // profile. Without it a package runs the profile when it says `"hardened": true`.
    const hardened = src.get(config, "hardened");
    if (hardened != .null and hardened != .bool) return error.InvalidHardenedProfile;
    const planned = switch (policy) {
        .family => if (hardened == .null or hardened.bool) true else return error.InvalidHardenedProfile,
        .adapt => hardened == .bool and hardened.bool,
    };
    if (tier == .release and planned) {
        // Each runs the suite as the Linux test jobs do, so each has their time limit; the suite and its
        // ThreadSanitizer run split into shards as those jobs do, and a fuzz campaign is one job.
        const linux = try jobCount(a, config, host_names[0], &.{"linux-debug"}, halfOf(try minutes(config, "test_job_timeout")));
        const tsan = try jobCount(a, config, tsan_name, &.{"linux-debug-tsan"}, halfOf(try scaled(config, "test_job_timeout", .tsan)));
        for ([_][]const u8{ "hardened", "hardened-fuzz", "hardened-tsan" }, [_]usize{ linux, 1, tsan }) |step, count| for (0..count) |i| {
            const shard = try shardName(a, i, count);
            var job: Job = .{
                .os = hosts[0],
                .name = try a.print("{s}{s}{s}", .{ step, if (count > 1) " shard " else "", shard }),
                .step = step,
                .args = try a.print("-Dci-lint=false -Dci-bench-smoke=false{s}", .{try buildArgs(a, src.get(config, "build_args"))}),
                .shard = shard,
                .setup = true,
                .job_timeout = try scaled(config, "test_job_timeout", if (std.mem.eql(u8, step, "hardened-tsan")) .tsan else .native),
            };
            job.cache_key = try key(a, job);
            try jobs.append(a, job);
        };
    }
    if (tier == .release) if (try fuzzJob(a, config)) |job| try jobs.append(a, job);
    try declaredJobs(a, config, tier, &jobs);
    return jobs.toOwnedSlice(a);
}

/// The package's own jobs, `jobs` in `ci/workflow.json`: each a build step run on the
/// hosts and in the tiers it names (Linux, and the ci and release tiers, unless it
/// says), with the gate's setup, caches and toolchain, so a push's run waits for it like
/// any other job of the gate.
///
///     {"name": "conformance", "step": "test", "directory": "conformance",
///      "os": ["ubuntu-latest", "macos-latest"], "tiers": ["ci", "release"],
///      "args": ["-Dsuite=full"], "setup": true, "timeout": 20, "shards": 2}
///
/// `shards` splits a test step over that many jobs per host, as the hosts' own test
/// jobs are split: each runs the share `PREFLIGHT_SHARD` names, balanced by the durations
/// the package records.
fn declaredJobs(a: std.mem.Allocator, config: src.Value, tier: Tier, jobs: *std.ArrayList(Job)) !void {
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
        var wanted = false;
        const tiers = src.get(entry, "tiers");
        if (tiers == .null) wanted = true else {
            if (tiers != .array or tiers.array.items.len == 0) return error.InvalidDeclaredJob;
            for (tiers.array.items) |item| {
                const each = std.meta.stringToEnum(Tier, try src.string(item, "")) orelse return error.InvalidDeclaredJob;
                // The fuzz tier is the fuzz job's alone.
                if (each == .fuzz) return error.InvalidDeclaredJob;
                if (each == tier) wanted = true;
            }
        }
        const setup = src.get(entry, "setup");
        if (setup != .null and setup != .bool and setup != .string) return error.InvalidDeclaredJob;
        const count = shardCount(src.get(entry, "shards")) catch return error.InvalidDeclaredJob;
        const marked = src.get(entry, "advisory");
        if (marked != .null and marked != .bool) {
            problem = try a.print("jobs: {s}: advisory is true or false", .{name});
            return error.InvalidDeclaredJob;
        }
        const advisory = marked == .bool and marked.bool;
        const declared_timeout = try minutes(entry, "timeout");
        if (advisory and declared_timeout + advisory_overhead_minutes > 360) {
            problem = try a.print("jobs: {s}: an advisory job's timeout is at most {d} minutes, which leaves its other steps' {d} within GitHub's 360", .{ name, 360 - advisory_overhead_minutes, advisory_overhead_minutes });
            return error.InvalidDeclaredJob;
        }
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
                var job: Job = .{
                    .os = os,
                    .name = if (advisory) try a.print("{s} (non-blocking)", .{named}) else named,
                    .advisory = if (advisory) true else null,
                    .step = step,
                    .args = std.mem.trimStart(u8, try buildArgs(a, src.get(entry, "args")), " "),
                    .shard = shard,
                    .setup = setup != .bool or setup.bool,
                    .prepare = if (setup == .string) setup.string else "",
                    .job_timeout = if (advisory) declared_timeout + advisory_overhead_minutes else declared_timeout,
                    .run_timeout = if (advisory) declared_timeout else null,
                    .directory = directory,
                    .declared = true,
                    .any_host = hosted == .null,
                };
                job.cache_key = try key(a, job);
                try jobs.append(a, job);
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

fn basePlan(a: std.mem.Allocator, config: src.Value, tier: Tier) ![]Job {
    try validate(a, config);
    switch (tier) {
        .ci => return ciPlan(a, config),
        .release => {},
        .fuzz => unreachable,
    }
    var jobs: std.ArrayList(Job) = .empty;
    // Every mode on every runner, so that a gate at hand on any of them proves its own system at
    // each mode a package releases in.
    for (hosts ++ arm_hosts, host_names ++ arm_host_names) |host, host_name| try hostJobs(a, config, &jobs, host, host_name, &.{ .debug, .safe, .fast });
    try emulatedJobs(a, config, &jobs);
    try freebsdJobs(a, config, &jobs);
    try ownTargetJobs(a, config, &jobs);
    try jobs.append(a, try lintJob(a, config, .release));
    try jobs.append(a, try snippetsJob(a, config));
    try releaseJobs(a, config, &jobs);
    try sdkJobs(a, config, &jobs);
    for (jobs.items) |*job| job.cache_key = try key(a, job.*);
    return jobs.items;
}

/// The source checks, Linux Debug and the Debug suite on macOS and Windows,
/// each recording its durations, and an object compile of every configured
/// target: what every push and pull request runs. The benchmarks' optimizing
/// compiles and the other modes are the release tier's.
fn ciPlan(a: std.mem.Allocator, config: src.Value) ![]Job {
    var jobs: std.ArrayList(Job) = .empty;
    try jobs.appendSlice(a, try linuxPlan(a, config));
    const start = jobs.items.len;
    for (hosts[1..], host_names[1..]) |host, host_name| try hostJobs(a, config, &jobs, host, host_name, &.{.debug});
    for (jobs.items[start..]) |*job| job.cache_key = try key(a, job.*);
    const targets = try src.items(src.get(config, "targets"));
    if (targets.len > 0) try crossJobs(a, config, &jobs, targets, false);
    try jobs.append(a, try snippetsJob(a, config));
    try configurationJobs(a, config, &jobs);
    return jobs.items;
}

/// The package's own compile (`compile_step`, `check` by default) in each configuration
/// `configurations` declares, by its name: a configuration's options reach the package's
/// tests, helpers and benchmarks only in a build of the package given them, so each is
/// compiled once, as the consumer check builds a consumer in each. The build checks each
/// entry against the options it declares; here each is read as the job's arguments.
fn configurationJobs(a: std.mem.Allocator, config: src.Value, jobs: *std.ArrayList(Job)) !void {
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
        var job: Job = .{
            .os = hosts[0],
            .name = try a.print("{s} ({s})", .{ compile, name.string }),
            .step = compile,
            .args = std.mem.trimStart(u8, try a.print("-Dci-lint=false{s}{s}", .{ args.written(), try buildArgs(a, src.get(config, "build_args")) }), " "),
            .job_timeout = try minutes(config, "cross_job_timeout"),
        };
        job.cache_key = try key(a, job);
        try jobs.append(a, job);
    }
}

/// The test jobs of one host: each mode in the host's shard count.
fn hostJobs(a: std.mem.Allocator, config: src.Value, jobs: *std.ArrayList(Job), host: []const u8, host_name: []const u8, modes: []const Mode) !void {
    const limit = try minutes(config, if (windowsHost(host)) "windows_job_timeout" else "test_job_timeout");
    const count = try jobCount(a, config, host_name, try columnsOf(a, stemOf(host_name), modes), halfOf(limit));
    for (modes) |mode| for (0..count) |i| {
        const shard = try shardName(a, i, count);
        try jobs.append(a, .{
            .os = host,
            .name = try a.print("test ({s}, {s}){s}{s}", .{ host, title(mode), if (count > 1) " shard " else "", shard }),
            .args = try a.print("-Doptimize={t} -Dci-lint=false -Dci-timings=true{s}", .{ mode, try buildArgs(a, src.get(config, "build_args")) }),
            .shard = shard,
            .setup = true,
            .job_timeout = try minutes(config, if (windowsHost(host)) "windows_job_timeout" else "test_job_timeout"),
        });
    };
}

fn windowsHost(host: []const u8) bool {
    return std.mem.eql(u8, host, hosts[2]) or std.mem.eql(u8, host, arm_hosts[1]);
}

fn linuxHost(host: []const u8) bool {
    return std.mem.eql(u8, host, hosts[0]) or std.mem.eql(u8, host, arm_hosts[0]);
}

/// The Debug suite on riscv64 Linux, which no hosted runner is: built for it on the Linux
/// runner, static with musl, and run on a riscv64 Linux kernel QEMU emulates (`-Dci-vm`), so
/// that what a kernel does (reaping, pidfds, io_uring, file maps) is a kernel's, not a
/// user-mode emulator's. Emulated, a suite takes several times as long as on a runner, so
/// it splits into as many jobs as `emulatedCount` says; its durations, QEMU's, are a column
/// of their own, which balances them.
fn emulatedJobs(a: std.mem.Allocator, config: src.Value, jobs: *std.ArrayList(Job)) !void {
    const count = try jobCount(a, config, emulated_host_name, &.{emulated_column}, try emulatedBudget(config));
    for (0..count) |i| {
        const shard = try shardName(a, i, count);
        try jobs.append(a, .{
            .os = hosts[0],
            .name = try a.print("test (riscv64-linux on its kernel under QEMU, Debug){s}{s}", .{ if (count > 1) " shard " else "", shard }),
            .args = try a.print("-Doptimize=debug -Dci-lint=false -Dci-timings=true -Dtarget=riscv64-linux-musl -Dci-vm{s}", .{try buildArgs(a, src.get(config, "build_args"))}),
            .shard = shard,
            .setup = true,
            .machine = .riscv64,
            .job_timeout = try scaled(config, "test_job_timeout", .qemu),
        });
    }
}

/// The `ci/durations.json` column the riscv64 suite records, as its test runner names it.
const emulated_column = "linux-riscv64-debug";

/// The seconds of tests the riscv64 job holds: `riscv64_seconds`, else half the native job's
/// time; its build, its kernel's boot and QEMU's translation take the rest of its scaled time.
fn emulatedBudget(config: src.Value) !f64 {
    const budget_value = src.get(config, "riscv64_seconds");
    if (budget_value != .null and !((number(budget_value) orelse 0) > 0)) return error.InvalidEmulatedSeconds;
    return number(budget_value) orelse halfOf(try minutes(config, "test_job_timeout"));
}

/// The seconds of recorded tests a job of `limit` minutes holds: half its time, the other half
/// its build, its setup and the margin.
fn halfOf(limit: usize) f64 {
    return @as(f64, @floatFromInt(limit * 60)) / 2;
}

/// A floor and a cap on a host's job count, which `shards.<host>` sets where a package means
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

/// How many jobs a host's suite takes, every host alike: as few as hold `budget` seconds each of
/// the tests it runs, by each of its `columns` in `ci/durations.json` (the most any one needs,
/// a job running every mode's share), within `shards.<host>`'s bounds. A column a finished run
/// measured (`complete`) holds every test that job runs, and only those are weighed: a test it
/// lacks does not run there (an end-to-end suite the emulated build leaves out: bay's riscv64
/// job runs its 132 unit tests, and its 75 end-to-end tests, weighed at Linux Debug's minutes
/// scaled, planned it seven jobs). Any other column weighs every test, one it has none of at its
/// Linux Debug time scaled as the tests both recorded ran (`order.estimate`), so a suite whose
/// run never finished is still sized by what it did run. With no record to go by, one job,
/// whose record sizes the next plan.
fn jobCount(a: std.mem.Allocator, config: src.Value, host: []const u8, columns: []const []const u8, budget: f64) !usize {
    const bounds = try shardBounds(a, src.get(config, "shards"), host);
    var needed: usize = 1;
    for (columns) |column| needed = @max(needed, try columnJobs(a, config, column, budget));
    return std.math.clamp(needed, bounds.min, bounds.max);
}

/// The jobs one column's tests take at `budget` seconds a job: at least one, and no more than
/// it has tests.
fn columnJobs(a: std.mem.Allocator, config: src.Value, column: []const u8, budget: f64) !usize {
    const durations = src.get(config, "durations");
    if (durations == .null) return 1;
    const tests = src.get(durations, "tests");
    if (tests != .object) return error.InvalidDurations;
    const names = if (try completeColumn(durations, column)) try recordedIn(a, durations, column) else tests.object.keys();
    if (names.len == 0) return 1;
    const estimate = preflight_order.estimate(a, durations, names, column) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidDurations => return error.InvalidDurations,
    };
    if (estimate.recorded == 0) return 1;
    var total: f64 = 0;
    for (estimate.weights) |seconds| total += seconds;
    return std.math.clamp(std.math.lossyCast(usize, @ceil(total / budget)), 1, names.len);
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
/// cross-compile's. It splits into `shards.freebsd` jobs, its durations a column of their own.
fn freebsdJobs(a: std.mem.Allocator, config: src.Value, jobs: *std.ArrayList(Job)) !void {
    const count = try jobCount(a, config, freebsd_host_name, &.{"freebsd-debug"}, halfOf(try scaled(config, "test_job_timeout", .kvm)));
    for (0..count) |i| {
        const shard = try shardName(a, i, count);
        try jobs.append(a, .{
            .os = hosts[0],
            .name = try a.print("test (x86_64-freebsd on its kernel under KVM, Debug){s}{s}", .{ if (count > 1) " shard " else "", shard }),
            .args = try a.print("-Doptimize=debug -Dci-lint=false -Dci-timings=true -Dtarget=x86_64-freebsd -Dci-vm{s}", .{try buildArgs(a, src.get(config, "build_args"))}),
            .shard = shard,
            .setup = true,
            .machine = .freebsd,
            .job_timeout = try scaled(config, "test_job_timeout", .kvm),
        });
    }
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
/// test jobs'. A target's durations share its runner's column: its system, architecture and
/// mode are the runner's, and a column keeps each test's longest time.
fn ownTargetJobs(a: std.mem.Allocator, config: src.Value, jobs: *std.ArrayList(Job)) !void {
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
        const limit = try minutes(config, if (windowsHost(runner.host)) "windows_job_timeout" else "test_job_timeout");
        const count = try jobCount(a, config, runner.name, try columnsOf(a, stemOf(runner.name), &.{.debug}), halfOf(limit));
        for (0..count) |i| {
            const shard = try shardName(a, i, count);
            try jobs.append(a, .{
                .os = runner.host,
                .name = try a.print("test ({s} on {s}, Debug){s}{s}", .{ name, runner.host, if (count > 1) " shard " else "", shard }),
                .args = try a.print("-Doptimize=debug -Dci-timings=true{s}", .{options.written()}),
                .shard = shard,
                .setup = true,
                .target = name,
                .job_timeout = try minutes(config, if (windowsHost(runner.host)) "windows_job_timeout" else "test_job_timeout"),
            });
        }
    }
}

pub const Tiers = struct { native: []Job, compile: []Job, run: []Job };

/// Portable hosts link once on their SDK runner per host and mode; every shard of
/// that host and mode runs the same binaries. A job of a configured target builds
/// where it runs.
pub fn split(a: std.mem.Allocator, config: src.Value, jobs: []const Job, tier: Tier) !Tiers {
    var native: std.ArrayList(Job) = .empty;
    var compile: std.ArrayList(Job) = .empty;
    var run: std.ArrayList(Job) = .empty;
    const enabled = src.get(config, "portable_tests");
    for (jobs) |job| {
        const portable_hosts = src.get(config, "portable_hosts");
        var allowed = portable_hosts == .null;
        for (try src.items(portable_hosts)) |host| if (std.mem.eql(u8, try src.string(host, ""), job.os)) {
            allowed = true;
        };
        // macOS links where it runs: its legs share one runner (`macosLegs`), and a link job
        // and its replays on that runner are one build and its run.
        if (tier == .ci or job.declared or job.machine != .none or job.target != null or enabled != .bool or !enabled.bool or !allowed or !std.mem.eql(u8, job.step, "ci-test") or linuxHost(job.os) or std.mem.eql(u8, job.os, hosts[1])) {
            try native.append(a, job);
            continue;
        }
        var whole = job;
        whole.shard = "";
        whole.name = job.name[0 .. std.mem.find(u8, job.name, " shard ") orelse job.name.len];
        const whole_key = try key(a, whole);
        const artifact = try a.print("preflight-{s}", .{whole_key});
        var built = false;
        for (compile.items) |existing| if (std.mem.eql(u8, existing.artifact, artifact)) {
            built = true;
        };
        if (!built) {
            const target = if (std.mem.eql(u8, job.os, hosts[1])) "aarch64-macos" else if (std.mem.eql(u8, job.os, arm_hosts[1])) "aarch64-windows-gnu" else "x86_64-windows-gnu";
            var builder = whole;
            builder.os = job.os;
            builder.step = "ci-build";
            builder.operation = .link;
            builder.setup = true;
            builder.args = try a.print("{s} -Dtarget={s} -Dcpu=baseline", .{ job.args, target });
            builder.name = try a.print("native link for {s}", .{whole.name});
            builder.cache_key = try a.print("compile-{s}", .{whole_key});
            builder.artifact = artifact;
            try compile.append(a, builder);
        }
        var executor = job;
        executor.step = "ci-run";
        executor.operation = .replay;
        executor.artifact = artifact;
        try run.append(a, executor);
    }
    return .{ .native = if (tier == .release) try macosLegs(a, native.items) else native.items, .compile = compile.items, .run = run.items };
}

/// GitHub ends a job it cannot give a runner ("not acquired by Runner of type hosted"), and
/// the account's macOS runners are few: a release run that asked for each macOS mode, shard
/// and declared job at once lost them, cancelled with no step (almanac 44324896023, strand
/// 44137916154). The release tier asks for one macOS runner: its macOS jobs run there in
/// sequence, each a leg with its own build, limit and records, in the order planned. A leg
/// that would take the job past GitHub's 360 minutes starts the next job.
fn macosLegs(a: std.mem.Allocator, jobs: []Job) ![]Job {
    var kept: std.ArrayList(Job) = .empty;
    var legs: std.ArrayList(Job) = .empty;
    var first: ?usize = null;
    for (jobs) |job| {
        // An advisory job runs alone: in a leg its failure would be the legs job's.
        if (!std.mem.eql(u8, job.os, hosts[1]) or job.advisory == true) {
            try kept.append(a, job);
            continue;
        }
        if (first == null) first = kept.items.len;
        try legs.append(a, job);
    }
    if (legs.items.len < 2) return jobs;
    var runs: std.ArrayList(Job) = .empty;
    var start: usize = 0;
    var total: usize = 0;
    for (legs.items, 0..) |leg, index| {
        if (index > start and total + leg.job_timeout > 360) {
            try runs.append(a, try legJob(a, legs.items[start..index]));
            start = index;
            total = 0;
        }
        total += leg.job_timeout;
    }
    try runs.append(a, try legJob(a, legs.items[start..]));
    if (runs.items.len > 1) for (runs.items, 1..) |*run, part| {
        run.name = try a.print("{s} ({d}/{d})", .{ run.name, part, runs.items.len });
    };
    try kept.insertSlice(a, first.?, runs.items);
    return kept.items;
}

/// One macOS job that runs `legs` in sequence (`preflight run` with `PREFLIGHT_LEGS`).
fn legJob(a: std.mem.Allocator, legs: []const Job) !Job {
    if (legs.len == 1) return legs[0];
    var minutes_total: usize = 0;
    var setup = false;
    for (legs) |leg| {
        minutes_total += leg.job_timeout;
        setup = setup or leg.setup;
    }
    var job: Job = .{
        .os = hosts[1],
        .name = try a.print("macOS, {d} legs in sequence", .{legs.len}),
        .step = "legs",
        .setup = setup,
        .job_timeout = @min(360, minutes_total),
        .legs = try std.json.Stringify.valueAlloc(a, legs, job_json),
    };
    job.cache_key = try key(a, job);
    return job;
}

/// The source checks and Linux Debug in Linux's jobs (`jobCount`), each recording
/// its durations.
fn linuxPlan(a: std.mem.Allocator, config: src.Value) ![]Job {
    var jobs: std.ArrayList(Job) = .empty;
    try jobs.append(a, try lintJob(a, config, .ci));
    const count = try jobCount(a, config, host_names[0], &.{"linux-debug"}, halfOf(try minutes(config, "test_job_timeout")));
    for (0..count) |i| {
        const shard = try shardName(a, i, count);
        try jobs.append(a, .{
            .os = hosts[0],
            .name = try a.print("Linux Debug{s}{s}", .{ if (count > 1) " shard " else "", shard }),
            .args = try a.print("-Doptimize=debug -Dci-lint=false -Dci-timings=true{s}", .{try buildArgs(a, src.get(config, "build_args"))}),
            .shard = shard,
            .setup = true,
            .job_timeout = try minutes(config, "test_job_timeout"),
            .cache_key = try a.print("fast-linux-debug-{d}", .{i}),
        });
    }
    return jobs.items;
}

/// The source checks: format, structure, the code rules, layout, snippets and
/// the package's own extra checks. Nothing in them runs a test, so they need
/// neither the external tools nor a test build.
/// The source checks. The release tier's (`-Dci-release`) fail on every
/// aegis-pack finding; a landing's report the flow rules'.
fn lintJob(a: std.mem.Allocator, config: src.Value, tier: Tier) !Job {
    return .{
        .os = hosts[0],
        .name = "source checks",
        .step = "lint",
        .args = std.mem.trimStart(u8, try a.print("{s}{s}", .{ if (tier == .release) " -Dci-release" else "", try buildArgs(a, src.get(config, "build_args")) }), " "),
        .job_timeout = try minutes(config, "source_job_timeout"),
        .cache_key = "lint",
    };
}

/// The documented snippets, a job of their own: a red lint, or one that refuses its
/// configuration, never hides a broken snippet.
fn snippetsJob(a: std.mem.Allocator, config: src.Value) !Job {
    return .{
        .os = hosts[0],
        .name = "documented snippets",
        .step = "snippets",
        .args = std.mem.trimStart(u8, try buildArgs(a, src.get(config, "build_args")), " "),
        .job_timeout = try minutes(config, "source_job_timeout"),
        .cache_key = "snippets",
    };
}

/// The target a `targets` entry names: a triple, or an object's `target`.
pub fn targetName(target: src.Value) src.TypeError![]const u8 {
    return if (target == .string) target.string else try src.string(src.get(target, "target"), "");
}

/// The minutes a target no run has measured is given, in a cross job of its own: GitHub's
/// longest, so that its first job finishes and measures it.
const unmeasured_job_minutes = 360;
/// The seconds of compiling one cross job is given, when `cross_seconds` does not say.
const default_cross_seconds = 200;
/// What a cross job spends before it compiles (checkout, Zig, caches, the toolchain), which
/// its `cross_job_timeout` must leave room for: relic's jobs took about four minutes.
const cross_setup_seconds = 300;

/// `seconds`, to the nearest second, as a duration prints.
fn wholeSeconds(seconds: f64) aegis.units.Duration(.second, i64) {
    return .fromRaw(std.math.lossyCast(i64, @round(seconds)));
}

/// The seconds `name` takes to compile, as the last release run
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
        const single = try singlePeak(config, try a.print("{s} {s}", .{ label, name })) orelse return 1;
        jobs = @min(jobs, std.math.cast(u32, room / @max(single, 1)) orelse jobs);
    };
    return @max(jobs, 1);
}

/// The most one process of a phase held, in bytes, as `ci/costs.json`'s `peaks` records the
/// phase; null where it records none.
fn singlePeak(config: src.Value, phase: []const u8) !?u64 {
    const peaks = src.get(src.get(config, "measured"), "peaks");
    if (peaks != .object) return null;
    const entry = peaks.object.get(phase) orelse return null;
    const single = src.get(entry, "single");
    if (single != .integer or single.integer < 0) return error.InvalidPeak;
    return @intCast(single.integer); // safe: not negative, checked above
}

fn number(value: src.Value) ?f64 {
    return switch (value) {
        .float => |seconds| seconds,
        .integer => |seconds| @floatFromInt(seconds),
        else => null,
    };
}

/// The object compile of `targets`, in as many jobs as `cross_jobs` asks for,
/// or as few as hold `cross_seconds` (200) of compiling each, by what the last
/// run measured of every target; a target it has not measured has a job of its
/// own, of `unmeasured_job_minutes`. The longest target goes first onto the job
/// with the least, so the jobs end together. With `bench`, each job also
/// compiles the ReleaseFast benchmarks.
fn crossJobs(a: std.mem.Allocator, config: src.Value, jobs: *std.ArrayList(Job), targets: []const src.Value, bench: bool) !void {
    if (targets.len == 0) return;
    const wanted = src.get(config, "cross_jobs");
    if (wanted != .null and (wanted != .integer or wanted.integer < 1)) return error.InvalidCrossJobs;
    const budget = src.get(config, "cross_seconds");
    if (budget != .null and !((number(budget) orelse 0) > 0)) return error.InvalidCrossSeconds;
    // A target no run has measured is packed with nothing and given GitHub's longest job: no
    // guess of its cost can be trusted to fit a bound (strand's x86_64-windows-gnu, costed at a
    // guess of 90 s with no ci/costs.json, outran its 20 minutes, run 43777274923). Its job
    // finishes and measures it, and from then on the bound below holds it, or refuses it by name.
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
    // A job holds at most what its own bound leaves after its setup, so no plan deals a job
    // more compiling than `cross_job_timeout` lets it finish (relic's 975 s target in 20
    // minutes ended two jobs at their bound, run 43737703239); a target past that is refused.
    const room = @as(f64, @floatFromInt(try minutes(config, "cross_job_timeout") * 60)) - cross_setup_seconds;
    var heaviest: f64 = 0;
    for (order) |index| if (cost[index] > room) {
        problem = try a.print("{s} takes {f} to compile, more than the {f} a cross job's cross_job_timeout leaves after its setup: raise cross_job_timeout", .{ try targetName(targets[index]), wholeSeconds(cost[index]), wholeSeconds(room) });
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
            problem = try a.print("cross_jobs {d} puts {f} of compiling in one job, more than the {f} its cross_job_timeout leaves after its setup: raise cross_job_timeout or cross_jobs", .{ count + unmeasured.items.len, wholeSeconds(longest), wholeSeconds(room) });
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
        try jobs.append(a, .{
            .os = hosts[0],
            .name = if (alone)
                try a.print("Cross compile {s}, unmeasured", .{names.items})
            else
                try a.print("Cross compile{s}{s}", .{ if (total > 1) " " else "", try shardName(a, group, total) }),
            .step = if (bench) "preflight-cross-bench" else "preflight-cross",
            .operation = .objects,
            .job_timeout = if (alone) unmeasured_job_minutes else try minutes(config, "cross_job_timeout"),
            .cache_key = try a.print("cross-{s}-{d}", .{ if (bench) "bench" else "objects", group }),
            .targets = names.items,
            .build_jobs = try crossBuildJobs(a, config, named.items, bench),
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

fn releaseJobs(a: std.mem.Allocator, config: src.Value, jobs: *std.ArrayList(Job)) !void {
    const compile = try src.string(src.get(config, "compile_step"), "check");
    // A compile job, as the cross ones: `cross_job_timeout` is its budget, not Job's default.
    for (hosts) |host| try jobs.append(a, .{ .os = host, .name = try a.print("compile ({s}, ReleaseSmall)", .{host}), .step = compile, .args = "-Doptimize=small", .job_timeout = try minutes(config, "cross_job_timeout") });
    try crossJobs(a, config, jobs, try src.items(src.get(config, "targets")), true);
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
    for ([_][]const u8{ "test_job_timeout", "windows_job_timeout", "source_job_timeout", "cross_job_timeout" }) |name| _ = try minutes(config, name);
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
    for ([_][]const u8{"portable_tests"}) |name| {
        const value = src.get(config, name);
        if (value != .null and value != .bool) return error.InvalidWorkflowBoolean;
    }
    const portable_hosts = src.get(config, "portable_hosts");
    if (portable_hosts != .null) {
        if (portable_hosts != .array) return error.InvalidPortableHosts;
        for (try src.strings(a, portable_hosts)) |host| {
            var found = false;
            for (every_host) |known| if (std.mem.eql(u8, host, known)) {
                found = true;
            };
            if (!found) return error.InvalidPortableHosts;
        }
    }
}

fn sdkJobs(a: std.mem.Allocator, config: src.Value, jobs: *std.ArrayList(Job)) !void {
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
        try jobs.append(a, .{ .os = host, .name = try a.print("{s}link ({s})", .{ if (std.mem.eql(u8, host, hosts[0])) "" else "SDK ", name }), .step = "ci-link", .args = try text.toOwnedSlice(), .setup = true, .operation = .link, .job_timeout = try minutes(config, "cross_job_timeout") });
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

test "the cross bundle retains every target, CPU and caller compile step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a,
        \\{"compile_step":"install","targets":["x86_64-windows-gnu",{"target":"aarch64-linux-gnu","cpu":"cortex_a72"}],"measured":{"phases":{"compile x86_64-windows-gnu":20,"benchmarks x86_64-windows-gnu":5,"compile aarch64-linux-gnu":20,"benchmarks aarch64-linux-gnu":5}}}
    , .{})).value;
    const jobs = try plan(a, config, .release);
    var bundles: usize = 0;
    for (jobs) |job| if (std.mem.eql(u8, job.step, "preflight-cross-bench")) {
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
    const config = (try std.json.parseFromSlice(src.Value, a,
        \\{"compile_step":"install","portable_tests":true,"cross_jobs":1,"targets":[{"target":"aarch64-linux-gnu","cpu":"cortex_a72"}]}
    , .{})).value;
    const targets = try fastTargets(a, config);
    try std.testing.expectEqual(@as(usize, 3), targets.len);
    const args = try crossArgs(a, &.{ "zig", "build" }, config, targets[0], "ci-check", null);
    try std.testing.expectEqualStrings("ci-check", args[2]);
    try std.testing.expectEqualStrings("-Dcpu=cortex_a72", args[5]);
    try std.testing.expectEqualStrings("-Doptimize=debug", args[6]);
    const bench = try crossArgs(a, &.{ "zig", "build" }, config, targets[0], "ci-check-bench", null);
    try std.testing.expectEqualStrings("ci-check-bench", bench[2]);
}

fn allTargets(jobs: []const Job, a: std.mem.Allocator) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (jobs) |job| {
        var each = std.mem.tokenizeScalar(u8, job.targets, ' ');
        while (each.next()) |name| try names.append(a, name);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn before(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.before);
    return std.mem.join(a, " ", names.items);
}

test "a cross target no run has measured has a job of its own, of GitHub's longest, named for it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // strand's 8155bf9: no ci/costs.json, and x86_64-windows-gnu outran the 20 minutes a guess
    // of 90 s had packed it into (run 43777274923).
    const many = (try std.json.parseFromSlice(src.Value, a,
        \\{"targets":["a-linux-gnu","b","c","x86_64-windows-gnu"]}
    , .{})).value;
    var jobs: std.ArrayList(Job) = .empty;
    try crossJobs(a, many, &jobs, try src.items(src.get(many, "targets")), false);
    try std.testing.expectEqual(@as(usize, 4), jobs.items.len);
    try std.testing.expectEqualStrings("a-linux-gnu b c x86_64-windows-gnu", try allTargets(jobs.items, a));
    try std.testing.expectEqualStrings("Cross compile x86_64-windows-gnu, unmeasured", jobs.items[3].name);
    for (jobs.items) |job| try std.testing.expectEqual(@as(usize, 360), job.job_timeout);
    // cross_jobs counts them among its jobs, and the measured share what is left.
    const asked = (try std.json.parseFromSlice(src.Value, a,
        \\{"cross_jobs":2,"targets":["a","b","c"],"measured":{"phases":{"compile a":10,"compile b":10,"benchmarks a":1,"benchmarks b":1}}}
    , .{})).value;
    jobs.clearRetainingCapacity();
    try crossJobs(a, asked, &jobs, try src.items(src.get(asked, "targets")), true);
    try std.testing.expectEqual(@as(usize, 2), jobs.items.len);
    try std.testing.expectEqualStrings("preflight-cross-bench", jobs.items[0].step);
    try std.testing.expectEqualStrings("Cross compile 1/2", jobs.items[0].name);
    try std.testing.expectEqualStrings("a b", jobs.items[0].targets);
    try std.testing.expectEqual(@as(usize, 20), jobs.items[0].job_timeout);
    try std.testing.expectEqualStrings("Cross compile c, unmeasured", jobs.items[1].name);
    for ([_][]const u8{ "{\"cross_jobs\":0,\"targets\":[\"a\"]}", "{\"cross_seconds\":0,\"targets\":[\"a\"]}" }) |text| {
        const bad = (try std.json.parseFromSlice(src.Value, a, text, .{})).value;
        try std.testing.expect(std.meta.isError(crossJobs(a, bad, &jobs, try src.items(src.get(bad, "targets")), false)));
    }
}

test "cross targets a run measured are balanced by their seconds, the benchmarks counted in the release tier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a,
        \\{"targets":["a","b","c","d","e"],"measured":{"phases":{"compile a":150,"compile b":40.5,"compile c":40,"compile d":30,"benchmarks a":100,"benchmarks b":10,"benchmarks c":10,"benchmarks d":10}}}
    , .{})).value;
    const targets = try src.items(src.get(config, "targets"));
    var fast: std.ArrayList(Job) = .empty;
    try crossJobs(a, config, &fast, targets, false);
    // 260.5 s of the measured four in jobs of 200 s, and e, unmeasured, alone.
    try std.testing.expectEqual(@as(usize, 3), fast.items.len);
    try std.testing.expectEqualStrings("a", fast.items[0].targets);
    try std.testing.expectEqualStrings("b c d", fast.items[1].targets);
    try std.testing.expectEqualStrings("e", fast.items[2].targets);
    var merge: std.ArrayList(Job) = .empty;
    try crossJobs(a, config, &merge, targets, true);
    // The benchmarks lengthen a to 250 s, which no job of 200 s holds alone: it has one to itself.
    try std.testing.expectEqual(@as(usize, 3), merge.items.len);
    try std.testing.expectEqualStrings("a", merge.items[0].targets);
    try std.testing.expectEqualStrings("b c d", merge.items[1].targets);
    try std.testing.expectEqualStrings("e", merge.items[2].targets);
}

test "portable matrix links Windows binaries on their SDK runners without losing native coverage; macOS builds where it runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"portable_tests\":true,\"targets\":[\"aarch64-linux-gnu\"]}", .{})).value;
    const jobs = try plan(a, config, .release);
    const tiers = try split(a, config, jobs, .release);
    // Windows and ARM Windows, each at Debug, ReleaseSafe and ReleaseFast.
    try std.testing.expectEqual(@as(usize, 6), tiers.compile.len);
    try std.testing.expectEqual(@as(usize, 6), tiers.run.len);
    for (tiers.compile, tiers.run) |builder, executor| {
        try std.testing.expectEqualStrings(executor.os, builder.os);
        try std.testing.expectEqualStrings(builder.artifact, executor.artifact);
        try std.testing.expect(!std.mem.eql(u8, executor.os, hosts[0]));
        try std.testing.expect(!std.mem.eql(u8, executor.os, hosts[1]));
    }
    try std.testing.expect(std.mem.find(u8, tiers.compile[0].args, "x86_64-windows-gnu") != null);
    // Every macOS job is a leg of the one macOS job, and no job is lost.
    var legs: usize = 0;
    var macos: usize = 0;
    for (tiers.native) |job| if (std.mem.eql(u8, job.os, hosts[1])) {
        macos += 1;
        legs += (try std.json.parseFromSliceLeaky([]const Job, a, job.legs.?, .{})).len;
    };
    try std.testing.expectEqual(@as(usize, 1), macos);
    try std.testing.expectEqual(jobs.len, tiers.native.len - macos + legs + tiers.run.len);
}

test "the release tier asks for one macOS runner: its macOS jobs are legs in sequence, the next job only past 360 minutes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"shards\":{\"macos\":{\"min\":2}}}", .{})).value;
    const jobs = try plan(a, config, .release);
    var planned: std.ArrayList(Job) = .empty;
    for (jobs) |job| if (std.mem.eql(u8, job.os, hosts[1])) try planned.append(a, job);
    const tiers = try split(a, config, jobs, .release);
    var one: ?Job = null;
    for (tiers.native) |job| if (std.mem.eql(u8, job.os, hosts[1])) {
        try std.testing.expect(one == null);
        one = job;
    };
    const job = one.?;
    try std.testing.expectEqualStrings("legs", job.step);
    const legs = try std.json.parseFromSliceLeaky([]const Job, a, job.legs.?, .{});
    // In the order planned, each leg as it was: its name, step, arguments, shard and limit.
    try std.testing.expectEqual(planned.items.len, legs.len);
    var minutes_total: usize = 0;
    for (planned.items, legs) |want, leg| {
        try std.testing.expectEqualStrings(want.name, leg.name);
        try std.testing.expectEqualStrings(want.args, leg.args);
        try std.testing.expectEqualStrings(want.shard, leg.shard);
        try std.testing.expectEqualStrings(want.cache_key, leg.cache_key);
        minutes_total += leg.job_timeout;
    }
    try std.testing.expectEqual(@min(360, minutes_total), job.job_timeout);
    // The ci tier keeps its one macOS test job as it was.
    for ((try split(a, config, try plan(a, config, .ci), .ci)).native) |ci| try std.testing.expect(ci.legs == null);
    // Legs past GitHub's 360 minutes start a second job, each named as one of two.
    const long = (try std.json.parseFromSlice(src.Value, a, "{\"shards\":{\"macos\":{\"min\":2}},\"test_job_timeout\":100}", .{})).value;
    var parts: std.ArrayList([]const u8) = .empty;
    for ((try split(a, long, try plan(a, long, .release), .release)).native) |each| if (std.mem.eql(u8, each.os, hosts[1])) {
        try std.testing.expect(each.job_timeout <= 360);
        try parts.append(a, each.name);
    };
    try std.testing.expect(parts.items.len > 1);
    try std.testing.expect(std.mem.endsWith(u8, parts.items[0], try a.print("(1/{d})", .{parts.items.len})));
}

test "each host's shards run every mode, split by count, with the lint and compile jobs once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"shards\":{\"windows\":{\"min\":3},\"macos\":{\"min\":2}}}", .{})).value;
    const jobs = try plan(a, config, .release);
    var windows: usize = 0;
    var macos: usize = 0;
    var linux: usize = 0;
    for (jobs) |job| {
        if (!std.mem.eql(u8, job.step, "ci-test")) continue;
        if (job.machine != .none) continue;
        if (std.mem.eql(u8, job.os, hosts[2])) windows += 1;
        if (std.mem.eql(u8, job.os, hosts[1])) macos += 1;
        if (std.mem.eql(u8, job.os, hosts[0])) {
            linux += 1;
            try std.testing.expectEqualStrings("", job.shard);
        }
    }
    try std.testing.expectEqual(@as(usize, 9), windows);
    try std.testing.expectEqual(@as(usize, 6), macos);
    try std.testing.expectEqual(@as(usize, 3), linux);
    for (jobs) |job| if (std.mem.eql(u8, job.name, "test (windows-latest, ReleaseSafe) shard 3/3")) {
        try std.testing.expectEqualStrings("3/3", job.shard);
    };
    for (jobs, 0..) |x, i| for (jobs[i + 1 ..]) |y| try std.testing.expect(!std.mem.eql(u8, x.cache_key, y.cache_key));
    // The source checks job owns lint in the release tier; no test job repeats it.
    for (jobs) |job| if (!std.mem.eql(u8, job.step, "lint") and job.setup) try std.testing.expect(std.mem.find(u8, job.args, "-Dci-lint=false") != null);
    try std.testing.expectError(error.InvalidShardCount, plan(a, (try std.json.parseFromSlice(src.Value, a, "{\"shards\":{\"windows\":{\"min\":0}}}", .{})).value, .release));
}

test "the FreeBSD job on its kernel splits into its shards, and runs where KVM is" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"shards\":{\"freebsd\":{\"min\":2}}}", .{})).value;
    var shards: usize = 0;
    for (try plan(a, config, .release)) |job| if (job.machine == .freebsd) {
        shards += 1;
        try std.testing.expectEqualStrings(hosts[0], job.os);
        try std.testing.expectEqualStrings(try a.print("{d}/2", .{shards}), job.shard);
        try std.testing.expect(std.mem.endsWith(u8, job.name, try a.print(" shard {d}/2", .{shards})));
    };
    try std.testing.expectEqual(@as(usize, 2), shards);
    // Only the release tier runs it.
    for (try plan(a, config, .ci)) |job| try std.testing.expect(job.machine == .none);
    try std.testing.expectError(error.InvalidShardCount, plan(a, (try std.json.parseFromSlice(src.Value, a, "{\"shards\":{\"freebsd\":{\"min\":0}}}", .{})).value, .release));
}

test "a configured target a runner executes, on an ABI not its own, runs its Debug suite there" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a,
        \\{"portable_tests":true,"shards":{"windows":{"min":2}},"build_args":["-Dfeature=true"],"targets":[
        \\"x86_64-windows-msvc",{"target":"aarch64-windows-msvc","args":["-Dsdk=true"]},"x86_64-linux-musl",
        \\"x86_64-windows-gnu","x86_64-windows",{"target":"aarch64-linux-gnu","cpu":"cortex_a72"},"aarch64-macos","x86_64-macos","riscv64-linux-musl"]}
    , .{})).value;
    const jobs = try plan(a, config, .release);
    var names: std.ArrayList([]const u8) = .empty;
    for (jobs) |job| if (job.target) |target| {
        try names.append(a, job.name);
        try std.testing.expectEqualStrings("ci-test", job.step);
        try std.testing.expect(job.setup);
        try std.testing.expect(std.mem.find(u8, job.args, try a.print("-Dtarget={s}", .{target})) != null);
        try std.testing.expect(std.mem.startsWith(u8, job.args, "-Doptimize=debug -Dci-timings=true -Dci-lint=false"));
        try std.testing.expect(std.mem.find(u8, job.args, "-Dfeature=true") != null);
    };
    try std.testing.expectEqual(@as(usize, 4), names.items.len);
    try std.testing.expectEqualStrings("test (x86_64-windows-msvc on windows-latest, Debug) shard 1/2", names.items[0]);
    try std.testing.expectEqualStrings("test (x86_64-windows-msvc on windows-latest, Debug) shard 2/2", names.items[1]);
    try std.testing.expectEqualStrings("test (aarch64-windows-msvc on windows-11-arm, Debug)", names.items[2]);
    try std.testing.expectEqualStrings("test (x86_64-linux-musl on ubuntu-latest, Debug)", names.items[3]);
    for (jobs) |job| if (std.mem.eql(u8, job.name, names.items[2])) {
        try std.testing.expectEqualStrings(arm_hosts[1], job.os);
        try std.testing.expect(std.mem.endsWith(u8, job.args, "-Dsdk=true"));
    };
    // Each builds where it runs, outside the compile-once split.
    const tiers = try split(a, config, jobs, .release);
    for ([_][]Job{ tiers.compile, tiers.run }) |part| for (part) |job| try std.testing.expect(job.target == null);
    var native: usize = 0;
    for (tiers.native) |job| native += @intFromBool(job.target != null);
    try std.testing.expectEqual(@as(usize, 4), native);
    // Only the release tier runs them, and a job that sets no target is written, and keyed, as before.
    for (try plan(a, config, .ci)) |job| try std.testing.expect(job.target == null);
    try std.testing.expect(std.mem.find(u8, try include(a, &.{.{ .os = hosts[0], .name = "x" }}), "\"target\"") == null);
}

test "the riscv64 job on its emulated kernel splits into its shards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"shards\":{\"riscv64\":{\"min\":2}}}", .{})).value;
    var shards: usize = 0;
    for (try plan(a, config, .release)) |job| if (job.machine == .riscv64) {
        shards += 1;
        try std.testing.expectEqualStrings(try a.print("{d}/2", .{shards}), job.shard);
        try std.testing.expect(std.mem.endsWith(u8, job.name, try a.print(" shard {d}/2", .{shards})));
    };
    try std.testing.expectEqual(@as(usize, 2), shards);
    try std.testing.expectError(error.InvalidShardCount, plan(a, (try std.json.parseFromSlice(src.Value, a, "{\"shards\":{\"riscv64\":{\"min\":0}}}", .{})).value, .release));
}

test "the riscv64 suite takes as many jobs as hold half a job of its recorded tests, those it never ran weighed by Linux Debug" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A 20-minute job holds 600 s of tests. `ran` took ten times its Linux time emulated;
    // `killed`, never run there, weighs 10 x 40 s; `new` was not recorded at all and weighs
    // the mean of the two: 200 + 400 + 300 s, two jobs.
    const recorded =
        \\{"durations":{"keys":["linux-debug","linux-riscv64-debug"],"tests":{"ran":[20,200],"killed":[40,null],"new":[null,null]}}}
    ;
    for ([_]struct { text: []const u8, jobs: usize }{
        .{ .text = recorded, .jobs = 2 },
        // `riscv64_seconds` sets the share; `shards.riscv64` floors the count.
        .{ .text = "{\"riscv64_seconds\":300," ++ recorded[1..], .jobs = 3 },
        .{ .text = "{\"shards\":{\"riscv64\":{\"min\":4}}," ++ recorded[1..], .jobs = 4 },
        // No record of the column or of Linux to scale: one job, whose record sizes the next.
        .{ .text = "{\"durations\":{\"keys\":[\"linux-debug\"],\"tests\":{\"a\":[null]}}}", .jobs = 1 },
        .{ .text = "{}", .jobs = 1 },
    }) |case| {
        const config = (try std.json.parseFromSlice(src.Value, a, case.text, .{})).value;
        var count: usize = 0;
        for (try plan(a, config, .release)) |job| if (job.machine == .riscv64) {
            count += 1;
        };
        try std.testing.expectEqual(case.jobs, count);
    }
    const bad = (try std.json.parseFromSlice(src.Value, a, "{\"riscv64_seconds\":0}", .{})).value;
    try std.testing.expectError(error.InvalidEmulatedSeconds, plan(a, bad, .release));
}

test "every host's job count is its record's, each against its own job's time, within the bounds shards sets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A 20-minute job holds 600 s of tests. Windows records 1500 s of Debug and 1700 s of
    // ReleaseSafe: three jobs, every mode's share in each. macOS records 500 s: one. Linux's
    // Debug 1300 s: three, in the ci tier's Linux Debug and the release tier's alike. Three
    // tests, so that each of three jobs has one to run.
    const record =
        \\"durations":{"keys":["linux-debug","macos-debug","windows-debug","windows-safe"],"complete":["linux-debug","macos-debug","windows-debug","windows-safe"],"tests":{"a":[500,100,500,500],"b":[400,200,500,700],"c":[400,200,500,500]}}
    ;
    const counted = struct {
        fn jobs(planned: []const Job, prefix: []const u8) usize {
            var n: usize = 0;
            for (planned) |job| if (std.mem.startsWith(u8, job.name, prefix)) {
                n += 1;
            };
            return n;
        }
    };
    const config = (try std.json.parseFromSlice(src.Value, a, "{" ++ record ++ "}", .{})).value;
    const release = try plan(a, config, .release);
    try std.testing.expectEqual(@as(usize, 3 * 3), counted.jobs(release, "test (windows-latest,"));
    try std.testing.expectEqual(@as(usize, 3), counted.jobs(release, "test (macos-latest,"));
    try std.testing.expectEqual(@as(usize, 3 * 3), counted.jobs(release, "test (ubuntu-latest,"));
    try std.testing.expectEqual(@as(usize, 3), counted.jobs(try plan(a, config, .ci), "Linux Debug"));
    // A Windows job of 30 minutes holds 900 s: two.
    const longer = (try std.json.parseFromSlice(src.Value, a, "{\"windows_job_timeout\":30," ++ record ++ "}", .{})).value;
    try std.testing.expectEqual(@as(usize, 2 * 3), counted.jobs(try plan(a, longer, .release), "test (windows-latest,"));
    // A cap and a floor a package means: Windows held to two, macOS kept at two.
    const bounded = (try std.json.parseFromSlice(src.Value, a, "{\"shards\":{\"windows\":{\"max\":2},\"macos\":{\"min\":2}}," ++ record ++ "}", .{})).value;
    const held = try plan(a, bounded, .release);
    try std.testing.expectEqual(@as(usize, 2 * 3), counted.jobs(held, "test (windows-latest,"));
    try std.testing.expectEqual(@as(usize, 2 * 3), counted.jobs(held, "test (macos-latest,"));
    // A host's entry is bounds alone: a count, bounds that bound nothing, an unknown bound and
    // a host that is none are refused.
    for ([_][]const u8{ "{\"shards\":{\"windows\":6}}", "{\"shards\":{\"windows\":{\"min\":3,\"max\":2}}}", "{\"shards\":{\"windows\":{}}}", "{\"shards\":{\"windows\":{\"most\":2}}}", "{\"shards\":{\"solaris\":{\"min\":2}}}" }) |text| {
        try std.testing.expectError(error.InvalidShardCount, plan(a, (try std.json.parseFromSlice(src.Value, a, text, .{})).value, .release));
    }
}

test "a riscv64 column a finished run measured weighs only the tests that job runs, never the end-to-end ones it leaves out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // bay's shape: unit tests the emulated job runs (recorded there, seconds each), and
    // end-to-end tests it never runs, minutes on Linux Debug and nothing on riscv64.
    const tests =
        \\"unit.a":[0.5,4],"unit.b":[0.2,2],"unit.c":[0.1,1],"e2e.resolve":[100,null],"e2e.release":[110,null],"e2e.prebuilt":[95,null]
    ;
    const finished = "{\"durations\":{\"keys\":[\"linux-debug\",\"linux-riscv64-debug\"],\"complete\":[\"linux-riscv64-debug\"],\"tests\":{" ++ tests ++ "}}}";
    // The same record before any finished run: an end-to-end test the column lacks may be one
    // a cut job never reached, and weighs its Linux time scaled (7 s / 0.8 s here): about 2,680 s
    // of tests in 600 s jobs, five.
    const cut = "{\"durations\":{\"keys\":[\"linux-debug\",\"linux-riscv64-debug\"],\"tests\":{" ++ tests ++ "}}}";
    for ([_]struct { text: []const u8, jobs: usize }{
        .{ .text = finished, .jobs = 1 },
        .{ .text = cut, .jobs = 5 },
        // A complete column that recorded nothing: one job, whose record sizes the next.
        .{ .text = "{\"durations\":{\"keys\":[\"linux-debug\",\"linux-riscv64-debug\"],\"complete\":[\"linux-riscv64-debug\"],\"tests\":{\"e2e\":[100,null]}}}", .jobs = 1 },
    }) |case| {
        const config = (try std.json.parseFromSlice(src.Value, a, case.text, .{})).value;
        var count: usize = 0;
        for (try plan(a, config, .release)) |job| if (job.machine == .riscv64) {
            count += 1;
        };
        try std.testing.expectEqual(case.jobs, count);
    }
}

test "no job passes a test timeout: the watchdog bounds each test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (try plan(a, (try std.json.parseFromSlice(src.Value, a, "{}", .{})).value, .release)) |job|
        try std.testing.expect(std.mem.find(u8, job.args, "test-timeout") == null);
}

test "Linux's job count splits the ci tier's Linux Debug tests, which no other job runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"shards\":{\"linux\":{\"min\":3}}}", .{})).value;
    const jobs = try plan(a, config, .ci);
    try std.testing.expectEqual(@as(usize, 7), jobs.len);
    try std.testing.expectEqualStrings("lint", jobs[0].step);
    // The documented snippets are a job of their own, which a red lint does not hide.
    try std.testing.expectEqualStrings("snippets", jobs[6].step);
    try std.testing.expectEqualStrings("-Doptimize=debug -Dci-lint=false -Dci-timings=true", jobs[1].args);
    try std.testing.expectEqualStrings("1/3", jobs[1].shard);
    try std.testing.expectEqualStrings("Linux Debug shard 2/3", jobs[2].name);
    try std.testing.expectEqualStrings("3/3", jobs[3].shard);
    for (jobs[1..6]) |job| try std.testing.expectEqualStrings("ci-test", job.step);
    for (jobs[4..6]) |job| try std.testing.expect(!std.mem.eql(u8, job.os, hosts[0]));
}

test "portable shards share one compilation per host and mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"portable_tests\":true,\"shards\":{\"windows\":{\"min\":3}}}", .{})).value;
    const jobs = try plan(a, config, .release);
    const tiers = try split(a, config, jobs, .release);
    // Windows and ARM Windows: macOS builds where it runs.
    try std.testing.expectEqual(@as(usize, 6), tiers.compile.len);
    try std.testing.expectEqual(@as(usize, 9 + 3), tiers.run.len);
    for (tiers.compile) |builder| {
        try std.testing.expectEqualStrings("", builder.shard);
        try std.testing.expect(std.mem.find(u8, builder.name, "shard") == null);
    }
    var sharing: usize = 0;
    for (tiers.run) |executor| if (std.mem.eql(u8, executor.name, "test (windows-latest, Debug) shard 2/3")) {
        for (tiers.run) |other| if (std.mem.eql(u8, other.artifact, executor.artifact)) {
            sharing += 1;
        };
    };
    try std.testing.expectEqual(@as(usize, 3), sharing);
}

test "the ci tier is the source checks, the Debug suite on Linux, macOS and Windows, and the configured targets' objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"cross_jobs\":1,\"targets\":[\"aarch64-linux-gnu\"],\"hardened\":true}", .{})).value;
    const jobs = try plan(a, config, .ci);
    try std.testing.expectEqual(@as(usize, 6), jobs.len);
    try std.testing.expectEqualStrings("lint", jobs[0].step);
    try std.testing.expectEqualStrings("snippets", jobs[5].step);
    try std.testing.expectEqualStrings("ci-test", jobs[1].step);
    try std.testing.expectEqualStrings("-Doptimize=debug -Dci-lint=false -Dci-timings=true", jobs[1].args);
    try std.testing.expectEqualStrings("test (macos-latest, Debug)", jobs[2].name);
    try std.testing.expectEqualStrings("test (windows-latest, Debug)", jobs[3].name);
    for (jobs[1..4]) |job| {
        try std.testing.expectEqualStrings("ci-test", job.step);
        try std.testing.expectEqualStrings("-Doptimize=debug -Dci-lint=false -Dci-timings=true", job.args);
        try std.testing.expect(job.operation == .execute);
    }
    // Every push compiles the configured targets.
    try std.testing.expectEqualStrings("preflight-cross", jobs[4].step);
    try std.testing.expectEqualStrings("aarch64-linux-gnu", jobs[4].targets);
    // SDK links, benchmarks, sanitizers and the hardened checks are the release tier's.
    for (jobs) |job| {
        try std.testing.expect(!std.mem.startsWith(u8, job.step, "hardened"));
        try std.testing.expect(!std.mem.eql(u8, job.step, "ci-link"));
    }
    for (jobs, 0..) |x, i| for (jobs[i + 1 ..]) |y| try std.testing.expect(!std.mem.eql(u8, x.cache_key, y.cache_key));
    const shards = (try std.json.parseFromSlice(src.Value, a, "{\"shards\":{\"windows\":{\"min\":2}}}", .{})).value;
    try std.testing.expectEqualStrings("test (windows-latest, Debug) shard 2/2", (try plan(a, shards, .ci))[4].name);
}

test "the ci tier runs macOS and Windows Debug natively, every shard building its own, even with portable tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"portable_tests\":true,\"shards\":{\"windows\":{\"min\":2}}}", .{})).value;
    const jobs = try plan(a, config, .ci);
    const tiers = try split(a, config, jobs, .ci);
    try std.testing.expectEqual(jobs.len, tiers.native.len);
    try std.testing.expectEqual(@as(usize, 0), tiers.compile.len);
    try std.testing.expectEqual(@as(usize, 0), tiers.run.len);
}

test "no cross job is dealt more compiling than its cross_job_timeout leaves, and a target that cannot fit is refused by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // relic's run 43737703239: aarch64-windows-gnu measured 975 s, in jobs bounded at 20 minutes.
    const measured = "\"measured\":{\"phases\":{\"compile aarch64-windows-gnu\":975,\"compile x86_64-linux-gnu\":400,\"compile aarch64-linux-gnu\":400}}";
    const fits = (try std.json.parseFromSlice(src.Value, a, try a.print("{{\"targets\":[\"aarch64-windows-gnu\",\"x86_64-linux-gnu\",\"aarch64-linux-gnu\"],\"cross_seconds\":2000,\"cross_job_timeout\":25,{s}}}", .{measured}), .{})).value;
    var jobs: std.ArrayList(Job) = .empty;
    try crossJobs(a, fits, &jobs, try src.items(src.get(fits, "targets")), false);
    // 25 minutes less 300 s of setup leaves 1200 s: the 975 s target needs a job of its own.
    try std.testing.expect(jobs.items.len >= 2);
    const tight = (try std.json.parseFromSlice(src.Value, a, try a.print("{{\"targets\":[\"aarch64-windows-gnu\",\"x86_64-linux-gnu\"],{s}}}", .{measured}), .{})).value;
    jobs.clearRetainingCapacity();
    try std.testing.expectError(error.CrossTargetPastTimeout, crossJobs(a, tight, &jobs, try src.items(src.get(tight, "targets")), false));
    try std.testing.expect(std.mem.find(u8, problem, "aarch64-windows-gnu takes 16m15s") != null);
    const fixed = (try std.json.parseFromSlice(src.Value, a, try a.print("{{\"targets\":[\"aarch64-windows-gnu\",\"x86_64-linux-gnu\",\"aarch64-linux-gnu\"],\"cross_jobs\":1,\"cross_job_timeout\":25,{s}}}", .{measured}), .{})).value;
    jobs.clearRetainingCapacity();
    try std.testing.expectError(error.CrossJobPastTimeout, crossJobs(a, fixed, &jobs, try src.items(src.get(fixed, "targets")), false));
}

test "an emulated or instrumented job takes its kind's budget times preflight's slowdown for it, at most 360" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"test_job_timeout\":30,\"policy\":\"family\"}", .{})).value;
    var seen: usize = 0;
    for (try plan(a, config, .release)) |job| {
        const want: ?usize = if (std.mem.startsWith(u8, job.name, "hardened-tsan")) 90 else if (std.mem.startsWith(u8, job.name, "test (riscv64-linux")) 120 else if (std.mem.startsWith(u8, job.name, "test (x86_64-freebsd")) 60 else if (std.mem.startsWith(u8, job.name, "test (ubuntu-latest, Debug)")) 30 else null;
        if (want) |minutes_wanted| {
            try std.testing.expectEqual(minutes_wanted, job.job_timeout);
            seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 4), seen);
    const long = (try std.json.parseFromSlice(src.Value, a, "{\"test_job_timeout\":120,\"policy\":\"family\"}", .{})).value;
    for (try plan(a, long, .release)) |job| if (std.mem.startsWith(u8, job.name, "test (riscv64-linux")) try std.testing.expectEqual(@as(usize, 360), job.job_timeout);
}

test "every compile and link job of the release tier takes cross_job_timeout, none Job's default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // strand's ReleaseSmall compiles took 20m44s and 20m19s against a fixed 20 (run 43741335353).
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"targets\":[\"aarch64-linux-gnu\",\"x86_64-windows-msvc\",\"aarch64-macos\"],\"sdk_targets\":[\"x86_64-windows-msvc\"],\"cross_job_timeout\":45,\"policy\":\"family\",\"measured\":{\"phases\":{\"compile aarch64-linux-gnu\":30,\"benchmarks aarch64-linux-gnu\":5,\"compile x86_64-windows-msvc\":30,\"benchmarks x86_64-windows-msvc\":5,\"compile aarch64-macos\":30,\"benchmarks aarch64-macos\":5}}}", .{})).value;
    var compiles: usize = 0;
    var links: usize = 0;
    for (try plan(a, config, .release)) |job| {
        const small = std.mem.endsWith(u8, job.name, ", ReleaseSmall)");
        const cross = std.mem.startsWith(u8, job.name, "Cross compile");
        const link = job.operation == .link;
        if (small) compiles += 1;
        if (link) links += 1;
        if (small or cross or link) try std.testing.expectEqual(@as(usize, 45), job.job_timeout);
    }
    try std.testing.expectEqual(@as(usize, 3), compiles);
    try std.testing.expect(links > 0);
}

test "the release tier is the full matrix: every mode on every host, ReleaseSmall on each system, cross targets and the source checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"targets\":[\"aarch64-linux-gnu\"],\"policy\":\"family\",\"measured\":{\"phases\":{\"compile aarch64-linux-gnu\":30,\"benchmarks aarch64-linux-gnu\":5}}}", .{})).value;
    const jobs = try plan(a, config, .release);
    const expected = [_][]const u8{
        "test (ubuntu-latest, Debug)",                          "test (ubuntu-latest, ReleaseSafe)",                    "test (ubuntu-latest, ReleaseFast)",
        "test (macos-latest, Debug)",                           "test (macos-latest, ReleaseSafe)",                     "test (macos-latest, ReleaseFast)",
        "test (windows-latest, Debug)",                         "test (windows-latest, ReleaseSafe)",                   "test (windows-latest, ReleaseFast)",
        "test (ubuntu-24.04-arm, Debug)",                       "test (ubuntu-24.04-arm, ReleaseSafe)",                 "test (ubuntu-24.04-arm, ReleaseFast)",
        "test (windows-11-arm, Debug)",                         "test (windows-11-arm, ReleaseSafe)",                   "test (windows-11-arm, ReleaseFast)",
        "source checks",                                        "documented snippets",                                  "compile (ubuntu-latest, ReleaseSmall)",
        "compile (macos-latest, ReleaseSmall)",                 "compile (windows-latest, ReleaseSmall)",               "Cross compile",
        "test (riscv64-linux on its kernel under QEMU, Debug)", "test (x86_64-freebsd on its kernel under KVM, Debug)",
        // Under the family's policy the hardened profile is every package's.
        "hardened",
        "hardened-fuzz",                                        "hardened-tsan",
    };
    try std.testing.expectEqual(expected.len, jobs.len);
    for (expected) |name| {
        var found: usize = 0;
        for (jobs) |job| if (std.mem.eql(u8, job.name, name)) {
            found += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), found);
    }
    // Every host the tier executes records its durations, QEMU's emulated kernel too, a column
    // of its own; none of it is the fast job.
    for (jobs) |job| {
        switch (job.machine) {
            .none => {},
            .riscv64 => {
                try std.testing.expect(std.mem.find(u8, job.args, "-Dci-timings=true -Dtarget=riscv64-linux-musl -Dci-vm") != null);
                continue;
            },
            .freebsd => {
                try std.testing.expect(std.mem.find(u8, job.args, "-Dci-timings=true -Dtarget=x86_64-freebsd -Dci-vm") != null);
                continue;
            },
        }
        if (std.mem.eql(u8, job.step, "ci-test")) try std.testing.expect(std.mem.find(u8, job.args, "-Dci-timings=true") != null);
    }
}

/// `jobs` with each job of legs (`macosLegs`) in place of its legs, as a test counts what is planned.
fn expanded(a: std.mem.Allocator, jobs: []const Job) ![]Job {
    var all: std.ArrayList(Job) = .empty;
    for (jobs) |job| {
        if (job.legs) |text| try all.appendSlice(a, try std.json.parseFromSliceLeaky([]const Job, a, text, .{})) else try all.append(a, job);
    }
    return all.items;
}

test "the ci tier executes macOS and Windows, and only the release tier ARM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"portable_tests\":true,\"shards\":{\"macos\":{\"min\":2}}}", .{})).value;
    for ([_]Tier{ .ci, .release }) |tier| {
        const tiers = try split(a, config, try plan(a, config, tier), tier);
        var executed: usize = 0;
        for ([_][]const Job{ try expanded(a, tiers.native), tiers.run }) |group| for (group) |job| {
            if (!std.mem.eql(u8, job.os, hosts[0])) executed += 1;
        };
        try std.testing.expectEqual(@as(usize, switch (tier) {
            // macOS's two shards and Windows, each building its own.
            .ci => 2 + 1,
            // Every mode on macOS (two shards), Windows and both ARM runners, and the
            // ReleaseSmall compiles of macOS and Windows.
            .release => 2 * 3 + 3 + 2 * 3 + 2,
            .fuzz => unreachable,
        }), executed);
    }
}

test "owner SDK link jobs retain configured targets CPUs and feature arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a,
        \\{"portable_tests":true,"build_args":["-Dfeature=true"],"targets":[{"target":"x86_64-macos","cpu":"baseline","args":["-Dtrust-store=true"]},"aarch64-macos","aarch64-windows-gnu","aarch64-linux-gnu"]}
    , .{})).value;
    const cross = try fastTargets(a, config);
    try std.testing.expectEqual(@as(usize, 5), cross.len);
    const argv = try crossArgs(a, &.{ "zig", "build" }, config, cross[0], "ci-check", null);
    try std.testing.expectEqualStrings("ci-check", argv[2]);
    try std.testing.expectEqualStrings("-Dcpu=baseline", argv[5]);
    try std.testing.expectEqualStrings("-Dfeature=true", argv[6]);
    try std.testing.expectEqualStrings("-Dtrust-store=true", argv[7]);
    for ([_]Tier{.release}) |tier| {
        const tiers = try split(a, config, try plan(a, config, tier), tier);
        var linked: usize = 0;
        for (try expanded(a, tiers.native)) |job| if (std.mem.eql(u8, job.step, "ci-link")) {
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
        for (tiers.compile) |job| {
            try std.testing.expect(job.operation == .link);
            try std.testing.expect(!std.mem.eql(u8, job.os, hosts[0]));
        }
        for (tiers.run) |job| try std.testing.expect(job.operation == .replay);
    }
    const bad = (try std.json.parseFromSlice(src.Value, a, "{\"build_args\":[\"-Dtarget=x86_64-macos\"]}", .{})).value;
    try std.testing.expectError(error.InvalidBuildArgs, plan(a, bad, .ci));
}

test "a macOS link that needs no framework runs on Linux; one that links a framework keeps the Mac" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a,
        \\{"targets":["x86_64-macos","aarch64-macos","x86_64-windows-gnu"],"sdk_targets":["aarch64-macos"]}
    , .{})).value;
    var seen: usize = 0;
    for (try plan(a, config, .release)) |job| {
        if (!std.mem.eql(u8, job.step, "ci-link")) continue;
        seen += 1;
        if (std.mem.find(u8, job.args, "x86_64-macos") != null) {
            try std.testing.expectEqualStrings(hosts[0], job.os);
            try std.testing.expectEqualStrings("link (x86_64-macos)", job.name);
        } else if (std.mem.find(u8, job.args, "aarch64-macos") != null) {
            try std.testing.expectEqualStrings(hosts[1], job.os);
            try std.testing.expectEqualStrings("SDK link (aarch64-macos)", job.name);
        } else try std.testing.expectEqualStrings(hosts[2], job.os);
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
    const wrong = (try std.json.parseFromSlice(src.Value, a, "{\"targets\":[\"x86_64-macos\"],\"sdk_targets\":\"x86_64-macos\"}", .{})).value;
    try std.testing.expectError(error.InvalidSdkTargets, plan(a, wrong, .release));
}

test "the hardened jobs are every package's under the family's policy, and without it a package's that says hardened" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { []const u8, ?usize };
    for ([_]Case{
        // The family's: planned with or without the key, and no opting out.
        .{ "{\"policy\":\"family\"}", 3 },
        .{ "{\"policy\":\"family\",\"hardened\":true}", 3 },
        .{ "{\"policy\":\"family\",\"hardened\":false}", null },
        // A stranger's: only when asked for.
        .{ "{}", 0 },
        .{ "{\"hardened\":false}", 0 },
        .{ "{\"hardened\":true}", 3 },
        .{ "{\"hardened\":\"yes\"}", null },
    }) |case| {
        const config = (try std.json.parseFromSlice(src.Value, a, case[0], .{})).value;
        const want = case[1] orelse {
            try std.testing.expectError(error.InvalidHardenedProfile, plan(a, config, .release));
            continue;
        };
        var found: usize = 0;
        for (try plan(a, config, .release)) |job| {
            if (std.mem.startsWith(u8, job.step, "hardened")) found += 1;
        }
        try std.testing.expectEqual(want, found);
    }
    try std.testing.expectError(error.UnknownPolicy, plan(a, (try std.json.parseFromSlice(src.Value, a, "{\"policy\":\"famliy\"}", .{})).value, .release));
}

test "hardened planner schedules native execution with no portable sanitizer replay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"portable_tests\":true,\"hardened\":true}", .{})).value;
    const tiers = try split(a, config, try plan(a, config, .release), .release);
    var executed: usize = 0;
    for (tiers.native) |job| if (std.mem.startsWith(u8, job.step, "hardened")) {
        executed += 1;
        try std.testing.expectEqualStrings(hosts[0], job.os);
        try std.testing.expectEqual(.execute, job.operation);
        try std.testing.expectEqualStrings("", job.artifact);
    };
    try std.testing.expectEqual(@as(usize, 3), executed);
}

test "the hardened jobs take the test jobs' time limit and shards, ThreadSanitizer's of its own, and fuzz in one job" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"test_job_timeout\":45,\"shards\":{\"linux\":{\"min\":2},\"tsan\":{\"min\":8}},\"policy\":\"family\"}", .{})).value;
    try validate(a, config);
    var counts = [_]usize{ 0, 0, 0 };
    for (try plan(a, config, .release)) |job| for ([_][]const u8{ "hardened", "hardened-fuzz", "hardened-tsan" }, &counts) |step, *count| {
        if (!std.mem.eql(u8, job.step, step)) continue;
        count.* += 1;
        // ThreadSanitizer's job runs the suite instrumented: preflight's slowdown for it.
        try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, step, "hardened-tsan")) 135 else 45), job.job_timeout);
        if (std.mem.eql(u8, step, "hardened-fuzz")) try std.testing.expectEqualStrings("", job.shard) else try std.testing.expect(job.shard.len > 0);
    };
    try std.testing.expectEqual([_]usize{ 2, 1, 8 }, counts);
    // Without bounds of its own, ThreadSanitizer's run is sized by its own record, never by the
    // suite's floor: with none yet, one job; with 4000 s of instrumented tests and 1800 s a job
    // (half its 60 minutes), three.
    for ([_]struct { text: []const u8, jobs: usize }{
        .{ .text = "{\"shards\":{\"linux\":{\"min\":3}},\"policy\":\"family\"}", .jobs = 1 },
        .{ .text = "{\"policy\":\"family\",\"durations\":{\"keys\":[\"linux-debug\",\"linux-debug-tsan\"],\"complete\":[\"linux-debug-tsan\"],\"tests\":{\"a\":[100,1500],\"b\":[100,1500],\"c\":[100,1000]}}}", .jobs = 3 },
    }) |case| {
        const own = (try std.json.parseFromSlice(src.Value, a, case.text, .{})).value;
        var tsan: usize = 0;
        for (try plan(a, own, .release)) |job| if (std.mem.eql(u8, job.step, "hardened-tsan")) {
            tsan += 1;
            try std.testing.expectEqual(@as(usize, 60), job.job_timeout);
        };
        try std.testing.expectEqual(case.jobs, tsan);
    }
    try std.testing.expectError(error.InvalidShardCount, validate(a, (try std.json.parseFromSlice(src.Value, a, "{\"shards\":{\"tsan\":{\"min\":0}}}", .{})).value));
}

test "a package's own jobs join the tiers they name, on the hosts they name, with the gate's setup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a,
        \\{"build_args":["-Dsimd=false"],"jobs":[
        \\ {"name":"conformance","step":"ci","directory":"conformance","os":["ubuntu-latest","macos-latest"]},
        \\ {"name":"contracts (values)","step":"contracts-values","tiers":["ci"],"args":["-Dgroup=values"],"setup":false,"timeout":40},
        \\ {"name":"reports","step":"check-reports","setup":"reports-setup","tiers":["release"]}]}
    , .{})).value;
    const merge = try plan(a, config, .ci);
    const release = try plan(a, config, .release);
    for (release) |job| try std.testing.expect(!std.mem.eql(u8, job.step, "contracts-values"));
    var conformance: usize = 0;
    for (merge) |job| {
        if (std.mem.eql(u8, job.directory, "conformance")) {
            conformance += 1;
            try std.testing.expectEqualStrings("ci", job.step);
            try std.testing.expect(job.setup);
            // The package's build options are its own builds'; a declared job takes only its own.
            try std.testing.expectEqualStrings("", job.args);
        }
        if (std.mem.eql(u8, job.step, "contracts-values")) {
            try std.testing.expect(!job.setup);
            try std.testing.expectEqual(@as(usize, 40), job.job_timeout);
            try std.testing.expectEqualStrings("-Dgroup=values", job.args);
        }
        try std.testing.expect(!std.mem.eql(u8, job.step, "check-reports"));
    }
    try std.testing.expectEqual(@as(usize, 2), conformance);
    for (merge) |job| if (std.mem.eql(u8, job.directory, "conformance") and std.mem.eql(u8, job.os, hosts[1])) try std.testing.expectEqualStrings("conformance (macos-latest)", job.name);
    var reports = false;
    for (release) |job| if (std.mem.eql(u8, job.step, "check-reports")) {
        reports = true;
        try std.testing.expectEqualStrings("reports-setup", job.prepare);
    };
    try std.testing.expect(reports);
    // A declared test step split in shards is one job per shard, each naming its share.
    const sharded = (try std.json.parseFromSlice(src.Value, a,
        \\{"jobs":[{"name":"ThreadSanitizer","step":"test","args":["-Dthread-sanitizer=true"],"tiers":["release"],"shards":3}]}
    , .{})).value;
    var shards: std.ArrayList([]const u8) = .empty;
    for (try plan(a, sharded, .release)) |job| if (job.declared) {
        try std.testing.expectEqualStrings("test", job.step);
        try std.testing.expectEqualStrings("-Dthread-sanitizer=true", job.args);
        try std.testing.expectEqualStrings(job.shard, job.name["ThreadSanitizer shard ".len..]);
        try shards.append(a, job.shard);
    };
    try std.testing.expectEqual(@as(usize, 3), shards.items.len);
    for (shards.items, [_][]const u8{ "1/3", "2/3", "3/3" }) |got, want| try std.testing.expectEqualStrings(want, got);
    // Declared jobs run where the gate does: natively, never replayed from a link.
    var linked = config;
    try linked.object.put(a, "portable_tests", .{ .bool = true });
    const tiers = try split(a, linked, try plan(a, linked, .ci), .ci);
    for (tiers.run) |job| try std.testing.expect(!job.declared);
    for (tiers.compile) |job| try std.testing.expect(!job.declared);
    for (merge, 0..) |x, i| for (merge[i + 1 ..]) |y| try std.testing.expect(!std.mem.eql(u8, x.cache_key, y.cache_key));
    for ([_][]const u8{
        "{\"jobs\":{}}",
        "{\"jobs\":[{\"step\":\"test\"}]}",
        "{\"jobs\":[{\"name\":\"x\"}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"a b\"}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"os\":[\"plan9\"]}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"tiers\":[\"nightly\"]}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"directory\":\"../up\"}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"timeout\":0}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"shards\":0}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"shards\":\"2\"}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"needs\":\"gate\"}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\"},{\"name\":\"x\",\"step\":\"u\"}]}",
        "{\"jobs\":[{\"name\":\"x\",\"step\":\"t\",\"advisory\":\"yes\"}]}",
    }) |bad| try std.testing.expect(std.meta.isError(plan(a, (try std.json.parseFromSlice(src.Value, a, bad, .{})).value, .ci)));
}

test "an advisory job runs as declared, says non-blocking in its name and carries its flag in the matrix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // relic's git-master leg: its tests against git's unreleased head, shown and not taken.
    const config = (try std.json.parseFromSlice(src.Value, a,
        \\{"jobs":[
        \\ {"name":"git master","step":"ci-git-master","advisory":true,"shards":2},
        \\ {"name":"conformance","step":"test","advisory":false}]}
    , .{})).value;
    var advisory: usize = 0;
    for (try plan(a, config, .ci)) |job| if (job.declared) {
        if (std.mem.eql(u8, job.step, "ci-git-master")) {
            advisory += 1;
            try std.testing.expectEqual(@as(?bool, true), job.advisory);
            try std.testing.expectEqualStrings(try a.print("git master shard {s} (non-blocking)", .{job.shard}), job.name);
            // Its run has its declared timeout, its job that and its other steps' budgets.
            try std.testing.expectEqual(@as(?usize, 20), job.run_timeout);
            try std.testing.expectEqual(20 + advisory_overhead_minutes, job.job_timeout);
        } else {
            // One that says false is any declared job: its result is the run's.
            try std.testing.expectEqual(@as(?bool, null), job.advisory);
            try std.testing.expectEqual(@as(?usize, null), job.run_timeout);
            try std.testing.expectEqual(@as(usize, 20), job.job_timeout);
            try std.testing.expectEqualStrings("conformance", job.name);
        }
    };
    try std.testing.expectEqual(@as(usize, 2), advisory);
    const listed = try include(a, try plan(a, config, .ci));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, listed, "\"advisory\":true"));
    try std.testing.expect(std.mem.find(u8, listed, "\"advisory\":false") == null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, listed, "\"run_timeout\":20"));
    // A timeout that leaves no room for the other steps' budgets within GitHub's 360 is refused.
    problem = "";
    try std.testing.expectError(error.InvalidDeclaredJob, plan(a, (try std.json.parseFromSlice(src.Value, a, "{\"jobs\":[{\"name\":\"git master\",\"step\":\"t\",\"advisory\":true,\"timeout\":241}]}", .{})).value, .ci));
    try std.testing.expectEqualStrings("jobs: git master: an advisory job's timeout is at most 240 minutes, which leaves its other steps' 120 within GitHub's 360", problem);
    // A release tier's advisory macOS job runs alone, never a leg of the blocking macOS job.
    const mac = (try std.json.parseFromSlice(src.Value, a,
        \\{"jobs":[
        \\ {"name":"git master","step":"ci-git-master","advisory":true,"os":["macos-latest"]},
        \\ {"name":"conformance","step":"test","os":["macos-latest"]}]}
    , .{})).value;
    var alone = false;
    for (try plan(a, mac, .release)) |job| {
        if (job.advisory == true) alone = std.mem.eql(u8, job.step, "ci-git-master");
        if (job.legs) |sequence| try std.testing.expect(std.mem.find(u8, sequence, "ci-git-master") == null);
    }
    try std.testing.expect(alone);
    // A non-boolean is refused naming the job.
    problem = "";
    try std.testing.expectError(error.InvalidDeclaredJob, plan(a, (try std.json.parseFromSlice(src.Value, a, "{\"jobs\":[{\"name\":\"git master\",\"step\":\"t\",\"advisory\":1}]}", .{})).value, .ci));
    try std.testing.expectEqualStrings("jobs: git master: advisory is true or false", problem);
}

test "the native link jobs are planned on the build's ci-build exactly when its tests are portable, never on a step it lacks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { []const u8, bool }{ .{ "{}", false }, .{ "{\"portable_tests\":false}", false }, .{ "{\"portable_tests\":true}", true } }) |case| {
        const text, const portable = case;
        const tiers = try split(a, (try std.json.parseFromSlice(src.Value, a, text, .{})).value, try plan(a, (try std.json.parseFromSlice(src.Value, a, text, .{})).value, .release), .release);
        var linked = false;
        for (tiers.compile) |job| linked = linked or std.mem.eql(u8, job.step, "ci-build");
        for (tiers.native) |job| try std.testing.expect(!std.mem.eql(u8, job.step, "ci-build"));
        try std.testing.expectEqual(portable, linked);
        try std.testing.expectEqual(portable, tiers.run.len != 0);
    }
}

test "an option the planner does not know, or a malformed timeout or step, is refused rather than ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "{\"lnad\":true}", "{\"package\":\"x\"}", "{\"test_job_timeout\":\"30\"}", "{\"test_job_timeout\":400}", "{\"compile_step\":3}", "{\"setup_step\":\"a b\"}" }) |bad|
        try std.testing.expect(std.meta.isError(plan(a, (try std.json.parseFromSlice(src.Value, a, bad, .{})).value, .ci)));
}

test "only the release tier's source checks hold every aegis-pack finding to the bar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{}", .{})).value;
    for ([_]Tier{ .ci, .release }) |tier| {
        const lint = for (try plan(a, config, tier)) |job| {
            if (std.mem.eql(u8, job.step, "lint")) break job;
        } else return error.NoLintJob;
        try std.testing.expectEqual(tier == .release, std.mem.find(u8, lint.args, "-Dci-release") != null);
    }
}

test "a cross compile's build runs with the jobs PREFLIGHT_JOBS allows, and with Zig's default without it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"targets\":[\"aarch64-linux-gnu\"]}", .{})).value;
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
    const config = (try std.json.parseFromSlice(src.Value, a, try a.print(
        \\{{"targets":["aarch64-windows-gnu","x86_64-linux-musl","x86_64-windows-gnu","aarch64-linux-gnu"],"cross_jobs":4,"cross_job_timeout":25,
        \\"measured":{{"phases":{{"compile aarch64-windows-gnu":819.9,"compile x86_64-linux-musl":268.2,"compile x86_64-windows-gnu":600,"compile aarch64-linux-gnu":200}},
        \\"peaks":{{"compile aarch64-windows-gnu":{{"bytes":{d},"single":{d},"jobs":4}},"compile x86_64-linux-musl":{{"bytes":{d},"single":{d},"jobs":4}},"compile x86_64-windows-gnu":{{"bytes":{d},"single":{d},"jobs":4}}}}}}}}
    , .{ 11 * gib, 5 * gib, 3 * gib, 1 * gib, 15 * gib, 86 * gb / 10 }), .{})).value;
    var jobs: std.ArrayList(Job) = .empty;
    try crossJobs(a, config, &jobs, try src.items(src.get(config, "targets")), false);
    try std.testing.expectEqual(@as(usize, 4), jobs.items.len);
    // 75% of 16 GiB is 12 GiB: one 8.6 GB compile fits once, 5 GiB twice, 1 GiB more often
    // than the runner's 4 CPUs.
    const want = [_]struct { []const u8, u32 }{ .{ "x86_64-windows-gnu", 1 }, .{ "aarch64-windows-gnu", 2 }, .{ "x86_64-linux-musl", 4 }, .{ "aarch64-linux-gnu", 1 } };
    for (want) |w| {
        const job = for (jobs.items) |job| {
            if (std.mem.eql(u8, job.targets, w[0])) break job;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(?u32, w[1]), job.build_jobs);
    }
    // A job of several targets takes the fewest any of them allows.
    const shared = (try std.json.parseFromSlice(src.Value, a, try a.print(
        \\{{"targets":["aarch64-windows-gnu","x86_64-linux-musl"],"cross_jobs":1,"cross_job_timeout":25,
        \\"measured":{{"phases":{{"compile aarch64-windows-gnu":300,"compile x86_64-linux-musl":200}},
        \\"peaks":{{"compile aarch64-windows-gnu":{{"bytes":{d},"single":{d},"jobs":4}},"compile x86_64-linux-musl":{{"bytes":{d},"single":{d},"jobs":4}}}}}}}}
    , .{ 11 * gib, 5 * gib, 3 * gib, 1 * gib }), .{})).value;
    jobs.clearRetainingCapacity();
    try crossJobs(a, shared, &jobs, try src.items(src.get(shared, "targets")), false);
    try std.testing.expectEqual(@as(usize, 1), jobs.items.len);
    try std.testing.expectEqual(@as(?u32, 2), jobs.items[0].build_jobs);
    var json: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(jobs.items[0], job_json, &json.writer);
    try std.testing.expect(std.mem.find(u8, json.written(), "\"build_jobs\":2") != null);
}
test "the fuzz job: the release tier's and a dispatched fuzz run's alone, where the build has its step, for its minutes and 20 more" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parse = struct {
        fn value(allocator: std.mem.Allocator, text: []const u8) !src.Value {
            return (try std.json.parseFromSlice(src.Value, allocator, text, .{})).value;
        }
    }.value;
    const fuzzed = try parse(a, "{\"fuzzed\":true,\"build_args\":[\"-Dsuite=full\"]}");
    const found = struct {
        fn job(jobs: []const Job) ?Job {
            for (jobs) |each| if (std.mem.eql(u8, each.step, "ci-fuzz")) return each;
            return null;
        }
    }.job;
    // Never the ci tier's.
    try std.testing.expect(found(try plan(a, fuzzed, .ci)) == null);
    const release = found(try plan(a, fuzzed, .release)).?;
    try std.testing.expectEqualStrings("fuzz", release.name);
    try std.testing.expectEqualStrings(hosts[0], release.os);
    try std.testing.expectEqual(@as(usize, 35), release.job_timeout);
    try std.testing.expect(release.setup);
    try std.testing.expectEqualStrings("-Dci-lint=false -Dci-bench-smoke=false -Dsuite=full", release.args);
    // A dispatched fuzz run is that job alone, the same job.
    const alone = try plan(a, fuzzed, .fuzz);
    try std.testing.expectEqual(@as(usize, 1), alone.len);
    try std.testing.expectEqualStrings(release.cache_key, alone[0].cache_key);
    try std.testing.expectEqual(@as(usize, 1), (try split(a, fuzzed, alone, .fuzz)).native.len);
    // Its minutes, from the configuration.
    try std.testing.expectEqual(@as(usize, 80), found(try plan(a, try parse(a, "{\"fuzzed\":true,\"fuzz_minutes\":60}"), .release)).?.job_timeout);
    // None where the build has no fuzz step (it declares no shakedown), or its minutes are 0.
    for ([_][]const u8{ "{}", "{\"fuzzed\":false}", "{\"fuzzed\":true,\"fuzz_minutes\":0}" }) |text| {
        const config = try parse(a, text);
        try std.testing.expect(found(try plan(a, config, .release)) == null);
        try std.testing.expectEqual(@as(usize, 0), (try plan(a, config, .fuzz)).len);
    }
    // Minutes a hosted job cannot hold, or none, are refused.
    for ([_][]const u8{ "{\"fuzz_minutes\":331}", "{\"fuzz_minutes\":-1}", "{\"fuzz_minutes\":\"15\"}" }) |text| {
        try std.testing.expectError(error.InvalidFuzzMinutes, plan(a, try parse(a, text), .release));
        try std.testing.expectError(error.InvalidFuzzMinutes, plan(a, try parse(a, text), .fuzz));
    }
    // The fuzz tier is the fuzz job's: a declared job cannot join it.
    try std.testing.expectError(error.InvalidDeclaredJob, plan(a, try parse(a, "{\"jobs\":[{\"name\":\"more\",\"step\":\"more\",\"tiers\":[\"fuzz\"]}]}"), .release));
}

test "the ci tier compiles the package's check in each configuration it declares, by its name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parse = struct {
        fn value(allocator: std.mem.Allocator, text: []const u8) !src.Value {
            return (try std.json.parseFromSlice(src.Value, allocator, text, .{})).value;
        }
    }.value;
    const config = try parse(a, "{\"configurations\": [{\"name\": \"default\", \"options\": {\"http\": true, \"lfs\": true}}, {\"name\": \"neither\", \"options\": {\"http\": false, \"lfs\": false}, \"modules\": [\"relic\"]}, {\"name\": \"level-3\", \"options\": {\"level\": 3, \"mode\": \"fast\"}}]}");
    var found: usize = 0;
    for (try plan(a, config, .ci)) |job| {
        if (!std.mem.startsWith(u8, job.name, "check (")) continue;
        found += 1;
        try std.testing.expectEqualStrings("check", job.step);
        if (std.mem.eql(u8, job.name, "check (neither)")) try std.testing.expectEqualStrings("-Dci-lint=false -Dhttp=false -Dlfs=false", job.args);
        if (std.mem.eql(u8, job.name, "check (level-3)")) try std.testing.expectEqualStrings("-Dci-lint=false -Dlevel=3 -Dmode=fast", job.args);
    }
    try std.testing.expectEqual(@as(usize, 3), found);
    // None declared, none planned; the release tier plans none of its own.
    for (try plan(a, try parse(a, "{}"), .ci)) |job| try std.testing.expect(!std.mem.startsWith(u8, job.name, "check ("));
    for (try plan(a, config, .release)) |job| try std.testing.expect(!std.mem.startsWith(u8, job.name, "check ("));
    // A name a job and a directory cannot take, or a value the job's arguments cannot carry, is refused.
    for ([_][]const u8{ "{\"configurations\": [{\"name\": \"no http\"}]}", "{\"configurations\": []}", "{\"configurations\": [{\"name\": \"x\", \"options\": {\"mode\": \"a b\"}}]}", "{\"configurations\": [{\"name\": \"x\", \"options\": {\"f\": 1.5}}]}" }) |text| {
        try std.testing.expectError(error.InvalidConfigurations, plan(a, try parse(a, text), .ci));
    }
}
