//! preflight's own source layers, lowest first. Test code is in no layer.
const family = @import("preflight_rules");
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "test runner modules", .patterns = &.{ "src/order.zig", "src/timings.zig", "src/watchdog.zig", "src/rules.zig" } },
    .{ .name = "test runner", .patterns = &.{"src/runner.zig"} },
    .{ .name = "build helper", .patterns = &.{ "src/configure.zig", "src/bench.zig", "src/hardened.zig", "src/record.zig", "src/portable.zig", "src/objects.zig", "src/consumer.zig", "src/build.zig", "src/toolchain_build.zig" } },
    .{ .name = "checks", .patterns = &.{"src/checks/*.zig"} },
    .{ .name = "deprecation codemod", .patterns = &.{ "src/deprecations/*.zig", "src/deprecations.zig" } },
    .{ .name = "configuration validation", .patterns = &.{"src/facts/*.zig"} },
    .{ .name = "configured build facts", .patterns = &.{"src/facts.zig"} },
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
const package_references = [_]gantry.rules.ReferenceRule{.{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
    "std",
    "builtin",
    "gantry",
    "glint",
    "layers",
    "test_options",
    "preflight_default_test_runner",
    "preflight_runner_options",
    "shakedown",
    "preflight_bench_options",
    "facts",
    "preflight_rules",
} }};
pub const references: []const gantry.rules.ReferenceRule = &(package_references ++ family.shakedown);

pub const owned: []const gantry.rules.TokenRule = &(family.durability ++ family.no_async);
