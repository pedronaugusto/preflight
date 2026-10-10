//! The source structure a package declares when it has no `ci/layers.zig`:
//! none. Layers, required files, entry points and reference or token rules are
//! the package's to declare; with none declared, the structure check holds the
//! sources to nothing beyond what every package gets.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{};
pub const required = [_][]const u8{};
pub const entries: []const []const u8 = &.{};
pub const modules: []const gantry.NamedModule = &.{};
pub const references: []const gantry.rules.ReferenceRule = &.{};
