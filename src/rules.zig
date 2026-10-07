//! Family policies imported by a package's ci/layers.zig. Compose only the
//! policies that apply: airlock owns raw durability calls; packages that
//! permit async spawning leave out no_async. Test support is always test-only.
const gantry = @import("gantry");

/// Durable writes go through airlock. Adopt everywhere outside airlock.
pub const durability = [_]gantry.rules.TokenRule{.{
    .name = "durability belongs to airlock",
    .sequences = &.{
        &.{ ".", "sync", "(" },
        &.{ ".", "syncFile", "(" },
        &.{ ".", "syncDir", "(" },
        &.{ "createFileAtomic", "(" },
        &.{ "fsync", "(" },
        &.{ "fdatasync", "(" },
        &.{ "FlushFileBuffers", "(" },
    },
}};

/// Test doubles cannot be imported by a production build. Gantry's test
/// context includes test-only declarations and configured test paths.
pub const shakedown = [_]gantry.rules.ReferenceRule{.{
    .name = "shakedown is test support",
    .target = "shakedown",
    .kind = .import,
}};

/// Adopt in packages whose callers own asynchronous work.
pub const no_async = [_]gantry.rules.TokenRule{.{
    .name = "async belongs to the caller",
    .sequences = &.{&.{ "io", ".", "async", "(" }},
}};

test {
    _ = @import("rules_test.zig");
}
