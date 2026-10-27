//! Zig's build-system protocol and the actual configured artifact graph, on the Zig versions `zig_version.zig` lists.
const std = @import("std");
const aegis = @import("aegis");
const builtin = @import("builtin");
const src = @import("checks/source.zig");
const zig_version = @import("zig_version.zig");
pub const configuration = @import("facts/configuration.zig");
pub const revisions = @import("facts/revisions.zig");
const C = std.Build.Configuration;
const Io = std.Io;
const limit = 64 * 1024 * 1024;

/// A configured build, and the package checked in it: the root package, or,
/// under bay, the root's dependency at the package's own directory, since the
/// root is then its development build.
pub const Snapshot = struct {
    config: C,
    path: []const u8,
    options: []const []const u8 = &.{},
    bytes: []const u8 = &.{},
    /// The checked package: one of its instances, which name its root.
    package: C.Package.Index = .root,
    /// Every instance of the checked package. A development build makes one per argument
    /// set (`b.dependency(name, args)`), each over the same files, as a package built in
    /// several configurations is; a step of any of them is the package's.
    instances: []const C.Package.Index = &.{},

    /// Whether `owner` is an instance of the checked package (the root build, read without bay).
    pub fn instance(snapshot: Snapshot, owner: C.Package.Index) bool {
        return owner == snapshot.package or std.mem.findScalar(C.Package.Index, snapshot.instances, owner) != null;
    }

    /// Whether a step or module `owner` owns is the checked package's: the root build's own,
    /// or one of the package's instances'.
    pub fn checks(snapshot: Snapshot, owner: C.Package.Index) bool {
        return owner == .root or snapshot.instance(owner);
    }
};
pub fn read(c: src.Context, zig: []const u8, options: []const []const u8) !Snapshot {
    _ = zig_version.require() catch {
        c.report("preflight: the configured-build reader supports {s}; this one was built with Zig {s}\n", .{ zig_version.supported, builtin.zig_version_string });
        return error.UnsupportedConfigurationVersion;
    };
    const version = try std.process.run(c.a, c.io, .{ .argv = &.{ zig, "version" }, .stdout_limit = .limited(1024), .stderr_limit = .limited(1024), .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(30) } } });
    try successful(version.term);
    if (!std.mem.eql(u8, std.mem.trim(u8, version.stdout, "\r\n"), builtin.zig_version_string)) return error.UnsupportedCompilerVersion;
    var argv: std.ArrayList([]const u8) = .empty;
    // Under bay the configured build is the development build, which holds the package.
    if (c.bay) |bay| try argv.appendSlice(c.a, &.{ bay, "dev", "--listen=-" }) else try argv.appendSlice(c.a, &.{ zig, "build", "--listen=-" });
    for (options) |option| {
        if (!std.mem.startsWith(u8, option, "-D") or std.mem.findScalar(u8, option, 0) != null) return error.InvalidConfigurationOption;
        try argv.append(c.a, option);
    }
    var snapshot = try capture(c, argv.items);
    snapshot.options = try c.a.dupe([]const u8, options);
    if (c.bay) |bay| {
        snapshot.instances = try checkedPackage(c, bay, &snapshot.config);
        snapshot.package = snapshot.instances[0];
    }
    return snapshot;
}

/// Every instance of the package at the checked directory, among the owners of the build's
/// steps, their root modules and those modules' files, in the order the build makes them.
fn checkedPackage(c: src.Context, bay: []const u8, config: *const C) ![]const C.Package.Index {
    const here = try c.directory().realPathFileAlloc(c.io, ".", c.a);
    // Zig reports a package's root from the directory it runs in, the build's root:
    // under bay the development root, which bay names.
    // aegis: no-danger: the development root bay names for this package
    var build_root = try Io.Dir.cwd().openDir(c.io, try developmentRoot(c, bay), .{});
    defer build_root.close(c.io);
    var owners: std.array_hash_map.Auto(C.Package.Index, void) = .empty;
    for (config.steps) |step| {
        try owners.put(c.a, step.owner, {});
        const compile = step.extended.cast(config, C.Step.Compile) orelse continue;
        const module = compile.root_module.get(config);
        try owners.put(c.a, module.owner, {});
        // A development build makes its own modules from the package's files: the files name the package.
        const file = (module.root_source_file.unwrap() orelse continue).get(config);
        if (file == .source_path) try owners.put(c.a, file.source_path.owner, {});
    }
    var instances: std.ArrayList(C.Package.Index) = .empty;
    for (owners.keys()) |owner| {
        const package = owner.get(config) orelse continue;
        // aegis: no-danger: a package root Zig's configuration of the package's own build names
        const path = build_root.realPathFileAlloc(c.io, package.root_path.slice(config), c.a) catch continue;
        if (std.mem.eql(u8, path, here)) try instances.append(c.a, owner);
    }
    if (instances.items.len == 0) return error.PackageNotInDevelopmentBuild;
    return instances.items;
}

/// The development build's root, as `bay locate --dev` names it. A bay that cannot say,
/// one from before `locate` among them, fails the read with what it wrote.
pub fn developmentRoot(c: src.Context, bay: []const u8) ![]const u8 {
    const located = try std.process.run(c.a, c.io, .{ .argv = &.{ bay, "locate", "--dev" }, .cwd = c.childCwd(), .environ_map = c.environ_map, .stdout_limit = .limited(1 << 16), .stderr_limit = .limited(1 << 16) });
    if (located.term != .exited or located.term.exited != 0) {
        c.report("preflight: `{s} locate --dev` failed, and the checked package's root is read from the development build's root it names; a bay with `locate` names it:\n{s}\n", .{ bay, std.mem.trim(u8, located.stderr, "\r\n") });
        return error.BayLocateFailed;
    }
    return std.mem.trim(u8, located.stdout, "\r\n");
}

fn capture(c: src.Context, argv: []const []const u8) !Snapshot {
    var child = try std.process.spawn(c.io, .{ .argv = argv, .cwd = c.childCwd(), .environ_map = c.environ_map, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
    var streams: Io.File.MultiReader.Buffer(2) = undefined;
    var multi: Io.File.MultiReader = undefined;
    multi.init(c.a, c.io, streams.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();
    // The child ends before its readers do: on Windows, deinit waits for every pending read,
    // and a build left waiting for its next message on stdin never ends one. Killing it
    // closes the pipes, which ends them; it is a no-op once `wait` has reaped it.
    defer child.kill(c.io);
    var protocol: Io.Writer.Allocating = .init(c.a);
    var frame_count: usize = 0;
    while (true) {
        try available(c, &multi, 8);
        const header = try multi.reader(0).takeStruct(std.zig.Server.Message.Header, .little);
        frame_count += 1;
        if (frame_count > 64 or header.bytes_len > 8 * 1024 * 1024) return error.ProtocolFrameTooLong;
        try available(c, &multi, header.bytes_len);
        const body = try multi.reader(0).take(header.bytes_len);
        if (protocol.written().len > limit - 8 - body.len) return error.ProtocolOutputTooLong;
        try protocol.writer.writeStruct(header, .little);
        try protocol.writer.writeAll(body);
        if (header.tag == .bsp_configuration_failed) {
            // What the build wrote to stderr says why; it ends after saying so.
            while (multi.fill(4096, protocol_timeout)) |_| {
                if (multi.reader(1).bufferedLen() > limit) break;
            } else |_| {}
            c.report("preflight: the build failed to configure ({s}):\n{s}\n", .{ try std.mem.join(c.a, " ", argv), multi.reader(1).buffered() });
            return error.BuildConfigurationFailed;
        }
        if (header.tag != .bsp_handshake and header.tag != .bsp_configuration) return error.UnexpectedBuildProtocolMessage;
        if (header.tag != .bsp_configuration) continue;
        var reader = Io.Reader.fixed(protocol.written());
        const config_path = try notification(c.a, &reader);
        // A poisoned configuration is deleted at clean exit. Read it while
        // the server is alive; never race a path notification against exit.
        const bytes = try aegis.own.readFile(c.io, c.directory(), config_path, c.a, .fromRaw(limit));
        const config = try configuration.load(c.a, bytes);
        var buffer: [16]u8 = undefined;
        var writer = child.stdin.?.writerStreaming(c.io, &buffer);
        try writer.interface.writeStruct(std.zig.Client.Message.Header{ .tag = .exit, .bytes_len = 0 }, .little);
        try writer.interface.flush();
        while (multi.fill(4096, protocol_timeout)) |_| {
            if (multi.reader(0).bufferedLen() > limit or multi.reader(1).bufferedLen() > limit) return error.ProtocolOutputTooLong;
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
        try multi.checkAnyError();
        try successful(try child.wait(c.io));
        if (multi.reader(0).bufferedLen() != 0) return error.UnexpectedBuildProtocolMessage;
        return .{ .config = config, .path = config_path, .bytes = bytes };
    }
}
const protocol_timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } };
/// Reads until `count` bytes of the protocol are there. A build that ends
/// before it has said what it configured has failed, and what it wrote to
/// stderr is why: that is what `c` reports.
fn available(c: src.Context, multi: *Io.File.MultiReader, count: usize) !void {
    while (multi.reader(0).bufferedLen() < count) {
        multi.fill(4096, protocol_timeout) catch |err| switch (err) {
            error.EndOfStream => {
                c.report("preflight: the build ended before it sent its configuration:\n{s}\n", .{multi.reader(1).buffered()});
                return error.TruncatedProtocolFrame;
            },
            else => return err,
        };
        if (multi.reader(0).bufferedLen() > limit or multi.reader(1).bufferedLen() > limit) return error.ProtocolOutputTooLong;
        try multi.checkAnyError();
    }
}
fn successful(term: std.process.Child.Term) !void {
    if (term != .exited) return error.BuildProtocolChildSignal;
    if (term.exited != 0) return error.BuildProtocolChildFailed;
}

pub fn notification(a: std.mem.Allocator, reader: *Io.Reader) ![]const u8 {
    var handshake = false;
    var path: ?[]const u8 = null;
    var frames: usize = 0;
    while (true) {
        if (reader.peekByte()) |_| {} else |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        }
        const header = reader.takeStruct(std.zig.Server.Message.Header, .little) catch |err| switch (err) {
            error.EndOfStream => return error.TruncatedProtocolFrame,
            else => return err,
        };
        frames += 1;
        if (frames > 64 or header.bytes_len > 8 * 1024 * 1024) return error.ProtocolFrameTooLong;
        const body = reader.take(header.bytes_len) catch |err| switch (err) {
            error.EndOfStream => return error.TruncatedProtocolFrame,
            else => return err,
        };
        switch (header.tag) {
            .bsp_handshake => {
                if (handshake or path != null or body.len != @sizeOf(std.zig.Server.Message.Handshake)) return error.MalformedBuildHandshake;
                var input = Io.Reader.fixed(body);
                const hello = try input.takeStruct(std.zig.Server.Message.Handshake, .little);
                if (hello.version != std.zig.Server.build_system_version) return error.UnsupportedBuildProtocol;
                if (hello.flags.unused != 0) return error.UnsupportedBuildProtocol;
                handshake = true;
            },
            .bsp_configuration => {
                if (!handshake or path != null or body.len == 0 or body.len > 32768 or std.mem.findScalar(u8, body, 0) != null) return error.MalformedConfigurationPath;
                path = try a.dupe(u8, body);
            },
            .bsp_configuration_failed => return error.BuildConfigurationFailed,
            // Compiler messages are not build-system handshake/configuration.
            else => return error.UnexpectedBuildProtocolMessage,
        }
    }
    return path orelse error.MissingBuildConfiguration;
}

/// Whether a module an artifact of the configured build compiles links a framework, which
/// only a host holding Apple's SDK can find.
pub fn linksFramework(a: std.mem.Allocator, snapshot: Snapshot) !bool {
    const c = &snapshot.config;
    var modules: std.AutoHashMapUnmanaged(C.Module.Index, void) = .empty;
    var pending: std.ArrayList(C.Module.Index) = .empty;
    for (c.steps) |step| {
        const compiled = step.extended.cast(c, C.Step.Compile) orelse continue;
        try pending.append(a, compiled.root_module);
    }
    while (pending.pop()) |id| {
        if ((try modules.getOrPut(a, id)).found_existing) continue;
        const module = id.get(c);
        if (module.frameworks.slice.len != 0) return true;
        for (module.import_table.get(c).imports.mal.items(.module)) |imported| try pending.append(a, imported);
    }
    return false;
}

pub fn write(a: std.mem.Allocator, snapshot: Snapshot, writer: *Io.Writer) !void {
    const c = &snapshot.config;
    var modules: std.AutoHashMapUnmanaged(C.Module.Index, void) = .empty;
    var pending: std.ArrayList(C.Module.Index) = .empty;
    try writer.writeAll("{\"protocol\":1,\"zig\":");
    try std.json.Stringify.value(builtin.zig_version_string, .{}, writer);
    try writer.writeAll(",\"configuration\":");
    try std.json.Stringify.value(snapshot.path, .{}, writer);
    try writer.writeAll(",\"configured_options\":");
    try std.json.Stringify.value(snapshot.options, .{}, writer);
    try writer.writeAll(",\"steps\":[");
    for (c.steps, 0..) |step, index| {
        const compiled = step.extended.cast(c, C.Step.Compile);
        if (compiled) |artifact| try pending.append(a, artifact.root_module);
        if (index > 0) try writer.writeByte(',');
        try std.json.Stringify.value(.{ .id = index, .name = step.name.slice(c), .owner = @backingInt(step.owner), .kind = step.extended.tag(c), .deps = step.deps.slice(c), .module = if (compiled) |artifact| @as(?u32, @backingInt(artifact.root_module)) else null, .@"test" = if (compiled) |artifact| (artifact.flags3.kind == .@"test" or artifact.flags3.kind == .test_obj) else false }, .{}, writer);
    }
    try writer.writeAll("],\"modules\":[");
    var count: usize = 0;
    while (pending.pop()) |id| {
        if ((try modules.getOrPut(a, id)).found_existing) continue;
        const module = id.get(c);
        if (count > 0) try writer.writeByte(',');
        count += 1;
        try writer.print("{{\"id\":{d},\"owner\":{d},\"flags\":", .{ @backingInt(id), @backingInt(module.owner) });
        try std.json.Stringify.value(module.flags, .{}, writer);
        try writer.writeAll(",\"flags2\":");
        try std.json.Stringify.value(module.flags2, .{}, writer);
        try writer.writeAll(",\"source\":");
        try writePath(a, c, module.root_source_file, writer);
        try writer.writeAll(",\"target\":");
        if (module.resolved_target.get(c)) |target| {
            const result = target.result.get(c);
            try std.json.Stringify.value(.{ .flags = result.flags, .cpu = if (result.cpu_name.value) |name| name.slice(c) else null, .features_add = result.cpu_features_add.value, .features_sub = result.cpu_features_sub.value }, .{}, writer);
        } else try writer.writeAll("null");
        try writer.writeAll(",\"imports\":[");
        const imports = module.import_table.get(c).imports.mal;
        for (imports.items(.name), imports.items(.module), 0..) |name, imported, i| {
            try pending.append(a, imported);
            if (i > 0) try writer.writeByte(',');
            try std.json.Stringify.value(.{ .name = name.slice(c), .module = @backingInt(imported) }, .{}, writer);
        }
        try writer.writeAll("],\"frameworks\":[");
        for (module.frameworks.slice, 0..) |framework, i| {
            if (i > 0) try writer.writeByte(',');
            try std.json.Stringify.value(.{ .name = framework.name.slice(c), .needed = framework.flags.needed, .weak = framework.flags.weak }, .{}, writer);
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("],\"options\":[");
    for (c.available_options, 0..) |option, i| {
        if (i > 0) try writer.writeByte(',');
        try std.json.Stringify.value(.{ .name = option.name.slice(c), .type = option.type }, .{}, writer);
    }
    try writer.writeAll("],\"lazy_dependencies\":[");
    for (c.unlazy_deps, 0..) |dependency, i| {
        if (i > 0) try writer.writeByte(',');
        try std.json.Stringify.value(dependency.slice(c), .{}, writer);
    }
    try writer.writeAll("],\"test_roots\":[");
    var first = true;
    for (c.steps, 0..) |step, i| {
        const artifact = step.extended.cast(c, C.Step.Compile) orelse continue;
        if (artifact.flags3.kind != .@"test" and artifact.flags3.kind != .test_obj) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("{{\"step\":{d},\"module\":{d},\"source\":", .{ i, @backingInt(artifact.root_module) });
        try writePath(a, c, artifact.root_module.get(c).root_source_file, writer);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"packages\":[");
    var owners: std.AutoHashMapUnmanaged(C.Package.Index, void) = .empty;
    first = true;
    for (c.steps) |step| {
        if ((try owners.getOrPut(a, step.owner)).found_existing) continue;
        const owner = step.owner.get(c) orelse continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try std.json.Stringify.value(.{ .id = @backingInt(step.owner), .prefix = owner.dep_prefix.slice(c), .hash = owner.hash.slice(c), .root = owner.root_path.slice(c) }, .{}, writer);
    }
    try writer.writeAll("]}\n");
}
fn writePath(a: std.mem.Allocator, c: *const C, index: C.LazyPath.OptionalIndex, writer: *Io.Writer) !void {
    const value = (index.unwrap() orelse return writer.writeAll("null")).get(c);
    switch (value) {
        .source_path => |source| try std.json.Stringify.value(.{ .kind = "source", .owner = @backingInt(source.owner), .path = try named(a, source.sub_path.slice(c)) }, .{}, writer),
        .relative => |relative| try std.json.Stringify.value(.{ .kind = "relative", .base = relative.flags.base, .path = try named(a, relative.sub_path.slice(c)) }, .{}, writer),
        .generated => |generated| try std.json.Stringify.value(.{ .kind = "generated", .id = @backingInt(generated.index), .up = generated.flags.up, .path = try named(a, generated.sub_path.slice(c)) }, .{}, writer),
    }
}

test "build protocol distinguishes compiler messages and rejects truncated unknown version and oversized frames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bytes: Io.Writer.Allocating = .init(arena.allocator());
    try bytes.writer.writeStruct(std.zig.Server.Message.Header{ .tag = .bsp_handshake, .bytes_len = 8 }, .little);
    try bytes.writer.writeStruct(std.zig.Server.Message.Handshake{ .version = 1, .flags = .{ .file_system_watch_supported = false } }, .little);
    try bytes.writer.writeStruct(std.zig.Server.Message.Header{ .tag = .bsp_configuration, .bytes_len = 4 }, .little);
    try bytes.writer.writeAll("path");
    var reader = Io.Reader.fixed(bytes.written());
    try std.testing.expectEqualStrings("path", try notification(arena.allocator(), &reader));
    for (0..bytes.written().len) |length| {
        reader = Io.Reader.fixed(bytes.written()[0..length]);
        if (notification(arena.allocator(), &reader)) |_| return error.AcceptedTruncation else |_| {}
    }
    var bad = try arena.allocator().dupe(u8, bytes.written());
    bad[8] = 2;
    reader = Io.Reader.fixed(bad);
    try std.testing.expectError(error.UnsupportedBuildProtocol, notification(arena.allocator(), &reader));
    bad[8] = 1;
    bad[0..4].* = .{ 0, 0, 0, 0 };
    reader = Io.Reader.fixed(bad);
    try std.testing.expectError(error.UnexpectedBuildProtocolMessage, notification(arena.allocator(), &reader));
    bad[4..8].* = .{ 0xff, 0xff, 0xff, 0xff };
    reader = Io.Reader.fixed(bad);
    try std.testing.expectError(error.ProtocolFrameTooLong, notification(arena.allocator(), &reader));
    try std.testing.expectError(error.MalformedConfiguration, configuration.load(arena.allocator(), "bad"));
}

/// The configured modules, as lint resolves a name an import leads by: each
/// module a compile step reaches, its root file where the build names one
/// (generated roots are not on disk) and what each of its import names leads to.
pub fn buildModules(a: std.mem.Allocator, snapshot: Snapshot) ![]const src.BuildModule {
    const c = &snapshot.config;
    var indices: std.array_hash_map.Auto(C.Module.Index, void) = .empty;
    var pending: std.ArrayList(C.Module.Index) = .empty;
    for (c.steps) |step| {
        const compiled = step.extended.cast(c, C.Step.Compile) orelse continue;
        try pending.append(a, compiled.root_module);
    }
    while (pending.pop()) |id| {
        if ((try indices.getOrPut(a, id)).found_existing) continue;
        const imports = id.get(c).import_table.get(c).imports.mal;
        for (imports.items(.module)) |imported| try pending.append(a, imported);
    }
    const out = try a.alloc(src.BuildModule, indices.count());
    for (indices.keys(), out) |id, *module| {
        const configured = id.get(c);
        const table = configured.import_table.get(c).imports.mal;
        const bindings = try a.alloc(src.BuildModule.Binding, table.len);
        for (table.items(.name), table.items(.module), bindings) |name, imported, *binding| {
            binding.* = .{ .name = name.slice(c), .module = indices.getIndex(imported).? };
        }
        module.* = .{ .root = try rootPath(a, c, snapshot.package, configured.root_source_file), .imports = bindings };
    }
    return out;
}

/// Where a module's root file is, relative to the repository's root: the checked
/// package's files are the repository's, wherever the configured build sits.
fn rootPath(a: std.mem.Allocator, c: *const C, checked: C.Package.Index, index: C.LazyPath.OptionalIndex) !?[]const u8 {
    const path = (index.unwrap() orelse return null).get(c);
    switch (path) {
        .source_path => |source| {
            if (source.owner == checked) return try named(a, source.sub_path.slice(c));
            const package = source.owner.get(c) orelse return try named(a, source.sub_path.slice(c));
            const own = checked.get(c) orelse return try named(a, try Io.Dir.path.join(a, &.{ package.root_path.slice(c), source.sub_path.slice(c) }));
            return try packagePath(a, own.root_path.slice(c), package.root_path.slice(c), source.sub_path.slice(c));
        },
        .relative => |relative| return if (relative.flags.base == .cwd) try named(a, relative.sub_path.slice(c)) else null,
        .generated => return null,
    }
}

/// A file of the package at `root`, as lint names it: relative to the repository when that
/// package is the checked one reached again (a build that depends on its own package twice,
/// as a benchmark built in another mode does, has two packages at one directory), else
/// where the package is.
fn packagePath(a: std.mem.Allocator, checked_root: []const u8, root: []const u8, sub_path: []const u8) ![]const u8 {
    const own = try Io.Dir.path.resolveAlloc(a, &.{checked_root});
    const other = try Io.Dir.path.resolveAlloc(a, &.{root});
    if (std.mem.eql(u8, own, other)) return try named(a, sub_path);
    return try named(a, try Io.Dir.path.join(a, &.{ root, sub_path }));
}

/// A path of the configured build as preflight names files: with `/` on every host, as lint
/// names them (`glint.assembly.normalize`). Zig's build keeps a module's paths with `\` on
/// Windows (`std.Build.Graph.dupePath`), so a Windows configuration hands them over so.
fn named(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const name = try a.dupe(u8, path);
    if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, name, '\\', '/');
    return name;
}

test "a module of the checked package reached through a second package is named as the repository's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("src/root.zig", try packagePath(a, "/work/pkg/.zig-cache/bay/../..", "/work/pkg", "src/root.zig"));
    try std.testing.expectEqualStrings("src/root.zig", try packagePath(a, "/work/pkg", "/work/pkg/.zig-cache/bay/../..", "src/root.zig"));
    try std.testing.expectEqualStrings("/work/zig-pkg/dep/src/root.zig", try packagePath(a, "/work/pkg", "/work/zig-pkg/dep", "src/root.zig"));
}

/// The test artifacts a run under the top-level step `step_name` runs without preflight's
/// runner: ones a build gave its tests after `addCi` read them, which then run with no
/// watchdog, shard, timing record or riscv64 machine. Empty for a build that gives no test
/// preflight's runner (one without `addCi`, as a declared job's nested build).
pub fn testsOutsideRunner(a: std.mem.Allocator, snapshot: Snapshot, step_name: []const u8) ![]const []const u8 {
    const c = &snapshot.config;
    var instrumented_any = false;
    for (c.steps) |step| {
        const compiled = step.extended.cast(c, C.Step.Compile) orelse continue;
        if (isTest(compiled) and runsPreflight(c, compiled)) instrumented_any = true;
    }
    if (!instrumented_any) return &.{};
    var pending: std.ArrayList(C.Step.Index) = .empty;
    for (c.steps, 0..) |step, index| {
        if (step.owner != .root or step.extended.cast(c, C.Step.TopLevel) == null) continue;
        if (std.mem.eql(u8, step.name.slice(c), step_name)) try pending.append(a, @fromBackingInt(@intCast(index)));
    }
    var seen: std.AutoHashMapUnmanaged(C.Step.Index, void) = .empty;
    var outside: std.array_hash_map.String(void) = .empty;
    while (pending.pop()) |index| {
        if ((try seen.getOrPut(a, index)).found_existing) continue;
        const step = index.ptr(c);
        try pending.appendSlice(a, step.deps.slice(c));
        const run = step.extended.cast(c, C.Step.Run) orelse continue;
        const producer = run.producer.value orelse continue;
        const compiled = producer.ptr(c).extended.cast(c, C.Step.Compile) orelse continue;
        if (isTest(compiled) and !runsPreflight(c, compiled)) try outside.put(a, compiled.root_name.slice(c), {});
    }
    return a.dupe([]const u8, outside.keys());
}

fn isTest(compiled: C.Step.Compile) bool {
    return compiled.flags3.kind == .@"test" or compiled.flags3.kind == .test_obj;
}

/// Whether `addCi` gave the artifact preflight's runner: its root module then imports the
/// runner's options, an artifact with a runner of its own included.
fn runsPreflight(c: *const C, compiled: C.Step.Compile) bool {
    for (compiled.root_module.get(c).import_table.get(c).imports.mal.items(.name)) |name| {
        if (std.mem.eql(u8, name.slice(c), "preflight_runner_options")) return true;
    }
    return false;
}

/// The test roots of the configured build: the root files of the package's test artifacts that
/// a run under one of `steps` (top-level steps CI runs) runs, and those of the ones none runs,
/// each with the artifacts that compile it. Zig runs a test binary's tests only when a run runs
/// it, so a root only compiled holds tests that never run, and reaches no file's tests.
/// Compiler module IDs supply roots; generated roots remain explicit rather than being guessed
/// from path spelling.
pub const TestRoots = struct { run: []const []const u8, unrun: []const Unrun };
pub const Unrun = struct { root: []const u8, artifacts: []const []const u8 };

pub fn testRoots(a: std.mem.Allocator, snapshot: Snapshot, steps: []const []const u8) !TestRoots {
    const c = &snapshot.config;
    var ran: std.array_hash_map.String(void) = .empty;
    var pending: std.ArrayList(C.Step.Index) = .empty;
    for (c.steps, 0..) |step, index| {
        if (step.owner != .root or step.extended.cast(c, C.Step.TopLevel) == null) continue;
        for (steps) |name| if (std.mem.eql(u8, step.name.slice(c), name)) try pending.append(a, @fromBackingInt(@intCast(index)));
    }
    var seen: std.AutoHashMapUnmanaged(C.Step.Index, void) = .empty;
    while (pending.pop()) |index| {
        if ((try seen.getOrPut(a, index)).found_existing) continue;
        const step = index.ptr(c);
        try pending.appendSlice(a, step.deps.slice(c));
        const run = step.extended.cast(c, C.Step.Run) orelse continue;
        const producer = run.producer.value orelse continue;
        const compiled = producer.ptr(c).extended.cast(c, C.Step.Compile) orelse continue;
        if (!isTest(compiled)) continue;
        if (try testRoot(a, snapshot, compiled)) |root| try ran.put(a, root, {});
    }
    var unrun: std.array_hash_map.String(std.array_hash_map.String(void)) = .empty;
    var any = false;
    for (c.steps) |step| {
        if (!snapshot.checks(step.owner)) continue;
        const compiled = step.extended.cast(c, C.Step.Compile) orelse continue;
        if (!isTest(compiled)) continue;
        const root = try testRoot(a, snapshot, compiled) orelse continue;
        any = true;
        if (ran.contains(root)) continue;
        const entry = try unrun.getOrPut(a, root);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        // A test compiled again for another target or as an object keeps its name.
        try entry.value_ptr.put(a, compiled.root_name.slice(c), {});
    }
    if (!any) return error.MissingConfiguredTestRoot;
    const out = try a.alloc(Unrun, unrun.count());
    for (unrun.keys(), unrun.values(), out) |root, artifacts, *item| item.* = .{ .root = root, .artifacts = artifacts.keys() };
    return .{ .run = ran.keys(), .unrun = out };
}

/// The root file of a test artifact of the checked package, as lint names it, or null for
/// one of another package's.
fn testRoot(a: std.mem.Allocator, snapshot: Snapshot, compiled: C.Step.Compile) !?[]const u8 {
    const c = &snapshot.config;
    const module = compiled.root_module.get(c);
    if (!snapshot.checks(module.owner)) return null;
    const source = (module.root_source_file.unwrap() orelse return error.MissingConfiguredTestRoot).get(c);
    return switch (source) {
        .source_path => |p| if (snapshot.instance(p.owner)) try named(a, p.sub_path.slice(c)) else null,
        .generated => |generated| try generatedName(a, c, generated),
        .relative => |p| if (p.flags.base == .cwd) try named(a, p.sub_path.slice(c)) else error.UnsupportedTestRootBase,
    };
}

fn generatedName(a: std.mem.Allocator, c: *const C, generated: C.LazyPath.Generated) ![]const u8 {
    if (generated.flags.up != 0) return error.UnsupportedGeneratedTestRoot;
    return named(a, try a.print(".preflight-generated/{d}/{s}", .{ @backingInt(generated.index), generated.sub_path.slice(c) }));
}

/// Embedded WriteFile content is already a compiler fact. Dynamic producer
/// output is not available during configuration and must never be fabricated.
pub fn generatedSources(a: std.mem.Allocator, snapshot: Snapshot) ![]const src.Source {
    const c = &snapshot.config;
    var out: std.ArrayList(src.Source) = .empty;
    for (c.steps) |step| {
        if (!snapshot.checks(step.owner)) continue;
        const artifact = step.extended.cast(c, C.Step.Compile) orelse continue;
        if (artifact.flags3.kind != .@"test" and artifact.flags3.kind != .test_obj) continue;
        const module = artifact.root_module.get(c);
        const path = (module.root_source_file.unwrap() orelse continue).get(c);
        if (path != .generated) continue;
        const name = try generatedName(a, c, path.generated);
        var found = false;
        for (c.steps) |producer| {
            const files = producer.extended.cast(c, C.Step.WriteFile) orelse continue;
            if (files.generated_directory != path.generated.index) continue;
            for (files.embeds.slice) |embed| {
                if (!std.mem.eql(u8, embed.sub_path.slice(c), path.generated.sub_path.slice(c))) continue;
                try out.append(a, try src.Source.parse(a, name, embed.contents.slice(c)));
                found = true;
            }
        }
        if (!found) return error.GeneratedTestRootUnavailable;
    }
    return out.items;
}

test "build protocol chunked transport cancellation child status and output faults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bytes: Io.Writer.Allocating = .init(a);
    try bytes.writer.writeStruct(std.zig.Server.Message.Header{ .tag = .bsp_handshake, .bytes_len = 8 }, .little);
    try bytes.writer.writeStruct(std.zig.Server.Message.Handshake{ .version = 1, .flags = .{ .file_system_watch_supported = false } }, .little);
    try bytes.writer.writeStruct(std.zig.Server.Message.Header{ .tag = .bsp_configuration, .bytes_len = 4 }, .little);
    try bytes.writer.writeAll("path");
    var buffer: [64]u8 = undefined;
    var chunked = std.testing.Reader.init(&buffer, &.{.{ .buffer = bytes.written() }});
    chunked.artificial_limit = .limited(1);
    try std.testing.expectEqualStrings("path", try notification(a, &chunked.interface));
    try std.testing.expectError(error.BuildProtocolChildSignal, successful(.{ .signal = .TERM }));
    try std.testing.expectError(error.BuildProtocolChildFailed, successful(.{ .exited = 3 }));
    // A build of its own that configures nothing: the repository's build would be configured
    // anew by a plain `zig build`, minutes on a cold host, for faults that need only a build.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data = "pub fn build(_: *@import(\"std\").Build) void {}\n" });
    const FaultIo = @import("shakedown").FaultIo;
    const faults = try FaultIo.init(std.testing.allocator, std.testing.io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .processSpawn, .n = 1 } }, .fault = .{ .fail = error.Canceled } }} });
    defer faults.deinit();
    try std.testing.expectError(error.Canceled, capture(.{ .a = a, .io = faults.io(), .dir = tmp.dir }, &.{ "zig", "build", "--listen=-" }));
    try std.testing.expectEqual(@as(u64, 1), faults.count(.processSpawn));
    const write_fault = try FaultIo.init(std.testing.allocator, std.testing.io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .file_write_streaming, .n = 1 } }, .fault = .{ .fail = error.InputOutput } }} });
    defer write_fault.deinit();
    try std.testing.expectError(error.WriteFailed, capture(.{ .a = a, .io = write_fault.io(), .dir = tmp.dir }, &.{ "zig", "build", "--listen=-" }));
    var writer = Io.Writer.failing;
    const fixture = @import("facts_test.zig");
    const seed = try fixture.seed(a);
    const loaded = try configuration.load(a, seed);
    try std.testing.expectError(error.WriteFailed, write(a, .{ .config = loaded, .path = "path" }, &writer));
}
