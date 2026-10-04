const std = @import("std");
pub const addCi = @import("src/build.zig").addCi;
pub const Config = @import("src/build.zig").Config;

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Run the shared check regression suite");
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/checks.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    const options = b.addOptions();
    options.addOption([]const u8, "root", b.pathFromRoot("."));
    tests.root_module.addOptions("test_options", options);
    const run = b.addRunArtifact(tests);
    test_step.dependOn(&run.step);
    const executable = b.addExecutable(.{ .name = "preflight", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    b.installArtifact(executable);
    const verify = b.step("verify", "Check format, checker regressions and the hosted runner");
    verify.dependOn(test_step);
    verify.dependOn(&b.addFmt(.{ .paths = &.{"."}, .check = true }).step);
    verify.dependOn(&executable.step);
    const root = b.option([]const u8, "repo-root", "Repository checked by the hosted runner") orelse ".";
    for ([_][]const u8{ "plan", "setup", "fetch", "run", "cache", "docs" }) |name| {
        const command = b.addRunArtifact(executable);
        command.addArg(name);
        command.setCwd(.{ .cwd_relative = root });
        if (b.args) |args| command.addArgs(args);
        b.step(name, name).dependOn(&command.step);
    }
}
