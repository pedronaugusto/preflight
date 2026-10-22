//! The hardened profile every package runs: its tests with runtime safety on over the
//! quarantine allocator, a bounded fuzz campaign and ThreadSanitizer; source-site safety rules
//! belong to glint.
const std = @import("std");
const configure = @import("configure.zig");
const builtin = @import("builtin");
const zig_version = @import("zig_version.zig");
const Tool = @import("tool.zig").Tool;

pub const Profile = struct {
    /// A step containing real std.testing.fuzz targets; null for a package with nothing to
    /// fuzz, which says so here.
    fuzz_step: ?[]const u8 = "test",
    fuzz_iterations: u64 = 10000,
    /// A step executing concurrent tests, not a compile-only step.
    tsan_step: []const u8 = "test",
};
pub const Options = struct { active: bool, tsan: bool };

pub fn declare(b: *std.Build) Options {
    return .{
        .active = b.option(bool, "ci-hardened", "Runtime safety enabled for this opt-in test configuration") orelse false,
        .tsan = b.option(bool, "ci-tsan", "Execute native x86_64 or aarch64 Linux or macOS tests with ThreadSanitizer") orelse false,
    };
}

/// `tool` is preflight's program, which judges the fuzz campaign.
pub fn add(b: *std.Build, package: *std.Build, tests: *std.Build.Step, given: Profile, options: Options, tool: Tool) void {
    _ = zig_version.require() catch {
        tests.dependOn(&b.addFail(b.fmt("hardened: supported only with {s}, not Zig {s}", .{ zig_version.supported, builtin.zig_version_string })).step);
        return;
    };
    if (options.active or options.tsan) {
        var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
        var modules: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
        apply(b, tests, options, &seen, &modules);
        for ([_]?[]const u8{ given.fuzz_step, given.tsan_step }) |chosen| {
            const name = chosen orelse continue;
            const selected = b.top_level_steps.get(name) orelse {
                tests.dependOn(&b.addFail(b.fmt("hardened: configured step {s} is absent", .{name})).step);
                continue;
            };
            apply(b, &selected.step, options, &seen, &modules);
        }
    }
    for ([_]?[]const u8{ given.fuzz_step, given.tsan_step }) |chosen| {
        const selected = b.top_level_steps.get(chosen orelse continue) orelse continue;
        var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
        if (!executesTests(b, &selected.step, &seen)) {
            tests.dependOn(&b.addFail(b.fmt("hardened: {s} must execute native tests, not compile only", .{chosen.?})).step);
        }
    }
    const normal = again(b, package, &.{ "test", "-Dci-hardened=true", "-Dci-lint=false", "-Dci-bench-smoke=false" });
    forward(b, normal);
    normal.setCwd(package.path("."));
    normal.has_side_effects = true;
    configure.claim(b, "hardened", "Execute opt-in safety-on tests using the existing std.testing allocator").dependOn(&normal.step);
    // Zig exits 0 from a campaign whose fuzzer crashed or never started; preflight
    // judges it on what the fuzzer leaves in the cache the campaign runs on.
    const fuzz = tool.run(b);
    fuzz.addArgs(&.{ "fuzz-campaign", "--cache" });
    fuzz.addDirectoryArg2(std.Build.LazyPath.cache_root, .{});
    fuzz.addArg("--cwd");
    fuzz.addDirectoryArg2(package.path("."), .{});
    fuzz.addArg("--");
    fuzz.addArgs(configure.rerun(b, package));
    fuzz.addArgs(&.{ given.fuzz_step orelse "test", "-Dci-hardened=true", "-Dci-lint=false", "-Dci-bench-smoke=false", b.fmt("--fuzz={d}", .{given.fuzz_iterations}) });
    forward(b, fuzz);
    fuzz.has_side_effects = true;
    const fuzz_step = configure.claim(b, "hardened-fuzz", "Execute a bounded native Zig fuzzer campaign; Zig retains cache corpus and coverage");
    if (given.fuzz_step == null) {
        // Nothing to fuzz, as the package's profile says: the campaign has nothing to run.
    } else if (given.fuzz_iterations == 0 or b.graph.host.result.os.tag == .windows or @bitSizeOf(usize) != 64) {
        fuzz_step.dependOn(&b.addFail("hardened-fuzz: needs a positive campaign limit and native 64-bit non-Windows Zig fuzzer support").step);
    } else fuzz_step.dependOn(&fuzz.step);
    const tsan = again(b, package, &.{ given.tsan_step, "-Dci-hardened=true", "-Dci-tsan=true", "-Dci-lint=false", "-Dci-bench-smoke=false" });
    forward(b, tsan);
    tsan.setCwd(package.path("."));
    tsan.has_side_effects = true;
    const tsan_step = configure.claim(b, "hardened-tsan", "Execute native x86_64 or aarch64 Linux or macOS tests with LLVM ThreadSanitizer");
    if (!sanitized(b.graph.host.result)) {
        tsan_step.dependOn(&b.addFail("hardened-tsan: unsupported target; requires native x86_64 or aarch64 Linux or macOS").step);
    } else tsan_step.dependOn(&tsan.step);
}

/// How many times a test's bound grows under ThreadSanitizer, which runs code
/// five to fifteen times slower: relic's heaviest tests passed under it and still
/// met the unscaled 120 s bound on a loaded machine.
pub const tsan_slowdown = 10;

/// Where ThreadSanitizer runs: Linux and macOS on x86_64 and aarch64, where Zig ships its runtime.
pub fn sanitized(target: std.Target) bool {
    return (target.os.tag == .linux or target.os.tag == .macos) and (target.cpu.arch == .x86_64 or target.cpu.arch == .aarch64);
}

/// This same build run again with `args`: the development build under bay, else zig build.
fn again(b: *std.Build, package: *std.Build, args: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(configure.rerun(b, package));
    run.addArgs(args);
    return run;
}

fn apply(b: *std.Build, step: *std.Build.Step, options: Options, seen: *std.AutoHashMapUnmanaged(*std.Build.Step, void), modules: *std.AutoHashMapUnmanaged(*std.Build.Module, void)) void {
    const entry = seen.getOrPut(b.allocator, step) catch @panic("OOM");
    if (entry.found_existing) return;
    if (step.cast(std.Build.Step.Compile)) |artifact| {
        if (!artifact.kind.isTest()) return;
        // Zig's native fuzz rebuild preserves this configured backend. On
        // x86_64 the self-hosted backend can produce a zero-PC coverage file.
        artifact.use_llvm = true;
        for (artifact.root_module.getGraph().modules) |module| {
            const applied = modules.getOrPut(b.allocator, module) catch @panic("OOM");
            if (applied.found_existing) continue;
            // Safety is Zig's Debug/ReleaseSafe default. Explicit measured source
            // loops can still use @setRuntimeSafety(false); glint checks reasons.
            // A module with no mode of its own takes its artifact's and keeps
            // doing so: the test runner's modules among them, and Zig gives
            // each mode its own `builtin`, so a runner module raised apart from
            // the root sees no tests to run.
            if (module.optimize) |mode| if (mode != .debug) {
                module.optimize = .safe;
            };
            if (options.tsan) {
                const target = module.resolved_target orelse artifact.root_module.resolved_target.?;
                if (!sanitized(target.result)) {
                    step.dependOn(&b.addFail("hardened-tsan: test module is not x86_64 or aarch64 Linux or macOS").step);
                    continue;
                }
                module.sanitize_thread = true;
                module.link_libc = true;
                artifact.use_llvm = true;
            }
        }
    }
    for (step.dependencies.items) |dep| apply(b, dep, options, seen, modules);
}

fn forward(b: *std.Build, run: *std.Build.Step.Run) void {
    for (b.user_input_options.keys(), b.user_input_options.values()) |name, value| {
        var control = false;
        for ([_][]const u8{ "ci-hardened", "ci-tsan", "ci-lint", "ci-bench-smoke" }) |key| if (std.mem.eql(u8, name, key)) {
            control = true;
        };
        if (control) continue;
        switch (value) {
            .flag => run.addArg(b.fmt("-D{s}", .{name})),
            .scalar => |text| run.addArg(b.fmt("-D{s}={s}", .{ name, text })),
            .list => |list| for (list.items) |text| run.addArg(b.fmt("-D{s}={s}", .{ name, text })),
            else => run.step.dependOn(&b.addFail("hardened: unsupported non-CLI configuration option").step),
        }
    }
}

/// Whether a test that `step` builds is built with ThreadSanitizer, whoever
/// asked for it: this profile's `-Dci-tsan`, or a package's own option that
/// sets a module's `sanitize_thread`. What a test's bound scales by.
pub fn sanitizesThreads(b: *std.Build, step: *std.Build.Step, seen: *std.AutoHashMapUnmanaged(*std.Build.Step, void)) bool {
    const entry = seen.getOrPut(b.allocator, step) catch @panic("OOM");
    if (entry.found_existing) return false;
    if (step.cast(std.Build.Step.Compile)) |artifact| if (artifact.kind.isTest()) {
        var modules: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
        if (modulesSanitize(b, artifact.root_module, &modules)) return true;
    };
    for (step.dependencies.items) |dep| if (sanitizesThreads(b, dep, seen)) return true;
    return false;
}

/// Whether `module` or one it imports sets `sanitize_thread`. Walked by
/// hand: `Module.getGraph` keeps the graph it makes, and asked this early,
/// before preflight's runner imports are added, it would keep one without
/// them.
fn modulesSanitize(b: *std.Build, module: *std.Build.Module, seen: *std.AutoHashMapUnmanaged(*std.Build.Module, void)) bool {
    const entry = seen.getOrPut(b.allocator, module) catch @panic("OOM");
    if (entry.found_existing) return false;
    if (module.sanitize_thread orelse false) return true;
    for (module.import_table.values()) |imported| if (modulesSanitize(b, imported, seen)) return true;
    return false;
}

fn executesTests(b: *std.Build, step: *std.Build.Step, seen: *std.AutoHashMapUnmanaged(*std.Build.Step, void)) bool {
    const entry = seen.getOrPut(b.allocator, step) catch @panic("OOM");
    if (entry.found_existing) return false;
    if (step.cast(std.Build.Step.Run)) |run| {
        if (run.argv.items.len > 0 and run.argv.items[0] == .artifact and run.argv.items[0].artifact.artifact.kind == .@"test") return true;
    }
    for (step.dependencies.items) |dep| if (executesTests(b, dep, seen)) return true;
    return false;
}
