//! Hosted setup deadlines and the generated caller's contract.
const std = @import("std");
const builtin = @import("builtin");
const root = @import("test_options").root;
const matrix = @import("matrix.zig");
const heldgit = @import("heldgit.zig");

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

/// The first tools attempt's deadline: a build's on a tools-cache miss, a setup's on a hit.
const first_attempt = "${{ steps.setup.outputs.tools-hit == 'true' && 5 || 30 }}";

fn contains(text: []const u8, expected: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, text, expected) != null);
}

test "hosted tool setup retries failures and step timeouts at most three times" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try read(arena.allocator(), ".github/workflows/zig.yml");
    for ([_][]const u8{ "gate", "master" }) |name| {
        const body = try job(text, name);
        for (1..4) |attempt| {
            const marker = try arena.allocator().print("        id: tools{d}\n", .{attempt});
            const start = std.mem.find(u8, body, marker) orelse return error.MissingSetupAttempt;
            const end = std.mem.findPos(u8, body, start, "      - ") orelse body.len;
            const step = body[start..end];
            // On a tools-cache miss the setup step builds the tools: the first attempt has a
            // build's deadline then, never a setup's.
            try contains(step, if (attempt == 1) "        timeout-minutes: " ++ first_attempt ++ "\n" else "        timeout-minutes: 5\n");
            try contains(step, " prepare\n");
            // The last attempt's failure is the job's, but for Zig master's, which never fails.
            const advisory = std.mem.eql(u8, name, "master");
            try std.testing.expectEqual(attempt < 3 or advisory, std.mem.find(u8, step, "continue-on-error: true") != null);
            if (attempt > 1) {
                try contains(step, try arena.allocator().print("if: ${{{{ !cancelled() && steps.tools{d}.outcome == 'failure' }}}}", .{attempt - 1}));
            } else if (std.mem.eql(u8, name, "gate")) {
                try contains(step, "if: matrix.setup");
            } else try contains(step, "if: steps.setup.outcome == 'success'");
        }
        try std.testing.expect(std.mem.find(u8, body, "id: tools4") == null);
        try contains(body, "      - uses: ./.preflight/.github/actions/setup\n        id: setup\n");
        try contains(body, "PREFLIGHT_PREPARED: 'true'");
        // A cold build of the held git takes longer than tools alone: it has a step and a
        // deadline of its own, once, before the attempts.
        if (std.mem.find(u8, body, "      - name: Hold the package's git\n")) |start| {
            const step = body[start .. std.mem.findPos(u8, body, start + 1, "      - ") orelse body.len];
            try contains(step, "        timeout-minutes: 30\n");
            try contains(step, " --held-git\n");
            try std.testing.expect(start < std.mem.find(u8, body, "id: tools1").?);
        }
    }
}

test "a guest leg's QEMU install ends a stalled download by apt's deadlines, with room for a slow mirror" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try job(try read(arena.allocator(), ".github/workflows/zig.yml"), "gate");
    for ([_][]const u8{ "riscv64 system emulation", "x86_64 system emulation and open KVM" }) |name| {
        const start = std.mem.find(u8, body, try arena.allocator().print("      - name: Install QEMU's {s}\n", .{name})) orelse return error.MissingInstall;
        const step = body[start .. std.mem.findPos(u8, body, start + 1, "      - ") orelse body.len];
        try contains(step, "        timeout-minutes: 15\n");
        try contains(step, "-o Acquire::Retries=3 -o Acquire::http::Timeout=60 -o Acquire::https::Timeout=60");
        try contains(step, "sudo apt-get $apt update\n");
        try contains(step, "sudo apt-get $apt install -y --no-install-recommends ");
    }
}

test "a run stops before it builds when the package pins another preflight than its caller runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try job(try read(arena.allocator(), ".github/workflows/zig.yml"), "toolchain");
    const toolchain = std.mem.find(u8, body, "- uses: ./.preflight/.github/actions/toolchain") orelse return error.TestExpectedToolchain;
    const check = std.mem.find(u8, body, "preflight pin --ref ${{ inputs.preflight-ref }}\n") orelse return error.TestExpectedPinCheck;
    const upload = std.mem.find(u8, body, "- uses: actions/upload-artifact@") orelse return error.TestExpectedUpload;
    try std.testing.expect(toolchain < check and check < upload);
}

test "the Zig master leg has bay on the path before its setup fetches through it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try job(try read(arena.allocator(), ".github/workflows/zig.yml"), "master");
    // The setup's fetch configures the package's build, `bay dev` for a
    // package bay develops; without bay it fails to start (`FileNotFound`).
    const bay = std.mem.find(u8, body, "- name: Take bay from the toolchain") orelse return error.TestExpectedBay;
    const setup = std.mem.find(u8, body, "- uses: ./.preflight/.github/actions/setup") orelse return error.TestExpectedSetup;
    try std.testing.expect(bay < setup);
}

/// The one rule of a non-blocking job, Zig master's and a declared advisory job's alike: the job
/// ends "success" whatever its steps did, as a job-level continue-on-error does not in a called
/// workflow, whose run it concludes "failure", which a release refuses. Every step continues on
/// error (`flag`: always, or where the job is advisory) and has a budget, so none stalls into the
/// job's bound; a failing setup skips what needs it; the suite runs on tools that passed; and the
/// shared report, the last step, always names the suite's outcome.
fn nonBlocking(a: std.mem.Allocator, body: []const u8, flag: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, body, "\n    continue-on-error:") == null);
    const continues = try a.print("\n        continue-on-error: {s}\n", .{flag});
    var steps = std.mem.splitSequence(u8, body, "\n      - ");
    _ = steps.next(); // the job's own keys
    var count: usize = 0;
    while (steps.next()) |step| {
        count += 1;
        const continued = std.mem.find(u8, step, continues) != null or std.mem.find(u8, step, "\n        continue-on-error: true\n") != null;
        if (!continued or std.mem.find(u8, step, "\n        timeout-minutes: ") == null) {
            std.debug.print("a step of a non-blocking job can fail it, or stall into its bound:\n{s}\n", .{step});
            return error.TestStepCanFailTheJob;
        }
    }
    try std.testing.expect(count >= 10);
    try contains(body, "steps.setup.outcome == 'success'");
    try contains(body, "steps.tools1.outcome == 'success' || steps.tools2.outcome == 'success' || steps.tools3.outcome == 'success'");
    const report = body[std.mem.find(u8, body, "      - name: Report\n        uses: ./.preflight/.github/actions/advisory-report\n") orelse return error.TestExpectedReport ..];
    try std.testing.expect(std.mem.find(u8, report[1..], "\n      - ") == null);
    try contains(report, "        outcome: ${{ steps.suite.outcome }}\n");
}

test "the Zig master job never fails: every step that can fail continues, a step needing another runs only where it passed, and the report warns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try job(try read(arena.allocator(), ".github/workflows/zig.yml"), "master");
    try nonBlocking(arena.allocator(), body, "true");
    try contains(body, "        if: steps.package.outcome == 'success' && steps.preflight.outcome == 'success' && steps.bay.outcome == 'success'\n");
    try contains(body, "        if: steps.setup.outcome == 'success'\n");
    try contains(body, "      - name: Report\n        uses: ./.preflight/.github/actions/advisory-report\n        timeout-minutes: 1\n        if: always()\n");
}

test "a declared advisory job is non-blocking by Zig master's rule, and its budgets fit the plan's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try job(try read(a, ".github/workflows/zig.yml"), "gate");
    try nonBlocking(a, body, "${{ matrix.advisory == true }}");
    try contains(body, "      - name: Report\n        uses: ./.preflight/.github/actions/advisory-report\n        if: always() && matrix.advisory == true\n");
    // The run has the plan's run_timeout; the steps that can run on a declared job but it --
    // none a machine's or a fuzz step's -- total the plan's advisory_overhead_minutes, so the
    // job's bound (run_timeout and that) is never met first.
    try contains(body, "      - name: Run the gate\n        id: suite\n");
    try contains(body, "        timeout-minutes: ${{ matrix.run_timeout || 360 }}\n");
    var total: usize = 0;
    var steps = std.mem.splitSequence(u8, body, "\n      - ");
    _ = steps.next();
    while (steps.next()) |step| {
        if (std.mem.startsWith(u8, step, "name: Run the gate\n")) continue;
        if (std.mem.find(u8, step, "matrix.machine ==") != null or std.mem.find(u8, step, "matrix.step ==") != null) continue;
        const at = (std.mem.find(u8, step, "\n        timeout-minutes: ") orelse return error.TestExpectedBudget) + 26;
        const value = step[at .. std.mem.findScalarPos(u8, step, at, '\n') orelse step.len];
        total += if (std.mem.eql(u8, value, first_attempt)) 30 else try std.fmt.parseInt(usize, value, 10);
    }
    try std.testing.expectEqual(matrix.advisory_overhead_minutes, total);
}

test "a failing advisory job leaves the run green, its outcome in the summary and a warning on the run" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The report's own script, run as the job runs it, for a suite that failed and one that passed.
    const action = try read(a, ".github/actions/advisory-report/action.yml");
    const begin = (std.mem.find(u8, action, "      run: |\n") orelse return error.TestExpectedScript) + 13;
    var script: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, action[begin..], '\n');
    while (lines.next()) |line| {
        if (line.len != 0 and !std.mem.startsWith(u8, line, "        ")) break;
        try script.appendSlice(a, if (line.len >= 8) line[8..] else line);
        try script.append(a, '\n');
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const summary = try std.Io.Dir.path.join(a, &.{ try tmp.dir.realPathFileAlloc(std.testing.io, ".", a), "summary.md" });
    for ([_][]const u8{ "failure", "success" }) |outcome| {
        var environ: std.process.Environ.Map = .init(a);
        try environ.put("PATH", "/usr/bin:/bin");
        try environ.put("GITHUB_STEP_SUMMARY", summary);
        try environ.put("TITLE", "git master: head, non-blocking");
        try environ.put("OUTCOME", outcome);
        try environ.put("STEPS", "setup success, tool setup success");
        try environ.put("NOTE", "");
        const ran = try std.process.run(a, std.testing.io, .{ .argv = &.{ "/bin/bash", "-c", script.items }, .environ_map = &environ });
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, ran.term);
        const warned = std.mem.find(u8, ran.stdout, "::warning title=git master%3A head%2C non-blocking::Zig ") != null;
        try std.testing.expectEqual(std.mem.eql(u8, outcome, "failure"), warned);
        if (warned) try contains(ran.stdout, ": the suite did not pass (setup success, tool setup success, suite failure)\n");
    }
    const written = try tmp.dir.readFileAlloc(std.testing.io, "summary.md", a, .limited(4096));
    try contains(written, "git master: head, non-blocking, Zig ");
    try contains(written, ": setup success, tool setup success, suite failure (non-blocking)\n");
    try contains(written, ": setup success, tool setup success, suite success (non-blocking)\n");
}

test "hosted advisory deadlines expire before the job can cancel the run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try job(try read(arena.allocator(), ".github/workflows/zig.yml"), "master");
    // A held git's build (30 minutes) raises the bound by as much, and only for a package
    // that names one.
    try contains(body, "    timeout-minutes: ${{ inputs.held-git != '' && 135 || 105 }}\n");
    var total: usize = 0;
    var steps: usize = 0;
    var deadlines: usize = 0;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "      - ")) steps += 1;
        if (std.mem.startsWith(u8, line, "        timeout-minutes: ")) {
            deadlines += 1;
            const value = line[25..];
            if (std.mem.startsWith(u8, value, "${{")) {
                try std.testing.expectEqualStrings(first_attempt, value);
                total += 30;
            } else total += try std.fmt.parseInt(usize, value, 10);
        }
    }
    try std.testing.expectEqual(steps, deadlines);
    // The held git's 30 minutes apart, the steps fit the bound of a package without one.
    try std.testing.expect(total - 30 < 105);
    try std.testing.expect(total < 135);
    try contains(body, "        if: always()\n");
    try contains(body, "steps.suite.outcome");
    const workflow = try read(arena.allocator(), ".github/workflows/zig.yml");
    for ([_][]const u8{ "toolchain", "profile", "runners" }) |name| {
        try std.testing.expect(std.mem.find(u8, try job(workflow, name), "\n    continue-on-error:") == null);
    }
    // The gate's jobs carry no job-level continue-on-error: a declared advisory job's steps
    // continue instead (`nonBlocking`).
    try std.testing.expect(std.mem.find(u8, try job(workflow, "gate"), "\n    continue-on-error:") == null);
    // Publishing the blocking gate's proof never depends on master.
    try contains(try job(workflow, "profile"), "needs: [toolchain, gate]");
}

test "generated caller uses the shared gate and exactly the planned matrices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const caller = try read(a, ".github/workflows/ci.yml");
    try contains(caller, "uses: ./.github/workflows/zig.yml");
    try contains(caller, "preflight-ref: ${{ github.sha }}");
    try contains(caller, "working-directory: \"sample\"");
    var config = (try std.json.parseFromSlice(std.json.Value, a, try read(a, "sample/ci/workflow.json"), .{})).value;
    // `plan` reads the macOS targets that link a framework from the sample's build (none
    // does), and whether it has the fuzz job's step: it has, as it declares shakedown.
    try config.object.put(a, "sdk_targets", .{ .array = .init(a) });
    try config.object.put(a, "fuzzed", .{ .bool = true });
    // The plan is sized by what the sample's last runs measured, as the caller was made
    // (`configuration` reads `costs.json` and `durations.json` beside it).
    try config.object.put(a, "measured", (try std.json.parseFromSlice(std.json.Value, a, try read(a, "sample/ci/costs.json"), .{})).value);
    if (read(a, "sample/ci/durations.json")) |text| {
        try config.object.put(a, "durations", (try std.json.parseFromSlice(std.json.Value, a, text, .{})).value);
    } else |err| if (err != error.FileNotFound) return err;
    try std.testing.expectEqual(@as(usize, 1), (try matrix.plan(a, config, .fuzz)).len);
    for (std.enums.values(matrix.Tier)) |tier| {
        try contains(caller, try a.print("      {t}-matrix: >-\n        {s}\n", .{ tier, try matrix.include(a, try matrix.plan(a, config, tier)) }));
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
        \\    b.step("ci-setup", "setup").dependOn(attempt(b, "x"));
        \\    b.step("before", "before tests").dependOn(attempt(b, "b"));
        \\    _ = b.step("probe", "the suite");
        \\}
        \\fn attempt(b: *std.Build, label: []const u8) *std.Build.Step {
        \\    const command = b.addSystemCommand(&.{ b.graph.zig_exe, "run" });
        \\    command.addFileArg(b.path("attempt.zig"));
        \\    command.addArgs(&.{ "--", label });
        \\    command.setCwd(b.path("."));
        \\    command.has_side_effects = true;
        \\    return &command.step;
        \\}
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "attempt.zig", .data =
        \\const std = @import("std");
        \\pub fn main(init: std.process.Init) !void {
        \\    const args = try init.minimal.args.toSlice(init.arena.allocator());
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
    // The cache every fixture's build shares (integration.zig), so the gate it builds is not
    // compiled again from nothing; the global cache stays the one the run has.
    try std.Io.Dir.cwd().createDirPath(io, try std.Io.Dir.path.join(a, &.{ root, ".zig-cache", "fixtures" }));
    const cache = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.Io.Dir.path.join(a, &.{ root, ".zig-cache", "fixtures" }), a);
    try env.put("ZIG_LOCAL_CACHE_DIR", cache);
    try env.put("STEP", "probe");
    try env.put("BUILD_ARGS", "");
    try env.put("PREFLIGHT_SETUP", "true");
    try env.put("PREFLIGHT_PREPARED", "true");
    const failed = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "--build-file", build_file, repo_arg, "prepare" }, .environ_map = &env });
    try std.testing.expect(failed.term == .exited and failed.term.exited != 0);
    const attempts = tmp.dir.readFileAlloc(io, "attempts", a, .limited(32)) catch |err| {
        std.debug.print("{s}", .{failed.stderr});
        return err;
    };
    try std.testing.expectEqualStrings("x", attempts);
    const prepared = try std.process.run(a, io, .{ .argv = &.{ "zig", "build", "--build-file", build_file, repo_arg, "run" }, .environ_map = &env });
    if (prepared.term != .exited or prepared.term.exited != 0) std.debug.print("{s}", .{prepared.stderr});
    try std.testing.expect(prepared.term == .exited and prepared.term.exited == 0);
    try std.testing.expectEqualStrings("xb", try tmp.dir.readFileAlloc(io, "attempts", a, .limited(32)));
}

test "the gate runs the step each planned job names, on the targets it names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body = try job(try read(arena.allocator(), ".github/workflows/zig.yml"), "gate");
    try contains(body, "STEP: ${{ matrix.step }}");
    try contains(body, "PREFLIGHT_TARGETS: ${{ matrix.targets }}");
    try contains(body, "hardened-fuzz");
    try contains(body, "matrix: ${{ fromJSON(inputs.tier == 'full' && inputs.full-matrix || inputs.tier == 'nightly' && inputs.nightly-matrix || inputs.tier == 'fuzz' && inputs.fuzz-matrix || inputs.ci-matrix) }}");
    // Each job keeps its record of what it spent by its name, which the next plan is sized by.
    try contains(body, "PREFLIGHT_NAME: ${{ matrix.name }}");
}

test "one job builds the checks, and the others take them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const workflow = try read(arena.allocator(), ".github/workflows/zig.yml");
    const built = try job(workflow, "toolchain");
    try contains(built, ".github/actions/toolchain");
    try contains(built, "name: toolchain-${{ inputs.preflight-ref }}");
    // The documentation-only filter runs on what that job built.
    try contains(built, "preflight skip");
    const gate = try job(workflow, "gate");
    try contains(gate, "toolchain: toolchain-${{ inputs.preflight-ref }}");
    try contains(gate, "needs:");
    try std.testing.expect(std.mem.find(u8, gate, "build.zig") == null);
    // Zig master builds its own, by the Zig that the checks read.
    try contains(try job(workflow, "master"), "--build-file .preflight/build.zig");
    try std.testing.expect(std.mem.find(u8, try job(workflow, "master"), "toolchain: ") == null);
}

test "toolchain fuzz artifacts follow the configured shared local cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const workflow = try read(arena.allocator(), ".github/workflows/zig.yml");
    const body = try job(workflow, "gate");
    try contains(body, "path: ${{ env.ZIG_LOCAL_CACHE_DIR }}/v");
    try contains(body, "if-no-files-found: error");
}

test "the fuzz job: dispatched alone or in the nightly tier, its corpora cached, its findings and corpora kept, red on a finding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const caller = try read(a, "src/checks/caller.yml");
    try contains(caller, "options: [ci, full, nightly, fuzz]");
    try contains(caller, "fuzz-minutes: ${{ github.event_name == 'workflow_dispatch' && inputs.fuzz-minutes || '' }}");
    const workflow = try read(a, ".github/workflows/zig.yml");
    // A fuzz dispatch for a package with no fuzz job fails at once, saying why.
    try contains(try job(workflow, "tier"), "inputs.tier == 'fuzz' && inputs.fuzz-matrix == '{\"include\":[]}'");
    try contains(try job(workflow, "toolchain"), "contains(fromJSON('[\"ci\",\"full\",\"nightly\",\"fuzz\"]'), inputs.tier)");
    const gate = try job(workflow, "gate");
    try contains(gate, "inputs.tier == 'fuzz' && inputs.fuzz-matrix ||");
    // A dispatch's own minutes: the job holds GitHub's whole limit and the budget ends it.
    try contains(gate, "timeout-minutes: ${{ inputs.tier == 'fuzz' && inputs.fuzz-minutes != '' && 360 || matrix.job_timeout }}");
    try contains(gate, "PREFLIGHT_FUZZ_MINUTES: ${{ inputs.tier == 'fuzz' && inputs.fuzz-minutes || '' }}");
    const store = "${{ matrix.directory || inputs.working-directory }}/.zig-cache/preflight-fuzz/*/";
    // The corpora come back before the gate and are saved after it, whatever it found.
    const restore = std.mem.find(u8, gate, "uses: actions/cache/restore@").?;
    const run = std.mem.find(u8, gate, "run: preflight run").?;
    const save = std.mem.find(u8, gate, "uses: actions/cache/save@").?;
    try std.testing.expect(restore < run and run < save);
    try contains(gate, try a.print("path: {s}cache/f\n", .{store}));
    try contains(gate, "      - name: Save the fuzz corpora\n        if: always() && matrix.step == 'ci-fuzz'\n");
    // Findings, their tapes among them, and the corpora, an input that crashed the fuzzer too.
    try contains(gate, try a.print("            {s}findings\n            {s}cache/f\n", .{ store, store }));
    // The fuzz run times no tests.
    try contains(try job(workflow, "profile"), "inputs.tier != 'fuzz'");
    // A red gate is folded (its test jobs are the gate's), and never the proof: the proof's
    // name needs the gate's success with the rest (relic's run 43621719158 left no records).
    const profile = try job(workflow, "profile");
    try contains(profile, "if: always() && (needs.gate.result == 'success' || needs.gate.result == 'failure') && inputs.tier != 'fuzz'\n");
    try contains(profile, "FINISHED: ${{ needs.gate.result == 'success' }}");
    try contains(profile, "name: ${{ env.FINISHED == 'true' && 'preflight' || 'records' }}-");
}

test "the held git's build is cached by its release, the recipe and the machine, restored before the tools and saved after the tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try read(a, ".github/workflows/zig.yml");
    const key = try a.print("key: preflight-git-${{{{ inputs.held-git }}}}-r{d}-${{{{ runner.os }}}}-${{{{ runner.arch }}}}-", .{heldgit.recipe});
    for ([_][]const u8{ "gate", "master" }) |name| {
        const body = try job(text, name);
        const restore = std.mem.find(u8, body, "- name: Restore the held git") orelse return error.MissingRestore;
        const tools = std.mem.find(u8, body, "id: tools1") orelse return error.MissingSetupAttempt;
        const save = std.mem.find(u8, body, "- name: Save the held git") orelse return error.MissingSave;
        try std.testing.expect(restore < tools and tools < save);
        try std.testing.expectEqual(2, std.mem.count(u8, body, key));
        try std.testing.expect(std.mem.find(u8, body[save..], "steps.held_git.outputs.cache-hit != 'true'") != null);
    }
    const setup = try read(a, ".github/actions/setup/action.yml");
    try contains(setup, "PREFLIGHT_GIT_STORE=${RUNNER_TEMP}/preflight-git");
    try std.testing.expect(std.mem.find(u8, setup, "choco") == null);
}

test "each job of the gate names its token's permissions: every one reads, and the profile job alone writes the record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const workflow = try read(a, ".github/workflows/zig.yml");
    try contains(workflow, "\npermissions: {}\njobs:\n");
    for ([_][]const u8{ "tier", "toolchain", "gate", "master", "profile", "runners" }) |name| try contains(try job(workflow, name), "\n    permissions:");
    try std.testing.expectEqual(1, std.mem.count(u8, workflow, "contents: write"));
    const profile = try job(workflow, "profile");
    try contains(profile, "    permissions:\n      contents: write\n");
    // Only main's full and nightly runs write it; never a pull request's.
    try contains(profile, "RECORD: ${{ github.event_name != 'pull_request' && github.ref == 'refs/heads/main' && (inputs.tier == 'full' || inputs.tier == 'nightly') }}");
    // It folds onto the newest record and appends: never a force push, and a lost race folds again.
    try contains(profile, "git fetch -q --depth=1 origin preflight-durations");
    try contains(profile, "git -C \"$record\" push -q origin HEAD:refs/heads/preflight-durations");
    try std.testing.expect(std.mem.find(u8, profile, "--force") == null and std.mem.find(u8, profile, "push -f") == null);
    // The heavy legs' Zig master is the nightly tier's.
    try contains(try job(workflow, "master"), "if: inputs.tier == 'nightly'");
}
