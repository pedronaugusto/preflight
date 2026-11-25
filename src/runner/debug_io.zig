//! std.debug's `Io` for every test build preflight's runner runs: std's own (its single-threaded
//! `Threaded`), each operation run with the calling task's cancel protection blocked, as std's
//! `debug.lockStderr` runs its own. Capturing a stack is no cancelation point. On macOS,
//! `SelfInfo/MachO.findModule` takes a cancelable lock, and a `Threaded` task's cancel state is
//! its thread's, whichever `Threaded` waits: contended, the lock took a pending cancel as its
//! `error.Canceled`, the unwinder fell back to frame pointers and dropped it, and the task's next
//! waits could no longer be canceled. A test allocating through `std.testing.allocator`, which
//! captures a stack, lost its cancel so (relic's lfs tests, reactor's Deadlines watcher).
const std = @import("std");
const Io = std.Io;

/// `inner`, every operation under blocked cancel protection.
pub fn of(comptime inner: Io) Io {
    return .{ .userdata = inner.userdata, .vtable = &Blocking(inner).vtable };
}

fn Blocking(comptime inner: Io) type {
    return struct {
        const vtable: Io.VTable = v: {
            var v: Io.VTable = undefined;
            for (@typeInfo(Io.VTable).@"struct".field_names) |name| @field(v, name) = switch (passed(name)) {
                true => @field(inner.vtable, name),
                false => &Wrapped(name).call,
            };
            break :v v;
        };

        /// The protection calls themselves, which the wrapper is made of.
        fn passed(comptime name: []const u8) bool {
            for ([_][]const u8{ "swapCancelProtection", "recancel", "checkCancel" }) |own| {
                if (std.mem.eql(u8, name, own)) return true;
            }
            return false;
        }

        fn Wrapped(comptime name: []const u8) type {
            const F = @typeInfo(@FieldType(Io.VTable, name)).pointer.child;
            const p = @typeInfo(F).@"fn".param_types;
            const R = @typeInfo(F).@"fn".return_type.?;
            const T = struct {
                fn t(comptime i: usize) type {
                    return p[i].?;
                }
            }.t;
            return switch (p.len) {
                1 => struct {
                    fn call(u: ?*anyopaque) R {
                        const old = protect();
                        defer restore(old);
                        return @field(inner.vtable, name)(u);
                    }
                },
                2 => struct {
                    fn call(u: ?*anyopaque, a: T(1)) R {
                        const old = protect();
                        defer restore(old);
                        return @field(inner.vtable, name)(u, a);
                    }
                },
                3 => struct {
                    fn call(u: ?*anyopaque, a: T(1), b: T(2)) R {
                        const old = protect();
                        defer restore(old);
                        return @field(inner.vtable, name)(u, a, b);
                    }
                },
                4 => struct {
                    fn call(u: ?*anyopaque, a: T(1), b: T(2), c: T(3)) R {
                        const old = protect();
                        defer restore(old);
                        return @field(inner.vtable, name)(u, a, b, c);
                    }
                },
                5 => struct {
                    fn call(u: ?*anyopaque, a: T(1), b: T(2), c: T(3), d: T(4)) R {
                        const old = protect();
                        defer restore(old);
                        return @field(inner.vtable, name)(u, a, b, c, d);
                    }
                },
                6 => struct {
                    fn call(u: ?*anyopaque, a: T(1), b: T(2), c: T(3), d: T(4), e: T(5)) R {
                        const old = protect();
                        defer restore(old);
                        return @field(inner.vtable, name)(u, a, b, c, d, e);
                    }
                },
                7 => struct {
                    fn call(u: ?*anyopaque, a: T(1), b: T(2), c: T(3), d: T(4), e: T(5), f: T(6)) R {
                        const old = protect();
                        defer restore(old);
                        return @field(inner.vtable, name)(u, a, b, c, d, e, f);
                    }
                },
                else => @compileError("Io.VTable." ++ name ++ " takes more parameters than the debug Io wraps"),
            };
        }

        fn protect() Io.CancelProtection {
            return inner.vtable.swapCancelProtection(inner.userdata, .blocked);
        }

        fn restore(old: Io.CancelProtection) void {
            _ = inner.vtable.swapCancelProtection(inner.userdata, old);
        }
    };
}
