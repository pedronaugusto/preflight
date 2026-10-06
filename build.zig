const std = @import("std");
const ci = @import("src/build.zig");
pub const addCi = ci.addCi;
pub const Config = ci.Config;
pub const TestTimeout = ci.TestTimeout;
pub const addCheck = ci.addCheck;
pub const addConsumerCheck = ci.consumer.add;
pub const ConsumerOptions = ci.consumer.Options;

pub fn build(b: *std.Build) void {
    const target = ci.ciTarget(b);
    const gantry_dep = b.lazyDependency("gantry", .{ .target = target, .optimize = .Debug }) orelse return;
    const gantry = gantry_dep.module("gantry");
    const test_step = b.step("test", "Run the shared check regression suite");
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/checks.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{.{ .name = "gantry", .module = gantry }},
    }) });
    const options = b.addOptions();
    options.addOption([]const u8, "root", b.pathFromRoot("."));
    tests.root_module.addOptions("test_options", options);
    // The gate below gives the suite preflight's runner, as it does a
    // consumer's tests; the order module the runner imports runs its own
    // tests beside it.
    const suite = b.allocator.create(std.Build.Step) catch @panic("OOM");
    suite.* = .init(.{ .id = .custom, .name = "check suite", .owner = b });
    suite.dependOn(&b.addRunArtifact(tests).step);
    const order = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/order.zig"), .target = target, .optimize = .Debug }) });
    const order_run = b.addRunArtifact(order);
    test_step.dependOn(suite);
    test_step.dependOn(&order_run.step);
    const executable = b.addExecutable(.{ .name = "preflight", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "gantry", .module = gantry }},
    }) });
    b.installArtifact(executable);
    const repo_root = b.option([]const u8, "repo-root", "Repository checked by the hosted runner");
    if (repo_root == null) {
        // preflight gates its own sources with the checks it ships.
        ci.addOwnCi(b, .{ .tests = suite });
        const verify = b.step("verify", "Check format, sources, checker regressions and the hosted runner");
        verify.dependOn(&b.top_level_steps.get("ci").?.step);
        verify.dependOn(&order_run.step);
        verify.dependOn(&b.addFmt(.{ .paths = &.{"."}, .check = true }).step);
        verify.dependOn(&executable.step);
    }
    const root = repo_root orelse ".";
    for ([_][]const u8{ "plan", "setup", "fetch", "run", "cache", "docs", "profile", "attest", "skip", "findings" }) |name| {
        if (b.top_level_steps.contains(name)) continue;
        const command = b.addRunArtifact(executable);
        command.addArg(name);
        command.setCwd(.{ .cwd_relative = root });
        if (b.args) |args| command.addArgs(args);
        b.step(name, name).dependOn(&command.step);
    }
}
