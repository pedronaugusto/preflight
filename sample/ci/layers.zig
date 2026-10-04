const gantry = @import("gantry");
pub const layers: []const gantry.rules.Layer = &.{.{ .name = "sample", .patterns = &.{"src/sample.zig"} }};
pub const required = [_][]const u8{"src/sample.zig"};
pub const entries: []const []const u8 = &.{};
pub const modules: []const gantry.NamedModule = &.{};
pub const references: []const gantry.rules.ReferenceRule = &.{.{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{"std"} }};
