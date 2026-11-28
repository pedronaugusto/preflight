//! The test runners' progress, printed as it lands: the slow tests' and each binary's time,
//! which the runners write while the build runs (`timings.Progress`). The build's own summary
//! of its steps comes only at its end, so a job its deadline ends showed nothing of where its
//! time went; these lines are in its log already.
const std = @import("std");
const aegis = @import("aegis");
const src = @import("source.zig");
const seam = @import("input.zig");

/// The variable that names the directory to the runners: `timings.progress_variable`, which the
/// runner's module holds (a test binary has that file as the runner's module alone).
pub const variable = "PREFLIGHT_PROGRESS";

/// Where a job's runners write their progress, in the package's directory.
pub const directory = ".zig-cache/preflight-progress";

/// How often the printer looks for new lines.
const every = aegis.units.Duration(.second, u32).literal("2s");
/// The time since the build began, which each line printed carries.
const Elapsed = aegis.units.Duration(.nanosecond, i96);

/// The printer of one build's progress: started before the build, ended after it.
pub const Printer = struct {
    c: src.Context,
    path: []const u8,
    started: std.Io.Clock.Timestamp,
    /// The bytes printed of each file, by its name.
    printed: std.StringHashMapUnmanaged(u64) = .empty,
    watching: ?std.Io.Future(void) = null,

    /// An emptied progress directory, named to the build's runners in `env`, and a printer of
    /// what they write to it. Without a thread to print on, the lines are printed at the end.
    pub fn start(printer: *Printer, env: *std.process.Environ.Map) !void {
        const c = printer.c;
        try c.directory().deleteTree(c.io, directory);
        try c.directory().createDirPath(c.io, directory);
        printer.path = try std.Io.Dir.path.join(c.a, &.{ try c.directory().realPathFileAlloc(c.io, ".", c.a), directory });
        try env.put(variable, printer.path);
        printer.started = .now(c.io, .awake);
        printer.watching = c.io.concurrent(watch, .{printer}) catch null;
    }

    /// Stops the printer, and prints what it had not.
    pub fn stop(printer: *Printer) void {
        // The watcher prints what is left as it ends; without one, it is printed here.
        if (printer.watching) |*watching| watching.cancel(printer.c.io) else printer.print();
        printer.watching = null;
    }

    /// Looks every `every` until `stop` cancels it, its one way to end, and then a last time.
    fn watch(printer: *Printer) void {
        while (true) {
            printer.c.io.sleep(every.toIoDuration(), .awake) catch |err| switch (err) {
                error.Canceled => return printer.print(),
            };
            printer.print();
        }
    }

    /// Prints each whole line the runners wrote since the last look, with the seconds since
    /// the build began. These lines are evidence and the build's result is the job's, so a
    /// look that fails says why and the build goes on.
    fn print(printer: *Printer) void {
        printer.look() catch |err| printer.c.report("preflight: the tests' progress, at {s}: {t}\n", .{ printer.path, err });
    }

    fn look(printer: *Printer) !void {
        const c = printer.c;
        var dir = try std.Io.Dir.cwd().openDir(c.io, printer.path, .{ .iterate = true });
        defer dir.close(c.io);
        var entries = dir.iterate();
        while (try entries.next(c.io)) |entry| if (entry.kind == .file) try printer.printFile(dir, entry.name);
    }

    fn printFile(printer: *Printer, dir: std.Io.Dir, name: []const u8) !void {
        const c = printer.c;
        // The printer's thread allocates apart from the build's, whose arena is not shared.
        const gpa = std.heap.page_allocator;
        if (!printer.printed.contains(name)) try printer.printed.put(gpa, try gpa.dupe(u8, name), 0);
        const slot = printer.printed.getEntry(name).?;
        const text = try seam.file(c.io, dir, name, gpa, .record);
        defer gpa.free(text);
        const from: usize = @intCast(slot.value_ptr.*); // safe: at most the file's length, which is in memory
        if (text.len <= from) return;
        // A line still being written waits for the next look.
        const whole = (std.mem.findScalarLast(u8, text[from..], '\n') orelse return) + 1;
        const at = Elapsed.fromIoDuration(printer.started.untilNow(c.io).raw, .exact).toSeconds(f64);
        var lines = std.mem.tokenizeScalar(u8, text[from..][0..whole], '\n');
        while (lines.next()) |line| c.report("preflight: at {d:.0}s: {s}\n", .{ at, line });
        slot.value_ptr.* += whole;
    }
};
