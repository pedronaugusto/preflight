//! A program and every process started under it, held as one tree and ended together, and a
//! supervisor's ending taken as the program's: what preflight's test runner and its bound on
//! the build's other runs (`bound.zig`) share. Std alone: compiled into every package's test
//! binaries, as the runner.
const std = @import("std");
const builtin = @import("builtin");
const inbound = @import("input.zig");

/// A tree's memory, in bytes: what it holds as a whole, and the most any one process of it holds.
/// Parallel compiles do not each hold a share of the whole: one may hold most of it.
pub const Usage = struct { tree: u64, single: u64 };

/// The tests' process and every process started under it, ended together
/// once the tests' process has ended, as conduit contains a child's
/// descendants: a test the watchdog ends, or one that leaves a process
/// running, leaves nothing behind (a `zig build` an integration test
/// started once held a fixture's corpus lock after its test had ended).
/// POSIX: a process group of the tests' own, the tests' process its
/// leader; a process that makes a group or session of its own leaves it.
/// Windows: a job that ends its processes when its last handle closes,
/// which a process leaves only when started to break away from it.
pub const Tree = struct {
    job: if (builtin.target.os.tag == .windows) std.os.windows.HANDLE else void,
    group: if (builtin.target.os.tag == .windows) void else std.posix.pid_t,

    /// The child was started suspended on Windows, so nothing it starts
    /// can be outside the job; elsewhere it leads a new process group.
    pub fn hold(child: *std.process.Child) !Tree {
        if (builtin.target.os.tag != .windows) return .{ .job = {}, .group = child.id.? };
        const windows = std.os.windows;
        errdefer _ = TerminateProcess(child.id.?, 1);
        const job = CreateJobObjectW(null, null) orelse return error.JobUncreated;
        errdefer windows.CloseHandle(job);
        var limits = std.mem.zeroes(ExtendedLimits);
        limits.basic.flags = kill_on_job_close;
        if (SetInformationJobObject(job, extended_limit_information, &limits, @sizeOf(ExtendedLimits)) == .FALSE) return error.JobUnlimited;
        if (AssignProcessToJobObject(job, child.id.?) == .FALSE) return error.JobUnassigned;
        if (ResumeThread(child.thread_handle) == std.math.maxInt(windows.DWORD)) return error.TestsUnresumed;
        return .{ .job = job, .group = {} };
    }

    /// Kills every process of the tree while its leader may still run, as a watchdog
    /// ends a program past its bound: the leader's wait then returns, and `end`
    /// takes what is left.
    pub fn kill(tree: Tree) void {
        if (builtin.target.os.tag == .windows) {
            _ = TerminateJobObject(tree.job, 1);
            return;
        }
        _ = std.posix.system.kill(-tree.group, .KILL);
    }

    /// Kills every process left in the tree. The group's leader has ended
    /// and been waited for, so an empty group is no process at all.
    pub fn end(tree: Tree, sio: std.Io) void {
        if (builtin.target.os.tag == .windows) {
            _ = TerminateJobObject(tree.job, 1);
            std.os.windows.CloseHandle(tree.job);
            return;
        }
        // A process of the group starting another as the group is signaled
        // may add one the signal missed: signal until none is left. An
        // ended process its parent has not waited for still counts, so the
        // tries are bounded.
        for (0..50) |_| {
            switch (std.posix.errno(std.posix.system.kill(-tree.group, .KILL))) {
                .SUCCESS => {},
                else => return,
            }
            // A cancel only shortens the waits between signals: the tree is still ended,
            // and the cancel is armed again for the caller's next cancelation point.
            sio.sleep(.fromMilliseconds(10), .awake) catch |err| switch (err) {
                error.Canceled => sio.recancel(),
            };
        }
    }

    /// The memory the tree holds, or null where it is not read. Linux: what every process of
    /// the group has resident now (`/proc/<pid>/stat`), and the most any one of them has held
    /// (its `VmHWM`), so a caller samples it for its peaks. Windows: the most the job and any
    /// one process of it have committed since it began, its own peaks, which no sample misses.
    /// Elsewhere, as on macOS, it is not read.
    pub fn memory(tree: Tree, io: std.Io) ?Usage {
        switch (builtin.target.os.tag) {
            .windows => {
                var limits = std.mem.zeroes(ExtendedLimits);
                if (QueryInformationJobObject(tree.job, extended_limit_information, &limits, @sizeOf(ExtendedLimits), null) == .FALSE) return null;
                return .{ .tree = limits.peak_job_memory, .single = limits.peak_process_memory };
            },
            .linux => return groupResident(io, tree.group),
            else => return null,
        }
    }

    const kill_on_job_close: u32 = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    const extended_limit_information: c_int = 9; // JobObjectExtendedLimitInformation
    /// `JOBOBJECT_EXTENDED_LIMIT_INFORMATION`.
    const ExtendedLimits = extern struct {
        basic: extern struct {
            per_process_user_time: i64,
            per_job_user_time: i64,
            flags: u32,
            minimum_working_set: usize,
            maximum_working_set: usize,
            active_processes: u32,
            affinity: usize,
            priority_class: u32,
            scheduling_class: u32,
        },
        io: [6]u64,
        process_memory: usize,
        job_memory: usize,
        peak_process_memory: usize,
        peak_job_memory: usize,
    };
    extern "kernel32" fn CreateJobObjectW(security: ?*std.os.windows.SECURITY_ATTRIBUTES, name: ?[*:0]const u16) callconv(.winapi) ?std.os.windows.HANDLE;
    extern "kernel32" fn QueryInformationJobObject(job: std.os.windows.HANDLE, class: c_int, information: *anyopaque, length: std.os.windows.DWORD, returned: ?*std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn SetInformationJobObject(job: std.os.windows.HANDLE, class: c_int, information: *const anyopaque, length: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn AssignProcessToJobObject(job: std.os.windows.HANDLE, process: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn TerminateJobObject(job: std.os.windows.HANDLE, code: std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn TerminateProcess(process: std.os.windows.HANDLE, code: std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn ResumeThread(thread: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.DWORD;
};

/// The resident bytes of every process whose group is `group`, and the most any one of them
/// has held, read from `/proc`; null where `/proc` cannot be listed. A process that ends while
/// it is read is not counted.
fn groupResident(io: std.Io, group: std.posix.pid_t) ?Usage {
    var proc = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch return null;
    defer proc.close(io);
    var entries = proc.iterate();
    var pages: u64 = 0;
    var single: u64 = 0;
    var buffer: [1024]u8 = undefined;
    while (entries.next(io) catch return null) |entry| {
        // A process's directory is its number; the others (self, net) are the kernel's.
        if (entry.name.len == 0 or std.mem.findNone(u8, entry.name, "0123456789") != null) continue;
        var process = proc.openDir(io, entry.name, .{}) catch |err| switch (err) {
            // A process that ended since the listing holds nothing.
            error.FileNotFound => continue,
            // Any other failure leaves the tree's memory unread rather than counted short.
            else => return null,
        };
        defer process.close(io);
        const line = inbound.file(io, process, "stat", &buffer) catch |err| switch (err) {
            error.FileNotFound => continue, // it ended since it was opened
            else => return null, // unread rather than counted short
        };
        const read = statGroupPages(line) orelse return null;
        if (read.group != group) continue;
        pages +|= read.pages;
        const status = inbound.file(io, process, "status", &buffer) catch |err| switch (err) {
            error.FileNotFound => continue, // it ended since its stat was read
            else => return null, // unread rather than counted short
        };
        single = @max(single, highWater(status) orelse (read.pages *| std.heap.pageSize()));
    }
    return .{ .tree = pages *| std.heap.pageSize(), .single = single };
}

/// The most a process has held resident, from its `/proc/<pid>/status` (`VmHWM`, in kB).
fn highWater(status: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        const rest = std.mem.cutPrefix(u8, line, "VmHWM:") orelse continue;
        var fields = std.mem.tokenizeAny(u8, rest, " \t");
        const kb = std.fmt.parseUnsigned(u64, fields.next() orelse return null, 10) catch return null;
        return kb *| 1024;
    }
    return null;
}

/// A process's group and resident pages, from its `/proc/<pid>/stat` line: fields 5 and 24,
/// counted after the command's closing parenthesis, which may itself hold spaces and `)`.
fn statGroupPages(line: []const u8) ?struct { group: i64, pages: u64 } {
    const close = std.mem.findScalarLast(u8, line, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, line[close + 1 ..], ' ');
    var index: usize = 3;
    var group: ?i64 = null;
    while (fields.next()) |field| : (index += 1) {
        if (index == 5) group = std.fmt.parseInt(i64, field, 10) catch return null;
        if (index == 24) return .{ .group = group orelse return null, .pages = std.fmt.parseUnsigned(u64, field, 10) catch return null };
    }
    return null;
}

test "a process's group and resident pages are read past a command holding spaces and parentheses" {
    const line = "4242 (zig (build) x) S 4200 4100 4100 0 -1 4194560 100 0 0 0 5 1 0 0 20 0 3 0 777 1234567 2048 18446744073709551615 1 1 0 0 0 0 0 0 0 0 0 17 2 0 0 0 0 0\n";
    const read = statGroupPages(line).?;
    try std.testing.expectEqual(@as(i64, 4100), read.group);
    try std.testing.expectEqual(@as(u64, 2048), read.pages);
    try std.testing.expectEqual(null, statGroupPages("4242 (cut) S 1 2"));
    try std.testing.expectEqual(null, statGroupPages("no parenthesis"));
    try std.testing.expectEqual(@as(?u64, 9_018_311 * 1024), highWater("Name:\tzig\nVmPeak:\t 12000000 kB\nVmHWM:\t 9018311 kB\nVmRSS:\t 100 kB\n"));
    try std.testing.expectEqual(@as(?u64, null), highWater("Name:\tzig\n"));
}

/// Windows' exit status whole, read before `wait` closes the process
/// handle; elsewhere the status is all in the term.
pub fn waitStatus(child: *std.process.Child) u32 {
    if (builtin.target.os.tag != .windows) return 0;
    const windows = std.os.windows;
    const process = child.id.?;
    _ = WaitForSingleObject(process, std.math.maxInt(windows.DWORD)); // INFINITE
    var code: windows.DWORD = 0;
    if (GetExitCodeProcess(process, &code) == .FALSE) return 1;
    return code;
}

extern "kernel32" fn WaitForSingleObject(handle: std.os.windows.HANDLE, milliseconds: std.os.windows.DWORD) callconv(.winapi) std.os.windows.DWORD;
extern "kernel32" fn GetExitCodeProcess(process: std.os.windows.HANDLE, code: *std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;

/// Ends this process as its program ended: with its exit status (`status`, Windows' whole),
/// or by its signal, so the build reads the program's ending as this process's own. `who`
/// names this process where a signal cannot be raised.
pub fn exitAs(term: std.process.Child.Term, status: u32, who: []const u8) noreturn {
    if (builtin.target.os.tag == .windows) std.os.windows.ntdll.RtlExitUserProcess(status);
    switch (term) {
        .exited => |code| std.process.exit(code),
        .signal => |sig| {
            if (sig == .STOP) unreachable; // a wait reports a stopped program as stopped: STOP ends none
            // KILL's action is the default and nothing blocks it: no process sets either, and
            // std's sigaction asserts it is not asked to.
            if (sig != .KILL) {
                const default: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
                std.posix.sigaction(sig, &default, null);
                var only = std.posix.sigemptyset();
                std.posix.sigaddset(&only, sig);
                std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &only, null);
            }
            // A signal this process cannot raise ends it with the shell's code for that signal,
            // said on stderr; a stderr that takes none of it leaves the code alone to say it.
            const code = 128 +| @as(u8, @truncate(@backingInt(sig)));
            std.posix.raise(sig) catch |err| {
                var buffer: [256]u8 = undefined;
                const stderr = std.debug.lockStderr(&buffer);
                defer std.debug.unlockStderr();
                stderr.file_writer.interface.print("{s}: the signal {t} not raised here ({t}): exiting with the shell's code for it\n", .{ who, sig, err }) catch std.process.exit(code);
                stderr.file_writer.interface.flush() catch std.process.exit(code);
            };
            std.process.exit(code);
        },
        .stopped, .unknown => std.process.exit(1),
    }
}
