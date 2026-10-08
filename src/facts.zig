//! Zig 0.17 build-system protocol and the actual configured artifact graph.
const std = @import("std");
const builtin = @import("builtin");
const src = @import("checks/source.zig");
pub const configuration = @import("facts/configuration.zig");
const C = std.Build.Configuration;
const Io = std.Io;
const limit = 64 * 1024 * 1024;

pub const Snapshot = struct { config: C, path: []const u8, options: []const []const u8 = &.{}, bytes: []const u8 = &.{} };
pub fn read(c: src.Context, zig: []const u8, options: []const []const u8) !Snapshot {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.17.0")) return error.UnsupportedConfigurationVersion;
    const version = try std.process.run(c.a, c.io, .{ .argv = &.{ zig, "version" }, .stdout_limit = .limited(1024), .stderr_limit = .limited(1024), .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(30) } } });
    try successful(version.term);
    if (!std.mem.eql(u8, std.mem.trim(u8, version.stdout, "\r\n"), builtin.zig_version_string)) return error.UnsupportedCompilerVersion;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(c.a, &.{ zig, "build", "--listen=-" });
    for (options) |option| {
        if (!std.mem.startsWith(u8, option, "-D") or std.mem.findScalar(u8, option, 0) != null) return error.InvalidConfigurationOption;
        try argv.append(c.a, option);
    }
    var snapshot = try capture(c, argv.items);
    snapshot.options = try c.a.dupe([]const u8, options);
    return snapshot;
}

fn capture(c: src.Context, argv: []const []const u8) !Snapshot {
    var child = try std.process.spawn(c.io, .{ .argv = argv, .cwd = c.childCwd(), .environ_map = c.environ_map, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
    defer child.kill(c.io);
    var streams: Io.File.MultiReader.Buffer(2) = undefined;
    var multi: Io.File.MultiReader = undefined;
    multi.init(c.a, c.io, streams.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();
    var protocol: Io.Writer.Allocating = .init(c.a);
    var frame_count: usize = 0;
    while (true) {
        try available(&multi, 8);
        const header = try multi.reader(0).takeStruct(std.zig.Server.Message.Header, .little);
        frame_count += 1;
        if (frame_count > 64 or header.bytes_len > 8 * 1024 * 1024) return error.ProtocolFrameTooLong;
        try available(&multi, header.bytes_len);
        const body = try multi.reader(0).take(header.bytes_len);
        if (protocol.written().len > limit - 8 - body.len) return error.ProtocolOutputTooLong;
        try protocol.writer.writeStruct(header, .little);
        try protocol.writer.writeAll(body);
        if (header.tag == .bsp_configuration_failed) return error.BuildConfigurationFailed;
        if (header.tag != .bsp_handshake and header.tag != .bsp_configuration) return error.UnexpectedBuildProtocolMessage;
        if (header.tag != .bsp_configuration) continue;
        var reader = Io.Reader.fixed(protocol.written());
        const config_path = try notification(c.a, &reader);
        // A poisoned configuration is deleted at clean exit. Read it while
        // the server is alive; never race a path notification against exit.
        const bytes = try c.directory().readFileAlloc(c.io, config_path, c.a, .limited(limit));
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
fn available(multi: *Io.File.MultiReader, count: usize) !void {
    while (multi.reader(0).bufferedLen() < count) {
        multi.fill(4096, protocol_timeout) catch |err| switch (err) {
            error.EndOfStream => return error.TruncatedProtocolFrame,
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

pub fn write(a: std.mem.Allocator, snapshot: Snapshot, writer: *Io.Writer) !void {
    const c = &snapshot.config;
    var modules: std.AutoHashMapUnmanaged(C.Module.Index, void) = .empty;
    var pending: std.ArrayList(C.Module.Index) = .empty;
    try writer.writeAll("{\"protocol\":1,\"zig\":\"0.17.0\",\"configuration\":");
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
        try writePath(c, module.root_source_file, writer);
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
        try writePath(c, artifact.root_module.get(c).root_source_file, writer);
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
fn writePath(c: *const C, index: C.LazyPath.OptionalIndex, writer: *Io.Writer) !void {
    const value = (index.unwrap() orelse return writer.writeAll("null")).get(c);
    switch (value) {
        .source_path => |source| try std.json.Stringify.value(.{ .kind = "source", .owner = @backingInt(source.owner), .path = source.sub_path.slice(c) }, .{}, writer),
        .relative => |relative| try std.json.Stringify.value(.{ .kind = "relative", .base = relative.flags.base, .path = relative.sub_path.slice(c) }, .{}, writer),
        .generated => |generated| try std.json.Stringify.value(.{ .kind = "generated", .id = @backingInt(generated.index), .up = generated.flags.up, .path = generated.sub_path.slice(c) }, .{}, writer),
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

/// Source roots of configured root-package test artifacts. Compiler module IDs supply roots;
/// generated roots remain explicit rather than being guessed from path spelling.
pub fn testRoots(a: std.mem.Allocator, snapshot: Snapshot) ![]const []const u8 {
    const c = &snapshot.config;
    var roots: std.array_hash_map.String(void) = .empty;
    for (c.steps) |step| {
        if (step.owner != .root) continue;
        if (step.extended.cast(c, C.Step.Compile)) |artifact| {
            if (artifact.flags3.kind != .@"test" and artifact.flags3.kind != .test_obj) continue;
            const module = artifact.root_module.get(c);
            if (module.owner != .root) continue;
            const source = (module.root_source_file.unwrap() orelse return error.MissingConfiguredTestRoot).get(c);
            switch (source) {
                .source_path => |p| if (p.owner == .root) try roots.put(a, p.sub_path.slice(c), {}),
                .generated => |generated| try roots.put(a, try generatedName(a, c, generated), {}),
                .relative => |p| if (p.flags.base == .cwd) try roots.put(a, p.sub_path.slice(c), {}) else return error.UnsupportedTestRootBase,
            }
        }
    }
    if (roots.count() == 0) return error.MissingConfiguredTestRoot;
    return a.dupe([]const u8, roots.keys());
}

fn generatedName(a: std.mem.Allocator, c: *const C, generated: C.LazyPath.Generated) ![]const u8 {
    if (generated.flags.up != 0) return error.UnsupportedGeneratedTestRoot;
    return a.print(".preflight-generated/{d}/{s}", .{ @backingInt(generated.index), generated.sub_path.slice(c) });
}

/// Embedded WriteFile content is already a compiler fact. Dynamic producer
/// output is not available during configuration and must never be fabricated.
pub fn generatedSources(a: std.mem.Allocator, snapshot: Snapshot) ![]const src.Source {
    const c = &snapshot.config;
    var out: std.ArrayList(src.Source) = .empty;
    for (c.steps) |step| {
        if (step.owner != .root) continue;
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
    try std.testing.expectError(error.BuildProtocolChildSignal, successful(.{ .signal = .KILL }));
    try std.testing.expectError(error.BuildProtocolChildFailed, successful(.{ .exited = 3 }));
    const FaultIo = @import("shakedown").FaultIo;
    const faults = try FaultIo.init(std.testing.allocator, std.testing.io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .processSpawn, .n = 1 } }, .fault = .{ .fail = error.Canceled } }} });
    defer faults.deinit();
    try std.testing.expectError(error.Canceled, capture(.{ .a = a, .io = faults.io() }, &.{ "zig", "build", "--listen=-" }));
    try std.testing.expectEqual(@as(u64, 1), faults.count(.processSpawn));
    const write_fault = try FaultIo.init(std.testing.allocator, std.testing.io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .file_write_streaming, .n = 1 } }, .fault = .{ .fail = error.InputOutput } }} });
    defer write_fault.deinit();
    try std.testing.expectError(error.WriteFailed, capture(.{ .a = a, .io = write_fault.io() }, &.{ "zig", "build", "--listen=-" }));
    var writer = Io.Writer.failing;
    const fixture = @import("facts_test.zig");
    const seed = try fixture.seed(a);
    const loaded = try configuration.load(a, seed);
    try std.testing.expectError(error.WriteFailed, write(a, .{ .config = loaded, .path = "path" }, &writer));
}
