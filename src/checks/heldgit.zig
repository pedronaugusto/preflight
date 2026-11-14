//! The package's held git: one git release, named with its hashes in `ci/workflow.json`
//! (`"git": {"version", "sha256", "windows": {"x86_64", "aarch64"}}`), on every job that runs
//! the package's tests, so a result that compares against git never depends on the runner's.
//! A package that names none keeps the runner's git.
//!
//! On Windows it is that Git for Windows release, its installer checked against the hash the
//! configuration holds. Everywhere else, and on the riscv64 machine, preflight builds it from
//! git's release tarball, checked against the configuration's hash, with zig cc for a target
//! named outright and the libraries it links built from the sources preflight pins (zlib,
//! LibreSSL, curl): no compiler, header or library of the host's enters, which the build checks
//! by reading what every program it made links. A build is kept in a store, one per release,
//! recipe and target, which a hosted job caches by that name.
//!
//! What it holds is what the family's interop suites run through git (relic's): HTTP and HTTPS
//! as a client (curl, LibreSSL), git's daemon and http-backend, credential helpers, iconv (the
//! platform's own: glibc's, Apple's /usr/lib/libiconv, musl's) and, on macOS, the fsmonitor
//! daemon. Left out, each failing by name where it is asked for: Perl's commands (send-email,
//! svn), Python's, Tcl's, gettext's translations (git speaks English), PCRE (`grep -P`) and
//! expat (`http-push` over WebDAV).
const std = @import("std");
const builtin = @import("builtin");
const aegis = @import("aegis");
const src = @import("source.zig");
const command = @import("command.zig");

/// The recipe below, numbered: a change to how git or its libraries are built takes a new
/// number, and so a new name in the store and in the hosted job's cache.
pub const recipe = 1;

/// The sources preflight pins (`build.zig.zon`), by the versions the store names.
pub const sources = .{ .zlib = "1.4", .libressl = "4.4.1", .curl = "8.23.0" };

/// What the configuration says of the held git.
pub const Held = struct {
    version: []const u8,
    /// Of `git-<version>.tar.xz`, git's release tarball.
    sha256: []const u8,
    /// Of Git for Windows' installers of the release, `Git-<version>-64-bit.exe` and
    /// `Git-<version>-arm64.exe`.
    windows_x86_64: []const u8,
    windows_aarch64: []const u8,
};

/// Why the configuration's `git` was refused, set when `parse` fails.
pub var problem: []const u8 = "";

/// The held git `config` (all of `ci/workflow.json`) names; null where it names none.
pub fn parse(config: src.Value) error{InvalidHeldGit}!?Held {
    const value = src.get(config, "git");
    if (value == .null) return null;
    if (value != .object) return refuse("git is an object: {\"version\": \"2.56.0\", \"sha256\": ..., \"windows\": {\"x86_64\": ..., \"aarch64\": ...}}; `preflight held-git pin <version>` writes it");
    for (value.object.keys()) |key| if (!isOneOf(key, &.{ "version", "sha256", "windows" })) return refuse("git takes version, sha256 and windows, nothing else");
    const version = string(value, "version") orelse return refuse("git.version is a release, as 2.56.0");
    if (!isRelease(version)) return refuse("git.version is a release, three numbers, as 2.56.0");
    const sha256 = string(value, "sha256") orelse return refuse("git.sha256 is the sha256 of git-<version>.tar.xz, 64 lowercase hex digits");
    if (!isDigest(sha256)) return refuse("git.sha256 is the sha256 of git-<version>.tar.xz, 64 lowercase hex digits");
    const windows = src.get(value, "windows");
    if (windows != .object) return refuse("git.windows holds the sha256 of each Git for Windows installer: {\"x86_64\": ..., \"aarch64\": ...}");
    for (windows.object.keys()) |key| if (!isOneOf(key, &.{ "x86_64", "aarch64" })) return refuse("git.windows takes x86_64 and aarch64, nothing else");
    const x86 = string(windows, "x86_64") orelse return refuse("git.windows.x86_64 is the sha256 of Git-<version>-64-bit.exe");
    const arm = string(windows, "aarch64") orelse return refuse("git.windows.aarch64 is the sha256 of Git-<version>-arm64.exe");
    if (!isDigest(x86) or !isDigest(arm)) return refuse("git.windows's hashes are sha256s, 64 lowercase hex digits");
    return .{ .version = version, .sha256 = sha256, .windows_x86_64 = x86, .windows_aarch64 = arm };
}

fn refuse(why: []const u8) error{InvalidHeldGit} {
    problem = why;
    return error.InvalidHeldGit;
}

fn string(object: src.Value, key: []const u8) ?[]const u8 {
    const value = src.get(object, key);
    return if (value == .string) value.string else null;
}

fn isOneOf(key: []const u8, keys: []const []const u8) bool {
    for (keys) |known| if (std.mem.eql(u8, key, known)) return true;
    return false;
}

/// Whether `text` is a release's version: three dot-separated numbers.
pub fn isRelease(text: []const u8) bool {
    var parts = std.mem.splitScalar(u8, text, '.');
    var count: usize = 0;
    while (parts.next()) |part| : (count += 1) {
        if (part.len == 0 or part.len > 4) return false;
        for (part) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return count == 3;
}

/// Whether `text` is a sha256 as the configuration writes one.
pub fn isDigest(text: []const u8) bool {
    if (text.len != 64) return false;
    for (text) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

/// Where git's release tarball is published.
pub fn tarballUrl(a: std.mem.Allocator, version: []const u8) ![]const u8 {
    return a.print("https://www.kernel.org/pub/software/scm/git/git-{s}.tar.xz", .{version});
}

/// Git for Windows' installer of `version` for `arch`: the first Windows build of the release.
pub fn windowsInstaller(a: std.mem.Allocator, version: []const u8, arch: std.Target.Cpu.Arch) !struct { url: []const u8, name: []const u8 } {
    const name = try a.print("Git-{s}-{s}.exe", .{ version, if (arch == .aarch64) "arm64" else "64-bit" });
    return .{ .url = try a.print("https://github.com/git-for-windows/git/releases/download/v{s}.windows.1/{s}", .{ version, name }), .name = name };
}

/// A target the held git is built for, named outright: the zig cc target, the triple the
/// libraries' configure scripts are given, and what git's Makefile would have asked `uname`.
pub const Platform = struct {
    /// The store's name for it.
    name: []const u8,
    zig: []const u8,
    host: []const u8,
    uname_s: []const u8,
    uname_m: []const u8,
    /// The platform's own certificate bundle, which curl reads at run time: what an HTTPS
    /// URL is verified against unless `http.sslCAInfo` names another.
    ca_bundle: []const u8,
    kind: enum { macos, glibc, musl },
};

/// The platforms the held git is built for: hosted Linux and macOS runners, and the riscv64
/// machine. Null for any other.
pub fn platform(target: std.Target) ?Platform {
    const arch = target.cpu.arch;
    if (arch != .x86_64 and arch != .aarch64 and arch != .riscv64) return null;
    switch (target.os.tag) {
        .macos => if (arch != .riscv64) return .{
            .name = if (arch == .x86_64) "x86_64-macos" else "aarch64-macos",
            .zig = if (arch == .x86_64) "x86_64-macos.13.0" else "aarch64-macos.13.0",
            .host = if (arch == .x86_64) "x86_64-apple-darwin" else "aarch64-apple-darwin",
            .uname_s = "Darwin",
            .uname_m = if (arch == .x86_64) "x86_64" else "arm64",
            .ca_bundle = "/etc/ssl/cert.pem",
            .kind = .macos,
        },
        .linux => if (target.abi.isMusl()) {
            if (arch == .riscv64) return .{ .name = "riscv64-linux-musl", .zig = "riscv64-linux-musl", .host = "riscv64-linux-musl", .uname_s = "Linux", .uname_m = "riscv64", .ca_bundle = "/etc/ssl/certs/ca-certificates.crt", .kind = .musl };
        } else if (arch != .riscv64) return .{
            .name = if (arch == .x86_64) "x86_64-linux-gnu" else "aarch64-linux-gnu",
            // The oldest glibc a hosted runner has had (Ubuntu 20.04).
            .zig = if (arch == .x86_64) "x86_64-linux-gnu.2.31" else "aarch64-linux-gnu.2.31",
            .host = if (arch == .x86_64) "x86_64-linux-gnu" else "aarch64-linux-gnu",
            .uname_s = "Linux",
            .uname_m = if (arch == .x86_64) "x86_64" else "aarch64",
            .ca_bundle = "/etc/ssl/certs/ca-certificates.crt",
            .kind = .glibc,
        },
        else => {},
    }
    return null;
}

/// The store's name for a build: the release, the first twelve digits of its tarball's hash,
/// the recipe and the platform. The hosted job caches the store by it.
pub fn buildName(a: std.mem.Allocator, held: Held, p: Platform) ![]const u8 {
    return a.print("git-{s}-{s}-r{d}-{s}", .{ held.version, held.sha256[0..12], recipe, p.name });
}

/// Where the sources and the machine's SDK are, for a build.
pub const Inputs = struct {
    zig: []const u8,
    zlib: []const u8,
    libressl: []const u8,
    curl: []const u8,
    /// The macOS SDK, whose base libraries and frameworks a macOS build links.
    sdk: ?[]const u8 = null,
    jobs: usize = 4,
};

/// The environment every step of a build runs with: zig cc for the platform, the libraries
/// built so far, and no pkg-config path but theirs.
pub fn environment(a: std.mem.Allocator, parent: *const std.process.Environ.Map, p: Platform, in: Inputs, prefix: []const u8) !std.process.Environ.Map {
    var env = try parent.clone(a);
    try env.put("CC", try a.print("{s} cc -target {s}", .{ in.zig, p.zig }));
    try env.put("AR", try a.print("{s} ar", .{in.zig}));
    try env.put("RANLIB", try a.print("{s} ranlib", .{in.zig}));
    try env.put("CPPFLAGS", try a.print("-I{s}/include{s}", .{ prefix, try frameworks(a, p, in) }));
    try env.put("LDFLAGS", try linkPaths(a, p, in, prefix));
    try env.put("PKG_CONFIG_LIBDIR", try a.print("{s}/lib/pkgconfig", .{prefix}));
    _ = env.swapRemove("PKG_CONFIG_PATH");
    _ = env.swapRemove("CFLAGS");
    _ = env.swapRemove("LIBS");
    return env;
}

fn frameworks(a: std.mem.Allocator, p: Platform, in: Inputs) ![]const u8 {
    if (p.kind != .macos) return "";
    return a.print(" -F{s}/System/Library/Frameworks", .{in.sdk.?});
}

fn linkPaths(a: std.mem.Allocator, p: Platform, in: Inputs, prefix: []const u8) ![]const u8 {
    if (p.kind != .macos) return a.print("-L{s}/lib", .{prefix});
    return a.print("-L{s}/lib -L{s}/usr/lib -F{s}/System/Library/Frameworks", .{ prefix, in.sdk.?, in.sdk.? });
}

/// One step of a build: a command in a source directory.
pub const Step = struct { cwd: []const u8, argv: []const []const u8 };

/// The build's steps, in order: zlib, LibreSSL and curl into `prefix`, then git into `out`,
/// each source copied to `work` first (a pinned source is never written to).
pub fn steps(a: std.mem.Allocator, p: Platform, in: Inputs, work: []const u8, prefix: []const u8, out: []const u8) ![]const Step {
    const jobs = try a.print("-j{d}", .{in.jobs});
    const zlib = try std.fs.path.join(a, &.{ work, "zlib" });
    const libressl = try std.fs.path.join(a, &.{ work, "libressl" });
    const curl = try std.fs.path.join(a, &.{ work, "curl" });
    const git = try std.fs.path.join(a, &.{ work, "git" });
    var list: std.ArrayList(Step) = .empty;
    try list.appendSlice(a, &.{
        .{ .cwd = zlib, .argv = &.{ "./configure", "--static", try a.print("--prefix={s}", .{prefix}) } },
        .{ .cwd = zlib, .argv = &.{ "make", jobs, "install" } },
        .{ .cwd = libressl, .argv = &.{ "./configure", try a.print("--host={s}", .{p.host}), try a.print("--prefix={s}", .{prefix}), "--disable-shared", "--enable-static", "--disable-asm", "--disable-tests" } },
        .{ .cwd = libressl, .argv = &.{ "make", jobs } },
        .{ .cwd = libressl, .argv = &.{ "make", "install" } },
        .{ .cwd = curl, .argv = try curlConfigure(a, p, prefix) },
        .{ .cwd = curl, .argv = &.{ "make", jobs } },
        .{ .cwd = curl, .argv = &.{ "make", "install" } },
    });
    const make = try gitMake(a, p, in, prefix, out);
    try list.append(a, .{ .cwd = git, .argv = try std.mem.concat(a, []const u8, &.{ &.{ "make", jobs }, make, &.{"all"} }) });
    try list.append(a, .{ .cwd = git, .argv = try std.mem.concat(a, []const u8, &.{ &.{"make"}, make, &.{"install"} }) });
    return list.items;
}

fn curlConfigure(a: std.mem.Allocator, p: Platform, prefix: []const u8) ![]const []const u8 {
    return a.dupe([]const u8, &.{
        "./configure",                             try a.print("--host={s}", .{p.host}),
        try a.print("--prefix={s}", .{prefix}),    "--disable-shared",
        "--enable-static",                         try a.print("--with-openssl={s}", .{prefix}),
        try a.print("--with-zlib={s}", .{prefix}), try a.print("--with-ca-bundle={s}", .{p.ca_bundle}),
        "--without-ca-path",                       "--without-libpsl",
        "--without-libidn2",                       "--without-brotli",
        "--without-zstd",                          "--without-nghttp2",
        "--without-nghttp3",                       "--without-ngtcp2",
        "--without-libssh2",                       "--without-libssh",
        "--without-librtmp",                       "--without-libgsasl",
        "--disable-ldap",                          "--disable-ldaps",
        "--disable-docs",                          "--disable-manual",
    });
}

/// git's Makefile variables. `uname_*` are the platform's, never the host's; `LD_MAJOR_VERSION`
/// is empty so the Makefile asks no host linker its version (zig's linker takes none of the
/// flags it would add); curl is linked from its archive with what it needs, frameworks git
/// links of its own left out (zig's linker keeps a framework named twice, and dyld refuses a
/// program that names one twice). RUNTIME_PREFIX finds git's programs beside the binary, so a
/// build moved from the store still runs.
fn gitMake(a: std.mem.Allocator, p: Platform, in: Inputs, prefix: []const u8, out: []const u8) ![]const []const u8 {
    const macos = p.kind == .macos;
    var vars: std.ArrayList([]const u8) = .empty;
    try vars.appendSlice(a, &.{
        try a.print("CC={s} cc -target {s}", .{ in.zig, p.zig }),
        try a.print("AR={s} ar", .{in.zig}),
        try a.print("CFLAGS=-O2 -I{s}/include{s}", .{ prefix, if (macos) try a.print(" -idirafter {s}/usr/include -F{s}/System/Library/Frameworks", .{ in.sdk.?, in.sdk.? }) else "" }),
        try a.print("LDFLAGS={s}", .{try linkPaths(a, p, in, prefix)}),
        try a.print("CURL_CONFIG={s}/bin/curl-config", .{prefix}),
        try a.print("CURL_LDFLAGS={s}/lib/libcurl.a -lssl -lcrypto -lz{s}", .{ prefix, if (macos) " -framework CoreFoundation -framework SystemConfiguration" else " -lpthread" }),
        try a.print("ZLIB_PATH={s}", .{prefix}),
        try a.print("OPENSSLDIR={s}", .{prefix}),
        try a.print("uname_S={s}", .{p.uname_s}),
        try a.print("uname_M={s}", .{p.uname_m}),
        try a.print("uname_O={s}", .{if (macos) "Darwin" else "GNU/Linux"}),
        "uname_R=",
        "uname_P=",
        "uname_V=",
        "LD_MAJOR_VERSION=",
        "RUNTIME_PREFIX=YesPlease",
        "NO_PERL=YesPlease",
        "NO_PYTHON=YesPlease",
        "NO_TCLTK=YesPlease",
        "NO_GETTEXT=YesPlease",
        "NO_EXPAT=YesPlease",
        "NO_RUST=YesPlease",
        "INSTALL_SYMLINKS=YesPlease",
        try a.print("prefix={s}", .{out}),
    });
    if (macos) try vars.append(a, "NO_APPLE_COMMON_CRYPTO=YesPlease");
    return vars.items;
}

/// The libraries a program of the held git may link on `p`: the platform's base and nothing
/// else; on musl none, the build being static.
pub fn allowed(p: Platform, library: []const u8) bool {
    const base: []const []const u8 = switch (p.kind) {
        .macos => &.{
            "/usr/lib/libSystem.B.dylib",
            "/usr/lib/libiconv.2.dylib",
            "/usr/lib/libobjc.A.dylib",
            "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation",
            "/System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices",
            "/System/Library/Frameworks/SystemConfiguration.framework/Versions/A/SystemConfiguration",
            "/System/Library/Frameworks/Security.framework/Versions/A/Security",
        },
        .glibc => &.{ "libc.so.6", "libm.so.6", "libpthread.so.0", "libdl.so.2", "librt.so.1", "libresolv.so.2", "ld-linux-x86-64.so.2", "ld-linux-aarch64.so.1" },
        .musl => &.{},
    };
    return isOneOf(library, base);
}

/// What a program links, read from its own headers: a Mach-O's dylib load commands, an
/// ELF's DT_NEEDED entries; empty for a file that is neither (a script) or links nothing.
pub fn linked(a: std.mem.Allocator, bytes: []const u8) ![]const []const u8 {
    if (bytes.len >= 4 and std.mem.readInt(u32, bytes[0..4], .little) == 0xfeedfacf) return machoLinked(a, bytes);
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "\x7fELF")) return elfLinked(a, bytes);
    return &.{};
}

fn machoLinked(a: std.mem.Allocator, bytes: []const u8) ![]const []const u8 {
    if (bytes.len < 32) return error.TruncatedProgram;
    const count = std.mem.readInt(u32, bytes[16..20], .little);
    var at: usize = 32;
    var list: std.ArrayList([]const u8) = .empty;
    for (0..count) |_| {
        if (at + 8 > bytes.len) return error.TruncatedProgram;
        const cmd = std.mem.readInt(u32, bytes[at..][0..4], .little);
        const size = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
        if (size < 8 or at + size > bytes.len) return error.TruncatedProgram;
        // LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB.
        switch (cmd) {
            0xc, 0x80000018, 0x8000001f, 0x20, 0x80000023 => {
                if (size < 12) return error.TruncatedProgram;
                const offset = std.mem.readInt(u32, bytes[at + 8 ..][0..4], .little);
                if (offset >= size) return error.TruncatedProgram;
                const name = bytes[at + offset .. at + size];
                try list.append(a, name[0 .. std.mem.findScalar(u8, name, 0) orelse name.len]);
            },
            else => {},
        }
        at += size;
    }
    return list.items;
}

fn elfLinked(a: std.mem.Allocator, bytes: []const u8) ![]const []const u8 {
    // 64-bit little-endian: every platform above.
    if (bytes.len < 64 or bytes[4] != 2 or bytes[5] != 1) return error.UnsupportedProgram;
    const shoff = std.mem.readInt(u64, bytes[0x28..][0..8], .little);
    const shentsize = std.mem.readInt(u16, bytes[0x3a..][0..2], .little);
    const shnum = std.mem.readInt(u16, bytes[0x3c..][0..2], .little);
    var list: std.ArrayList([]const u8) = .empty;
    for (0..shnum) |i| {
        const header = std.math.cast(usize, shoff + i * shentsize) orelse return error.TruncatedProgram;
        if (header + 64 > bytes.len) return error.TruncatedProgram;
        // SHT_DYNAMIC.
        if (std.mem.readInt(u32, bytes[header + 4 ..][0..4], .little) != 6) continue;
        const offset: usize = @intCast(std.mem.readInt(u64, bytes[header + 0x18 ..][0..8], .little));
        const size: usize = @intCast(std.mem.readInt(u64, bytes[header + 0x20 ..][0..8], .little));
        const link = std.mem.readInt(u32, bytes[header + 0x28 ..][0..4], .little);
        const strings_header = std.math.cast(usize, shoff + @as(u64, link) * shentsize) orelse return error.TruncatedProgram;
        if (strings_header + 64 > bytes.len or offset + size > bytes.len) return error.TruncatedProgram;
        const strings: usize = @intCast(std.mem.readInt(u64, bytes[strings_header + 0x18 ..][0..8], .little));
        var entry: usize = offset;
        while (entry + 16 <= offset + size) : (entry += 16) {
            const tag = std.mem.readInt(u64, bytes[entry..][0..8], .little);
            if (tag == 0) break;
            // DT_NEEDED.
            if (tag != 1) continue;
            const at = strings + @as(usize, @intCast(std.mem.readInt(u64, bytes[entry + 8 ..][0..8], .little)));
            if (at >= bytes.len) return error.TruncatedProgram;
            const rest = bytes[at..];
            try list.append(a, rest[0 .. std.mem.findScalar(u8, rest, 0) orelse rest.len]);
        }
    }
    return list.items;
}

/// Why a program of the build may not stand: a library outside the platform's base, or one
/// named twice; null when it may.
pub fn linkProblem(a: std.mem.Allocator, p: Platform, libraries: []const []const u8) !?[]const u8 {
    for (libraries, 0..) |library, i| {
        if (!allowed(p, library)) return try a.print("links {s}, which is neither a pinned source nor the platform's base", .{library});
        for (libraries[0..i]) |earlier| if (std.mem.eql(u8, earlier, library)) return try a.print("links {s} twice, which dyld refuses", .{library});
    }
    return null;
}

/// `url`'s bytes, checked against `sha256`, fetched up to three times.
fn fetchChecked(c: *src.Context, url: []const u8, sha256: []const u8) ![]const u8 {
    for (0..command.backoff.len + 1) |attempt| {
        const bytes = fetch(c, url) catch |err| {
            if (attempt == command.backoff.len) {
                c.fail("held git: {s} could not be fetched: {t}", .{ url, err });
                return error.CheckFailed;
            }
            c.report("held git: {s} failed ({t}); retry {d}/{d}\n", .{ url, err, attempt + 2, command.backoff.len + 1 });
            try std.Io.sleep(c.io, command.backoff[attempt], .awake);
            continue;
        };
        const found = digest(bytes);
        if (!std.mem.eql(u8, &found, sha256)) {
            c.fail("held git: {s} has sha256 {s}, and ci/workflow.json holds {s}: not the release the package names", .{ url, &found, sha256 });
            return error.CheckFailed;
        }
        return bytes;
    }
    unreachable;
}

fn fetch(c: *src.Context, url: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = c.a, .io = c.io };
    defer client.deinit();
    var output: std.Io.Writer.Allocating = .init(c.a);
    const response = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &output.writer });
    if (response.status != .ok) return error.DownloadFailed;
    return output.written();
}

fn digest(bytes: []const u8) [64]u8 {
    var sum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &sum, .{});
    return std.fmt.bytesToHex(sum, .lower);
}

/// The store's default: `PREFLIGHT_GIT_STORE` (a hosted job's, which it caches), else
/// `preflight-git` in Zig's global cache.
pub fn defaultStore(c: *src.Context, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("PREFLIGHT_GIT_STORE")) |store| if (store.len != 0) return store;
    if (environ.get("ZIG_GLOBAL_CACHE_DIR")) |cache| if (cache.len != 0) return std.fs.path.join(c.a, &.{ cache, "preflight-git" });
    const home = environ.get("HOME") orelse environ.get("USERPROFILE") orelse return error.NoStore;
    return std.fs.path.join(c.a, &.{ home, ".cache", "zig", "preflight-git" });
}

/// The held git for `p` in `store`, built there from the release tarball and the pinned
/// sources when it is not yet: its directory, whose `bin/git` is the release.
pub fn build(c: *src.Context, environ: *const std.process.Environ.Map, held: Held, p: Platform, in: Inputs, store: []const u8) ![]const u8 {
    const io = c.io;
    const name = try buildName(c.a, held, p);
    const out = try std.fs.path.join(c.a, &.{ store, name });
    const git = try std.fs.path.join(c.a, &.{ out, "bin", "git" });
    if (exists(io, git)) {
        c.report("held git: {s}, kept in {s}\n", .{ name, store });
        return out;
    }
    const work = try std.fs.path.join(c.a, &.{ store, try c.a.print("{s}.work", .{name}) });
    const partial = try std.fs.path.join(c.a, &.{ store, try c.a.print("{s}.partial", .{name}) });
    try std.Io.Dir.cwd().deleteTree(io, work);
    try std.Io.Dir.cwd().deleteTree(io, partial);
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(c.a, &.{ work, "git" }));
    c.report("held git: building {s} (zlib {s}, LibreSSL {s}, curl {s}, zig cc -target {s})\n", .{ name, sources.zlib, sources.libressl, sources.curl, p.zig });
    const tarball = try fetchChecked(c, try tarballUrl(c.a, held.version), held.sha256);
    const archive = try std.fs.path.join(c.a, &.{ work, "git.tar.xz" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = archive, .data = tarball });
    try run(c, environ, work, &.{ "tar", "-xf", archive, "-C", "git", "--strip-components=1" });
    // The pinned sources are read-only: each is copied to be built.
    for ([_][]const u8{ in.zlib, in.libressl, in.curl }, [_][]const u8{ "zlib", "libressl", "curl" }) |from, to| {
        try run(c, environ, work, &.{ "cp", "-R", try c.a.print("{s}/.", .{from}), to });
        try run(c, environ, work, &.{ "chmod", "-R", "u+w", to });
    }
    const prefix = try std.fs.path.join(c.a, &.{ work, "prefix" });
    var env = try environment(c.a, environ, p, in, prefix);
    for (try steps(c.a, p, in, work, prefix, partial)) |step| try run(c, &env, step.cwd, step.argv);
    try check(c, held, p, partial);
    try std.Io.Dir.rename(std.Io.Dir.cwd(), partial, std.Io.Dir.cwd(), out, io);
    try std.Io.Dir.cwd().deleteTree(io, work);
    c.report("held git: {s} built into {s}\n", .{ name, store });
    return out;
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn run(c: *src.Context, environ: *const std.process.Environ.Map, cwd: []const u8, argv: []const []const u8) !void {
    var child = try std.process.spawn(c.io, .{ .argv = argv, .cwd = .{ .path = cwd }, .environ_map = environ });
    const term = try child.wait(c.io);
    if (term == .exited and term.exited == 0) return;
    c.fail("held git: `{s}` in {s} failed", .{ try std.mem.join(c.a, " ", argv), cwd });
    return error.CheckFailed;
}

/// A build stands when its git is the release and every program it made links the
/// platform's base alone, each library once.
fn check(c: *src.Context, held: Held, p: Platform, out: []const u8) !void {
    const io = c.io;
    // A build for another machine (the riscv64 one) is run there, not here.
    const here = platform(builtin.target);
    if (here != null and std.mem.eql(u8, here.?.name, p.name)) {
        const said = try std.process.run(c.a, io, .{ .argv = &.{ try std.fs.path.join(c.a, &.{ out, "bin", "git" }), "--version" } });
        const want = try c.a.print("git version {s}", .{held.version});
        if (!command.succeeded(said) or !std.mem.eql(u8, std.mem.trimEnd(u8, said.stdout, "\r\n"), want)) {
            c.fail("held git: the build says {s}, not {s}", .{ std.mem.trimEnd(u8, said.stdout, "\r\n"), want });
            return error.CheckFailed;
        }
    }
    for ([_][]const u8{ "bin", "libexec/git-core" }) |sub| {
        const path = try std.fs.path.join(c.a, &.{ out, sub });
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            // glint-ignore: A009 -- the build's own programs, which this reads only for what they link
            const bytes = try dir.readFileAlloc(io, entry.name, c.a, .unlimited);
            const libraries = linked(c.a, bytes) catch |err| {
                c.fail("held git: {s}/{s} could not be read: {t}", .{ path, entry.name, err });
                return error.CheckFailed;
            };
            if (try linkProblem(c.a, p, libraries)) |why| {
                c.fail("held git: {s}/{s} {s}", .{ path, entry.name, why });
                return error.CheckFailed;
            }
        }
    }
}

/// Git for Windows' release `held` names, installed where the runner's own is (`C:\Program
/// Files\Git`), from its installer checked against the configuration's hash and kept in the
/// store. The path that runs it: `cmd\git.exe` there.
pub fn installWindows(c: *src.Context, environ: *const std.process.Environ.Map, held: Held, arch: std.Target.Cpu.Arch, store: []const u8) !void {
    const io = c.io;
    const installer = try windowsInstaller(c.a, held.version, arch);
    const sha256 = if (arch == .aarch64) held.windows_aarch64 else held.windows_x86_64;
    const kept = try std.fs.path.join(c.a, &.{ store, installer.name });
    try std.Io.Dir.cwd().createDirPath(io, store);
    // glint-ignore: A009 -- an installer this store kept, checked against its hash before it runs
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, kept, c.a, .unlimited) catch try fetchChecked(c, installer.url, sha256);
    if (!std.mem.eql(u8, &digest(bytes), sha256)) {
        c.fail("held git: {s} has sha256 {s}, and ci/workflow.json holds {s}", .{ kept, &digest(bytes), sha256 });
        return error.CheckFailed;
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = kept, .data = bytes });
    try run(c, environ, store, &.{ kept, "/VERYSILENT", "/NORESTART", "/NOCANCEL", "/SP-", "/SUPPRESSMSGBOXES", "/CLOSEAPPLICATIONS" });
    const programs = environ.get("ProgramFiles") orelse "C:\\Program Files";
    const git = try std.fs.path.join(c.a, &.{ programs, "Git", "cmd", "git.exe" });
    const said = try std.process.run(c.a, io, .{ .argv = &.{ git, "--version" } });
    const want = try c.a.print("git version {s}.windows.1", .{held.version});
    if (!command.succeeded(said) or !std.mem.eql(u8, std.mem.trimEnd(u8, said.stdout, "\r\n"), want)) {
        c.fail("held git: {s} says {s}, not {s}", .{ git, std.mem.trimEnd(u8, said.stdout, "\r\n"), want });
        return error.CheckFailed;
    }
    c.report("held git: {s}\n", .{want});
}

/// The `git` of `ci/workflow.json` for `version`: its tarball's and installers' hashes, each
/// fetched and hashed here, written for the diff to show.
pub fn pin(c: *src.Context, path: []const u8, version: []const u8) !void {
    if (!isRelease(version)) {
        c.fail("held-git-pin: {s} is no release; name one as 2.56.0", .{version});
        return error.CheckFailed;
    }
    var hashes: [3][64]u8 = undefined;
    const urls = [_][]const u8{ try tarballUrl(c.a, version), (try windowsInstaller(c.a, version, .x86_64)).url, (try windowsInstaller(c.a, version, .aarch64)).url };
    for (urls, &hashes) |url, *hash| {
        c.report("held-git-pin: {s}\n", .{url});
        hash.* = digest(fetch(c, url) catch |err| {
            c.fail("held-git-pin: {s} could not be fetched: {t}", .{ url, err });
            return error.CheckFailed;
        });
    }
    var config = try c.options(path);
    if (config != .object) {
        c.fail("held-git-pin: {s} is no JSON object", .{path});
        return error.CheckFailed;
    }
    var windows: std.json.ObjectMap = .empty;
    try windows.put(c.a, "x86_64", .{ .string = &hashes[1] });
    try windows.put(c.a, "aarch64", .{ .string = &hashes[2] });
    var git: std.json.ObjectMap = .empty;
    try git.put(c.a, "version", .{ .string = version });
    try git.put(c.a, "sha256", .{ .string = &hashes[0] });
    try git.put(c.a, "windows", .{ .object = windows });
    try config.object.put(c.a, "git", .{ .object = git });
    var text: std.Io.Writer.Allocating = .init(c.a);
    try std.json.Stringify.value(config, .{ .whitespace = .indent_2 }, &text.writer);
    try text.writer.writeByte('\n');
    try c.directory().writeFile(c.io, .{ .sub_path = path, .data = text.written() });
    c.report("held-git-pin: {s} holds git {s}\n", .{ path, version });
}

test "a held git is a release and three sha256s, each refused by name" {
    const a = std.testing.allocator;
    const tarball_sha = "26c56c296b38c0695b26fa95f475f1d01704d2d38e73465ca30b0b2f5dc789d3";
    const good = try std.fmt.allocPrint(a, "{{\"git\": {{\"version\": \"2.56.0\", \"sha256\": \"{s}\", \"windows\": {{\"x86_64\": \"{s}\", \"aarch64\": \"{s}\"}}}}}}", .{ tarball_sha, tarball_sha, tarball_sha });
    defer a.free(good);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, good, .{});
    defer parsed.deinit();
    const held = (try parse(parsed.value)).?;
    try std.testing.expectEqualStrings("2.56.0", held.version);
    try std.testing.expectEqualStrings(tarball_sha, held.windows_aarch64);
    const none = try std.json.parseFromSlice(std.json.Value, a, "{\"targets\": []}", .{});
    defer none.deinit();
    try std.testing.expectEqual(null, try parse(none.value));
    for ([_][]const u8{
        "{\"git\": \"2.56.0\"}",
        "{\"git\": {\"version\": \"2.56\", \"sha256\": \"x\", \"windows\": {}}}",
        "{\"git\": {\"version\": \"2.56.0\", \"sha256\": \"ABC\", \"windows\": {}}}",
        "{\"git\": {\"version\": \"2.56.0\", \"latest\": true}}",
    }) |text| {
        const bad = try std.json.parseFromSlice(std.json.Value, a, text, .{});
        defer bad.deinit();
        try std.testing.expectError(error.InvalidHeldGit, parse(bad.value));
        try std.testing.expect(problem.len != 0);
    }
    try std.testing.expect(isRelease("2.56.0") and !isRelease("2.56") and !isRelease("2.56.0-rc1") and !isRelease("v2.56.0"));
}

test "every hosted platform and the riscv64 machine are named outright, and no other" {
    const query = struct {
        fn of(text: []const u8) !std.Target {
            return std.zig.system.resolveTargetQuery(std.testing.io, try std.Target.Query.parse(.{ .arch_os_abi = text }));
        }
    }.of;
    try std.testing.expectEqualStrings("aarch64-macos.13.0", platform(try query("aarch64-macos")).?.zig);
    try std.testing.expectEqualStrings("x86_64-linux-gnu.2.31", platform(try query("x86_64-linux-gnu")).?.zig);
    try std.testing.expectEqualStrings("riscv64-linux-musl", platform(try query("riscv64-linux-musl")).?.zig);
    try std.testing.expectEqual(null, platform(try query("x86_64-windows-gnu")));
    try std.testing.expectEqual(null, platform(try query("x86_64-freebsd")));
    try std.testing.expectEqual(null, platform(try query("riscv64-linux-gnu")));
}

test "git is made with zig cc for the platform, the host asked nothing, and the features left out named" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const riscv: Platform = platform(try std.zig.system.resolveTargetQuery(std.testing.io, try std.Target.Query.parse(.{ .arch_os_abi = "riscv64-linux-musl" }))).?;
    const made = try steps(a, riscv, .{ .zig = "/z/zig", .zlib = "/s/zlib", .libressl = "/s/libressl", .curl = "/s/curl" }, "/w", "/w/prefix", "/out");
    const git = made[made.len - 2].argv;
    try std.testing.expectEqualStrings("/w/git", made[made.len - 2].cwd);
    for ([_][]const u8{ "CC=/z/zig cc -target riscv64-linux-musl", "uname_S=Linux", "uname_M=riscv64", "LD_MAJOR_VERSION=", "NO_PERL=YesPlease", "NO_EXPAT=YesPlease", "NO_GETTEXT=YesPlease", "RUNTIME_PREFIX=YesPlease", "prefix=/out" }) |variable| {
        try std.testing.expect(isOneOf(variable, git));
    }
    // Neither curl nor iconv is left out: HTTP and HTTPS, and every encoding the platform has.
    for (git) |arg| try std.testing.expect(!std.mem.startsWith(u8, arg, "NO_CURL") and !std.mem.startsWith(u8, arg, "NO_ICONV") and !std.mem.startsWith(u8, arg, "NO_OPENSSL"));
    for (made) |step| try std.testing.expect(std.mem.startsWith(u8, step.cwd, "/w/"));
    const curl = made[5].argv;
    try std.testing.expect(isOneOf("--host=riscv64-linux-musl", curl) and isOneOf("--with-openssl=/w/prefix", curl) and isOneOf("--with-ca-bundle=/etc/ssl/certs/ca-certificates.crt", curl));
}

test "a program may link the platform's base alone, and none twice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mac: Platform = platform(try std.zig.system.resolveTargetQuery(std.testing.io, try std.Target.Query.parse(.{ .arch_os_abi = "aarch64-macos" }))).?;
    const core = "/System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices";
    try std.testing.expectEqual(null, try linkProblem(a, mac, &.{ "/usr/lib/libSystem.B.dylib", "/usr/lib/libiconv.2.dylib", core }));
    try std.testing.expect(try linkProblem(a, mac, &.{ core, "/usr/lib/libSystem.B.dylib", core }) != null);
    try std.testing.expect(try linkProblem(a, mac, &.{"/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib"}) != null);
    const gnu: Platform = platform(try std.zig.system.resolveTargetQuery(std.testing.io, try std.Target.Query.parse(.{ .arch_os_abi = "x86_64-linux-gnu" }))).?;
    try std.testing.expectEqual(null, try linkProblem(a, gnu, &.{ "libc.so.6", "libpthread.so.0" }));
    try std.testing.expect(try linkProblem(a, gnu, &.{"libcurl.so.4"}) != null);
}

test "what a Mach-O program links is read from its load commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bytes: [32 + 2 * 48]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], 0xfeedfacf, .little);
    std.mem.writeInt(u32, bytes[16..20], 2, .little);
    for ([_][]const u8{ "/usr/lib/libSystem.B.dylib", "/usr/lib/libiconv.2.dylib" }, 0..) |name, i| {
        const at = 32 + i * 48;
        std.mem.writeInt(u32, bytes[at..][0..4], 0xc, .little);
        std.mem.writeInt(u32, bytes[at + 4 ..][0..4], 48, .little);
        std.mem.writeInt(u32, bytes[at + 8 ..][0..4], 24, .little);
        @memcpy(bytes[at + 24 ..][0..name.len], name);
    }
    const names = try linked(a, &bytes);
    try std.testing.expectEqual(2, names.len);
    try std.testing.expectEqualStrings("/usr/lib/libiconv.2.dylib", names[1]);
    try std.testing.expectEqual(0, (try linked(a, "#!/bin/sh\n")).len);
}
