//! Opt-in build/test orchestration; source-site safety rules belong to glint.
const std = @import("std");
const builtin = @import("builtin");

pub const Profile = struct {
    /// A step containing real std.testing.fuzz targets.
    fuzz_step: []const u8 = "test",
    fuzz_iterations: u64 = 10000,
    /// A step executing concurrent tests, not a compile-only step.
    tsan_step: []const u8 = "test",
};
pub const Options = struct { active: bool, tsan: bool };

pub fn declare(b: *std.Build) Options {
    return .{
        .active = b.option(bool, "ci-hardened", "Runtime safety enabled for this opt-in test configuration") orelse false,
        .tsan = b.option(bool, "ci-tsan", "Execute native x86_64 Linux tests with ThreadSanitizer") orelse false,
    };
}

pub fn add(b: *std.Build, tests: *std.Build.Step, profile: ?Profile, options: Options) void {
    const given = profile orelse {
        if (options.active or options.tsan) tests.dependOn(&b.addFail("hardened: this package has not opted in via Config.hardened").step);
        return;
    };
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.17.0")) {
        tests.dependOn(&b.addFail("hardened: supported only with Zig 0.17.0").step);
        return;
    }
    if (options.active or options.tsan) {
        var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
        var modules: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
        apply(b, tests, options, &seen, &modules);
        for ([_][]const u8{ given.fuzz_step, given.tsan_step }) |name| {
            const selected = b.top_level_steps.get(name) orelse {
                tests.dependOn(&b.addFail(b.fmt("hardened: configured step {s} is absent", .{name})).step);
                continue;
            };
            apply(b, &selected.step, options, &seen, &modules);
        }
    }
    for ([_][]const u8{ given.fuzz_step, given.tsan_step }) |name| {
        const selected = b.top_level_steps.get(name) orelse continue;
        var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
        if (!executesTests(b, &selected.step, &seen)) {
            tests.dependOn(&b.addFail(b.fmt("hardened: {s} must execute native tests, not compile only", .{name})).step);
        }
    }
    const normal = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test", "-Dci-hardened=true", "-Dci-lint=false", "-Dci-bench-smoke=false" });
    forward(b, normal);
    normal.setCwd(b.path("."));
    normal.has_side_effects = true;
    b.step("hardened", "Execute opt-in safety-on tests using the existing std.testing allocator").dependOn(&normal.step);
    const fuzz = b.addSystemCommand(&.{ b.graph.zig_exe, "build", given.fuzz_step, "-Dci-hardened=true", "-Dci-lint=false", "-Dci-bench-smoke=false", b.fmt("--fuzz={d}", .{given.fuzz_iterations}) });
    forward(b, fuzz);
    fuzz.setCwd(b.path("."));
    fuzz.has_side_effects = true;
    const fuzz_step = b.step("hardened-fuzz", "Execute a bounded native Zig fuzzer campaign; Zig retains cache corpus and coverage");
    if (given.fuzz_iterations == 0 or b.graph.host.result.os.tag == .windows or @bitSizeOf(usize) != 64) {
        fuzz_step.dependOn(&b.addFail("hardened-fuzz: needs a positive campaign limit and native 64-bit non-Windows Zig fuzzer support").step);
    } else fuzz_step.dependOn(&fuzz.step);
    const tsan = b.addSystemCommand(&.{ b.graph.zig_exe, "build", given.tsan_step, "-Dci-hardened=true", "-Dci-tsan=true", "-Dci-lint=false", "-Dci-bench-smoke=false" });
    forward(b, tsan);
    tsan.setCwd(b.path("."));
    tsan.has_side_effects = true;
    const tsan_step = b.step("hardened-tsan", "Execute native x86_64 Linux tests with LLVM ThreadSanitizer");
    if (b.graph.host.result.os.tag != .linux or b.graph.host.result.cpu.arch != .x86_64) {
        tsan_step.dependOn(&b.addFail("hardened-tsan: unsupported target; requires native x86_64 Linux").step);
    } else tsan_step.dependOn(&tsan.step);
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
            if (module.optimize != .debug) module.optimize = .safe;
            if (options.tsan) {
                const target = module.resolved_target orelse artifact.root_module.resolved_target.?;
                if (target.result.os.tag != .linux or target.result.cpu.arch != .x86_64) {
                    step.dependOn(&b.addFail("hardened-tsan: test module is not x86_64 Linux").step);
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

fn executesTests(b: *std.Build, step: *std.Build.Step, seen: *std.AutoHashMapUnmanaged(*std.Build.Step, void)) bool {
    const entry = seen.getOrPut(b.allocator, step) catch @panic("OOM");
    if (entry.found_existing) return false;
    if (step.cast(std.Build.Step.Run)) |run| {
        if (run.argv.items.len > 0 and run.argv.items[0] == .artifact and run.argv.items[0].artifact.artifact.kind == .@"test") return true;
    }
    for (step.dependencies.items) |dep| if (executesTests(b, dep, seen)) return true;
    return false;
}
