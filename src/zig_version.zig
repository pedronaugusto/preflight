//! The Zig versions preflight's adapters over the compiler's internal formats are verified against.
//!
//! Zig's serialized build configuration and its build-system protocol are not a
//! stable API, and the adapters read them through the compiling Zig's own
//! `std.Build.Configuration`, so the compiling and the invoked Zig must be the
//! same build. This file is the one place that says which Zig builds those
//! adapters have been checked on; every other site asks it.
const std = @import("std");
const builtin = @import("builtin");

/// A Zig version with a verified build-system format.
pub const Series = enum {
    /// The 0.17.0 release.
    release_0_17,
    /// Builds of master leading to 0.18.0, `0.18.0-dev.<n>+<hash>`.
    master_0_18,
};

/// What a user is told when their Zig is neither.
pub const supported = "Zig 0.17.0 or a Zig 0.18.0-dev master build";

/// The verified series a Zig version belongs to, or null for any other version.
pub fn series(version: std.SemanticVersion) ?Series {
    if (version.major != 0) return null;
    if (version.minor == 17 and version.patch == 0 and version.pre == null) return .release_0_17;
    if (version.minor == 18 and version.patch == 0) {
        const pre = version.pre orelse return null;
        if (std.mem.startsWith(u8, pre, "dev.")) return .master_0_18;
    }
    return null;
}

/// The series of the Zig this program was compiled with. Compilation against an
/// unverified Zig is allowed (a build script must still run to report it); the
/// adapters refuse to read anything until this succeeds.
pub fn require() error{UnsupportedZigVersion}!Series {
    return series(builtin.zig_version) orelse error.UnsupportedZigVersion;
}

test "the verified series are the 0.17.0 release and 0.18.0 master builds only" {
    try std.testing.expectEqual(Series.release_0_17, series(try std.SemanticVersion.parse("0.17.0")).?);
    try std.testing.expectEqual(Series.master_0_18, series(try std.SemanticVersion.parse("0.18.0-dev.131+41f885830")).?);
    try std.testing.expectEqual(Series.master_0_18, series(try std.SemanticVersion.parse("0.18.0-dev.1+0000000")).?);
    for ([_][]const u8{
        "0.16.0",
        "0.17.1",
        "0.17.0-dev.5+abcdef0",
        "0.18.0",
        "0.18.1-dev.2+abcdef0",
        "0.18.0-rc.1",
        "0.19.0-dev.9+abcdef0",
        "1.17.0",
    }) |text| try std.testing.expectEqual(@as(?Series, null), series(try std.SemanticVersion.parse(text)));
}

test "the Zig compiling the tests is a verified one" {
    _ = try require();
}
