//! The repository's `.gitattributes`, which `generate` writes beside the caller and the lint and
//! the gate hold to it, as they hold the caller: every text file LF on every system, so no
//! checkout writes CRLF into a file a test reads byte for byte (datapad's spec texts on Windows,
//! its first ci run); the files the package holds as bytes, from `binary` in
//! `ci/preflight.json`; and CHANGELOG.md merged as a union, so two changes that add entries under
//! one group both keep them. Nothing but `generate` writes it.
const std = @import("std");

/// The file's path, from the repository's top.
pub const path = ".gitattributes";

/// The file for `binary`, the package's patterns of files held as bytes (gitattributes
/// patterns from the package's directory), with `directory` the package's directory from the
/// repository's top ("." at the top). A pattern the file could not hold as one is refused
/// (`error.InvalidBinary`, `problem` set to why).
pub fn render(a: std.mem.Allocator, binary: []const []const u8, directory: []const u8, problem: *[]const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll(
        \\# Made by preflight's `generate`, which the lint and the gate hold this file to: the files
        \\# held as bytes are `binary` in ci/preflight.json.
        \\
        \\# Everything this repository holds is LF on every system, so no diff and no gate reads
        \\# a line ending as a change, and no checkout writes CRLF into a file a test reads.
        \\* text=auto eol=lf
        \\
    );
    if (binary.len != 0) try w.writeAll("\n# The files the package holds as bytes, read exactly as they are.\n");
    for (binary) |pattern| {
        if (refusal(pattern)) |why| {
            problem.* = try a.print("binary: `{s}`: {s}", .{ pattern, why });
            return error.InvalidBinary;
        }
        const relative = std.mem.trimStart(u8, pattern, "/");
        if (std.mem.eql(u8, directory, ".")) {
            try w.print("{s} binary\n", .{relative});
        } else try w.print("{s}/{s} binary\n", .{ directory, relative });
    }
    try w.writeAll(
        \\
        \\# Two changes that add lines under one group of CHANGELOG.md both keep them, with no
        \\# conflict to resolve; `bay release` orders the section.
        \\CHANGELOG.md merge=union
        \\
    );
    return out.written();
}

/// Why `pattern` cannot be one line's pattern of the file, or null: it would be empty, read as
/// a comment or a negation, split at a space, or name a path from outside the package.
fn refusal(pattern: []const u8) ?[]const u8 {
    if (std.mem.trim(u8, pattern, "/").len == 0) return "names no file";
    if (pattern[0] == '#') return "would be a comment";
    if (pattern[0] == '!') return "a negative pattern is not allowed in .gitattributes";
    for (pattern) |byte| switch (byte) {
        ' ', '\t', '\r', '\n' => return "holds whitespace, which ends a pattern",
        '\\' => return "holds `\\`: a pattern separates its directories with `/`",
        else => {},
    };
    var parts = std.mem.splitScalar(u8, pattern, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return "leaves the package's directory";
    return null;
}

test "the file holds LF for everything, the package's bytes and CHANGELOG.md's union merge, in that order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var problem: []const u8 = "";
    const text = try render(a, &.{ "src/zone/tzdb.bin", "/testdata/zoneinfo/**" }, ".", &problem);
    const eol = std.mem.find(u8, text, "\n* text=auto eol=lf\n").?;
    const bytes = std.mem.find(u8, text, "\nsrc/zone/tzdb.bin binary\ntestdata/zoneinfo/** binary\n").?;
    const changelog = std.mem.find(u8, text, "\nCHANGELOG.md merge=union\n").?;
    // A later line wins in .gitattributes: the bytes' after the line-ending rule.
    try std.testing.expect(eol < bytes and bytes < changelog);
    try std.testing.expect(std.mem.endsWith(u8, text, "CHANGELOG.md merge=union\n"));
    // None declared: no section for them; a package below the top has its patterns from there.
    try std.testing.expect(std.mem.find(u8, try render(a, &.{}, ".", &problem), "binary\n") == null);
    try std.testing.expect(std.mem.find(u8, try render(a, &.{"data/*.bin"}, "sample", &problem), "\nsample/data/*.bin binary\n") != null);
}

test "a binary pattern the file cannot hold as one is refused by name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var problem: []const u8 = "";
    for ([_][2][]const u8{
        .{ "", "names no file" },
        .{ "#notes", "would be a comment" },
        .{ "!keep.bin", "negative pattern" },
        .{ "test data/x.bin", "whitespace" },
        .{ "testdata\\x.bin", "separates its directories with `/`" },
        .{ "../other/x.bin", "leaves the package's directory" },
    }) |case| {
        try std.testing.expectError(error.InvalidBinary, render(a, &.{case[0]}, ".", &problem));
        try std.testing.expect(std.mem.find(u8, problem, case[1]) != null);
    }
}
