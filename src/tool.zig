//! preflight's command program as a build sees it: compiled from the sources
//! here, or the binary a hosted runner already holds. A job that takes the
//! binary spares itself the compile, which a cold cache makes minutes long.
const std = @import("std");

pub const Tool = union(enum) {
    compiled: *std.Build.Step.Compile,
    /// The path of a binary built from the same commit.
    prebuilt: []const u8,

    /// A run of the program. A prebuilt one always runs: nothing says which
    /// files it reads, and a check that is cached passes without looking.
    pub fn run(tool: Tool, b: *std.Build) *std.Build.Step.Run {
        switch (tool) {
            .compiled => |compile| return b.addRunArtifact(compile),
            .prebuilt => |path| {
                const command = b.addSystemCommand(&.{path});
                command.has_side_effects = true;
                return command;
            },
        }
    }
};
