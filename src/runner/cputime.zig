//! The CPU time a process and every process started under it have used: what a watchdog
//! (`watchdog.zig`) reads as a tree's progress. Each system's own reading, found by parent
//! links, so a process that makes a group or session of its own (a nested preflight run's
//! tests) still counts: Linux's `/proc`, macOS's libproc, the BSDs' process tables, Windows' job
//! accounting. Every target a package of the family names has its reading, and a target with
//! none fails to compile, by name. Std alone: compiled into every package's test binaries, as
//! the runner.
const std = @import("std");
const builtin = @import("builtin");
/// Linux's `/proc/<pid>/stat` parsed, which `cputime_test.zig` tests through this module.
pub const proc_stat = @import("proc_stat.zig");

const os = builtin.target.os.tag;

/// What a tree is read by: its first process on POSIX, the job that holds it on Windows.
pub const Root = if (os == .windows) std.os.windows.HANDLE else std.posix.pid_t;

/// The tree this process leads, for its watchdog to read: on POSIX this process, and on Windows
/// a job of its own that it joins, with every process it starts after.
pub fn own() !Root {
    switch (os) {
        .windows => {
            const job = Windows.CreateJobObjectW(null, null) orelse return error.JobUncreated;
            // A process already in a job (the runner's supervisor's) joins this one nested in it.
            if (Windows.AssignProcessToJobObject(job, std.os.windows.GetCurrentProcess()) == .FALSE) return error.JobUnjoined;
            return job;
        },
        .linux => return if (builtin.link_libc) std.c.getpid() else std.os.linux.getpid(),
        else => return std.c.getpid(),
    }
}

/// Nanoseconds of CPU time `root` and every process under it have used, the ended ones their
/// parents have waited for among them. A process that ends while the tree is read is counted
/// with its parent once that parent has waited for it.
pub fn tree(io: std.Io, gpa: std.mem.Allocator, root: Root) !u64 {
    return switch (os) {
        .linux => Linux.tree(io, gpa, root),
        .macos => Darwin.tree(gpa, root),
        .windows => Windows.tree(root),
        .freebsd, .netbsd, .openbsd, .dragonfly => Bsd.tree(gpa, root),
        else => @compileError("preflight's watchdog has no reading of a process tree's CPU time on " ++ @tagName(os)),
    };
}

/// One process of a system's table: its parent, and the CPU time it and the children it has
/// waited for have used.
const Process = struct { pid: std.posix.pid_t, parent: std.posix.pid_t, ns: u64 };

/// What `root` and every process whose parent links lead to it have used, of `table`.
fn sum(gpa: std.mem.Allocator, table: []const Process, root: std.posix.pid_t) !u64 {
    var members: std.AutoHashMapUnmanaged(std.posix.pid_t, void) = .empty;
    defer members.deinit(gpa);
    try members.put(gpa, root, {});
    const taken = try gpa.alloc(bool, table.len);
    defer gpa.free(taken);
    @memset(taken, false);
    var total: u64 = 0;
    // One pass per generation: a process is taken once its parent is.
    var grew = true;
    while (grew) {
        grew = false;
        for (table, taken) |process, *is| {
            if (is.* or !(process.pid == root or members.contains(process.parent))) continue;
            is.* = true;
            grew = true;
            try members.put(gpa, process.pid, {});
            total +|= process.ns;
        }
    }
    return total;
}

const Linux = struct {
    const getauxval = if (builtin.link_libc) std.c.getauxval else std.os.linux.getauxval;

    fn tree(io: std.Io, gpa: std.mem.Allocator, root: Root) !u64 {
        const hz = getauxval(std.elf.AT.CLKTCK);
        if (hz == 0) return error.ClockTicksUnknown;
        var proc = try std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true });
        defer proc.close(io);
        var table: std.ArrayList(Process) = .empty;
        defer table.deinit(gpa);
        var entries = proc.iterate();
        var buffer: [1024]u8 = undefined;
        while (try entries.next(io)) |entry| {
            // A process's directory is its number; the others (self, net) are the kernel's.
            if (entry.name.len == 0 or std.mem.findNone(u8, entry.name, "0123456789") != null) continue;
            const pid = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch return error.ProcessNumberUnread;
            var path: [32]u8 = undefined;
            const line = proc.readFile(io, try std.mem.print(&path, "{s}/stat", .{entry.name}), &buffer) catch |err| switch (err) {
                // It ended since the listing (procfs's ESRCH, which Zig names FileNotFound):
                // what it used is its parent's once waited for.
                error.FileNotFound => continue,
                else => |e| return e,
            };
            const read = proc_stat.cpuTicks(line) orelse return error.ProcessStatUnread;
            const parent = std.math.cast(std.posix.pid_t, read.parent) orelse return error.ProcessStatUnread;
            try table.append(gpa, .{ .pid = pid, .parent = parent, .ns = read.ticks *| (std.time.ns_per_s / hz) });
        }
        return sum(gpa, table.items, root);
    }
};

/// libproc: each process's children by `proc_listpids`, and what it and its waited-for
/// children used by `proc_pid_rusage`, in the Mach timebase's units.
const Darwin = struct {
    const ppid_only = 6; // PROC_PPID_ONLY
    const rusage_info_v1 = 1; // RUSAGE_INFO_V1
    /// `struct rusage_info_v1`.
    const RusageInfo = extern struct {
        uuid: [16]u8,
        user_time: u64,
        system_time: u64,
        pkg_idle_wkups: u64,
        interrupt_wkups: u64,
        pageins: u64,
        wired_size: u64,
        resident_size: u64,
        phys_footprint: u64,
        proc_start_abstime: u64,
        proc_exit_abstime: u64,
        child_user_time: u64,
        child_system_time: u64,
        child_pkg_idle_wkups: u64,
        child_interrupt_wkups: u64,
        child_pageins: u64,
        child_elapsed_abstime: u64,
    };
    comptime {
        std.debug.assert(@sizeOf(RusageInfo) == 144);
    }
    extern "c" fn proc_listpids(kind: u32, info: u32, buffer: ?*anyopaque, size: c_int) c_int;
    extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *RusageInfo) c_int;

    fn tree(gpa: std.mem.Allocator, root: Root) !u64 {
        var timebase: std.c.mach_timebase_info_data = undefined;
        if (std.c.mach_timebase_info(&timebase) != 0 or timebase.denom == 0) return error.TimebaseUnread;
        var pending: std.ArrayList(std.posix.pid_t) = .empty;
        defer pending.deinit(gpa);
        try pending.append(gpa, root);
        var children: std.ArrayList(c_int) = .empty;
        defer children.deinit(gpa);
        try children.resize(gpa, 64);
        var ticks: u128 = 0;
        while (pending.pop()) |pid| {
            var info: RusageInfo = undefined;
            if (proc_pid_rusage(pid, rusage_info_v1, &info) != 0) switch (std.posix.errno(-1)) {
                // It ended since its parent listed it: its parent counts it once it has waited.
                .SRCH => continue,
                else => return error.RusageUnread,
            };
            ticks +|= @as(u128, info.user_time) + info.system_time + info.child_user_time + info.child_system_time;
            while (true) {
                const room: c_int = @intCast(children.items.len * @sizeOf(c_int));
                const bytes = proc_listpids(ppid_only, @bitCast(pid), children.items.ptr, room);
                if (bytes < 0) return error.ChildrenUnlisted;
                const listed: usize = @intCast(@divTrunc(bytes, @sizeOf(c_int)));
                // A full buffer may have cut the list: list again into a larger one.
                if (listed >= children.items.len) {
                    try children.resize(gpa, children.items.len * 2);
                    continue;
                }
                for (children.items[0..listed]) |child| if (child > 0) try pending.append(gpa, child);
                break;
            }
        }
        return std.math.cast(u64, ticks * timebase.numer / timebase.denom) orelse std.math.maxInt(u64);
    }
};

/// The job's accounting: every process that was ever in it, those in jobs nested in it among
/// them, in units of 100 ns.
const Windows = struct {
    const basic_accounting: c_int = 1; // JobObjectBasicAccountingInformation
    /// `JOBOBJECT_BASIC_ACCOUNTING_INFORMATION`.
    const Accounting = extern struct {
        total_user_time: i64,
        total_kernel_time: i64,
        this_period_total_user_time: i64,
        this_period_total_kernel_time: i64,
        total_page_fault_count: u32,
        total_processes: u32,
        active_processes: u32,
        total_terminated_processes: u32,
    };
    extern "kernel32" fn CreateJobObjectW(security: ?*std.os.windows.SECURITY_ATTRIBUTES, name: ?[*:0]const u16) callconv(.winapi) ?std.os.windows.HANDLE;
    extern "kernel32" fn AssignProcessToJobObject(job: std.os.windows.HANDLE, process: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn QueryInformationJobObject(job: std.os.windows.HANDLE, class: c_int, information: *anyopaque, length: std.os.windows.DWORD, returned: ?*std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;

    fn tree(job: Root) !u64 {
        var accounting: Accounting = undefined;
        if (QueryInformationJobObject(job, basic_accounting, &accounting, @sizeOf(Accounting), null) == .FALSE) return error.JobUnread;
        const units = std.math.cast(u64, accounting.total_user_time +| accounting.total_kernel_time) orelse return error.JobUnread;
        return units *| 100;
    }
};

/// The BSDs' process tables, one record per process, by `sysctl`: each layout written from the
/// system's own header (`sys/user.h`, `sys/sysctl.h`, `sys/kinfo.h`), its size asserted against
/// the header's, so a layout that drifts fails to compile.
const Bsd = struct {
    fn tree(gpa: std.mem.Allocator, root: Root) !u64 {
        const Record = Layout.Record;
        var mib = Layout.mib;
        var buffer: []align(@alignOf(Record)) u8 = &.{};
        defer gpa.free(buffer);
        // The table grows between the sizing and the read: read again into a larger buffer.
        const records = for (0..8) |_| {
            var size: usize = 0;
            if (std.c.sysctl(&mib, mib.len, null, &size, null, 0) != 0) return error.ProcessTableUnread;
            size += size / 4 + @sizeOf(Record);
            gpa.free(buffer);
            buffer = &.{};
            buffer = try gpa.alignedAlloc(u8, .of(Record), size);
            Layout.count(&mib, size);
            if (std.c.sysctl(&mib, mib.len, buffer.ptr, &size, null, 0) == 0) break std.mem.bytesAsSlice(Record, buffer[0 .. size - size % @sizeOf(Record)]);
            switch (std.posix.errno(-1)) {
                .NOMEM => continue,
                else => return error.ProcessTableUnread,
            }
        } else return error.ProcessTableUnread;
        const table = try gpa.alloc(Process, records.len);
        defer gpa.free(table);
        for (records, table) |*record, *process| process.* = try Layout.process(record);
        return sum(gpa, table, root);
    }

    const Layout = switch (os) {
        .freebsd => FreeBsd,
        .netbsd => NetBsd,
        .openbsd => OpenBsd,
        .dragonfly => DragonFly,
        else => void,
    };

    fn ns(seconds: anytype, microseconds: anytype) u64 {
        const s = std.math.cast(u64, seconds) orelse 0;
        const us = std.math.cast(u64, microseconds) orelse 0;
        return s *| std.time.ns_per_s +| us *| std.time.ns_per_us;
    }

    const Timeval = extern struct { sec: i64, usec: i64 };

    /// `struct rusage`: its two times, then fourteen longs.
    const Rusage = extern struct { utime: Timeval, stime: Timeval, rest: [14]i64 };

    /// FreeBSD's `struct kinfo_proc` (`sys/user.h`), by `KERN_PROC_PROC`: a record per process,
    /// not per thread.
    const FreeBsd = struct {
        const mib = [_]c_int{ 1, 14, 8 }; // CTL_KERN, KERN_PROC, KERN_PROC_PROC
        /// `KINFO_PROC_SIZE` of `machine/proc.h`: 1088 on every 64-bit target.
        const kinfo_proc_size = if (@sizeOf(usize) == 8) 1088 else @compileError("preflight's watchdog reads FreeBSD's process table on 64-bit targets alone");
        const Record = extern struct {
            structsize: c_int,
            _0: [68]u8,
            pid: i32,
            ppid: i32,
            _1: [248]u8,
            /// Microseconds the process has run.
            runtime: u64,
            _2: [272]u8,
            rusage: Rusage,
            /// What the children it has waited for used.
            rusage_ch: Rusage,
            _3: [192]u8,
        };
        comptime {
            std.debug.assert(@sizeOf(Record) == kinfo_proc_size);
            std.debug.assert(@offsetOf(Record, "pid") == 72);
            std.debug.assert(@offsetOf(Record, "ppid") == 76);
            std.debug.assert(@offsetOf(Record, "runtime") == 328);
            std.debug.assert(@offsetOf(Record, "rusage") == 608);
            std.debug.assert(@offsetOf(Record, "rusage_ch") == 752);
            std.debug.assert(@sizeOf(Rusage) == 144);
        }

        fn count(_: *[mib.len]c_int, _: usize) void {}

        fn process(record: *const Record) !Process {
            if (record.structsize != @sizeOf(Record)) return error.ProcessRecordUnread;
            const child = record.rusage_ch;
            return .{
                .pid = record.pid,
                .parent = record.ppid,
                .ns = record.runtime *| std.time.ns_per_us +| ns(child.utime.sec, child.utime.usec) +| ns(child.stime.sec, child.stime.usec),
            };
        }
    };

    /// The times NetBSD's and OpenBSD's records carry, each seconds and microseconds of 32 bits:
    /// the process's user and system time, valid while it lives (`p_uvalid`), and what the
    /// children it has waited for used, user and system together.
    const Times = extern struct {
        user_sec: u32,
        user_usec: u32,
        system_sec: u32,
        system_usec: u32,
    };

    /// A NetBSD or OpenBSD record's process: the record's size is fixed by its header on every
    /// architecture, and the call names the size and how many records fit (`count`).
    fn fixedRecord(record: anytype) Process {
        const alive: u64 = if (record.uvalid != 0) ns(record.times.user_sec, record.times.user_usec) +| ns(record.times.system_sec, record.times.system_usec) else 0;
        return .{ .pid = record.pid, .parent = record.ppid, .ns = alive +| ns(record.children_sec, record.children_usec) };
    }

    /// NetBSD's `struct kinfo_proc2` (`sys/sysctl.h`), by `KERN_PROC2` and `KERN_PROC_ALL`: a
    /// record per process, the same on every architecture.
    const NetBsd = struct {
        /// CTL_KERN, KERN_PROC2, KERN_PROC_ALL, its argument, the record's size, how many fit.
        const mib = [_]c_int{ 1, 47, 0, 0, @sizeOf(Record), std.math.maxInt(c_int) };
        const Record = extern struct {
            _0: [116]u8,
            pid: i32,
            ppid: i32,
            _1: [324]u8,
            uvalid: u32,
            _2: [12]u8,
            times: Times,
            _3: [112]u8,
            children_sec: u32,
            children_usec: u32,
            _4: [80]u8,
        };
        comptime {
            std.debug.assert(@sizeOf(Record) == 680);
            std.debug.assert(@offsetOf(Record, "pid") == 116);
            std.debug.assert(@offsetOf(Record, "ppid") == 120);
            std.debug.assert(@offsetOf(Record, "uvalid") == 448);
            std.debug.assert(@offsetOf(Record, "times") == 464);
            std.debug.assert(@offsetOf(Record, "children_sec") == 592);
        }

        fn count(given: *[mib.len]c_int, size: usize) void {
            given[5] = std.math.cast(c_int, size / @sizeOf(Record)) orelse std.math.maxInt(c_int);
        }

        fn process(record: *const Record) !Process {
            return fixedRecord(record);
        }
    };

    /// OpenBSD's `struct kinfo_proc` (`sys/sysctl.h`), by `KERN_PROC` and `KERN_PROC_ALL`: a
    /// record per process (its threads only with `KERN_PROC_SHOW_THREADS`), the same on every
    /// architecture.
    const OpenBsd = struct {
        /// CTL_KERN, KERN_PROC, KERN_PROC_ALL, its argument, the record's size, how many fit.
        const mib = [_]c_int{ 1, 66, 0, 0, @sizeOf(Record), std.math.maxInt(c_int) };
        const Record = extern struct {
            _0: [108]u8,
            pid: i32,
            ppid: i32,
            _1: [284]u8,
            uvalid: u32,
            _2: [16]u8,
            times: Times,
            _3: [116]u8,
            children_sec: u32,
            children_usec: u32,
            _4: [88]u8,
        };
        comptime {
            std.debug.assert(@sizeOf(Record) == 648);
            std.debug.assert(@offsetOf(Record, "pid") == 108);
            std.debug.assert(@offsetOf(Record, "ppid") == 112);
            std.debug.assert(@offsetOf(Record, "uvalid") == 400);
            std.debug.assert(@offsetOf(Record, "times") == 420);
            std.debug.assert(@offsetOf(Record, "children_sec") == 552);
        }

        fn count(given: *[mib.len]c_int, size: usize) void {
            given[5] = std.math.cast(c_int, size / @sizeOf(Record)) orelse std.math.maxInt(c_int);
        }

        fn process(record: *const Record) !Process {
            return fixedRecord(record);
        }
    };

    /// DragonFly's `struct kinfo_proc` (`sys/kinfo.h`), by `KERN_PROC_ALL`: a record per process,
    /// its threads summed into `kp_lwp` (`sysctl_out_proc` without `KERN_PROC_FLAG_LWP`). A live
    /// process's time is its threads' statclock time in microseconds (`kl_uticks`, `kl_sticks`):
    /// `kp_ru` holds only threads that have exited.
    const DragonFly = struct {
        const mib = [_]c_int{ 1, 14, 0 }; // CTL_KERN, KERN_PROC, KERN_PROC_ALL
        const Lwp = extern struct {
            _0: [40]u8,
            uticks: u64,
            sticks: u64,
            _1: [256]u8,
        };
        const Record = extern struct {
            _0: [220]u8,
            pid: i32,
            ppid: i32,
            _1: [284]u8,
            /// What the children it has waited for used.
            cru: Rusage,
            _2: [8]u8,
            lwp: Lwp,
            _3: [72]u8,
        };
        comptime {
            if (@sizeOf(usize) != 8) @compileError("preflight's watchdog reads DragonFly's process table on 64-bit targets alone");
            std.debug.assert(@sizeOf(Record) == 1048);
            std.debug.assert(@sizeOf(Lwp) == 312);
            std.debug.assert(@offsetOf(Record, "pid") == 220);
            std.debug.assert(@offsetOf(Record, "ppid") == 224);
            std.debug.assert(@offsetOf(Record, "cru") == 512);
            std.debug.assert(@offsetOf(Record, "lwp") == 664);
            std.debug.assert(@offsetOf(Lwp, "uticks") == 40);
            std.debug.assert(@offsetOf(Lwp, "sticks") == 48);
        }

        fn count(_: *[mib.len]c_int, _: usize) void {}

        fn process(record: *const Record) !Process {
            const child = record.cru;
            return .{
                .pid = record.pid,
                .parent = record.ppid,
                .ns = (record.lwp.uticks +| record.lwp.sticks) *| std.time.ns_per_us +| ns(child.utime.sec, child.utime.usec) +| ns(child.stime.sec, child.stime.usec),
            };
        }
    };
};
