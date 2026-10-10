//! Own-gate policy over Zig-resolved pins and gantry's source reachability facts.
//! Manifest declarations are not runtime edges, and lazy is not a test scope.
const std = @import("std");
const builtin = @import("builtin");
const gantry = @import("gantry");
const zig_version = @import("zig_version");
const Kind = enum { runtime, @"test", bootstrap };
const Dep = struct { name: []const u8, hash: []const u8 };
const Package = struct { hash: []const u8, root: []const u8, available: bool, dependencies: []const Dep };
const Import = struct { name: []const u8, module: usize };
const Module = struct { owner: []const u8, source_arg: ?usize, imports: []const Import };
const Root = struct { module: usize, kind: Kind };
const Config = struct { zig: []const u8, packages: []const Package, modules: []const Module, roots: []const Root };
/// `root` is the module the traversal started from: the compiler builds only
/// that module's `test` blocks, never those of the modules it imports.
const Node = struct { module: usize, root: usize, file: []const u8, kind: Kind };
const Identity = struct { name: []const u8, fingerprint: u64 };
const Pin = struct { name: []const u8, family: bool = false };

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) return error.ExpectedResolvedConfiguration;
    _ = zig_version.require() catch return error.UnsupportedClosureConfiguration;
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .limited(64 << 20));
    const config = try std.json.parseFromSliceLeaky(Config, a, text, .{ .max_value_len = 64 << 20 });
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stderr().writerStreaming(init.io, &buffer);
    defer output.interface.flush() catch {};
    const reader: Reader = .{ .io = init.io, .args = args };
    try validate(a, config, reader, Reader.read, &output.interface);
    try output.interface.flush();
}
const Reader = struct {
    io: std.Io,
    args: []const []const u8,
    fn read(self: Reader, a: std.mem.Allocator, p: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, p, a, .limited(1 << 20));
    }
    fn source(self: Reader, module: Module) ![]const u8 {
        const index = module.source_arg orelse return error.MissingConfiguredSource;
        if (index >= self.args.len or index < 2) return error.InvalidConfiguredSource;
        return self.args[index];
    }
};

/// Validates the recursively resolved declarations separately from traversal.
/// Runtime/test classification comes from gantry imports in their real module
/// binding context, including relative sources and references only tests reach.
fn validate(a: std.mem.Allocator, c: Config, reader: anytype, comptime read: anytype, out: *std.Io.Writer) !void {
    if (!std.mem.eql(u8, c.zig, builtin.zig_version_string)) return error.UnsupportedClosureConfiguration;
    if (c.packages.len == 0 or c.packages.len > 512 or c.modules.len > 4096 or c.roots.len > 4096) return error.InvalidClosureConfiguration;
    var packages: std.StringHashMapUnmanaged(usize) = .empty;
    for (c.packages, 0..) |package, index| {
        if (package.hash.len > 1024 or package.root.len > 32768 or package.dependencies.len > 4096) return error.InvalidClosureConfiguration;
        if ((try packages.getOrPut(a, package.hash)).found_existing) return error.DuplicateResolvedIdentity;
        packages.getPtr(package.hash).?.* = index;
    }
    if (!packages.contains("")) return error.MissingRootPackage;
    const family = try a.alloc(bool, c.packages.len);
    @memset(family, false);
    const identities = try a.alloc(?Identity, c.packages.len);
    @memset(identities, null);
    var pending_packages: std.ArrayList(usize) = .empty;
    var seen_packages: std.AutoHashMapUnmanaged(usize, void) = .empty;
    try pending_packages.append(a, packages.get("").?);
    while (pending_packages.pop()) |index| {
        if ((try seen_packages.getOrPut(a, index)).found_existing) continue;
        const package = c.packages[index];
        if (!package.available) continue; // pinned, unmaterialized bootstrap: not production proof
        const path = try std.Io.Dir.path.join(a, &.{ package.root, "build.zig.zon" });
        const manifest = try read(reader, a, path);
        identities[index] = try identity(a, manifest);
        if (package.hash.len != 0) try matchesHash(package.hash, identities[index].?);
        const declarations = try gantry.manifests.parse(a, "build.zig.zon", manifest);
        if (declarations.len != package.dependencies.len) return error.ResolvedDependencyMismatch;
        for (declarations) |dependency| {
            const resolved = for (package.dependencies) |resolved| {
                if (std.mem.eql(u8, resolved.name, dependency.name)) break resolved;
            } else return error.UnresolvedDeclaredDependency;
            if (!std.mem.eql(u8, dependency.requirement, resolved.hash)) return error.ResolvedPinMismatch;
            const child = packages.get(resolved.hash) orelse return error.UnresolvedDeclaredDependency;
            const pinned = try pin(a, dependency);
            family[child] = family[child] or pinned.family;
            const child_package = c.packages[child];
            if (pinned.family and child_package.available) {
                const child_manifest = try read(reader, a, try std.Io.Dir.path.join(a, &.{ child_package.root, "build.zig.zon" }));
                const child_identity = try identity(a, child_manifest);
                if (!std.mem.eql(u8, pinned.name, child_identity.name)) return error.ResolvedIdentityMismatch;
            }
            try pending_packages.append(a, child);
            // These are declaration facts, not assertions of runtime reachability.
            if (pinned.family and (std.mem.eql(u8, pinned.name, "preflight") or std.mem.eql(u8, pinned.name, "ziglint"))) {
                if (!try isLazy(a, manifest, dependency.name)) return error.UnboundedBootstrap;
                try out.print("check-toolchain: bootstrap {s} -> {s} pin={s} materialized={}\n", .{ identities[index].?.name, pinned.name, resolved.hash, child_package.available });
            }
        }
    }
    for (c.modules) |module| {
        if (!packages.contains(module.owner) or module.imports.len > 4096) return error.InvalidClosureConfiguration;
        var names: std.StringHashMapUnmanaged(void) = .empty;
        for (module.imports) |imported| {
            if (imported.module >= c.modules.len or imported.name.len == 0 or imported.name.len > 32768) return error.InvalidClosureConfiguration;
            if ((try names.getOrPut(a, imported.name)).found_existing) return error.DuplicateModuleBinding;
        }
    }
    var pending: std.ArrayList(Node) = .empty;
    for (c.roots) |root| {
        if (root.module >= c.modules.len or root.kind == .bootstrap) return error.InvalidClosureConfiguration;
        try pending.append(a, .{ .module = root.module, .root = root.module, .kind = root.kind, .file = try reader.source(c.modules[root.module]) });
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var edges: std.StringHashMapUnmanaged(void) = .empty;
    var bytes: usize = 0;
    while (pending.pop()) |node| {
        const key = try a.print("{d}:{d}:{t}:{s}", .{ node.root, node.module, node.kind, node.file });
        if ((try seen.getOrPut(a, key)).found_existing) continue;
        if (seen.count() > 100_000) return error.ClosureTooLarge;
        const module = c.modules[node.module];
        const own = packages.get(module.owner).?;
        if (!c.packages[own].available or identities[own] == null) return error.UnresolvedProductionIdentity;
        const source = try read(reader, a, node.file);
        if (source.len > (64 << 20) - bytes) return error.ClosureTooLarge;
        bytes += source.len;
        var facts = try gantry.imports(a, .zig, source);
        defer facts.deinit();
        if (facts.unsupported().len != 0) return error.UnsupportedReachabilityFacts;
        for (facts.items()) |reference| {
            if (reference.dead) continue;
            // Tests inside a production artifact are not configured there.
            // Traverse them through the compiler-configured test roots instead.
            if (node.kind == .runtime and reference.kind == .@"test") continue;
            // Nor does a test build compile the tests of the modules its root
            // imports: a dependency's embedded tests are its own to bind.
            if (node.module != node.root and reference.kind == .@"test") continue;
            const kind: Kind = if (node.kind == .@"test" or reference.kind == .@"test") .@"test" else .runtime;
            if (std.mem.eql(u8, reference.name, "std") or std.mem.eql(u8, reference.name, "builtin") or std.mem.eql(u8, reference.name, "root")) continue;
            if (std.mem.endsWith(u8, reference.name, ".zig") or std.mem.endsWith(u8, reference.name, ".zon")) {
                const path = try std.Io.Dir.path.resolve(a, &.{ std.Io.Dir.path.dirname(node.file) orelse ".", reference.name });
                try pending.append(a, .{ .module = node.module, .root = node.root, .file = path, .kind = kind });
                continue;
            }
            const imported = for (module.imports) |imported| {
                if (std.mem.eql(u8, imported.name, reference.name)) break imported;
            } else {
                try out.print("check-toolchain: unresolved {t} import {s} in {s} (module {d})\n", .{ kind, reference.name, node.file, node.module });
                return error.UnresolvedProductionImport;
            };
            const child = c.modules[imported.module];
            const child_index = packages.get(child.owner).?;
            const child_identity = identities[child_index] orelse return error.UnresolvedProductionIdentity;
            if (own != child_index) {
                const edge_key = try a.print("{s}:{s}:{t}", .{ module.owner, child.owner, kind });
                if (!(try edges.getOrPut(a, edge_key)).found_existing) {
                    const parent = identities[own].?;
                    try out.print("check-toolchain: {t} {s} -> {s} pin={s}\n", .{ kind, parent.name, child_identity.name, child.owner });
                    if (kind == .runtime) try runtimeEdge(parent.name, child_identity.name, family[child_index]);
                }
            }
            try pending.append(a, .{ .module = imported.module, .root = node.root, .file = try reader.source(child), .kind = kind });
        }
    }
}

fn runtimeEdge(parent: []const u8, child: []const u8, family: bool) !void {
    if (!family and !familyName(child)) return; // externals still recursively traversed
    const parent_rank = rank(parent) orelse return error.OutsideTheToolchain;
    const child_rank = rank(child) orelse return error.OutsideTheToolchain;
    if (child_rank >= parent_rank) return error.ToolchainLayerViolation;
}
fn rank(name: []const u8) ?usize {
    for ([_][]const u8{ "aegis", "sweep", "glint", "gantry", "preflight" }, 0..) |value, i| if (std.mem.eql(u8, value, name)) return i;
    return null;
}
fn familyName(name: []const u8) bool {
    // Resolved identity policy; URL aliases do not supply identity.
    for ([_][]const u8{ "aegis", "sweep", "glint", "gantry", "preflight", "shakedown", "ziglint", "airlock", "strand", "conduit", "uplink", "relic", "lookout", "cloak", "warp", "morse", "visor", "chronicle", "reactor", "parallax", "tycho" }) |value| if (std.mem.eql(u8, value, name)) return true;
    return false;
}
fn pin(a: std.mem.Allocator, dep: gantry.Dependency) !Pin {
    if (dep.origin != .remote or dep.requirement.len == 0) return error.UnpinnedDependency;
    const uri = std.Uri.parse(dep.source) catch return error.InvalidDependencySource;
    const host = if (uri.host) |host| try host.toRawMaybeAlloc(a) else "";
    const path = try uri.path.toRawMaybeAlloc(a);
    const git = std.mem.startsWith(u8, uri.scheme, "git+");
    if (git) {
        const revision = dep.revision();
        if (revision.len != 40) return error.UnpinnedDependency;
        for (revision) |byte| if (!std.ascii.isHex(byte)) return error.UnpinnedDependency;
    }
    if (!std.ascii.eqlIgnoreCase(host, "github.com")) return .{ .name = "" };
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, path, "/"), '/');
    const owner = parts.next() orelse return .{ .name = "" };
    if (!std.mem.eql(u8, owner, "pedronaugusto")) return .{ .name = "" };
    const repository = parts.next() orelse return error.InvalidDependencySource;
    const name = if (std.mem.endsWith(u8, repository, ".git")) repository[0 .. repository.len - 4] else repository;
    if (name.len == 0) return error.InvalidDependencySource;
    return .{ .name = name, .family = true };
}
/// Pin validation is useful on declarations, but never a closure verdict.
fn check(a: std.mem.Allocator, package: []const u8, manifest: []const u8, out: *std.Io.Writer) !usize {
    _ = package;
    _ = out;
    for (try gantry.manifests.parse(a, "build.zig.zon", manifest)) |dependency| _ = try pin(a, dependency);
    return 0;
}
fn zon(a: std.mem.Allocator, manifest: []const u8) !std.zig.Zoir {
    const source = try a.dupeSentinel(u8, manifest, 0);
    var ast = try std.zig.Ast.parse(a, source, .{ .mode = .zon });
    defer ast.deinit(a);
    const result = try std.zig.ZonGen.generate(a, ast, .{});
    if (result.hasCompileErrors()) return error.InvalidManifest;
    return result;
}
fn field(z: *const std.zig.Zoir, node: std.zig.Zoir.Node, name: []const u8) !?std.zig.Zoir.Node {
    if (node == .empty_literal) return null;
    if (node != .struct_literal) return error.InvalidManifest;
    for (node.struct_literal.names, 0..) |value, i| if (std.mem.eql(u8, value.get(z), name)) return node.struct_literal.vals.at(@intCast(i)).get(z);
    return null;
}
fn identity(a: std.mem.Allocator, manifest: []const u8) !Identity {
    var z = try zon(a, manifest);
    defer z.deinit(a);
    const root = std.zig.Zoir.Node.Index.root.get(&z);
    const name = (try field(&z, root, "name")) orelse return error.MissingPackageIdentity;
    const fingerprint = (try field(&z, root, "fingerprint")) orelse return error.MissingPackageIdentity;
    if (name != .enum_literal or fingerprint != .int_literal) return error.InvalidPackageIdentity;
    return .{ .name = try a.dupe(u8, name.enum_literal.get(&z)), .fingerprint = switch (fingerprint.int_literal) {
        .small => |value| std.math.cast(u64, value) orelse return error.InvalidPackageIdentity,
        .big => |value| value.toInt(u64) catch return error.InvalidPackageIdentity,
    } };
}
/// Zig 0.17 compiler/Maker/Package.zig Hash.projectId and Fingerprint:
/// the final 44 URL-safe base64 bytes encode 33 bytes, first LE u32 = project ID.
/// The compiler has already checked fetched contents against the content hash.
fn matchesHash(hash: []const u8, value: Identity) !void {
    if (hash.len < 46 or hash.len > 110) return error.ResolvedIdentityMismatch;
    const name_end = std.mem.findScalar(u8, hash, '-') orelse return error.ResolvedIdentityMismatch;
    if (!std.mem.eql(u8, hash[0..name_end], value.name)) return error.ResolvedIdentityMismatch;
    var bytes: [33]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&bytes, hash[hash.len - 44 ..]) catch return error.ResolvedIdentityMismatch;
    const id: u32 = @truncate(value.fingerprint);
    if (id == 0 or id == 0xffffffff or id != std.mem.readInt(u32, bytes[0..4], .little)) return error.ResolvedIdentityMismatch;
    if (std.hash.Crc32.hash(value.name) != value.fingerprint >> 32) return error.ResolvedIdentityMismatch;
}
fn isLazy(a: std.mem.Allocator, manifest: []const u8, dependency: []const u8) !bool {
    var z = try zon(a, manifest);
    defer z.deinit(a);
    const root = std.zig.Zoir.Node.Index.root.get(&z);
    const deps = (try field(&z, root, "dependencies")) orelse return error.InvalidManifest;
    const dep = (try field(&z, deps, dependency)) orelse return error.InvalidManifest;
    const lazy = (try field(&z, dep, "lazy")) orelse return false;
    return lazy == .true;
}

test "closure rejects mutable dependency pins" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    const manifest = ".{ .dependencies = .{ .sweep = .{ .url = \"git+https://github.com/pedronaugusto/sweep#main\", .hash = \"sweep-hash\" } } }";
    try std.testing.expectError(error.UnpinnedDependency, check(arena.allocator(), "preflight", manifest, &out.writer));
}

test "closure does not mistake an unrelated URL path for a family identity" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    const manifest = ".{ .dependencies = .{ .external = .{ .url = \"https://example.invalid/github.com/pedronaugusto/strand/archive.tar.gz\", .hash = \"external-content-hash\" } } }";
    try std.testing.expectEqual(@as(usize, 0), try check(arena.allocator(), "preflight", manifest, &out.writer));
}

const Fixture = struct {
    main_source: []const u8 = "pub const runtime = @import(\"gantry\"); test \"doubles\" { _ = @import(\"shakedown\"); }",
    gantry_source: []const u8 = "pub const nested = @import(\"renamed\");",
    nested_manifest: []const u8 = ".{ .name = .strand, .fingerprint = 694876690031050755, .dependencies = .{} }",
    failure: ?anyerror = null,
    fn source(_: Fixture, module: Module) ![]const u8 {
        const paths = [_][]const u8{ "main.zig", "gantry.zig", "strand.zig", "doubles.zig" };
        const index = module.source_arg orelse return error.MissingConfiguredSource;
        if (index >= paths.len) return error.InvalidConfiguredSource;
        return paths[index];
    }
    fn read(self: Fixture, a: std.mem.Allocator, path: []const u8) ![]const u8 {
        _ = a;
        if (self.failure) |failure| return failure;
        if (std.mem.eql(u8, path, "root/build.zig.zon")) return
        \\.{ .name = .preflight, .fingerprint = 5964003376910827521, .dependencies = .{
        \\ .gantry = .{ .url = "git+https://github.com/pedronaugusto/gantry#1111111111111111111111111111111111111111", .hash = "gantry-0.1.0-AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", .lazy = true },
        \\ .shakedown = .{ .url = "git+https://github.com/pedronaugusto/shakedown#2222222222222222222222222222222222222222", .hash = "shakedown-0.1.0-BAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", .lazy = true },
        \\} }
        ;
        if (std.mem.eql(u8, path, "gantry/build.zig.zon")) return
        \\.{ .name = .gantry, .fingerprint = 13596458448597286914, .dependencies = .{
        \\ .alias = .{ .url = "git+https://example.invalid/nested#3333333333333333333333333333333333333333", .hash = "strand-0.1.0-AwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" },
        \\ .preflight = .{ .url = "git+https://github.com/pedronaugusto/preflight#4444444444444444444444444444444444444444", .hash = "preflight-0.1.0-AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", .lazy = true },
        \\} }
        ;
        if (std.mem.eql(u8, path, "nested/build.zig.zon")) return self.nested_manifest;
        if (std.mem.eql(u8, path, "doubles/build.zig.zon")) return ".{ .name = .shakedown, .fingerprint = 1131071330934849540, .dependencies = .{} }";
        if (std.mem.eql(u8, path, "main.zig")) return self.main_source;
        if (std.mem.eql(u8, path, "gantry.zig")) return self.gantry_source;
        if (std.mem.eql(u8, path, "strand.zig")) return "pub const value = 1;";
        if (std.mem.eql(u8, path, "doubles.zig")) return "pub const value = 2;";
        return error.FileNotFound;
    }
    fn config() Config {
        return .{
            .zig = builtin.zig_version_string,
            .packages = &.{
                .{ .hash = "", .root = "root", .available = true, .dependencies = &.{ .{ .name = "gantry", .hash = "gantry-0.1.0-AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }, .{ .name = "shakedown", .hash = "shakedown-0.1.0-BAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" } } },
                .{ .hash = "gantry-0.1.0-AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", .root = "gantry", .available = true, .dependencies = &.{ .{ .name = "alias", .hash = "strand-0.1.0-AwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }, .{ .name = "preflight", .hash = "preflight-0.1.0-AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" } } },
                .{ .hash = "strand-0.1.0-AwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", .root = "nested", .available = true, .dependencies = &.{} },
                .{ .hash = "shakedown-0.1.0-BAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", .root = "doubles", .available = true, .dependencies = &.{} },
                .{ .hash = "preflight-0.1.0-AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", .root = "", .available = false, .dependencies = &.{} },
            },
            .modules = &.{
                .{ .owner = "", .source_arg = 0, .imports = &.{ .{ .name = "gantry", .module = 1 }, .{ .name = "shakedown", .module = 3 } } },
                .{ .owner = "gantry-0.1.0-AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", .source_arg = 1, .imports = &.{.{ .name = "renamed", .module = 2 }} },
                .{ .owner = "strand-0.1.0-AwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", .source_arg = 2, .imports = &.{} },
                .{ .owner = "shakedown-0.1.0-BAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", .source_arg = 3, .imports = &.{} },
            },
            .roots = &.{ .{ .module = 0, .kind = .runtime }, .{ .module = 0, .kind = .@"test" } },
        };
    }
};

test "closure rejects a transitive production family identity behind external URL and module aliases" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try std.testing.expectError(error.OutsideTheToolchain, validate(arena.allocator(), Fixture.config(), Fixture{}, Fixture.read, &out.writer));
    try std.testing.expect(std.mem.find(u8, out.written(), "runtime gantry -> strand") != null);
}

test "closure distinguishes production test and pinned unmaterialized bootstrap edges" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    const fixture: Fixture = .{ .gantry_source = "test \"only\" { _ = @import(\"renamed\"); }" };
    try validate(arena.allocator(), Fixture.config(), fixture, Fixture.read, &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "test preflight -> shakedown") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "runtime preflight -> gantry") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "bootstrap gantry -> preflight pin=preflight-0.1.0-AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA materialized=false") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "runtime gantry -> strand") == null);
}

test "closure follows the tests of the root module only, as the compiler builds them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    // An imported module's embedded test names a module its binding lacks:
    // the test build never compiles it, so it is no unresolved import.
    const fixture: Fixture = .{ .gantry_source = "test \"embedded\" { _ = @import(\"unbound\"); _ = @import(\"renamed\"); }" };
    try validate(arena.allocator(), Fixture.config(), fixture, Fixture.read, &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "gantry -> strand") == null);
    // The root module's own tests are built, so its unbound import is real.
    const own: Fixture = .{ .main_source = "pub const runtime = @import(\"gantry\"); test \"own\" { _ = @import(\"unbound\"); }" };
    try std.testing.expectError(error.UnresolvedProductionImport, validate(arena.allocator(), Fixture.config(), own, Fixture.read, &out.writer));
}

test "closure rejects direct test-support production imports and upward toolchain edges" {
    try std.testing.expectError(error.OutsideTheToolchain, runtimeEdge("preflight", "shakedown", true));
    try std.testing.expectError(error.ToolchainLayerViolation, runtimeEdge("gantry", "preflight", true));
    try std.testing.expectError(error.OutsideTheToolchain, runtimeEdge("preflight", "new-family-package", true));
    try runtimeEdge("preflight", "gantry", true);
    try runtimeEdge("gantry", "sweep", true);
}

test "closure rejects resolved pin identity module and compiler mismatches" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    var config = Fixture.config();
    const packages = try a.dupe(Package, config.packages);
    config.packages = packages;
    packages[0].dependencies = &.{ .{ .name = "gantry", .hash = "strand-0.1.0-AwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }, .{ .name = "shakedown", .hash = "shakedown-0.1.0-BAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" } };
    try std.testing.expectError(error.ResolvedPinMismatch, validate(a, config, Fixture{}, Fixture.read, &out.writer));
    packages[0] = Fixture.config().packages[0];
    const modules = try a.dupe(Module, config.modules);
    config.modules = modules;
    modules[1].imports = &.{.{ .name = "renamed", .module = 99 }};
    try std.testing.expectError(error.InvalidClosureConfiguration, validate(a, config, Fixture{}, Fixture.read, &out.writer));
    config = Fixture.config();
    config.zig = "0.18.0";
    try std.testing.expectError(error.UnsupportedClosureConfiguration, validate(a, config, Fixture{}, Fixture.read, &out.writer));
}

test "closure reader cancellation missing input and output failure never become a green verdict" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try std.testing.expectError(error.Canceled, validate(arena.allocator(), Fixture.config(), Fixture{ .failure = error.Canceled }, Fixture.read, &out.writer));
    try std.testing.expectError(error.FileNotFound, validate(arena.allocator(), Fixture.config(), Fixture{ .failure = error.FileNotFound }, Fixture.read, &out.writer));
    var failing = std.Io.Writer.fixed(&.{});
    try std.testing.expectError(error.WriteFailed, validate(arena.allocator(), Fixture.config(), Fixture{}, Fixture.read, &failing));
}

test "closure validates native content-hash project identity and rejects renamed fingerprints" {
    const hash = "gantry-0.1.0-1iNrkYwDDACsflv8JL7EcKNxh68qFeRvfnj44o2gpGWP";
    const actual: Identity = .{ .name = "gantry", .fingerprint = 0xbcb052ec916b23d6 };
    try matchesHash(hash, actual);
    try std.testing.expectError(error.ResolvedIdentityMismatch, matchesHash(hash, .{ .name = "sweep", .fingerprint = actual.fingerprint }));
    try std.testing.expectError(error.ResolvedIdentityMismatch, matchesHash(hash, .{ .name = actual.name, .fingerprint = actual.fingerprint ^ 1 }));
    try std.testing.expectError(error.ResolvedIdentityMismatch, matchesHash("gantry-0.1.0-............................................", actual));
}

test "closure skips gantry dead facts but rejects unsupported reachable import recovery" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try validate(arena.allocator(), Fixture.config(), Fixture{ .gantry_source = "const unused = @import(\"renamed\"); pub const value = 1;" }, Fixture.read, &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "runtime gantry -> strand") == null);
    try std.testing.expectError(error.UnsupportedReachabilityFacts, validate(arena.allocator(), Fixture.config(), Fixture{ .gantry_source = "pub const value = @import(dynamic);" }, Fixture.read, &out.writer));
    try std.testing.expectError(error.ResolvedIdentityMismatch, validate(arena.allocator(), Fixture.config(), Fixture{ .nested_manifest = ".{ .name = .uplink, .fingerprint = 3, .dependencies = .{} }" }, Fixture.read, &out.writer));
}
