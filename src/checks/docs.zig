const std = @import("std");
const src = @import("source.zig");

pub fn snippet(c: src.Context, generator: src.Value) ![]const u8 {
    const source = src.string(src.get(generator, "source"), "");
    const text = try c.read(source);
    const marker = try c.a.print("// --- README:{s} ---", .{src.string(src.get(generator, "region"), "usage")});
    var parts = std.mem.splitSequence(u8, text, marker);
    _ = parts.next();
    const body = parts.next() orelse return error.MissingReadmeMarker;
    _ = parts.next() orelse return error.MissingReadmeMarker;
    if (parts.next() != null) return error.DuplicateReadmeMarker;
    var out: std.Io.Writer.Allocating = .init(c.a);
    try out.writer.writeAll("```zig\n");
    const show = src.get(generator, "want_import");
    if (show != .bool or show.bool) {
        const imports = src.get(generator, "imports");
        if (imports == .null) try appendImport(c.a, &out.writer, text, src.string(src.get(generator, "module"), "")) else {
            for (src.items(imports)) |name| try appendImport(c.a, &out.writer, text, src.string(name, ""));
        }
        try out.writer.writeByte('\n');
    }
    const dedented = try dedent(c.a, body);
    try out.writer.writeAll(dedented);
    try out.writer.writeAll("\n```\n");
    return out.written();
}

fn appendImport(a: std.mem.Allocator, writer: *std.Io.Writer, text: []const u8, name: []const u8) !void {
    const prefix = try a.print("const {s} = @import(", .{name});
    var lines = std.mem.splitScalar(u8, text, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        try writer.writeAll(line);
        try writer.writeByte('\n');
        count += 1;
    }
    if (count != 1) return error.MissingModuleImport;
}

fn dedent(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var indent: usize = std.math.maxInt(usize);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        indent = @min(indent, line.len - std.mem.trimStart(u8, line, " \t").len);
    }
    if (indent == std.math.maxInt(usize)) return "";
    lines.reset();
    var out: std.Io.Writer.Allocating = .init(a);
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.trim(u8, trimmed, " \t").len != 0) try out.writer.writeAll(trimmed[@min(indent, trimmed.len)..]);
        try out.writer.writeByte('\n');
    }
    return std.mem.trim(u8, out.written(), "\n");
}

pub fn generate(c: src.Context, generator: src.Value) ![]const u8 {
    const command = src.get(generator, "command");
    if (command == .null) return snippet(c, generator);
    const argv = try zigCommand(c.a, command);
    const result = try std.process.run(c.a, c.io, .{ .argv = argv, .cwd = c.childCwd(), .environ_map = c.environ_map });
    if (result.term != .exited or result.term.exited != 0) {
        c.report("docs: generator failed: {s}\n", .{result.stderr});
        return error.GeneratorFailed;
    }
    const text = try c.a.dupe(u8, result.stdout);
    const normalized = try std.mem.replaceOwned(u8, c.a, text, "\r\n", "\n");
    return c.a.print("{s}\n", .{std.mem.trimEnd(u8, normalized, "\n")});
}

pub fn zigCommand(a: std.mem.Allocator, command: src.Value) ![]const []const u8 {
    const values = src.items(command);
    if (values.len < 2 or !std.mem.eql(u8, src.string(values[0], ""), "zig") or !std.mem.eql(u8, src.string(values[1], ""), "build")) return error.CheckMustUseZigBuild;
    const argv = try a.alloc([]const u8, values.len);
    for (values, argv) |value, *arg| arg.* = src.string(value, "");
    return argv;
}

pub fn check(c: *src.Context, config: src.Value) !void {
    const generators = src.get(config, "docs");
    var seen = std.StringHashMap(void).init(c.a);
    var dir = try c.directory().openDir(c.io, ".", .{ .iterate = true });
    defer dir.close(c.io);
    var iterator = dir.iterate();
    while (try iterator.next(c.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        const text = try c.read(entry.name);
        var offset: usize = 0;
        const begin = "<!-- BEGIN GENERATED ";
        while (std.mem.findPos(u8, text, offset, begin)) |start| {
            const label_end = std.mem.findPos(u8, text, start + begin.len, " -->\n") orelse return error.MalformedGeneratedBlock;
            const label = std.mem.trim(u8, text[start + begin.len .. label_end], " \t");
            const body_start = label_end + 5;
            const end = std.mem.findPos(u8, text, body_start, "<!-- END GENERATED") orelse return error.MissingGeneratedBlockEnd;
            offset = end + "<!-- END GENERATED".len;
            const generator = src.get(generators, label);
            if (generator == .null) {
                c.fail("{s}: generated block '{s}' has no ci/ configuration", .{ entry.name, label });
                continue;
            }
            try seen.put(label, {});
            const wanted = generate(c.*, generator) catch |err| {
                c.fail("{s}: {s}: {t}", .{ entry.name, label, err });
                continue;
            };
            if (!std.mem.eql(u8, wanted, text[body_start..end])) c.fail("{s}: generated block '{s}' differs from its example", .{ entry.name, label });
        }
    }
    if (generators == .object) {
        var configured = generators.object.iterator();
        while (configured.next()) |entry| {
            if (!seen.contains(entry.key_ptr.*)) c.fail("docs: configured block '{s}' is absent", .{entry.key_ptr.*});
        }
    }
}

test "dedent preserves relative indentation and excludes marker whitespace" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectEqualStrings("const x = 1;\nif (x) {\n    foo();\n}", try dedent(arena.allocator(), "\n    const x = 1;\n    if (x) {\n        foo();\n    }\n    "));
}

test "configured generators cannot call other runtimes" {
    const a = std.testing.allocator;
    const value = try std.json.parseFromSlice(src.Value, a, "[\"python3\",\"ci/docs.py\"]", .{});
    defer value.deinit();
    try std.testing.expectError(error.CheckMustUseZigBuild, zigCommand(a, value.value));
}

test "documentation matches examples and refuses drift and missing markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var c: src.Context = .{ .a = a, .io = std.testing.io, .dir = tmp.dir };
    try tmp.dir.writeFile(c.io, .{ .sub_path = "usage.zig", .data = "const example = @import(\"example\");\nfn main() void {\n // --- README:usage ---\n const x = 1;\n // --- README:usage ---\n}\n" });
    const config = (try std.json.parseFromSlice(src.Value, a, "{\"docs\":{\"usage\":{\"source\":\"usage.zig\",\"region\":\"usage\",\"module\":\"example\"}}}", .{})).value;
    const wanted = try snippet(c, src.get(src.get(config, "docs"), "usage"));
    const readme = try a.print("<!-- BEGIN GENERATED usage -->\n{s}<!-- END GENERATED -->\n", .{wanted});
    try tmp.dir.writeFile(c.io, .{ .sub_path = "README.md", .data = readme });
    try check(&c, config);
    try std.testing.expectEqual(@as(usize, 0), c.errors);
    try tmp.dir.writeFile(c.io, .{ .sub_path = "README.md", .data = "<!-- BEGIN GENERATED usage -->\nstale\n<!-- END GENERATED -->\n" });
    try check(&c, config);
    try std.testing.expectEqual(@as(usize, 1), c.errors);
    try tmp.dir.writeFile(c.io, .{ .sub_path = "usage.zig", .data = "// marker missing\n" });
    try std.testing.expectError(error.MissingReadmeMarker, snippet(c, src.get(src.get(config, "docs"), "usage")));
}

/// The region `zig build docs -- <region>` names, after the options the build
/// passes: `usage` when there is none.
pub fn region(args: []const []const u8) []const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config")) {
            i += 1;
        } else return args[i];
    }
    return "usage";
}

test "the docs region is the first argument after the options, else usage" {
    try std.testing.expectEqualStrings("usage", region(&.{ "--config", "ci/preflight.json" }));
    try std.testing.expectEqualStrings("api", region(&.{ "--config", "ci/preflight.json", "api" }));
    try std.testing.expectEqualStrings("api", region(&.{"api"}));
}
