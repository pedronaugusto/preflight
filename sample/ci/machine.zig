//! The host's side of the sample's FreeBSD run (src/testing/machine.zig has the tests').
//! `prepare` makes the channel before the machine boots; `change`, while the tests run,
//! changes the share's directory under the scratch once a test says its file is made, as the
//! host's build does throughout a run; `check`, after the tests, reads what a test made beside
//! the scratch, which the machine carries to the host when the tests end, then removes it.
//! Each acts only where the tests run: shard 1/n of a sharded job, the tests being unsharded.
const std = @import("std");
const machine = @import("machine");

/// How long `change` waits for the test, in tenths of a second: the machine boots and runs
/// the tests before it. The build starts `change` once the machine and the tests are built
/// (build.zig's `Handshake`), so a cold build is never counted.
const ready_wait = 6000;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;
    // The tests are unsharded (build.zig's `addCi`): they run whole on shard 1/n, and on no
    // other, where the host's side has no test to answer.
    const shard = init.environ_map.get("PREFLIGHT_SHARD") orelse "";
    if (shard.len != 0 and !std.mem.startsWith(u8, shard, "1/")) return;
    const cwd = std.Io.Dir.cwd();
    if (std.mem.eql(u8, args[1], "prepare")) {
        try cwd.createDirPath(io, machine.channel);
        var answers = try cwd.openDir(io, machine.channel, .{});
        defer answers.close(io);
        for ([_][]const u8{ machine.ready, machine.changed }) |name| answers.deleteFile(io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    } else if (std.mem.eql(u8, args[1], "change")) {
        var answers = try cwd.openDir(io, machine.channel, .{});
        defer answers.close(io);
        try waitFor(io, answers, machine.ready);
        // A second on, so that the directory's mtime, and so its 9p version, is another.
        try io.sleep(.fromSeconds(1), .awake);
        try cwd.createDirPath(io, machine.scratch);
        var scratch = try cwd.openDir(io, machine.scratch, .{});
        defer scratch.close(io);
        try scratch.writeFile(io, .{ .sub_path = "preflight-sample-host-change", .data = "" });
        try scratch.deleteFile(io, "preflight-sample-host-change");
        try answers.writeFile(io, .{ .sub_path = machine.changed, .data = "" });
    } else if (std.mem.eql(u8, args[1], "check")) {
        var text: [machine.made_text.len]u8 = undefined;
        for ([_][]const u8{ machine.made_file, machine.made_inner, machine.made_link }) |path| {
            const read = cwd.readFile(io, path, &text) catch |err| return named(io, path, err);
            if (!std.mem.eql(u8, read, machine.made_text)) return named(io, path, error.NotWhatTheTestWrote);
        }
        var target: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const link = target[0..try cwd.readLink(io, machine.made_link, &target)];
        if (!std.mem.eql(u8, link, std.fs.path.basename(machine.made_file))) return named(io, machine.made_link, error.NotTheTestsLink);
        try cwd.deleteFile(io, machine.made_link);
        try cwd.deleteFile(io, machine.made_file);
        try cwd.deleteTree(io, machine.made_dir);
    } else return error.Usage;
}

/// `err`, once the path it is about is on stderr.
fn named(io: std.Io, path: []const u8, err: anyerror) anyerror {
    var buffer: [std.Io.Dir.max_path_bytes + 128]u8 = undefined;
    const line = std.mem.print(&buffer, "the sample's FreeBSD run: {s}: {t}\n", .{ path, err }) catch return err;
    // A stderr that refuses the line is the failure to name in its place.
    std.Io.File.stderr().writeStreamingAll(io, line) catch |refused| return refused;
    return err;
}

fn waitFor(io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    for (0..ready_wait) |_| {
        dir.access(io, name, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try io.sleep(.fromMilliseconds(100), .awake);
                continue;
            },
            else => |e| return e,
        };
        return;
    }
    return error.TestNeverReady;
}
