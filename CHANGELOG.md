# Changelog

## [Unreleased]

### Breaking

- The hosted gate has tiers: `fast`, `merge` (fast plus the Debug suite on macOS and Windows; pull requests and the merge queue run it) and `release` (the former full matrix). `zig.yml` takes `tier` in place of `full`, and `merge-*` and `release-*` matrices in place of `full-matrix`, `compile-matrix` and `run-matrix`; `zig build plan` takes `--tier` in place of `--full`, and `skip.yml` takes `tier`. The proof artifact is `preflight-merge-<sha>` or `preflight-release-<sha>`, and a main push accepts either for its exact commit.
- Requires Zig 0.17.0. gantry is pinned at e8ed868, its 0.17 port; ziglint at 6adecff of pedronaugusto/ziglint, v0.5.3 ported to 0.17.
- `zig build ci-linux`, its Debian image `src/checks/linux.Dockerfile` and the `container` command are removed; preflight starts no containers.
- Timing keys and record names use Zig 0.17's mode names: `linux-debug`, `windows-safe`, `test-linux-debug-all.ndjson`. Rename the columns of `ci/durations.json` (`-Debug` to `-debug`, `-ReleaseSafe` to `-safe`, `-ReleaseFast` to `-fast`, `-ReleaseSmall` to `-small`).
- Test runs carry no environment from the build, since Zig 0.17 keeps a run's environment in its cached configuration: the runner reads `PREFLIGHT_SHARD` and `PREFLIGHT_TEST_SEED` when it runs, and `preflight_runner_options` carries the recorded durations and the timing record's name. `PREFLIGHT_TIMINGS` and `PREFLIGHT_DURATIONS` are gone; `preflight_order.init` takes the durations' text and `preflight_timings.Recorder.init` the record's name. Test artifacts that share a root module share its runner options and timing record.
- A test runner of its own fails by name when the tests run sharded, at run time rather than when the build is configured.
- Check layers, cycles and entries over the production graph only. Test code sits in no layer: a test file or `test_support` file listed in `ci/layers.zig` fails as "test source in a layer". Remove test files and test-only layers from the table.
- Ownership reads the layer patterns: every production source matches exactly one layer. `required` only names paths that must exist; it no longer has to list every source.
- New structure rules: "production reaches tests" fails a production edge into test code, and "test layers" fails an inline-test import of a higher layer than its file.
- Fail an import in a declaration nothing reaches (no public, exported or comptime member, field, `main` or test leads to it), in test code too.
- Path patterns use gantry's dialect everywhere, including `test_support` and `function_limits`: `*` no longer crosses `/`. Write `src/testing/**` for nested support; that is now the default.
- The structure runner reads `test_support` from the configured `ci/preflight.json`.
- The source checks no longer refuse a production declaration that imports a test file by name; "production reaches tests" replaces it and lets a declaration only tests reach import test code.
- Pin gantry 665538e, where Zig imports in test context are test edges, `check` returns owned `Findings`, a dead import is marked on its reference, and a token rule takes `.tokens = &.{...}` in place of `.token`: owned token rules in `ci/layers.zig` change with it.
- Unused imports are the structure runner's, read from gantry's dead marks, so lint and structure share one reachability: a decl literal (`return .default;`) or `@field(@This(), "name")` now reaches its declaration. They read `imports: unused imports: <file>: @import("<name>")`.
- A test file matched only through a glob layer pattern is in no layer; a literal pattern naming one still fails. An `entries` path that is test code fails, since the entry rule reads only the production graph.
- The structure runner walks the configured `sources` roots, not `src` alone.
- A per-test watchdog of 120 s is on by default. `Config.test_timeout` is a `TestTimeout`: `.default`, `.{ .bound = .{ .limit, .reason } }` or `.{ .off = reason }`; an empty reason fails the build. preflight passes the build runner no `--test-timeout`, and a `test_timeout` in `ci/workflow.json` fails the plan.
- A test artifact with a runner of its own fails the build by name while the watchdog is on or the build is sharded; a single-threaded test build fails while the watchdog is on.
- `addConsumerCheck`'s `.use_llvm` names a function of the package's `build.zig` that the consumer's build calls with its own target and mode, in place of a value.
- Timing records carry their `shard`; a test that two shards of one column both recorded fails `zig build profile`. Two test runs with one name get distinct record files.
- Shard by test case, not by named case. `ci/workflow.json` takes `"shards": {"windows": n, "macos": n, "linux": n}` and `"fast_shards": n`; `windows_shards`, `fast_windows_shards`, `shard_jobs`, `fast_linux_shards`, `fast_linux_jobs` and `priority` fail the plan. Each shard job compiles the whole suite once and the test runner runs its share, balanced by `ci/durations.json`. Matrix jobs carry `shard` instead of `cases`, and the runner no longer passes `-Dtest-case`; drop the case options from the package's build.
- The reusable workflow drops the `measured-plan` input and its planning job; the static matrices are complete. The `preflight-full-<sha>` proof artifact holds the refreshed `durations.json` instead of `summary.json`.
- `preflight_order.init` takes the test functions rather than their count, and returns only this shard's indices. The module file is `src/order.zig`.
- The shared runner's `fuzz` is upstream's; it reports a fuzz test only in a build with fuzzing, as upstream's runner does.
- Timing records carry a `key` (`windows-Debug`), and shard timing files end `-2of5.ndjson` rather than with a case name.

### Added

- `Config.test_timeout`: a watchdog in the shared runner fails a test that outlasts it, Io teardown included, with its name, phase and seed.
- `Config.test_log_level`: the `std.log` level tests print at, so a library sets it here rather than writing `std.testing.log_level`.
- `addConsumerCheck` generates and builds the consumer project, replacing each package's `ci/consumer/` build and manifest; the build has a Zig cache of its own; `addCheck` builds, tests and runs a repository check program.
- `zig build profile` folds timing records into `ci/durations.json`, keeping targets a run did not measure.
- preflight gates itself with its own `ci/layers.zig` and lint; `zig build verify` runs them.
- Keep exact exception ledgers shrinking, reject stale debt, check unreachable reasons, debug prints and file case, shuffle tests by seed, and report assertion density.

- Share source checks and fast and full CI gates through Zig alone, with a build helper and a reusable workflow.

- Run fast CI in one stage per host and plan only measured full-tier shards.

### Fixed

- The full tier's ThreadSanitizer job leaves the source checks to their own job, as every other test job does.
- `catch unreachable` and `std.debug.print` checks skip the configured `test_support`, not always `src/testing/`.
