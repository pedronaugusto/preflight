//! The bound on one test, and on each run `bounded.zig` bounds: a watch, on any `Io`'s awake
//! clock, that ends the run once its process tree has made no progress for its limit, or once
//! the hosted job's deadline comes. Progress is the tree's CPU time (`runner/cputime.zig`): a
//! tree that hangs (a deadlock, a wait nothing completes) uses none, and a slow machine's still
//! uses some, so a busy host never fails a live run, where a bound on its wall time did (three of
//! preflight's own integration tests at a load average of 70). A tree that spins uses CPU time
//! without end: only the job's deadline, the host's own limit, ends it.
const std = @import("std");
// Compiled into every package's test binaries: std alone, as order.zig.

/// Waits until `done` is set or `limit` has passed on `io`'s awake clock,
/// from when this is called. Returns whether the limit passed first. A wake
/// that leaves `done` unset waits on for what is left.
pub fn expired(io: std.Io, done: *std.Io.Event, limit: std.Io.Duration) bool {
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = limit, .clock = .awake });
    while (!done.isSet()) {
        if (std.Io.Clock.Timestamp.compare(.now(io, .awake), .gte, deadline)) return true;
        done.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
            // The deadline, or a wake that left the test running: the clock says which.
            error.Timeout => {},
            // Nothing but the watched test may end the watch.
            error.Canceled => return false,
        };
    }
    return false;
}

/// Less CPU time than this over a whole limit is no progress: what a hung tree's reading moves
/// by, the systems counting a process's time in clock ticks (Linux's 10 ms, Windows' 15.6 ms).
pub const progress_floor: std.Io.Duration = .fromMilliseconds(50);

/// What one run is given: how long its tree may make no progress, and what is left of its job
/// when the job's deadline comes sooner, so a job running out of time ends in the run it was
/// in, named, before the host cancels it unnamed.
pub const Bound = struct {
    /// How long the tree may make no progress; null bounds the run by the job's deadline alone.
    limit: ?std.Io.Duration,
    /// What is left of the job's time when the bound is taken; null outside a hosted job.
    job: ?std.Io.Duration,
};

/// `job_deadline` is the job's, in seconds of `io`'s real clock, or null for a
/// job with none.
pub fn bound(io: std.Io, limit: ?std.Io.Duration, job_deadline: ?i64) Bound {
    const seconds = job_deadline orelse return .{ .limit = limit, .job = null };
    const now = std.Io.Clock.real.now(io).nanoseconds;
    const left = @as(i96, seconds) * std.time.ns_per_s - now;
    return .{ .limit = limit, .job = .fromNanoseconds(@max(left, 0)) };
}

/// How a watch ended.
pub const Ending = union(enum) {
    /// The run ended first.
    done,
    /// Its tree made no progress for the whole limit.
    stalled,
    /// It was running when the job's time ran out.
    job_ran_out,
    /// The job's time had run out before its turn: it never ran.
    not_started,
    /// Its tree's CPU time could not be read: a run whose progress is unknown is not let run on
    /// as if it made some.
    unread: anyerror,
};

/// Watches a run until `done` is set, its tree makes no progress for `b.limit`, or the job's
/// time in `b` runs out. `reading.cpu()` is the tree's CPU time in nanoseconds, any count that
/// grows as the tree works; the count falling (a process left the tree with its time) is no
/// progress, and what it grows by from there is.
pub fn watch(io: std.Io, done: *std.Io.Event, b: Bound, reading: anytype) Ending {
    if (b.job) |left| if (left.nanoseconds == 0) return .not_started;
    const start: std.Io.Clock.Timestamp = .now(io, .awake);
    const job_end: ?std.Io.Clock.Timestamp = if (b.job) |left| start.addDuration(.{ .raw = left, .clock = .awake }) else null;
    const limit = b.limit orelse {
        const left = b.job orelse unreachable; // a run with neither bound is not watched
        return if (expired(io, done, left)) .job_ran_out else .done;
    };
    var mark = reading.cpu() catch |err| return .{ .unread = err };
    var since = start;
    const every = sampling(limit);
    while (true) {
        var next: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = every, .clock = .awake });
        if (job_end) |end| if (std.Io.Clock.Timestamp.compare(end, .lt, next)) {
            next = end;
        };
        done.waitTimeout(io, .{ .deadline = next }) catch |err| switch (err) {
            // The sample's time, or a wake that left the run going: read either way.
            error.Timeout => {},
            // Nothing but the watched run may end the watch.
            error.Canceled => return .done,
        };
        if (done.isSet()) return .done;
        const now: std.Io.Clock.Timestamp = .now(io, .awake);
        if (job_end) |end| if (std.Io.Clock.Timestamp.compare(now, .gte, end)) return .job_ran_out;
        const cpu: u64 = reading.cpu() catch |err| return .{ .unread = err };
        if (cpu < mark) {
            mark = cpu;
        } else if (cpu - mark >= progress_floor.nanoseconds) {
            mark = cpu;
            since = now;
            continue;
        }
        if (since.durationTo(now).raw.nanoseconds >= limit.nanoseconds) return .stalled;
    }
}

/// How often a watch reads its tree: an eighth of the limit, so a stall is ended within an
/// eighth of it past the limit, and at most once a second.
fn sampling(limit: std.Io.Duration) std.Io.Duration {
    return .fromNanoseconds(std.math.clamp(@divTrunc(limit.nanoseconds, 8), std.time.ns_per_ms, std.time.ns_per_s));
}

/// The job's deadline, as `PREFLIGHT_DEADLINE` holds it: whole seconds since
/// the epoch, or null where it is unset.
pub fn parseDeadline(text: ?[]const u8) error{InvalidDeadline}!?i64 {
    const value = text orelse return null;
    return std.fmt.parseInt(i64, value, 10) catch error.InvalidDeadline;
}

/// What a job does after its tests, before the host's limit: the build's
/// report and the upload of the timing records.
pub const after_tests_s = 120;

/// What `jobDeadline` fails with: a job that sets one of its start and limit
/// and not the other, or either as no whole number.
pub const JobDeadlineError = error{ IncompleteJobDeadline, InvalidJobStart, InvalidJobTimeout };

/// The hosted job's deadline, for `PREFLIGHT_DEADLINE`: when it started,
/// `PREFLIGHT_STARTED` seconds of the real clock, plus its limit,
/// `PREFLIGHT_JOB_TIMEOUT` minutes, less `after_tests_s`; null outside a
/// hosted job, which sets neither.
pub fn jobDeadline(env: *const std.process.Environ.Map) JobDeadlineError!?i64 {
    const started = env.get("PREFLIGHT_STARTED");
    const timeout = env.get("PREFLIGHT_JOB_TIMEOUT");
    if (started == null and timeout == null) return null;
    if (started == null or timeout == null) return error.IncompleteJobDeadline;
    const start = std.fmt.parseInt(i64, started.?, 10) catch return error.InvalidJobStart;
    const minutes = std.fmt.parseInt(i64, timeout.?, 10) catch return error.InvalidJobTimeout;
    // Checked: the values are the environment's, and an absurd one is refused, not wrapped.
    const limit = std.math.mul(i64, minutes, 60) catch return error.InvalidJobTimeout;
    const end = std.math.add(i64, start, limit) catch return error.InvalidJobTimeout;
    return std.math.sub(i64, end, after_tests_s) catch error.InvalidJobStart;
}
