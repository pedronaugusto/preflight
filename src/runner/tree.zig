//! A program and every process started under it, held as one tree and ended together, and a
//! supervisor's ending taken as the program's: what preflight's test runner and its bound on
//! the build's other runs (`bound.zig`) share. Std alone: compiled into every package's test
//! binaries, as the runner.
const std = @import("std");
const builtin = @import("builtin");

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
    extern "kernel32" fn SetInformationJobObject(job: std.os.windows.HANDLE, class: c_int, information: *const anyopaque, length: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn AssignProcessToJobObject(job: std.os.windows.HANDLE, process: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn TerminateJobObject(job: std.os.windows.HANDLE, code: std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn TerminateProcess(process: std.os.windows.HANDLE, code: std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn ResumeThread(thread: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.DWORD;
};

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
            const default: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
            std.posix.sigaction(sig, &default, null);
            var only = std.posix.sigemptyset();
            std.posix.sigaddset(&only, sig);
            std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &only, null);
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
