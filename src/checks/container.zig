//! An explicit Linux gate; Docker is never started by the ordinary CI steps.
const std = @import("std");
const src = @import("source.zig");

pub const Options = struct {
    musl: bool = false,
    cgroup: bool = false,
    optimize: ?[]const u8 = null,
    lint: bool = true,
    /// The image preflight ships, used when the package has no `ci/linux.Dockerfile`.
    default_image: ?[]const u8 = null,
};

pub fn options(args: []const []const u8) !Options {
    var result: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--musl")) result.musl = true else if (std.mem.eql(u8, args[i], "--no-lint")) result.lint = false else if (std.mem.eql(u8, args[i], "--default-image")) {
            if (i + 1 == args.len) return error.MissingContainerOption;
            i += 1;
            result.default_image = args[i];
        } else if (std.mem.eql(u8, args[i], "--cgroup") or std.mem.eql(u8, args[i], "--optimize")) {
            if (i + 1 == args.len) return error.MissingContainerOption;
            const key = args[i];
            i += 1;
            if (std.mem.eql(u8, key, "--cgroup")) {
                if (!std.mem.eql(u8, args[i], "true") and !std.mem.eql(u8, args[i], "false")) return error.InvalidCgroupOption;
                result.cgroup = std.mem.eql(u8, args[i], "true");
            } else {
                if (!std.mem.eql(u8, args[i], "Debug") and !std.mem.eql(u8, args[i], "ReleaseSafe") and !std.mem.eql(u8, args[i], "ReleaseFast")) return error.InvalidOptimizeMode;
                result.optimize = args[i];
            }
        } else return error.UnknownContainerOption;
    }
    return result;
}

pub fn run(c: src.Context, config: src.Value, opts: Options) !void {
    const file = try image(c, opts);
    const package = src.string(src.get(config, "package"), "package");
    const tag = try std.fmt.allocPrint(c.a, "{s}-preflight-{s}", .{ package, if (opts.musl) "musl" else "linux" });
    try command(c, &.{ "docker", "build", "--quiet", "--file", file, "--build-arg", "ZIG=0.16.0", "--tag", tag, "ci" });
    const root = try c.directory().realPathFileAlloc(c.io, ".", c.a);
    const volume = try std.fmt.allocPrint(c.a, "{s}:/src", .{root});
    const modes: []const []const u8 = if (opts.optimize) |mode| &.{mode} else &.{ "Debug", "ReleaseSafe" };
    for (modes) |mode| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(c.a, &.{ "docker", "run", "--rm", "--init" });
        if (opts.cgroup) try argv.append(c.a, "--privileged");
        try argv.appendSlice(c.a, &.{ "--volume", volume, "--workdir", "/src", "--env", "HOME=/tmp/preflight-home", "--env", "XDG_CONFIG_HOME=/tmp/preflight-home", tag, "zig", "build", "ci" });
        try argv.append(c.a, try std.fmt.allocPrint(c.a, "-Doptimize={s}", .{mode}));
        if (!opts.lint) try argv.append(c.a, "-Dci-lint=false");
        var timeout = std.mem.tokenizeAny(u8, src.string(src.get(config, "test_timeout"), ""), " \t");
        while (timeout.next()) |arg| try argv.append(c.a, arg);
        try argv.appendSlice(c.a, &.{ "--cache-dir", "/src/.zig-cache/preflight-linux/local", "--global-cache-dir", "/src/.zig-cache/preflight-linux/global" });
        try command(c, argv.items);
    }
}

fn command(c: src.Context, argv: []const []const u8) !void {
    var child = try std.process.spawn(c.io, .{ .argv = argv });
    const term = try child.wait(c.io);
    if (term != .exited or term.exited != 0) return error.ContainerCommandFailed;
}

test "container execution is explicit and rejects invalid modes or missing values" {
    const opts = try options(&.{ "--musl", "--optimize", "ReleaseSafe", "--cgroup", "true", "--no-lint" });
    try std.testing.expect(opts.musl and opts.cgroup and !opts.lint);
    try std.testing.expectEqualStrings("ReleaseSafe", opts.optimize.?);
    try std.testing.expectError(error.MissingContainerOption, options(&.{"--optimize"}));
    try std.testing.expectError(error.InvalidOptimizeMode, options(&.{ "--optimize", "fast" }));
    try std.testing.expectError(error.InvalidCgroupOption, options(&.{ "--cgroup", "yes" }));
}

/// The package's own image, else preflight's glibc image. A musl image is
/// always the package's: preflight ships none.
fn image(c: src.Context, opts: Options) ![]const u8 {
    const own = if (opts.musl) "ci/linux.alpine.Dockerfile" else "ci/linux.Dockerfile";
    if (c.exists(own)) return own;
    if (!opts.musl) if (opts.default_image) |path| return path;
    return error.MissingLinuxImage;
}

test "a package without its own Linux image uses preflight's glibc image" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c: src.Context = .{ .a = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    const opts = try options(&.{ "--default-image", "/preflight/src/checks/linux.Dockerfile" });
    try std.testing.expectEqualStrings("/preflight/src/checks/linux.Dockerfile", try image(c, opts));
    try std.testing.expectError(error.MissingLinuxImage, image(c, .{ .musl = true, .default_image = opts.default_image }));
    try tmp.dir.createDirPath(c.io, "ci");
    try tmp.dir.writeFile(c.io, .{ .sub_path = "ci/linux.Dockerfile", .data = "FROM scratch\n" });
    try std.testing.expectEqualStrings("ci/linux.Dockerfile", try image(c, opts));
    try std.testing.expectError(error.MissingContainerOption, options(&.{"--default-image"}));
}
