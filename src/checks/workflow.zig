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

/// The jobs of an earlier caller that its generator wrote, and so may go.
const generated_jobs = [_][]const u8{ "gate", "land", "checks", "skip" };

/// The last job `keepsEveryJob` refused to drop, for the command to name.
pub var undeclared: []const u8 = "";

/// Refuses to replace `existing` while it holds a job `generated` does not: the
/// generator owns the whole caller, and a package's own job is declared in
/// `ci/workflow.json` `jobs`, so it is rendered with the gate and a landing
/// waits for it. Nothing is dropped unseen.
pub fn keepsEveryJob(existing: []const u8, generated: []const u8) !void {
    var missing = false;
    var in_jobs = false;
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        if (line.len > 0 and line[0] != ' ' and line[0] != '#') {
            in_jobs = std.mem.eql(u8, std.mem.trimEnd(u8, line, " \r"), "jobs:");
            continue;
        }
        if (!in_jobs) continue;
        const name = jobKey(line) orelse continue;
        var known = false;
        for (generated_jobs) |job| known = known or std.mem.eql(u8, job, name);
        if (known) continue;
        if (hasJob(generated, name)) continue;
        undeclared = name;
        missing = true;
    }
    if (missing) return error.UndeclaredCallerJob;
}

/// Whether `caller` opens a job named `name`.
fn hasJob(caller: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, caller, '\n');
    while (lines.next()) |line| if (jobKey(line)) |key| if (std.mem.eql(u8, key, name)) return true;
    return false;
}

/// The job a line opens: `  name:` and nothing else but a comment.
fn jobKey(line: []const u8) ?[]const u8 {
    if (line.len < 4 or line[0] != ' ' or line[1] != ' ' or line[2] == ' ' or line[2] == '#') return null;
    const colon = std.mem.findScalar(u8, line, ':') orelse return null;
    const rest = std.mem.trim(u8, line[colon + 1 ..], " \r");
    if (rest.len != 0 and rest[0] != '#') return null;
    return line[2..colon];
}

const default_cron = "23 3 * * *";

/// The triggers `ci/workflow.json` asks for beyond the dispatch and the pull request.
const Triggers = struct { push: []const u8, schedule: []const u8, nightly_tier: []const u8 };

/// `attest` adds the push trigger on main that checks the commit's recorded merge or release run;
/// `nightly` is `false`, or `{ "cron": ..., "tier": ... }` (default: release at 03:23 UTC).
fn triggers(a: std.mem.Allocator, config: src.Value) !Triggers {
    const nightly = src.get(config, "nightly");
    if (nightly != .null and nightly != .bool and nightly != .object) return error.InvalidNightly;
    var cron: []const u8 = default_cron;
    var tier: []const u8 = "release";
    if (nightly == .object) {
        for (nightly.object.keys()) |key| if (!std.mem.eql(u8, key, "cron") and !std.mem.eql(u8, key, "tier")) return error.InvalidNightly;
        cron = src.string(src.get(nightly, "cron"), default_cron);
        tier = src.string(src.get(nightly, "tier"), "release");
        var fields: usize = 0;
        var parts = std.mem.tokenizeScalar(u8, cron, ' ');
        while (parts.next()) |part| : (fields += 1) {
            for (part) |byte| if (!std.ascii.isDigit(byte) and std.mem.findScalar(u8, "*/,-", byte) == null) return error.InvalidNightly;
        }
        if (fields != 5) return error.InvalidNightly;
        if (!std.mem.eql(u8, tier, "fast") and !std.mem.eql(u8, tier, "merge") and !std.mem.eql(u8, tier, "release")) return error.InvalidNightly;
    }
    const off = nightly == .bool and !nightly.bool;
    return .{
        .push = if (std.mem.eql(u8, try boolean(config, "attest"), "true")) "  push:\n    branches: [main]\n" else "",
        .schedule = if (off) "" else try a.print("  schedule:\n    - cron: '{s}'\n", .{cron}),
        .nightly_tier = tier,
    };
}

pub fn render(a: std.mem.Allocator, config: src.Value, pin: []const u8, directory: []const u8, own: bool, workflow: []const u8) ![]const u8 {
    // Every writer in renderAllocating is memory-backed. Its only write
    // failure is allocation exhaustion; preserve the allocator error contract.
    return renderAllocating(a, config, pin, directory, own, workflow) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}

fn renderAllocating(a: std.mem.Allocator, config: src.Value, pin: []const u8, directory: []const u8, own: bool, workflow: []const u8) ![]const u8 {
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
    const gate = if (own) "./.github/workflows/zig.yml" else try a.print("pedronaugusto/preflight/.github/workflows/zig.yml@{s}", .{pin});
    const when = try triggers(a, config);
    const lands = std.mem.eql(u8, try boolean(config, "land"), "true");
    // Only the job that lands writes, and only to move main; it waits for the whole gate.
    const land_input =
        \\      land:
        \\        description: Fast-forward main to this commit when the merge tier passes
        \\        type: boolean
        \\        default: true
        \\
    ;
    const land_job = try a.print(
        \\  land:
        \\    needs: gate
        \\    if: github.event_name == 'workflow_dispatch' && inputs.land && inputs.tier == 'merge' && needs.gate.result == 'success'
        \\    runs-on: ubuntu-latest
        \\    timeout-minutes: 5
        \\    permissions:
        \\      contents: write
        \\    steps:
        \\{s}
        \\
    , .{if (own) "      - uses: actions/checkout@v4\n      - uses: ./.github/actions/land" else try a.print("      - uses: pedronaugusto/preflight/.github/actions/land@{s}", .{pin})});
    const tokens = [_][]const u8{ "@WORKFLOW@", "@GATE@", "@PIN@", "@DIRECTORY@", "@PUSH@", "@SCHEDULE@", "@NIGHTLY@", "@LANDINPUT@", "@LAND@", "@MATRICES@", "@WINDOWS_GIT@", "@COMPILE_ONCE@" };
    const values = [_][]const u8{ workflow, gate, if (own) "${{ github.sha }}" else pin, try std.json.Stringify.valueAlloc(a, directory, .{}), when.push, when.schedule, when.nightly_tier, if (lands) land_input else "", if (lands) land_job else "", matrices.written(), try boolean(config, "windows_git_latest"), try boolean(config, "compile_once") };
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
    try std.testing.expectError(error.InvalidPreflightPin, render(a, config, "main", ".", false, "ci.yml"));
    try std.testing.expectError(error.InvalidWorkflowConfig, render(a, .null, "", ".", false, "ci.yml"));
    try std.testing.expectError(error.InvalidWorkflowPath, render(a, config, "9af905ed85cab6dbb19d9431c65ee3f41fbaa74d", "../escape", false, "ci.yml"));
}

test "caller generation is deterministic with all tier matrices and refreshes its manifest pin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"compile_once\":true,\"targets\":[\"x86_64-macos\",\"aarch64-macos\"],\"shards\":{\"windows\":3}}", .{})).value;
    const first_pin = "9af905ed85cab6dbb19d9431c65ee3f41fbaa74d";
    const next_pin = "76b1366323da4700bc0dcd3e24f2d7c4ee0e0ce9";
    const first = try render(a, config, first_pin, ".", false, "ci.yml");
    try std.testing.expectEqualStrings(first, try render(a, config, first_pin, ".", false, "ci.yml"));
    const second = try render(a, config, next_pin, ".", false, "ci.yml");
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
    try std.testing.expectError(error.InvalidWorkflowBoolean, render(a, malformed, first_pin, ".", false, "ci.yml"));
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
    const output = try render(arena.allocator(), parsed.value, "9af905ed85cab6dbb19d9431c65ee3f41fbaa74d", ".", false, "ci.yml");
    try std.testing.expect(std.mem.find(u8, output, "merge-compile-matrix") != null);
}

test "caller generation survives every allocation failure without resizing its backing storage" {
    const alloc = @import("shakedown").alloc;
    var no_resize: alloc.NoResize = .init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), allocationRender, .{});
}

test "regeneration refuses to drop a job the configuration does not declare, and renders the declared ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pin = "9af905ed85cab6dbb19d9431c65ee3f41fbaa74d";
    const base = try render(a, (try std.json.parseFromSlice(src.Value, a, "{\"land\":true}", .{})).value, pin, ".", false, "ci.yml");
    try keepsEveryJob("", base);
    try keepsEveryJob(base, base);
    // What an earlier generator wrote goes with it.
    try keepsEveryJob(try std.mem.concat(a, u8, &.{ base, "  skip:\n    uses: ./skip.yml\n  checks:\n    runs-on: ubuntu-latest\n" }), base);
    const own = try std.mem.concat(a, u8, &.{ base, "  sizes:  # kept\n    needs: gate\n    runs-on: ubuntu-latest\n" });
    try std.testing.expectError(error.UndeclaredCallerJob, keepsEveryJob(own, base));
    // Declared, the job is a gate job: in the matrices, with no job of its own to keep.
    const declared = try render(a, (try std.json.parseFromSlice(src.Value, a, "{\"land\":true,\"jobs\":[{\"name\":\"sizes\",\"step\":\"check-sizes\"}]}", .{})).value, pin, ".", false, "ci.yml");
    try std.testing.expect(std.mem.find(u8, declared, "\"step\":\"check-sizes\"") != null);
    try std.testing.expectError(error.UndeclaredCallerJob, keepsEveryJob(own, declared));
    try keepsEveryJob(declared, declared);
}

test "a project with nothing set gets pull requests, dispatch and a nightly release run, and no landing or main status run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pin = "9af905ed85cab6dbb19d9431c65ee3f41fbaa74d";
    const plain = try render(a, (try std.json.parseFromSlice(src.Value, a, "{}", .{})).value, pin, ".", false, "ci.yml");
    try std.testing.expect(std.mem.find(u8, plain, "  pull_request:\n") != null);
    try std.testing.expect(std.mem.find(u8, plain, "  push:\n") == null);
    try std.testing.expect(std.mem.find(u8, plain, "- cron: '23 3 * * *'") != null);
    try std.testing.expect(std.mem.find(u8, plain, "&& 'release' || 'merge'") != null);
    // No landing: no input for it, and nothing in the caller may write.
    try std.testing.expect(std.mem.find(u8, plain, "      land:") == null);
    try std.testing.expect(std.mem.find(u8, plain, "  land:") == null);
    try std.testing.expect(std.mem.find(u8, plain, "contents: write") == null);
    const set = try render(a, (try std.json.parseFromSlice(src.Value, a, "{\"land\":true,\"attest\":true,\"nightly\":{\"cron\":\"5 1 * * 0\",\"tier\":\"merge\"}}", .{})).value, pin, ".", false, "ci.yml");
    try std.testing.expect(std.mem.find(u8, set, "  push:\n    branches: [main]\n") != null);
    try std.testing.expect(std.mem.find(u8, set, "- cron: '5 1 * * 0'") != null);
    try std.testing.expect(std.mem.find(u8, set, "&& 'merge' || 'merge'") != null);
    try std.testing.expect(std.mem.find(u8, set, "contents: write") != null);
    try std.testing.expect(std.mem.find(u8, set, "  land:\n    needs: gate\n") != null);
    try std.testing.expect(std.mem.find(u8, set, "uses: pedronaugusto/preflight/.github/actions/land@" ++ pin) != null);
    // The gate itself never writes: the reusable workflow asks for no more than read.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, set, "contents: write"));
    try std.testing.expect(std.mem.find(u8, set, "description: Fast-forward main to this commit when the merge tier passes\n        type: boolean\n        default: true") != null);
    const off = try render(a, (try std.json.parseFromSlice(src.Value, a, "{\"nightly\":false}", .{})).value, pin, ".", false, "ci.yml");
    try std.testing.expect(std.mem.find(u8, off, "schedule:") == null);
    for ([_][]const u8{ "{\"nightly\":{\"cron\":\"daily\"}}", "{\"nightly\":{\"tier\":\"all\"}}", "{\"nightly\":{\"when\":1}}", "{\"nightly\":3}", "{\"land\":\"yes\"}" }) |text| {
        try std.testing.expect(std.meta.isError(render(a, (try std.json.parseFromSlice(src.Value, a, text, .{})).value, pin, ".", false, "ci.yml")));
    }
}
