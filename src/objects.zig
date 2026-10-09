//! A compile projection of the configured build graph. Native artifacts stay
//! intact; this graph emits objects and never proves a successful SDK link.
const std = @import("std");

pub fn add(b: *std.Build, tests: *std.Build.Step, sdk: ?[]const u8) void {
    const objects = &b.top_level_steps.get("ci-check").?.step;
    const links = &b.top_level_steps.get("ci-link").?.step;
    var projection: Projection = .{ .b = b, .objects = objects, .sdk = sdk };
    projection.collect(tests, links);
    projection.collect(b.getInstallStep(), links);
    if (b.top_level_steps.get("bench-build")) |bench| projection.collect(&bench.step, links);
    if (b.top_level_steps.get("check")) |check| projection.collect(&check.step, links);
    for (b.modules.values()) |module| {
        const object = b.addObject(.{ .name = "ci-root", .root_module = projection.module(module) });
        _ = object.getEmittedBin();
        objects.dependOn(&object.step);
    }
}

const Projection = struct {
    b: *std.Build,
    objects: *std.Build.Step,
    sdk: ?[]const u8,
    steps: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty,
    modules: std.AutoHashMapUnmanaged(*std.Build.Module, *std.Build.Module) = .empty,
    sdks: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty,
    artifacts: std.AutoHashMapUnmanaged(*std.Build.Step.Compile, *std.Build.Step.Compile) = .empty,

    fn collect(p: *Projection, step: *std.Build.Step, links: *std.Build.Step) void {
        const entry = p.steps.getOrPut(p.b.allocator, step) catch @panic("OOM");
        if (entry.found_existing) return;
        if (step.cast(std.Build.Step.Compile)) |compiled| {
            p.nativeSdk(compiled);
            links.dependOn(step);
            p.objects.dependOn(&p.artifact(compiled).step);
            return;
        }
        for (step.dependencies.items) |dependency| p.collect(dependency, links);
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
            .name = original.name,
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

    fn module(p: *Projection, original: *std.Build.Module) *std.Build.Module {
        if (p.modules.get(original)) |copy| return copy;
        // Copy compiler options, source inputs and include paths. Project
        // artifact edges to object validation; SDK link requests remain on
        // the original modules used by ci-link, ci and ci-build.
        const copy = p.b.allocator.create(std.Build.Module) catch @panic("OOM");
        copy.* = original.*;
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
