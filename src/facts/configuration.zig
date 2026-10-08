//! Bounds validation around Zig 0.17's own serialized configuration types.
//! This is a version-specific adapter, not an external stable graph API.
const std = @import("std");
const C = std.Build.Configuration;
pub const LoadError = error{ MalformedConfiguration, ConfigurationBudget, OutOfMemory };
const RefKind = enum { module, imports, deps, package, path, target, query, environment, system_lib, c_file, c_files, rc_file, arg, strings };
const types = .{ C.Module, C.ImportTable, C.Deps, C.Package, C.LazyPath, C.ResolvedTarget, C.TargetQuery, C.EnvironMap, C.SystemLib, C.CSourceFile, C.CSourceFiles, C.RcSourceFile, C.Step.Run.Arg, struct { strings: C.Storage.LengthPrefixedList(C.String) } };
const Ref = struct { kind: RefKind, index: u32 };
const Guard = struct {
    a: std.mem.Allocator,
    c: *const C,
    pending: std.ArrayList(Ref) = .empty,
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    depth: usize = 0,
    budget: usize = 1000000,
    string_budget: usize = 64 * 1024 * 1024,

    fn span(g: *Guard, i: *usize, count: usize) LoadError![]const u32 {
        if (i.* > g.c.extra.len or count > g.c.extra.len - i.*) return error.MalformedConfiguration;
        if (count > g.budget) return error.ConfigurationBudget;
        g.budget -= count;
        const slice = g.c.extra[i.*..][0..count];
        i.* += count;
        return slice;
    }
    fn enqueue(g: *Guard, kind: RefKind, index: u32) LoadError!void {
        const key = (@as(u64, @backingInt(kind)) << 32) | index;
        const entry = try g.seen.getOrPut(g.a, key);
        if (!entry.found_existing) try g.pending.append(g.a, .{ .kind = kind, .index = index });
    }
    fn value(g: *Guard, comptime T: type, v: T) LoadError!void {
        if (T == C.Bytes) {
            if (v.index > g.c.string_bytes.len or v.len > g.c.string_bytes.len - v.index) return error.MalformedConfiguration;
            return;
        }
        if (T == C.String) {
            const index = @backingInt(v);
            if (index >= g.c.string_bytes.len) return error.MalformedConfiguration;
            const tail = g.c.string_bytes[index..];
            const length = std.mem.findScalar(u8, tail[0..@min(tail.len, 32768)], 0) orelse return error.MalformedConfiguration;
            if (length + 1 > g.string_budget) return error.ConfigurationBudget;
            g.string_budget -= length + 1;
            return;
        }
        if (T == C.Step.Index) {
            if (@backingInt(v) >= g.c.steps.len) return error.MalformedConfiguration;
            return;
        }
        if (T == C.GeneratedFileIndex) {
            if (@backingInt(v) >= g.c.generated_files_len) return error.MalformedConfiguration;
            return;
        }
        if (T == C.StringList) return g.enqueue(.strings, @backingInt(v));
        if (T == C.OptionalString or T == C.OptionalStringList or T == C.OptionalGeneratedFileIndex or T == C.Package.OptionalIndex or T == C.LazyPath.OptionalIndex or T == C.ResolvedTarget.OptionalIndex or T == C.TargetQuery.OptionalIndex) {
            if (v.unwrap()) |some| try g.value(@TypeOf(some), some);
            return;
        }
        inline for (types, 0..) |S, kind| {
            if (S != types[types.len - 1] and T == S.Index) {
                if (T == C.Package.Index and v == .root) return;
                return g.enqueue(@fromBackingInt(@intCast(kind)), @backingInt(v));
            }
        }
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                if (info.layout != .auto) inline for (info.field_names) |name| {
                    if (comptime std.mem.eql(u8, name, "_")) {
                        if (@field(v, name) != 0) return error.MalformedConfiguration;
                    }
                    try g.value(@TypeOf(@field(v, name)), @field(v, name));
                };
            },
            .@"enum" => |info| {
                if (comptime @hasDecl(T, "storage")) {
                    if (T.storage == .extended) {
                        const U = @typeInfo(@TypeOf(T.get)).@"fn".return_type.?;
                        var index: usize = @backingInt(v);
                        _ = try g.decode(U, &index);
                    }
                } else if (info.mode == .exhaustive) {
                    _ = std.enums.fromInt(T, @backingInt(v)) orelse return error.MalformedConfiguration;
                }
            },
            else => {},
        }
    }
    fn decode(g: *Guard, comptime T: type, i: *usize) LoadError!T {
        if (g.depth >= 64) return error.ConfigurationBudget;
        g.depth += 1;
        defer g.depth -= 1;
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                var result: T = undefined;
                inline for (info.field_names, info.field_types) |name, F| @field(result, name) = try g.field(F, i, &result);
                return result;
            },
            .@"union" => |info| {
                const Tag = info.tag_type.?;
                var copy = i.*;
                const raw = (try g.span(&copy, 1))[0];
                // Only the tag is common across variants. Validate reserved
                // fields after decoding the selected variant's actual flags.
                const selected = std.enums.fromInt(Tag, @as(@Int(.unsigned, @bitSizeOf(Tag)), @truncate(raw))) orelse return error.MalformedConfiguration;
                return switch (selected) {
                    inline else => |tag| @unionInit(T, @tagName(tag), try g.decode(@FieldType(T, @tagName(tag)), i)),
                };
            },
            else => return error.MalformedConfiguration,
        }
    }
    fn field(g: *Guard, comptime T: type, i: *usize, parent: anytype) LoadError!T {
        const v: T = switch (@typeInfo(T)) {
            .void => {},
            .int => |info| switch (info.bits) {
                32 => (try g.span(i, 1))[0],
                64 => @bitCast((try g.span(i, 2))[0..2].*),
                else => @compileError("unsupported configuration integer"),
            },
            .@"enum" => |info| b: {
                const raw = (try g.span(i, 1))[0];
                if (raw > std.math.maxInt(info.tag_type)) return error.MalformedConfiguration;
                const backing: info.tag_type = @intCast(raw);
                break :b if (info.mode == .exhaustive) (std.enums.fromInt(T, backing) orelse return error.MalformedConfiguration) else @fromBackingInt(backing);
            },
            .@"struct" => |info| switch (info.layout) {
                .@"packed" => b: {
                    const words = try g.span(i, @sizeOf(T) / 4);
                    break :b @bitCast(if (@sizeOf(T) == 4) words[0] else words[0..2].*);
                },
                .@"extern" => b: {
                    const words = try g.span(i, @sizeOf(T) / 4);
                    break :b @as(*align(4) const T, @ptrCast(words.ptr)).*; // safe: bounded native u32 storage; Zig configuration's extern structs have u32 alignment.
                },
                .auto => if (T == std.Target.Cpu.Feature.Set) b: {
                    const words = try g.span(i, @sizeOf(T) / 4);
                    break :b @as(*align(4) const T, @ptrCast(words.ptr)).*; // safe: feature set copied by value from a bounds-checked u32 slice, retaining its native layout.
                } else try g.storage(T, i, parent),
            },
            else => @compileError("unsupported configuration field " ++ @typeName(T)),
        };
        try g.value(T, v);
        return v;
    }
    fn storage(g: *Guard, comptime T: type, i: *usize, parent: anytype) LoadError!T {
        switch (T.storage) {
            .flag_optional => return .{ .value = if (@field(@field(parent, @tagName(T.flags)), @tagName(T.flag))) try g.field(T.Value, i, parent) else null },
            .enum_optional => return .{ .value = if (@field(@field(parent, @tagName(T.flags)), @tagName(T.flag)) == T.tag) try g.field(T.Value, i, parent) else null },
            .flag_union => {
                const tag: T.Tag = @field(@field(parent, @tagName(T.flags)), @tagName(T.flag));
                return .{ .u = switch (tag) {
                    inline else => |t| @unionInit(T.Union, @tagName(t), try g.field(@FieldType(T.Union, @tagName(t)), i, parent)),
                } };
            },
            .length_prefixed_list, .flag_length_prefixed_list, .flag_list => {
                if (T.storage == .flag_length_prefixed_list and !@field(@field(parent, @tagName(T.flags)), @tagName(T.flag))) return .{ .slice = &.{} };
                const count: usize = if (T.storage == .flag_list) @field(@field(parent, @tagName(T.flags)), @tagName(T.flag)) else (try g.span(i, 1))[0];
                const words = try g.span(i, std.math.mul(usize, count, @sizeOf(T.Elem) / 4) catch return error.MalformedConfiguration);
                const slice: []const T.Elem = @ptrCast(words); // safe: serialized elements have u32 native layout and the entire list was checked above.
                for (slice) |elem| try g.value(T.Elem, elem);
                return .{ .slice = slice };
            },
            .multi_list => {
                const count: usize = (try g.span(i, 1))[0];
                const names = @typeInfo(T.Elem).@"struct";
                const words = try g.span(i, std.math.mul(usize, count, names.field_names.len) catch return error.MalformedConfiguration);
                inline for (names.field_types, 0..) |F, n| for (words[n * count ..][0..count]) |raw| try g.value(F, @fromBackingInt(raw));
                return .{ .mal = .{ .bytes = @ptrCast(@constCast(words.ptr)), .len = count, .capacity = count } }; // safe: Zig's multi-list decoder borrows native u32 columns validated above.
            },
            .union_list => {
                if (!@field(@field(parent, @tagName(T.flags)), @tagName(T.flag))) return .{ .data = null, .len = 0 };
                const start = i.*;
                var count: usize = 0;
                while (true) {
                    const bits = count * @bitSizeOf(T.Meta);
                    const end = (bits + @bitSizeOf(T.Meta) + 31) / 32;
                    if (start > g.c.extra.len or end > g.c.extra.len - start) return error.MalformedConfiguration;
                    const raw = C.loadBits(u32, g.c.extra[start..][0..end], bits, T.MetaInt);
                    const tag = std.enums.fromInt(T.Tag, @as(@Int(.unsigned, @bitSizeOf(T.Tag)), @truncate(raw))) orelse return error.MalformedConfiguration;
                    _ = tag;
                    count += 1;
                    if (count > g.budget) return error.ConfigurationBudget;
                    if (raw >> @bitSizeOf(T.Tag) != 0) break;
                }
                _ = try g.span(i, (count * @bitSizeOf(T.Meta) + 31) / 32);
                const payload_start = i.*;
                const words = try g.span(i, count);
                for (words, 0..) |raw, n| {
                    const meta = C.loadBits(u32, g.c.extra[start..], n * @bitSizeOf(T.Meta), T.Meta);
                    switch (meta.tag) {
                        inline else => |tag| try g.value(@FieldType(T.Union, @tagName(tag)), @fromBackingInt(raw)),
                    }
                }
                return .{ .data = @ptrFromInt(payload_start), .len = count }; // safe: Zig represents deserialized union-list storage by an extra-array index, never dereferenced as a pointer.
            },
            else => @compileError("unsupported configuration storage"),
        }
    }
};

pub fn load(a: std.mem.Allocator, bytes: []const u8) LoadError!C {
    if (bytes.len < @sizeOf(C.Header) or bytes.len > 64 * 1024 * 1024) return error.MalformedConfiguration;
    const header = std.mem.bytesToValue(C.Header, bytes[0..@sizeOf(C.Header)]);
    var expected: usize = @sizeOf(C.Header);
    inline for (.{ .{ header.string_bytes_len, u8 }, .{ header.steps_len, C.Step }, .{ header.path_deps_len, C.PathDep }, .{ header.unlazy_deps_len, C.String }, .{ header.system_integrations_len, C.SystemIntegration }, .{ header.available_options_len, C.AvailableOption }, .{ header.search_prefixes_len, C.String }, .{ header.extra_len, u32 } }) |part| {
        expected = std.math.add(usize, expected, std.math.mul(usize, part[0], @sizeOf(part[1])) catch return error.MalformedConfiguration) catch return error.MalformedConfiguration;
    }
    if (expected != bytes.len or header.steps_len == 0 or @backingInt(header.default_step) >= header.steps_len or header.generated_files_len > 1000000 or @as(u32, @bitCast(header.flags)) > 1) return error.MalformedConfiguration;
    var reader = std.Io.Reader.fixed(bytes);
    const c = C.load(a, &reader) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.MalformedConfiguration;
    var g: Guard = .{ .a = a, .c = &c };
    defer g.pending.deinit(a);
    defer g.seen.deinit(a);
    for (c.steps) |step| {
        try g.value(C.String, step.name);
        try g.value(C.Package.Index, step.owner);
        try g.value(C.Deps.Index, step.deps);
        try g.value(@TypeOf(step.extended), step.extended);
    }
    for (c.path_deps) |dep| try g.value(C.PathDep, dep);
    for (c.unlazy_deps) |s| try g.value(C.String, s);
    for (c.search_prefixes) |s| try g.value(C.String, s);
    for (c.available_options) |opt| try g.value(C.AvailableOption, opt);
    for (c.system_integrations) |opt| try g.value(C.SystemIntegration, opt);
    while (g.pending.pop()) |ref| switch (ref.kind) {
        inline else => |kind| {
            var i: usize = ref.index;
            _ = try g.decode(types[@backingInt(kind)], &i);
        },
    };
    return c;
}
