//! `ci-held-git`: the held git `ci/workflow.json` names (`git`), which a hosted job's
//! `preflight prepare` asks for before its tests: Git for Windows' release installed on
//! Windows, else git built from its release tarball into the store with zig cc and the
//! sources preflight pins (zlib, LibreSSL, curl), each fetched only by a build that asks for
//! it. The command (`checks/heldgit.zig`) builds and checks; this passes it the sources.
const std = @import("std");
const configure = @import("configure.zig");
const Tool = @import("tool.zig").Tool;

/// The sources a held git is built from, from `pkg`'s pins; null while they are being fetched.
pub const Sources = struct { zlib: std.Build.LazyPath, libressl: std.Build.LazyPath, curl: std.Build.LazyPath };

pub fn sources(pkg: *std.Build) ?Sources {
    const zlib = pkg.dependencyLazy("held_git_zlib", .{}) catch return null;
    const libressl = pkg.dependencyLazy("held_git_libressl", .{}) catch return null;
    const curl = pkg.dependencyLazy("held_git_curl", .{}) catch return null;
    return .{ .zlib = zlib.path("."), .libressl = libressl.path("."), .curl = curl.path(".") };
}

/// Whether the package's `ci/workflow.json` names a held git; the command reads what it names.
pub fn named(package: *std.Build) bool {
    const text = configure.read(package, "ci/workflow.json", 16 * 1024 * 1024) orelse return false;
    const config = std.json.parseFromSliceLeaky(std.json.Value, package.allocator, text, .{}) catch return false;
    return config == .object and config.object.contains("git");
}

/// A run of `held-git` for `target` (the machine's own when null), given the pinned sources;
/// null while they are being fetched.
pub fn run(b: *std.Build, package: *std.Build, pkg: *std.Build, tool: Tool, target: ?[]const u8) ?*std.Build.Step.Run {
    const command = tool.run(b);
    command.addArgs(&.{ "held-git", "--zig-exe", b.graph.zig_exe, "--config" });
    command.addFileArg(package.path("ci/workflow.json"));
    if (target) |triple| command.addArgs(&.{ "--target", triple });
    // Git for Windows is installed from its release: nothing is built, nothing fetched for it.
    if (target != null or b.graph.host.result.os.tag != .windows) {
        const given = sources(pkg) orelse return null;
        command.addArg("--zlib");
        command.addDirectoryArg2(given.zlib, .{});
        command.addArg("--libressl");
        command.addDirectoryArg2(given.libressl, .{});
        command.addArg("--curl");
        command.addDirectoryArg2(given.curl, .{});
    }
    command.setCwd(package.path("."));
    // The store is the build's cache: a run whose build is kept there is a lookup.
    command.has_side_effects = true;
    return command;
}

/// `ci-held-git`, when the package names a held git.
pub fn add(b: *std.Build, package: *std.Build, pkg: *std.Build, tool: Tool) void {
    const step = configure.claim(b, "ci-held-git", "The held git ci/workflow.json names: Git for Windows' release installed, else git built from its release tarball with zig cc and the pinned sources, put first on a hosted job's path");
    if (!named(package)) {
        step.dependOn(&b.addFail("ci-held-git: ci/workflow.json names no held git; `preflight held-git-pin <version>` names one").step);
        return;
    }
    const command = run(b, package, pkg, tool, null) orelse return;
    step.dependOn(&command.step);
}
