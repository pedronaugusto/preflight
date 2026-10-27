//! A compile projection of the configured build graph. Native artifacts stay
//! intact; this graph emits objects and never proves a successful SDK link.
const std = @import("std");

/// `ci-check` compiles the tests, the installed artifacts, the package's
/// `check` graph, its public modules and, in Debug, its benchmarks.
/// A consumer may build the package with libc, where `builtin.link_libc`
/// selects other code (visor 0.5.7 broke on x86_64-windows-gnu so, a path no
/// compile without libc reached): `ci-check` compiles the tests and the public
/// modules a second time linking libc, for each target Zig ships a libc for,
/// unless they link it already. A program's libc is its own, so the installed
/// artifacts and the benchmarks are compiled as they are built.
/// `ci-check-bench` compiles the benchmarks as they are built to run, which in
/// ReleaseFast takes longer than all the rest: the fast tier leaves it to the
/// merge tier, since a benchmark's Debug object already holds what a target
/// accepts of its source.
/// `targets` is `check`'s compile of the other targets, which runs builds of its own: no
/// projection reaches into it. `check` is the development build's own, null where preflight's is the step.
pub const Steps = struct { objects: *std.Build.Step, bench_objects: *std.Build.Step, links: *std.Build.Step, bench: ?*std.Build.Step, targets: ?*std.Build.Step, check: ?*std.Build.Step };

pub fn add(b: *std.Build, package: *std.Build, tests: *std.Build.Step, sdk: ?[]const u8, steps: Steps) void {
    const objects = steps.objects;
    const bench_objects = steps.bench_objects;
    const links = steps.links;
    var projection: Projection = .{ .b = b, .objects = objects, .sdk = sdk, .skip = steps.targets };
    projection.collect(tests, links);
    projection.collect(package.getInstallStep(), links);
    // `check` is the development build's own where it has one, else the package's.
    if (steps.check orelse if (package.top_level_steps.get("check")) |own| &own.step else null) |check| projection.collect(check, links);
    if (steps.bench) |bench| {
        var debug: Projection = .{ .b = b, .objects = objects, .sdk = null, .skip = steps.targets, .debug = true };
        debug.collect(bench, links);
        var release: Projection = .{ .b = b, .objects = bench_objects, .sdk = sdk, .skip = steps.targets };
        release.collect(bench, links);
    }
    var libc: Projection = .{ .b = b, .objects = objects, .sdk = null, .skip = steps.targets, .libc = true };
    libc.collect(tests, null);
    for (package.modules.values()) |module| {
        const object = b.addObject(.{ .name = "ci-root", .root_module = projection.module(module) });
        _ = object.getEmittedBin();
        objects.dependOn(&object.step);
        if (!Projection.libcApplies(module)) continue;
        const with_libc = b.addObject(.{ .name = "ci-root-libc", .root_module = libc.module(module) });
        _ = with_libc.getEmittedBin();
        objects.dependOn(&with_libc.step);
    }
}

const Projection = struct {
    b: *std.Build,
    objects: *std.Build.Step,
    sdk: ?[]const u8,
    /// `check`'s compile of the other targets: builds of its own, never projected.
    skip: ?*std.Build.Step,
    /// Compile every module in Debug, whatever the graph asks.
    debug: bool = false,
    /// Link libc in every module: the tests alone, each where Zig ships the
    /// target's libc and the test does not link it already.
    libc: bool = false,
    steps: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty,
    modules: std.AutoHashMapUnmanaged(*std.Build.Module, *std.Build.Module) = .empty,
    sdks: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty,
    artifacts: std.AutoHashMapUnmanaged(*std.Build.Step.Compile, *std.Build.Step.Compile) = .empty,
    options: std.AutoHashMapUnmanaged(*std.Build.Step.Options, *std.Build.Step.Options) = .empty,

    /// `links`: where the compiles found go to be linked, null for a
    /// projection that only compiles.
    fn collect(p: *Projection, step: *std.Build.Step, links: ?*std.Build.Step) void {
        if (step == p.skip) return;
        const entry = p.steps.getOrPut(p.b.allocator, step) catch @panic("OOM");
        if (entry.found_existing) return;
        if (step.cast(std.Build.Step.Compile)) |compiled| {
            if (p.libc and (!compiled.kind.isTest() or compiled.dependsOnSystemLibrary("c") or !libcApplies(compiled.root_module))) return;
            p.nativeSdk(compiled);
            if (links) |link| link.dependOn(step);
            p.objects.dependOn(&p.artifact(compiled).step);
            return;
        }
        for (step.dependencies.items) |dependency| p.collect(dependency, links);
    }

    /// Whether Zig ships a libc for the module's target, which a module
    /// without a target takes from its importer and so never knows.
    fn libcApplies(original: *std.Build.Module) bool {
        const target = original.resolved_target orelse return false;
        if (original.link_libc == true) return false;
        return std.zig.target.canBuildLibC(&target.result);
    }

    fn nativeSdk(p: *Projection, compiled: *std.Build.Step.Compile) void {
        const sdk = p.sdk orelse return;
        if (p.b.graph.host.result.os.tag != .macos or compiled.rootModuleTarget().os.tag != .macos) return;
        for (compiled.getCompileDependencies(true)) |dependency| for (dependency.root_module.getGraph().modules) |mod| {
            const applied = p.sdks.getOrPut(p.b.allocator, mod) catch @panic("OOM");
            if (applied.found_existing) continue;
            mod.addSystemFrameworkPath(.{ .cwd_relative = p.b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
            mod.addSystemIncludePath(.{ .cwd_relative = p.b.pathJoin(&.{ sdk, "usr/include" }) });
            mod.addLibraryPath(.{ .cwd_relative = p.b.pathJoin(&.{ sdk, "usr/lib" }) });
        };
    }

    fn artifact(p: *Projection, original: *std.Build.Step.Compile) *std.Build.Step.Compile {
        if (p.artifacts.get(original)) |object| return object;
        const object = std.Build.Step.Compile.create(original.step.owner, .{
            .name = if (p.libc) p.b.fmt("{s}-libc", .{original.name}) else original.name,
            .root_module = p.module(original.root_module),
            .kind = if (original.kind.isTest()) .test_obj else .obj,
            .filters = original.filters,
            .test_runner = original.test_runner,
            .use_llvm = original.use_llvm,
            .use_lld = original.use_lld,
            .zig_lib_dir = original.zig_lib_dir,
            .max_rss = original.step.max_rss,
        });
        object.installed_headers = original.installed_headers;
        // Zig owns exact diagnostic matching and rejects unexpected success.
        // Deliberate semantic failures cannot produce a generated binary.
        object.expect_errors = original.expect_errors;
        object.error_limit = original.error_limit;
        if (object.expect_errors == null) _ = object.getEmittedBin();
        p.artifacts.put(p.b.allocator, original, object) catch @panic("OOM");
        return object;
    }

    /// The options a module's source is generated from, with every program
    /// they name by path replaced by its object. A test names its helper
    /// programs this way, and the original step would link each of them for
    /// the target, which is what this projection never does.
    fn source(p: *Projection, original: ?std.Build.LazyPath) ?std.Build.LazyPath {
        const lazy = original orelse return null;
        const generated = switch (lazy) {
            .generated => |g| g,
            else => return lazy,
        };
        const options = p.b.graph.generated_files.items[@backingInt(generated.index)].cast(std.Build.Step.Options) orelse return lazy;
        return .{ .generated = .{ .index = p.projectedOptions(options).generated_file, .up = generated.up, .sub_path = generated.sub_path } };
    }

    fn projectedOptions(p: *Projection, original: *std.Build.Step.Options) *std.Build.Step.Options {
        if (p.options.get(original)) |copy| return copy;
        var changed = false;
        for ([_][]const std.Build.Step.Options.NamedPath{ original.files.items, original.directories.items, original.untracked_paths.items }) |named| {
            for (named) |entry| {
                const mapped = p.projectedPath(entry.path);
                if (!std.meta.eql(mapped, entry.path)) changed = true;
            }
        }
        if (!changed) {
            p.options.put(p.b.allocator, original, original) catch @panic("OOM");
            return original;
        }
        const owner = original.step.owner;
        const copy = std.Build.Step.Options.create(owner);
        copy.contents = original.contents.clone(owner.allocator) catch @panic("OOM");
        const arena = owner.graph.arena;
        inline for (.{ "files", "directories", "untracked_paths" }) |field| {
            for (@field(original, field).items) |entry| {
                const mapped = p.projectedPath(entry.path);
                @field(copy, field).append(arena, .{ .name = entry.name, .path = mapped }) catch @panic("OOM");
                mapped.addStepDependencies(&copy.step);
            }
        }
        p.options.put(p.b.allocator, original, copy) catch @panic("OOM");
        return copy;
    }

    /// `lazy`, or where it is a program's output, that program's object.
    fn projectedPath(p: *Projection, lazy: std.Build.LazyPath) std.Build.LazyPath {
        const generated = switch (lazy) {
            .generated => |g| g,
            else => return lazy,
        };
        const compiled = p.b.graph.generated_files.items[@backingInt(generated.index)].cast(std.Build.Step.Compile) orelse return lazy;
        const emitted = compiled.getEmittedBin().generated;
        if (emitted.index != generated.index) return lazy;
        const projected = p.artifact(compiled).getEmittedBin().generated;
        return .{ .generated = .{ .index = projected.index, .up = generated.up, .sub_path = generated.sub_path } };
    }

    fn module(p: *Projection, original: *std.Build.Module) *std.Build.Module {
        if (p.modules.get(original)) |copy| return copy;
        // Copy compiler options, source inputs and include paths. Project
        // artifact edges to object validation; SDK link requests remain on
        // the original modules used by ci-link, ci and ci-build.
        const copy = p.b.allocator.create(std.Build.Module) catch @panic("OOM");
        copy.* = original.*;
        if (p.debug) copy.optimize = .Debug;
        if (p.libc) copy.link_libc = true;
        copy.root_source_file = p.source(original.root_source_file);
        copy.cached_graph = .{ .modules = &.{}, .names = &.{} };
        copy.import_table = .empty;
        copy.link_objects = .empty;
        // Zig resolves framework and system-library names even in build-obj.
        // They belong to the untouched native link graph, not this projection.
        copy.frameworks = .empty;
        copy.include_dirs = .empty;
        p.modules.put(p.b.allocator, original, copy) catch @panic("OOM");
        for (original.import_table.keys(), original.import_table.values()) |name, imported| copy.addImport(name, p.module(imported));
        for (original.include_dirs.items) |include| {
            copy.include_dirs.append(p.b.allocator, switch (include) {
                .other_step => |other| .{ .path = p.artifact(other).getEmittedIncludeTree() },
                else => include,
            }) catch @panic("OOM");
        }
        for (original.link_objects.items) |link| {
            const projected: std.Build.Module.LinkObject = switch (link) {
                .other_step => |other| {
                    p.objects.dependOn(&p.artifact(other).step);
                    continue;
                },
                .system_lib => continue,
                else => link,
            };
            copy.link_objects.append(p.b.allocator, projected) catch @panic("OOM");
        }
        return copy;
    }
};
