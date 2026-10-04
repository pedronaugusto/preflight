//! Source policy uses Zig's parser, so literals and comments cannot become code.
pub const source = @import("checks/source.zig");
pub const policy = @import("checks/policy.zig");
pub const imports = @import("checks/imports.zig");
pub const docs = @import("checks/docs.zig");
pub const matrix = @import("checks/matrix.zig");
pub const cache = @import("checks/cache.zig");
pub const ziglint = @import("checks/ziglint.zig");
pub const integration = @import("checks/integration.zig");
pub const container = @import("checks/container.zig");
pub const profile = @import("checks/profile.zig");
pub const paths = @import("checks/paths.zig");
pub const attest = @import("checks/attest.zig");

test {
    _ = source;
    _ = policy;
    _ = imports;
    _ = docs;
    _ = matrix;
    _ = cache;
    _ = ziglint;
    _ = integration;
    _ = container;
    _ = profile;
    _ = attest;
    _ = paths;
}
