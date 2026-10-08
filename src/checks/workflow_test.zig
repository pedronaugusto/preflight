//! Hosted setup deadlines and the generated caller's contract.
const std = @import("std");
const root = @import("test_options").root;
const matrix = @import("matrix.zig");

fn read(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.Io.Dir.path.join(a, &.{ root, path }), a, .limited(1024 * 1024));
}

fn job(text: []const u8, name: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var start: ?usize = null;
    var offset: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "  ") and line.len > 2 and line[2] != ' ' and std.mem.endsWith(u8, line, ":")) {
            if (start) |begin| return text[begin..offset];
            if (std.mem.eql(u8, line[2 .. line.len - 1], name)) start = offset;
        }
        offset += line.len + 1;
    }
    return text[start orelse return error.MissingJob ..];
}

fn contains(text: []const u8, expected: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, text, expected) != null);
}

test "hosted tool setup retries failures and step timeouts at most three times" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try read(arena.allocator(), ".github/workflows/zig.yml");
    for ([_][]const u8{ "fast", "gate", "master", "execute" }) |name| {
        const body = try job(text, name);
        for (1..4) |attempt| {
            const marker = try arena.allocator().print("        id: tools{d}\n", .{attempt});
            const start = std.mem.find(u8, body, marker) orelse return error.MissingSetupAttempt;
            const end = std.mem.findPos(u8, body, start, "      - ") orelse body.len;
            const step = body[start..end];
            try contains(step, "        timeout-minutes: 5\n");
            try contains(step, " prepare\n");
            try std.testing.expectEqual(attempt < 3, std.mem.find(u8, step, "continue-on-error: true") != null);
            if (attempt > 1) {
                try contains(step, try arena.allocator().print("if: ${{{{ !cancelled() && steps.tools{d}.outcome == 'failure' }}}}", .{attempt - 1}));
            } else if (std.mem.eql(u8, name, "gate") or std.mem.eql(u8, name, "execute")) {
                try contains(step, "if: matrix.setup");
            }
        }
        try std.testing.expect(std.mem.find(u8, body, "id: tools4") == null);
        try contains(body, "PREFLIGHT_PREPARED: 'true'");
    }
}

test "hosted advisory deadlines expire before the job can cancel the run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try job(try read(arena.allocator(), ".github/workflows/zig.yml"), "master");
    try contains(body, "    continue-on-error: true\n");
    try contains(body, "    timeout-minutes: 60\n");
    var total: usize = 0;
    var steps: usize = 0;
    var deadlines: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "      - ")) steps += 1;
        if (std.mem.startsWith(u8, line, "        timeout-minutes: ")) {
            deadlines += 1;
            total += try std.fmt.parseInt(usize, line[25..], 10);
        }
    }
    try std.testing.expectEqual(steps, deadlines);
    try std.testing.expect(total < 60);
    try contains(body, "        if: always()\n");
    try contains(body, "steps.suite.outcome");
    const workflow = try read(arena.allocator(), ".github/workflows/zig.yml");
    for ([_][]const u8{ "fast", "gate", "compile", "execute" }) |name| {
        try std.testing.expect(std.mem.find(u8, try job(workflow, name), "\n    continue-on-error:") == null);
    }
    // Publishing the blocking gate's proof never depends on master.
    try contains(try job(workflow, "profile"), "needs: [gate, compile, execute]");
}

test "generated caller uses the shared gate and exactly the planned matrices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const caller = try read(a, ".github/workflows/ci.yml");
    try contains(caller, "uses: ./.github/workflows/zig.yml");
    try contains(caller, "preflight-ref: ${{ github.sha }}");
    const config = (try std.json.parseFromSlice(std.json.Value, a, try read(a, "sample/ci/workflow.json"), .{})).value;
    for ([_]matrix.Tier{ .fast, .merge, .release }) |tier| {
        const tiers = try matrix.split(a, config, try matrix.plan(a, config, tier), tier);
        const groups = [_][]const matrix.Job{ tiers.native, tiers.compile, tiers.run };
        for (groups, [_][]const u8{ "", "-compile", "-run" }) |group, suffix| {
            if (tier == .fast and suffix.len != 0) continue;
            try contains(caller, try a.print("      {t}{s}-matrix: >-\n        {s}\n", .{
                tier, suffix, try std.json.Stringify.valueAlloc(a, .{ .include = group }, .{}),
            }));
        }
    }
}

test "hosted prepare makes one attempt and a prepared gate keeps before-tests without repeating setup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "ci", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "ci/workflow.json", .data = "{\"setup_step\":\"ci-setup\",\"before_tests_step\":\"before\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    b.step("ci-setup", "setup").dependOn(&b.addSystemCommand(&.{ "zig", "run", "attempt.zig", "--", "x" }).step);
        \\    b.step("before", "before tests").dependOn(&b.addSystemCommand(&.{ "zig", "run", "attempt.zig", "--", "b" }).step);
        \\    _ = b.step("probe", "the suite");
        \\}
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "attempt.zig", .data =
        \\const std = @import("std");
        \\pub fn main(init: std.process.Init) !void {
        \\    const args = try init.minimal.args.toSlice(init.gpa);
        \\    defer init.gpa.free(args);
        \\    const file = try std.Io.Dir.cwd().createFile(init.io, "attempts", .{ .truncate = false, .read = true });
        \\    defer file.close(init.io);
        \\    var buffer: [32]u8 = undefined;
        \\    var writer = file.writer(init.io, &buffer);
        \\    writer.pos = (try file.stat(init.io)).size;
        \\    try writer.interface.writeAll(args[1]);
        \\    try writer.interface.flush();
        \\    if (std.mem.eql(u8, args[1], "x")) return error.SetupFailed;
        \\}
        \\
    });
    const build_file = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.Io.Dir.path.join(a, &.{ root, "build.zig" }), a);
    const fixture_root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const repo_arg = try a.print("-Drepo-root={s}", .{fixture_root});
    var env = try std.testing.environ.createMap(a);
    defer env.deinit();
    try env.put("STEP", "probe");
    try env.put("BUILD_ARGS", "");
    try env.put("PREFLIGHT_SETUP", "true");
    try env.put("PREFLIGHT_PREPARED", "true");
    const failed = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "--build-file", build_file, repo_arg, "prepare" }, .environ_map = &env });
    try std.testing.expect(failed.term == .exited and failed.term.exited != 0);
    try std.testing.expectEqualStrings("x", try tmp.dir.readFileAlloc(io, "attempts", a, .limited(32)));
    const prepared = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "--build-file", build_file, repo_arg, "run" }, .environ_map = &env });
    if (prepared.term != .exited or prepared.term.exited != 0) std.debug.print("{s}", .{prepared.stderr});
    try std.testing.expect(prepared.term == .exited and prepared.term.exited == 0);
    try std.testing.expectEqualStrings("xb", try tmp.dir.readFileAlloc(io, "attempts", a, .limited(32)));
}
