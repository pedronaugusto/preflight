//! preflight's own source layers, lowest first. Test code is in no layer.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "test runner modules", .patterns = &.{ "src/order.zig", "src/timings.zig", "src/watchdog.zig" } },
    .{ .name = "test runner", .patterns = &.{"src/runner.zig"} },
    .{ .name = "build helper", .patterns = &.{ "src/configure.zig", "src/bench.zig", "src/record.zig", "src/portable.zig", "src/consumer.zig", "src/build.zig" } },
    .{ .name = "checks", .patterns = &.{"src/checks/*.zig"} },
    .{ .name = "deprecation codemod", .patterns = &.{ "src/deprecations/*.zig", "src/deprecations.zig" } },
    .{ .name = "structure rules", .patterns = &.{"src/structure/check.zig"} },
    .{ .name = "check index", .patterns = &.{"src/checks.zig"} },
    .{ .name = "structure runner", .patterns = &.{"src/structure.zig"} },
    .{ .name = "commands", .patterns = &.{"src/main.zig"} },
};
pub const required = [_][]const u8{ "src/main.zig", "src/structure.zig", "src/build.zig", "src/runner.zig", "src/order.zig", "src/timings.zig" };
/// Roots a build compiles; nothing imports them.
pub const entries: []const []const u8 = &.{ "src/structure.zig", "src/build.zig", "src/runner.zig" };
/// The modules the build helper injects into a package's test binaries.
pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "preflight_order", .path = "src/order.zig" },
    .{ .name = "preflight_timings", .path = "src/timings.zig" },
};
pub const references: []const gantry.rules.ReferenceRule = &.{.{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
    "std",
    "builtin",
    "gantry",
    "sweep",
    "layers",
    "test_options",
    "preflight_default_test_runner",
    "preflight_runner_options",
    "shakedown",
} }};
