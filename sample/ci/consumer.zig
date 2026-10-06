//! What a project that depends on the sample writes.
const sample = @import("preflight_sample");

pub fn main() void {
    _ = sample.sum(2, 3);
}
