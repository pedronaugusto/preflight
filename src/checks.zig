//! Source policy uses Zig's parser, so literals and comments cannot become code.
pub const source = @import("checks/source.zig");
pub const policy = @import("checks/policy.zig");
pub const imports = @import("checks/imports.zig");
pub const docs = @import("checks/docs.zig");
pub const matrix = @import("checks/matrix.zig");
pub const cache = @import("checks/cache.zig");
pub const ziglint = @import("checks/ziglint.zig");
pub const ledger = @import("checks/ledger.zig");
pub const quality = @import("checks/quality.zig");
pub const integration = @import("checks/integration.zig");
pub const profile = @import("checks/profile.zig");
pub const paths = @import("checks/paths.zig");
pub const attest = @import("checks/attest.zig");
pub const manifest = @import("checks/manifest.zig");
pub const command = @import("checks/command.zig");

test {
    _ = @import("rules.zig");
    _ = @import("structure/check.zig");
    _ = @import("consumer.zig");
    _ = @import("record.zig");
    _ = @import("configure.zig");
    _ = source;
    _ = policy;
    _ = imports;
    _ = docs;
    _ = matrix;
    _ = cache;
    _ = ziglint;
    _ = ledger;
    _ = quality;
    _ = integration;
    _ = profile;
    _ = attest;
    _ = manifest;
    _ = command;
    _ = paths;
    _ = @import("deprecations.zig");
}
