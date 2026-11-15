//! The structure runner's input seam: where bytes from outside enter the structure check, each
//! read held to a limit named here. The package's configuration is read here and nowhere else
//! in the runner; what reads the bytes this hands back parses them as the input they are. The
//! sources the check scans are gantry's to read.
const std = @import("std");
const aegis = @import("aegis");

/// How much of a file a read takes: each read names the kind of file it is.
pub const Limit = enum {
    /// The package's configuration, `ci/preflight.json` or the one `--config` names.
    configuration,

    fn bytes(limit: Limit) aegis.units.Bytes(u64) {
        return .fromRaw(switch (limit) {
            .configuration => 64 * 1024 * 1024,
        });
    }
};

/// The file at `path` under `dir`, at most `limit`'s bytes, owned by the caller.
pub fn file(io: std.Io, dir: std.Io.Dir, path: []const u8, gpa: std.mem.Allocator, limit: Limit) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, dir, path, gpa, limit.bytes());
}
