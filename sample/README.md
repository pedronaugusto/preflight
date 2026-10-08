# preflight_sample

A consumer exercised by preflight's own hosted gate. `build.zig` opts into native hardened checks and wires `bench/sum.zig` to the published shakedown measuring API. Its runtime module depends only on std.

Run `zig build bench-build` to compile, `zig build test` for one smoke invocation per row, and `zig build bench` for manual ReleaseFast measurement. `zig build hardened-fuzz` executes its seeded corpus; `zig build hardened-tsan` requires native x86_64 Linux. `ci/workflow.json` enables the profile jobs through preflight's one canonical planner. `zig build facts -Doptimize=safe` reads this consumer's actual configured modules and artifact graph.
