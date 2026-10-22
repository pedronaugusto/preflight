//! preflight's own source layers, lowest first. Test code is in no layer.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "ZON sources", .patterns = &.{"src/zon.zig"} },
    .{ .name = "supported Zig versions", .patterns = &.{"src/zig_version.zig"} },
    .{ .name = "test runner modules", .patterns = &.{ "src/order.zig", "src/timings.zig", "src/watchdog.zig" } },
    .{ .name = "test runner", .patterns = &.{"src/runner.zig"} },
    .{ .name = "test machine", .patterns = &.{ "src/vm/cpio.zig", "src/vm/guest.zig", "src/vm/host.zig" } },
    .{ .name = "build helper", .patterns = &.{ "src/vm.zig", "src/configure.zig", "src/bench.zig", "src/fuzz.zig", "src/hardened.zig", "src/record.zig", "src/portable.zig", "src/objects.zig", "src/consumer.zig", "src/plain.zig", "src/nested.zig", "src/tool.zig", "src/build.zig" } },
    .{ .name = "checks", .patterns = &.{ "src/checks/*.zig", "src/checks/glint/*.zig" } },
    .{ .name = "deprecation codemod", .patterns = &.{ "src/deprecations/*.zig", "src/deprecations.zig" } },
    .{ .name = "configuration validation", .patterns = &.{"src/facts/*.zig"} },
    .{ .name = "configured build facts", .patterns = &.{"src/facts.zig"} },
    .{ .name = "structure rules", .patterns = &.{"src/structure/check.zig"} },
    .{ .name = "command line", .patterns = &.{"src/cli.zig"} },
    .{ .name = "check index", .patterns = &.{"src/checks.zig"} },
    .{ .name = "structure runner", .patterns = &.{ "src/structure.zig", "src/layers_default.zig" } },
    .{ .name = "commands", .patterns = &.{"src/main.zig"} },
};
pub const required = [_][]const u8{ "src/main.zig", "src/structure.zig", "src/build.zig", "src/runner.zig", "src/order.zig", "src/timings.zig", "src/watchdog.zig" };
/// Roots a build compiles; nothing imports them.
pub const entries: []const []const u8 = &.{ "src/structure.zig", "src/build.zig", "src/runner.zig", "src/layers_default.zig", "src/vm/guest.zig", "src/vm/host.zig" };
/// The modules the build helper injects into a package's test binaries.
pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "preflight_order", .path = "src/order.zig" },
    .{ .name = "preflight_timings", .path = "src/timings.zig" },
    .{ .name = "preflight_watchdog", .path = "src/watchdog.zig" },
    .{ .name = "checks", .path = "src/checks.zig" },
    .{ .name = "facts", .path = "src/facts.zig" },
};
const package_references = [_]gantry.rules.ReferenceRule{.{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
    "std",
    "builtin",
    "gantry",
    "gantry.zig",
    "glint",
    "ensign",
    "changelog",
    "layers",
    "test_options",
    "preflight_default_test_runner",
    "preflight_runner_options",
    "preflight_quarantine",
    "shakedown",
    "preflight_bench_options",
    "facts",
} }};
pub const references: []const gantry.rules.ReferenceRule = &package_references;

/// preflight's callers own asynchronous work. (Durability is airlock's, held by the
/// default policy's P006 in every package.)
pub const owned: []const gantry.rules.TokenRule = &.{
    .{ .name = "async belongs to the caller", .sequences = &.{&.{ "io", ".", "async", "(" }} },
};
