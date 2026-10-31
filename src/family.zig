//! The family's policy, which a project opts into with `"policy": "family"` in
//! `ci/preflight.json`. Under it preflight holds the project to the family's bar: the
//! hardened profile on shakedown's quarantine, rules only raised, ReleaseSafe releases,
//! bay's CHANGELOG and shakedown's benchmark comparison. Without it preflight adapts to
//! what the project has, as a stranger's tool does.
const std = @import("std");

pub const Policy = enum { adapt, family };

/// The key of `ci/preflight.json` that names the policy.
pub const key = "policy";

/// The refusal of a value that names no policy, for the command to report.
pub const refusal = "policy: the one policy is \"family\" (`\"policy\": \"family\"` in ci/preflight.json); without the key preflight adapts to the project";

/// The policy `value` names: none when it is absent, else `family`. Anything else is
/// refused, so a misspelt policy can't quietly hold a project to none.
pub fn of(value: std.json.Value) error{UnknownPolicy}!Policy {
    return switch (value) {
        .null => .adapt,
        .string => |name| if (std.mem.eql(u8, name, "family")) .family else error.UnknownPolicy,
        else => error.UnknownPolicy,
    };
}

test "no policy adapts, `family` is the family's, and anything else is refused" {
    try std.testing.expectEqual(Policy.adapt, try of(.null));
    try std.testing.expectEqual(Policy.family, try of(.{ .string = "family" }));
    try std.testing.expectError(error.UnknownPolicy, of(.{ .string = "famliy" }));
    try std.testing.expectError(error.UnknownPolicy, of(.{ .bool = true }));
}
