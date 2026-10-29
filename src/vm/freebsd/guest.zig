//! The first process of the FreeBSD test machine (vm/freebsd.zig), started by
//! the kernel from its `init_path`. For now it proves the boot: it writes
//! `booted <release>` to the status port (the second serial port), says so on
//! the console, and powers the machine off.
const std = @import("std");

// aegis: boundary: libc's reboot(2), which std.c does not declare for FreeBSD
extern "c" fn reboot(howto: c_int) c_int;
// aegis: boundary: libc's tcdrain(3), which std.c does not declare for FreeBSD
extern "c" fn tcdrain(fd: c_int) c_int;
// aegis: boundary: libc's pause(3), which std.c does not declare
extern "c" fn pause() c_int;
/// sys/reboot.h's RB_POWEROFF: power the machine off after halting.
const power_off = 0x4000;

const status_port = "/dev/cuau1";

pub fn main() void {
    var release_buffer: [64]u8 = undefined;
    var release_len: usize = release_buffer.len;
    const release: []const u8 = if (std.c.sysctlbyname("kern.osrelease", &release_buffer, &release_len, null, 0) == 0) std.mem.sliceTo(release_buffer[0..release_len], 0) else "unknown";
    var line_buffer: [128]u8 = undefined;
    const line = std.mem.print(&line_buffer, "booted {s}\n", .{release}) catch "booted\n";
    say("/dev/console", "preflight: the first process is running; status on " ++ status_port ++ "\n");
    say(status_port, line);
    _ = reboot(power_off);
    // The first process never ends: the kernel panics when it does.
    while (true) _ = pause();
}

/// Writes `text` to the terminal device at `path` and waits until it has left.
fn say(path: [*:0]const u8, text: []const u8) void {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .NOCTTY = true });
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    _ = std.c.write(fd, text.ptr, text.len);
    _ = tcdrain(fd);
}
