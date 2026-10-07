# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- Pin gantry ce7061e, which reads path patterns as git's globs through sweep: in layers, `test_support`, `function_limits` and every other path pattern `src/**` no longer matches `src` itself, brackets (`[ch]`) and `\` escapes are syntax, and a pattern sweep refuses fails the check. A layer pattern with a bracket or escape is a glob, not one file's name.
- `build.zig.zon`'s `.paths` ships exactly `build.zig`, `build.zig.zon`, the source roots, `LICENSE`, `README.md` and `CHANGELOG.md`; lint fails any other path, and any it names that does not exist. Name a further path a consumer's build reads in `ci/preflight.json` `shipped` with its reason.
- A file with tests is reached only when a test block names it: the alias itself (`_ = corpus;`), a whole `@import`, or `refAllDecls(@This())` over a public alias. A member a test uses (`corpus.seed()`, `@import("event.zig").Key`) no longer reaches the file's tests.
- A repository with a `bench/` directory gives `addCi` its `.bench`; without it the tests fail by name.
- Pin ziglint 924b6b5: Z015 counts a merged error set (`A || B`) as named and finds public declarations in every enclosing container, tagged unions included; Z023 finds the receiver of a struct nested in another. An exception `ziglint_exceptions` records for one of those findings is now unused and fails; drop it.
- `preflight_timings.Recorder` keeps no `Io`: `deinit(io)` and `record(io, name, nanoseconds, status)` take it. `init` returns `Recorder.InitError` and `record` `Recorder.RecordError`.
- `preflight_order.init` returns `InitError`: a seed that is no `u32` is `InvalidSeed` (it was `Overflow` or `InvalidCharacter`), and durations that do not parse are `InvalidDurations`, as from `weigh`, which returns `WeighError`. `assign` returns `std.mem.Allocator.Error`.
- Pin gantry 6599037, where a reader is `read(context, scratch, io, path)` and `manifests` names its error sets after their functions; before it, gantry dc53715, where `scan` takes an `io` and hands it to the reader, `Options.diagnostics` replaces `scanWithDiagnostic`, and every public error set is named. A package's `ci/layers.zig` needs no change.
- The hosted gate has tiers: `fast`, `merge` (fast plus the Debug suite on macOS and Windows; pull requests and the merge queue run it) and `release` (the former full matrix). `zig.yml` takes `tier` in place of `full`, and `merge-*` and `release-*` matrices in place of `full-matrix`, `compile-matrix` and `run-matrix`; `zig build plan` takes `--tier` in place of `--full`, and `skip.yml` takes `tier`. The proof artifact is `preflight-merge-<sha>` or `preflight-release-<sha>`, and a main push accepts either for its exact commit.
- Requires Zig 0.17.0. ziglint is pinned at pedronaugusto/ziglint, v0.5.3 ported to 0.17.
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
- `addConsumerCheck` takes no `.use_llvm`: Zig 0.17 builds what its own backend could not.
- A test run that carries an environment of the build's (`setEnvironmentVariable`, `getEnvMap`) fails by name: Zig 0.17 keeps the whole environment in the cached configuration, where a later shard, seed or tool path finds it stale. Read such values when the tests run.
- The setup action's `install-zig` input is gone with the containers; it takes `zig-version` (default 0.17.0), which its cache keys carry.
- Timing records carry their `shard`; a test that two shards of one column both recorded fails `zig build profile`. Two test runs with one name get distinct record files.
- Shard by test case, not by named case. `ci/workflow.json` takes `"shards": {"windows": n, "macos": n, "linux": n}` and `"fast_shards": n`; `windows_shards`, `fast_windows_shards`, `shard_jobs`, `fast_linux_shards`, `fast_linux_jobs` and `priority` fail the plan. Each shard job compiles the whole suite once and the test runner runs its share, balanced by `ci/durations.json`. Matrix jobs carry `shard` instead of `cases`, and the runner no longer passes `-Dtest-case`; drop the case options from the package's build.
- The reusable workflow drops the `measured-plan` input and its planning job; the static matrices are complete. The `preflight-full-<sha>` proof artifact holds the refreshed `durations.json` instead of `summary.json`.
- `preflight_order.init` takes the test functions rather than their count, and returns only this shard's indices. The module file is `src/order.zig`.
- The shared runner's `fuzz` is upstream's; it reports a fuzz test only in a build with fuzzing, as upstream's runner does.
- Timing records carry a `key` (`windows-Debug`), and shard timing files end `-2of5.ndjson` rather than with a case name.

### Added

- `Config.bench`: `zig build bench` builds every program in ReleaseFast under `zig-out/bench` and runs the timed ones one after another with no arguments; `zig build test` runs each once with `--smoke`.
- `ci/layers.zig` `reexports`: a namespace file's imports of the files in its own directory, which layers and cycles do not read.
- `ci/preflight.json` `test_dependencies`: packages only tests may import; an import of one outside test code fails the structure check.
- `zig build deprecations` follows std's deprecations: it rewrites every reference to what the building Zig release deprecated, through std's own aliases and a table per release checked against that std, and lists what needs a person. `-- --write` applies it.
- `Config.test_timeout`: a watchdog in the shared runner fails a test that outlasts it, Io teardown included, with its name, phase and seed.
- `Config.test_log_level`: the `std.log` level tests print at, so a library sets it here rather than writing `std.testing.log_level`.
- `addConsumerCheck` generates and builds the consumer project, replacing each package's `ci/consumer/` build and manifest; the build has a Zig cache of its own; `addCheck` builds, tests and runs a repository check program.
- `zig build profile` folds timing records into `ci/durations.json`, keeping targets a run did not measure.
- preflight gates itself with its own `ci/layers.zig` and lint; `zig build verify` runs them.
- Keep exact exception ledgers shrinking, reject stale debt, check unreachable reasons, debug prints and file case, shuffle tests by seed, and report assertion density.

- Share source checks and fast and full CI gates through Zig alone, with a build helper and a reusable workflow.

- Run fast CI in one stage per host and plan only measured full-tier shards.
- The merge and release tiers run the Debug suite on Linux with Zig master, never blocking; the run's summary reports it.
- `zig build deprecations` moves `@import("builtin")`'s `os`, `cpu`, `abi`, `object_format` and `mode` to `target.*` and `optimize`; replaces a deprecated `std.Build.Step.Run` method that only forwards (`addArtifactArg`, `addDirectoryArg`, `addOutputFileArg` and the rest) with the call it makes; follows std's method aliases (`getLastOrNull` to `last`) on values of a std type, generic types and values a std method returned included; and follows a deprecated decl literal (`Optimize.ReleaseFast` to `.fast`).
- `zig build test -Dtest-filter=...` runs part of preflight's own suite.

### Changed

- The structure check compiles each pattern once and matches each path against the test patterns once.
- Each job fetches what its own build asks for, configuring it with the job's arguments, instead of every dependency: a lazy dependency only another job asks for, such as a terminal emulator that builds with exactly one Zig, no longer stops the Zig master leg. The package cache key changes with it.
- The package ships its CHANGELOG, beside the README and LICENSE.
- The README reads in the packages' order: install, usage, design, API, scope, built with, testing, licence.
- The generated matrices pass Zig 0.17's `-Doptimize=debug`, `safe`, `fast` and `small`; regenerate a caller's with `zig build plan`.

### Fixed

- A dispatched fast tier compares the branch with `origin/main` from their merge base, not with `HEAD^`: a docs-only last commit no longer skips the gate for the code before it.
- The structure check fails on a source gantry could not read, which gave the graph none of its imports.
- Tests run git without the user's or the system's configuration.
- The full tier's ThreadSanitizer job leaves the source checks to their own job, as every other test job does.
- `catch unreachable` and `std.debug.print` checks skip the configured `test_support`, not always `src/testing/`.

[Unreleased]: https://github.com/pedronaugusto/preflight/commits/main
