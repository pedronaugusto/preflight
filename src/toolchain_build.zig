//! Own-gate adapter over the installed Zig 0.17 configure data. Not an external API.
const std = @import("std");
const builtin = @import("builtin");

pub fn add(b: *std.Build, checker: *std.Build.Module, production: []const *std.Build.Module, tests: []const *std.Build.Module) void {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.17.0")) @panic("unsupported closure configuration: requires Zig 0.17.0");
    const run = b.addRunArtifact(b.addExecutable(.{ .name = "check-toolchain", .root_module = checker }));
    // The source reader follows gantry facts during make. Its complete dynamic
    // input set is deliberately not represented as a cached fixed manifest list.
    run.has_side_effects = true;
    const a = b.allocator;
    var output: std.Io.Writer.Allocating = .init(a);
    const w = &output.writer;
    var modules: std.array_hash_map.Auto(*std.Build.Module, void) = .empty;
    for (production) |module| modules.put(a, module, {}) catch @panic("OOM");
    for (tests) |module| modules.put(a, module, {}) catch @panic("OOM");
    var pending_steps: std.ArrayList(*std.Build.Step) = .empty;
    var seen_steps: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    var test_roots: std.array_hash_map.Auto(*std.Build.Module, void) = .empty;
    for (tests) |module| test_roots.put(a, module, {}) catch @panic("OOM");
    for (b.top_level_steps.values()) |step| pending_steps.append(a, &step.step) catch @panic("OOM");
    while (pending_steps.pop()) |step| {
        if ((seen_steps.getOrPut(a, step) catch @panic("OOM")).found_existing) continue;
        for (step.dependencies.items) |dependency| pending_steps.append(a, dependency) catch @panic("OOM");
        if (step.owner != b) continue;
        if (step.cast(std.Build.Step.Compile)) |artifact| {
            if (artifact.kind == .@"test" or artifact.kind == .test_obj) {
                test_roots.put(a, artifact.root_module, {}) catch @panic("OOM");
                modules.put(a, artifact.root_module, {}) catch @panic("OOM");
            }
        }
    }
    var at: usize = 0;
    while (at < modules.count()) : (at += 1) {
        const module = modules.keys()[at];
        for (module.import_table.values()) |imported| modules.put(a, imported, {}) catch @panic("OOM");
    }
    write(w, "{\"zig\":\"0.17.0\",\"packages\":[");
    package(w, "", b.root.joinString(a, "") catch @panic("OOM"), true, b.available_deps);
    for (std.Build.package_map.values()) |entry| {
        write(w, ",");
        package(w, entry.hash, entry.build_root, entry.available, entry.deps);
    }
    write(w, "],\"modules\":[");
    // argv[1] is the generated configure record; following arguments are native
    // LazyPaths, so Zig resolves generated roots and declares their producers.
    var source_arg: usize = 2;
    var sources: std.ArrayList(std.Build.LazyPath) = .empty;
    for (modules.keys(), 0..) |module, i| {
        if (i != 0) write(w, ",");
        write(w, "{\"owner\":");
        json(w, module.owner.pkg_hash);
        write(w, ",\"source_arg\":");
        if (module.root_source_file) |source| {
            json(w, source_arg);
            source_arg += 1;
            sources.append(a, source) catch @panic("OOM");
        } else write(w, "null");
        write(w, ",\"imports\":[");
        for (module.import_table.keys(), module.import_table.values(), 0..) |name, imported, j| {
            if (j != 0) write(w, ",");
            json(w, .{ .name = name, .module = modules.getIndex(imported).? });
        }
        write(w, "]}");
    }
    write(w, "],\"roots\":[");
    var first = true;
    for ([_][]const *std.Build.Module{ production, test_roots.keys() }, 0..) |roots, group| for (roots) |module| {
        if (!first) write(w, ",");
        first = false;
        json(w, .{ .module = modules.getIndex(module).?, .kind = if (group == 0) "runtime" else "test" });
    };
    write(w, "]}\n");
    run.addFileArg(b.addWriteFiles().add("toolchain-configuration.json", output.written()));
    for (sources.items) |source| run.addFileArg(source);
    const step = b.step("check-toolchain", "Check resolved toolchain pins and gantry production reachability");
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = checker })).step);
    step.dependOn(&run.step);
    // Also exercised by every ordinary hosted shared-checker verification.
    b.top_level_steps.get("verify").?.step.dependOn(step);
}
fn package(w: *std.Io.Writer, hash: []const u8, root: []const u8, available: bool, deps: @FieldType(std.Build, "available_deps")) void {
    write(w, "{\"hash\":");
    json(w, hash);
    write(w, ",\"root\":");
    json(w, root);
    write(w, ",\"available\":");
    json(w, available);
    write(w, ",\"dependencies\":[");
    for (deps, 0..) |dependency, i| {
        if (i != 0) write(w, ",");
        json(w, .{ .name = dependency[0], .hash = dependency[1] });
    }
    write(w, "]}");
}
fn json(w: *std.Io.Writer, value: anytype) void {
    std.json.Stringify.value(value, .{}, w) catch @panic("OOM");
}
fn write(w: *std.Io.Writer, value: []const u8) void {
    w.writeAll(value) catch @panic("OOM");
}
