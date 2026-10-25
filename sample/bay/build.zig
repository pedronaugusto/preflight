//! A project outside preflight's package family, developed with bay: aegis is
//! what it ships with, and preflight and shakedown are its development tools.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    _ = b.addModule("bay_sample", .{
        .root_source_file = b.path("src/backoff.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "aegis", .module = aegis.module("aegis") }},
    });
}

/// The tests, the module's own and those on shakedown, under preflight's gate.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // The package in a second configuration, only built, as a family package builds its
    // variants: a dependency instance of its own over the same files, made first.
    const variant = b.dependency("bay_sample", .{ .target = target, .optimize = .small });
    const small = b.addObject(.{ .name = "bay_sample_small", .root_module = variant.module("bay_sample") });
    const package = b.dependency("bay_sample", .{ .target = target, .optimize = optimize });
    const module = package.module("bay_sample");
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize }).module("shakedown");
    const step = b.step("test", "Run the tests");
    step.dependOn(&small.step);
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = package.path("src/backoff_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "bay_sample", .module = module }, .{ .name = "shakedown", .module = shakedown } },
    }) })).step);
    tools.preflight.addCi(b, package.builder, .{ .tests = step });
}
