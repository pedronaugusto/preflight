//! The one caller template and planner: consumer repositories hold only inputs
//! and the generated workflow, never another generator.
const std = @import("std");
const src = @import("source.zig");
const matrix = @import("matrix.zig");

const template = @embedFile("caller.yml");
const repository = "git+https://github.com/pedronaugusto/preflight#";
const Manifest = struct {
    dependencies: struct {
        preflight: struct { url: ?[]const u8 = null },
    },
};

pub fn pinned(c: src.Context, manifest_path: []const u8) ![]const u8 {
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = try std.zon.parse.fromSlice(Manifest, .{
        .gpa = c.a,
        .arena = c.a,
        .source = try c.a.dupeSentinel(u8, try c.read(manifest_path), 0),
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    });
    const url = manifest.dependencies.preflight.url orelse return error.MissingPublishedPreflightPin;
    if (!std.mem.startsWith(u8, url, repository)) return error.InvalidPreflightRepository;
    const pin = url[repository.len..];
    if (pin.len != 40) return error.InvalidPreflightPin;
    for (pin) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidPreflightPin;
    return pin;
}

pub fn render(a: std.mem.Allocator, config: src.Value, pin: []const u8, directory: []const u8, own: bool) ![]const u8 {
    // Every writer in renderAllocating is memory-backed. Its only write
    // failure is allocation exhaustion; preserve the allocator error contract.
    return renderAllocating(a, config, pin, directory, own) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}

fn renderAllocating(a: std.mem.Allocator, config: src.Value, pin: []const u8, directory: []const u8, own: bool) ![]const u8 {
    if (config != .object) return error.InvalidWorkflowConfig;
    if (!own) {
        if (pin.len != 40) return error.InvalidPreflightPin;
        for (pin) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidPreflightPin;
    }
    try relative(directory, true);
    var matrices: std.Io.Writer.Allocating = .init(a);
    defer matrices.deinit();
    for ([_]matrix.Tier{ .fast, .merge, .release }) |tier| {
        const tiers = try matrix.split(a, config, try matrix.plan(a, config, tier), tier);
        for ([_][]const matrix.Job{ tiers.native, tiers.compile, tiers.run }, [_][]const u8{ "", "-compile", "-run" }) |group, suffix| {
            if (tier == .fast and suffix.len != 0) continue;
            try matrices.writer.print("      {t}{s}-matrix: >-\n        {s}\n", .{ tier, suffix, try std.json.Stringify.valueAlloc(a, .{ .include = group }, .{}) });
        }
    }
    const skip = if (own) "./.github/workflows/skip.yml" else try a.print("pedronaugusto/preflight/.github/workflows/skip.yml@{s}", .{pin});
    const gate = if (own) "./.github/workflows/zig.yml" else try a.print("pedronaugusto/preflight/.github/workflows/zig.yml@{s}", .{pin});
    const tokens = [_][]const u8{ "@SKIP@", "@GATE@", "@PIN@", "@DIRECTORY@", "@MATRICES@", "@WINDOWS_GIT@", "@COMPILE_ONCE@" };
    const values = [_][]const u8{ skip, gate, if (own) "${{ github.sha }}" else pin, try std.json.Stringify.valueAlloc(a, directory, .{}), matrices.written(), try boolean(config, "windows_git_latest"), try boolean(config, "compile_once") };
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    var offset: usize = 0;
    while (offset < template.len) {
        var matched = false;
        for (tokens, values) |token, value| {
            if (std.mem.startsWith(u8, template[offset..], token)) {
                try text.writer.writeAll(value);
                offset += token.len;
                matched = true;
                break;
            }
        }
        if (!matched) {
            try text.writer.writeByte(template[offset]);
            offset += 1;
        }
    }
    if (own) try text.writer.writeAll(
        \\  checks:
        \\    needs: skip
        \\    if: needs.skip.outputs.docs-only != 'true' && github.event_name != 'push' && !inputs.status-only && (github.event_name != 'workflow_dispatch' || inputs.tier != 'fast')
        \\    runs-on: ubuntu-latest
        \\    steps:
        \\      - uses: actions/checkout@v4
        \\      - uses: mlugg/setup-zig@v2
        \\        with:
        \\          version: 0.17.0
        \\      - run: zig build verify -Dci-bench-smoke=false
        \\
    );
    return text.toOwnedSlice();
}

fn boolean(config: src.Value, name: []const u8) ![]const u8 {
    const value = src.get(config, name);
    return switch (value) {
        .null => "false",
        .bool => if (value.bool) "true" else "false",
        else => error.InvalidWorkflowBoolean,
    };
}

fn relative(path: []const u8, directory: bool) !void {
    if (directory and std.mem.eql(u8, path, ".")) return;
    if (path.len == 0 or std.Io.Dir.path.isAbsolute(path) or std.mem.findScalar(u8, path, '\\') != null) return error.InvalidWorkflowPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".git")) return error.InvalidWorkflowPath;
        for (part) |byte| if (byte < 32 or byte == 127) return error.InvalidWorkflowPath;
    }
}

/// Validates and renders everything before opening the sole output. Existing
/// directories and files are opened without following symlinks. This is a
/// regeneration write, not a durable/crash-atomic publication operation.
pub fn write(c: src.Context, path: []const u8, text: []const u8) !void {
    try relative(path, false);
    if (!std.mem.endsWith(u8, path, ".yml") and !std.mem.endsWith(u8, path, ".yaml")) return error.InvalidWorkflowPath;
    var dir = try c.directory().openDir(c.io, ".", .{ .follow_symlinks = false });
    defer dir.close(c.io);
    var parts = std.mem.splitScalar(u8, path, '/');
    var part = parts.next().?;
    while (parts.next()) |next| {
        const child = try dir.openDir(c.io, part, .{ .follow_symlinks = false });
        dir.close(c.io);
        dir = child;
        part = next;
    }
    const file = dir.openFile(c.io, part, .{ .mode = .read_write, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => try dir.createFile(c.io, part, .{ .exclusive = true }),
        else => return err,
    };
    defer file.close(c.io);
    if ((try file.stat(c.io)).kind != .file) return error.InvalidWorkflowOutput;
    try file.setLength(c.io, 0);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(c.io, &buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

test "caller generation validates pins and output paths before replacing files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: src.Context = .{ .a = a, .io = std.testing.io, .dir = tmp.dir };
    try tmp.dir.writeFile(c.io, .{ .sub_path = "kept.yml", .data = "kept\n" });
    for ([_][]const u8{ "../kept.yml", "/kept.yml", ".git/kept.yml", "kept.txt", "sub//kept.yml" }) |path| try std.testing.expectError(error.InvalidWorkflowPath, write(c, path, "changed"));
    try std.testing.expectEqualStrings("kept\n", try c.read("kept.yml"));
    const config = (try std.json.parseFromSlice(src.Value, a, "{}", .{})).value;
    try std.testing.expectError(error.InvalidPreflightPin, render(a, config, "main", ".", false));
    try std.testing.expectError(error.InvalidWorkflowConfig, render(a, .null, "", ".", false));
    try std.testing.expectError(error.InvalidWorkflowPath, render(a, config, "9af905ed85cab6dbb19d9431c65ee3f41fbaa74d", "../escape", false));
}

test "caller generation is deterministic with all tier matrices and refreshes its manifest pin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"compile_once\":true,\"targets\":[\"x86_64-macos\",\"aarch64-macos\"],\"shards\":{\"windows\":3}}", .{})).value;
    const first_pin = "9af905ed85cab6dbb19d9431c65ee3f41fbaa74d";
    const next_pin = "76b1366323da4700bc0dcd3e24f2d7c4ee0e0ce9";
    const first = try render(a, config, first_pin, ".", false);
    try std.testing.expectEqualStrings(first, try render(a, config, first_pin, ".", false));
    const second = try render(a, config, next_pin, ".", false);
    try std.testing.expect(std.mem.find(u8, second, first_pin) == null);
    try std.testing.expect(std.mem.find(u8, second, next_pin) != null);
    for ([_]matrix.Tier{ .fast, .merge, .release }) |tier| {
        const tiers = try matrix.split(a, config, try matrix.plan(a, config, tier), tier);
        for ([_][]const matrix.Job{ tiers.native, tiers.compile, tiers.run }, [_][]const u8{ "", "-compile", "-run" }) |group, suffix| {
            if (tier == .fast and suffix.len != 0) continue;
            const block = try a.print("      {t}{s}-matrix: >-\n        {s}\n", .{ tier, suffix, try std.json.Stringify.valueAlloc(a, .{ .include = group }, .{}) });
            try std.testing.expect(std.mem.find(u8, second, block) != null);
        }
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: src.Context = .{ .a = a, .io = std.testing.io, .dir = tmp.dir };
    for ([_][]const u8{ "main", "924b6b5", "9AF905ED85CAB6DBB19D9431C65EE3F41FBAA74D" }) |bad| {
        try tmp.dir.writeFile(c.io, .{ .sub_path = "build.zig.zon", .data = try a.print(".{{ .dependencies = .{{ .preflight = .{{ .url = \"{s}{s}\" }} }} }}", .{ repository, bad }) });
        try std.testing.expectError(error.InvalidPreflightPin, pinned(c, "build.zig.zon"));
    }
    try tmp.dir.writeFile(c.io, .{ .sub_path = "build.zig.zon", .data = ".{ .dependencies = .{ .preflight = .{ .path = \"..\" } } }" });
    try std.testing.expectError(error.MissingPublishedPreflightPin, pinned(c, "build.zig.zon"));
    const malformed = (try std.json.parseFromSlice(src.Value, a, "{\"compile_once\":\"true\"}", .{})).value;
    try std.testing.expectError(error.InvalidWorkflowBoolean, render(a, malformed, first_pin, ".", false));
}

test "caller output refuses symlink files and directories and propagates write failures" {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const FaultIo = @import("shakedown").FaultIo;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const c: src.Context = .{ .a = arena.allocator(), .io = io, .dir = tmp.dir };
    try tmp.dir.writeFile(io, .{ .sub_path = "kept.yml", .data = "kept" });
    try tmp.dir.symLink(io, "kept.yml", "link.yml", .{});
    try std.testing.expectError(error.SymLinkLoop, write(c, "link.yml", "changed"));
    try tmp.dir.createDir(io, "real", .default_dir);
    try tmp.dir.symLink(io, "real", "alias", .{ .is_directory = true });
    const rejected = write(c, "alias/new.yml", "changed");
    if (rejected) |_| return error.AcceptedSymlinkDirectory else |_| {}
    try std.testing.expectEqualStrings("kept", try c.read("kept.yml"));
    const faults = try FaultIo.init(std.testing.allocator, io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .fileWritePositional, .n = 1 } }, .fault = .{ .fail = error.NoSpaceLeft } }} });
    defer faults.deinit();
    const faulted: src.Context = .{ .a = c.a, .io = faults.io(), .dir = tmp.dir };
    try std.testing.expectError(error.WriteFailed, write(faulted, "new.yml", "changed"));
    try std.testing.expectEqual(@as(u64, 1), faults.count(.fileWritePositional));
}

fn allocationRender(a: std.mem.Allocator) !void {
    const parsed = try std.json.parseFromSlice(src.Value, a, "{\"compile_once\":true,\"targets\":[\"x86_64-macos\"],\"shards\":{\"windows\":2}}", .{});
    defer parsed.deinit();
    // Rendering uses an arena by contract. Exercise each allocation in the
    // arena's growth, and verify its error cleanup against the leak checker.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const output = try render(arena.allocator(), parsed.value, "9af905ed85cab6dbb19d9431c65ee3f41fbaa74d", ".", false);
    try std.testing.expect(std.mem.find(u8, output, "merge-compile-matrix") != null);
}

test "caller generation survives every allocation failure without resizing its backing storage" {
    const alloc = @import("shakedown").alloc;
    var no_resize: alloc.NoResize = .init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), allocationRender, .{});
}
