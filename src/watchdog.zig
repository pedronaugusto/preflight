//! The bound on one test: the wait a watchdog thread makes, on any `Io`'s
//! awake clock, until the test is done or its time is up.
const std = @import("std");
// Compiled into every package's test binaries: std alone, as order.zig.

/// Waits until `done` is nonzero or `limit` has passed on `io`'s awake
/// clock, from when this is called. Returns whether the limit passed first.
/// A wake that leaves `done` at zero waits on for what is left.
// std owns clock-tagged waits; `done` is an atomic completion flag, with one publisher and
// one observer. It protects no borrowed data, and cannot be replaced by a spin guard.
pub fn expired(io: std.Io, done: *std.atomic.Value(u32), limit: std.Io.Duration) bool {
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{ .raw = limit, .clock = .awake });
    while (done.load(.acquire) == 0) {
        if (std.Io.Clock.Timestamp.compare(.now(io, .awake), .gte, deadline)) return true;
        io.futexWaitTimeout(u32, &done.raw, 0, .{ .deadline = deadline }) catch |err| switch (err) {
            // Nothing but the watched test may end the watch.
            error.Canceled => return false,
        };
    }
    return false;
}

/// The wait one test is given: `limit`, or what is left of its job when the
/// job's deadline comes sooner, so a job running out of time ends in the
/// test it was in, named, before the host cancels it unnamed.
pub const Bound = struct {
    limit: std.Io.Duration,
    /// Whether the job's deadline, not the test's limit, sets the wait.
    job: bool,
};

/// `job_deadline` is the job's, in seconds of `io`'s real clock, or null for a
/// job with none.
pub fn bound(io: std.Io, limit: std.Io.Duration, job_deadline: ?i64) Bound {
    const seconds = job_deadline orelse return .{ .limit = limit, .job = false };
    // aegis: design: std alone, as the test runner and build module every package compiles (aegis's own too) must be
    const left = @as(i96, seconds) * std.time.ns_per_s - std.Io.Clock.real.now(io).nanoseconds;
    // aegis: design: std alone, as the test runner and build module every package compiles (aegis's own too) must be
    if (left >= limit.nanoseconds) return .{ .limit = limit, .job = false };
    return .{ .limit = .fromNanoseconds(@max(left, 0)), .job = true };
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
