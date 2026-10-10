# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- The linked graph is held to one revision of each package and no cycle between packages, the package under test included: a test dependency that links the package back takes the package's own module, bound by the build script. `ci/toolchain.zig`, `check-toolchain` and the toolchain closure policy are gone; this general check replaces them, and preflight needs no `revision_exceptions`. preflight no longer pins aegis.
- Nothing of preflight's own pins reaches a package's artifact. The test runner, `preflight_order` and the watchdog link std alone: `Shard` holds a plain `index` below a nonzero `count` (`Shard.init(index, count)`). Benchmarks and fuzzing use the package's own `shakedown`, which it must declare; `Config.fuzz_step` is opt-in (null by default), and without it there is no `fuzz` step and nothing is fetched for one.
- The family rule sets leave preflight: the `rules` module and `preflight_rules` are gone. Test-only packages are `test_dependencies` in `ci/preflight.json`; token rules are a package's own, in its `ci/layers.zig`.
- `ci/workflow.json` `jobs` declares a package's own CI jobs as build steps (hosts, tiers, directory, arguments, setup step, timeout), rendered into the gate's matrices; a landing waits for them. The generator owns the whole caller and refuses to replace one holding a job the configuration does not declare; the earlier splice of hand-written jobs is gone. `sanitizer` and `sanitizer_job_timeout` are refused: declare the run in `jobs`, or use `hardened`. Every key is validated, and an unknown one (`package` among them) is refused.
- Landing moves into the caller: one `land` job that needs the gate and alone may write, rendered with its input only when `land` is set, so a caller without `land` asks for no write permission (before, every caller pinned to a commit with landing failed to start unless it set `land`). zig.yml loses its `land`, `test-job-timeout` and `windows-job-timeout` inputs. Pull requests queue by number, so two of them never cancel each other or a run on main.
- A step name preflight claims that the package already has fails the package's tests with a message naming it, instead of crashing the build.
- attest finds the proof by its artifact name, in whichever workflow file the caller lives, one request per tier.

### Added

- A project with no `ci/preflight.json`, `ci/workflow.json` or `ci/layers.zig` gets every default; `.paths` need not name a README or changelog the package does not have. `sample/zero`, such a project, runs in preflight's own gate on every host.
- `lint` checks that every nested manifest pins each package the root also pins exactly as the root does.
- A passing test run and a passing lint write nothing under `zig build`, which shows any stderr of a passing step under "failed command:"; a failure prints all of it. A hosted job keeps lint's report in its summary.

- The merge tier is the gate a landing passes, four jobs: the source checks and the Debug suite on Linux, macOS and Windows. The cross compile, the ReleaseFast benchmarks, the SDK links, ThreadSanitizer, the hardened checks and the Zig master leg move to the release tier, which a nightly schedule runs (`nightly` in `ci/workflow.json`: `false`, or `{ "cron", "tier" }`). Regenerate callers.
- `land` in `ci/workflow.json` (default off): a merge-tier dispatch whose jobs are all green fast-forwards main to the commit it tested, never forced, with the run's own token, whose push starts no run. `attest` (default off) adds the push-to-main job that checks for a recorded merge or release run. A caller kept by hand no longer loses its own jobs: regeneration keeps every job the generator does not write.
- `lint` fails an artifact that links two revisions of one package, naming both and who pulls each; `revision_exceptions` in `ci/preflight.json` names a package with the reason. The test runner and benchmark programs take the package's own aegis and shakedown when it declares them.
- `addConsumerCheck` takes `.options`, the options a consumer gives the package.
- `deprecations` no longer panics on a name bound to a deprecated `builtin` field.
- The hosted workflow is restructured, and every caller regenerates its workflow with `zig build plan -- --workflow .github/workflows/ci.yml` after taking this commit. The `skip` workflow is gone: the first job of a run, `toolchain`, filters documentation-only changes. The fast tier is three kinds of job that run side by side, not one: the source checks (`lint`), the Linux Debug tests (`ci`, in `fast_shards` shards) and the cross compile (`preflight-cross`, in as many jobs as hold `cross_seconds` of compiling, or `cross_jobs`). The step `preflight-fast` and the matrix field it was named in are gone; matrices carry `targets`.
- The ReleaseFast benchmark objects move from the fast tier to the merge and release tiers: `ci-check` compiles a benchmark in Debug, `ci-check-bench` in ReleaseFast. The ReleaseFast compile took longer than every other object of a target together (relic: 1m45s of 2m10s on a 16-core machine), and the Debug object holds what a target accepts of the source; a benchmark that fails only when optimized (`builtin.mode == .fast`) is now found by the merge tier.
- A package's build output is no longer cached between runs, only Zig's own: the next run changes the sources, and a gigabyte per job evicted the rest of the repository's caches. `.preflight/.zig-cache` is no longer cached either; no job compiles the checks.
- The code rules are glint's, run as a library over the repository's Zig files in one project, with every import resolved from the build's own configuration. The ziglint fork is gone: its dependency, its output parser, the `--ziglint` argument, and `ziglint_paths` and `ziglint_exceptions` with them. preflight's own cast-reason, function-length, `catch unreachable` and debug-print scans are glint's P001, P003, P004 and P005 (same predicates; P001 stays the four pointer casts in production code, and a test-support file's casts need their reason as production's do), so each is found once. The new gate covers Z011 across calls ziglint could not follow (`Run.enableTestRunnerMode`, deprecated container aliases), Z013, P002 and, for a repository that adopts them, glint's aegis rules at their gate. Policy: correctness and the family's own rules gate, the Zig style rules and Z026 (glint finds about three times the discarded errors the fork did) report until a package gates them, Z024 stays off. Z011 and P005 are *findings*: a finding fails, a call glint cannot resolve does not. Move each `// ziglint-ignore: Z0nn reason` to `// glint-ignore: Z0nn -- reason`; the rules glint removed (Z015, Z017 to Z023 and others) need no suppression.
- An analysis that did not finish is never a pass (review F04). A file that does not parse or lower, an exhausted fact budget, a site a gating rule could not decide, an unreadable file and a suppression that suppresses nothing (the default; `glint.strict_suppressions` turns it off) each fail the run, whatever the findings policy allows.
- Retired and failing by name: `ziglint_exceptions`, `unreachable_exceptions`, `debug_print_exceptions`, `ziglint_paths`, `glint_config`. The exact-match ledgers and their shrinking budget are gone with git-base history: `PREFLIGHT_LEDGER_BASE`, `PREFLIGHT_ADOPT`, the reusable workflow's `adopt` input and the `findings` step and command. `zig build findings` is replaced by the lint step's own report.
- `glint` in `ci/preflight.json` amends the family's policy by rule (`rules`: `off`, `report` or `gate`), `casts`, `cast_scope`, `strict_suppressions`, `fact_budget`, `max_line_length` and `disallowed`; an unknown setting fails, and there is no `profile`. `glint_paths` selects the files to check, separate from `sources`, so benchmarks, examples, CI code and the build script are linted and gated without being shipped; without it the selection is `sources` plus `examples`, `ci`, `conformance`, `bench` and `build.zig` where they exist.
- Zig is read through gantry's frontend module: gantry 9cf62da, whose Zig reading takes glint's token tier. The checks fetch glint, and aegis under it, for every repository.
- Pin glint ce01c5e, aegis 104b1c0 and shakedown caf3803. glint is one module (the token facts are `glint.token`), so the checks executable takes gantry's Zig frontend and glint built the same way, in ReleaseSafe. A conversion aegis cannot fail carries no error set: the runner's timeout report no longer has a `catch` on it.
- `ci/toolchain.zig` follows a name the module binds as a module, whatever it ends with (`gantry.zig`), and names the file it cannot read.

- `preflight_order.Shard.index` and `.count` use aegis-backed `ShardIndex` and `ShardCount`. `Shard.init(index, count)` checks the index/count relation; `assign` also checks load-storage bounds; `assign` adds `InvalidShard` and `InvalidWeights` to `AssignError`, and `init` adds `InvalidWeights` to `InitError`. Shard syntax and selected test indices are unchanged.
- `TestTimeout.nanoseconds() ?u64` becomes `TestTimeout.duration() ?std.Io.Duration`. Configuration rejects custom bounds above `u64` nanoseconds in every mode, retaining the existing one-nanosecond floor and reason requirement. Public `TestTimeout.bound.limit` and watchdog waits keep `std.Io.Duration`.

- Benchmark programs can use injected published `shakedown.bench` and build provenance directly. `bench-build` builds ReleaseFast programs/comparison without executing; hosted gates disable benchmark smoke. `bench-ab` builds immutable revisions, interleaves caller-selected workloads and delegates comparison to shakedown. Both revisions must implement this contract.
- `Config.hardened` and workflow `hardened` opt into safety-on test configurations, executed native Zig fuzzer campaigns and x86_64 Linux LLVM ThreadSanitizer jobs. Unsupported targets and compile-only profile steps fail explicitly; existing allocator ownership is preserved.
- The own toolchain closure gate validates recursive resolved content-hash pins and fetched package identities, then follows gantry production/test import facts through actual configured module bindings. Pinned lazy bootstrap versions remain distinct; unsupported facts and unresolved inputs fail clearly.
- `facts` reads Zig 0.17.0's build-system protocol and bounded serialized configured graph. Lint uses actual configured test roots, including embedded WriteFile roots, instead of the handwritten `test_roots` list. Unavailable dynamic generated test content and unsupported versions/inputs fail clearly. This is a version-specific internal-format adapter, not a stable Zig external graph API. Existing object/native-link graphs and legacy ziglint behavior remain.

- Cross object projections retain expected compile-error diagnostics and limits, omit emitted binaries for deliberate failures, and keep wrong diagnostics or unexpected success failing through Zig's own matching. Positive object and original native SDK-link validation remain intact.
- `ci-check` emits root, test, benchmark, helper and transitive native objects instead of linking binaries. `ci-link` retains the native link gate. Portable test artifacts are linked on their destination SDK runner; regenerate callers to update every matrix. Required libraries and Apple frameworks remain on native modules.
- `addCi` exposes `zig build plan -- --workflow .github/workflows/ci.yml`: the canonical Zig generator replaces the caller and all tier matrices using the immutable preflight pin in `build.zig.zon`. No package-local planner, Python or hand-edited workflow pin is needed. Declarative `build_args`, target `args` and `windows_git_latest` are supported; malformed inputs and unsafe output paths are refused.
- Refresh lazy test-only shakedown to green main 9357a9a and the green gantry prerequisite to 3677ee0.
- Pin shakedown 99418ac, the `shakedown.bench` injected into benchmark programs and read by `bench-ab`: a row's `fixture` (`setup`, `teardown`) now has a `lifetime`, `.row` or `.batch`, in place of `setup` and `teardown` fields that surrounded every batch, and a row may `stage` and `settle` each batch and refuse to grow. A program written against the earlier rows names its fixture's lifetime.

- File-name case is owned by ziglint Z009; preflight's `file-name-case` check and `file_name_exceptions` ledger are removed. Move any needed naming exceptions to the Z009 ziglint ledger. Gantry's deeper declaration liveness owns unused imports, so the ziglint invocation disables Z013. Z011 remains the deprecation gate; the separate codemod stays.
- Path compilation and matching use gantry's exported `Globs` exclusively, with malformed patterns returned as errors even on empty inputs. The direct sweep dependency is removed.

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

- `zig build fuzz`: shakedown's continuous fuzzing of the package's `check` properties,
  off the landing path, its corpora and findings outside the repository
  (`-- --limit 50M --sessions 4 --store ~/fuzz`).
- `zig build lint` reports the parsers of untrusted input with no fuzz target, without
  failing: public parser-named functions taking bytes or a reader, and `fuzz.parsers`;
  `fuzz.trusted` leaves one out with its reason.
- The protocol fuzzer of preflight's own suite is a shakedown `check` property.

- `toolchain`, the first job of a hosted run, builds the checks once for Linux, macOS and Windows (`zig build toolchain`) or takes the build that preflight's own run made of the pinned commit (the artifact `toolchain-<commit>`, kept ninety days), and every other job downloads it. A cold job spent four to six minutes compiling the checks, two or three times (the docs filter, the lint, the driver); none does now. The Zig master leg builds its own, since the checks read the configuration of the Zig that built them.
- `addCi` takes `-Dci-checks=<path>`, a preflight built from the same commit, in place of compiling the checks into the consumer's graph; the hosted `run` passes its own path. A local build compiles them as before.
- Every command the gate runs and every source check reports its seconds in the log, the job summary and a record (`phases-<job>.ndjson` in the timings artifact). The merge and release tiers' profile job folds them into `ci/costs.json` beside `ci/durations.json`, in the proof artifact, and the plan balances the cross jobs by them: the longest target first onto the job with the least, a target nobody measured at the mean of the others (90 s with none). `cross_seconds` (200) is the compile each job may hold; `cross_jobs` fixes the count instead.
- The `warm` job: a run on main does a gate job's setup, on four Linux, three Windows and one macOS runner, once a week, so that its caches hold the build runner every `zig build` compiles first (a minute and a half cold, in every job of a new branch) and the package's external tools (relic builds Git: two minutes). A branch restores the caches of main and its own. Zig's own cache is keyed by the CPU model, since the build runner is built for the CPU it runs on and the hosted runners have four or more of them: a cache from another model cost a job the same minute and a half as no cache.
- Family rule sets imported as `preflight_rules` in `ci/layers.zig`: `durability` outside airlock, `shakedown` for test-only imports, and `no_async` for packages whose callers own spawning. The dependency exports them as its `rules` module too. The sample and preflight adopt them.

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

- The configured-build reader, the hardened checks and the own toolchain gate accept Zig master builds leading to 0.18.0 (`0.18.0-dev.<n>`) beside the 0.17.0 release; any other Zig is refused with a message naming the two. One file, `zig_version.zig`, lists them. The configuration and protocol formats are the same on both today, so the Zig master leg of the hosted gate now runs the Debug suite instead of stopping at `UnsupportedConfigurationVersion`. `zig build facts` and the toolchain record name the Zig that produced them instead of a fixed `0.17.0`.
- Pin gantry 3ce6836 and sweep 394604e, where one path pattern matches a path in half the time: the source checks match `test_files`, `test_support` and `function_limits` patterns that way.
- The structure check compiles each pattern once and matches each path against the test patterns once.
- Each job fetches what its own build asks for, configuring it with the job's arguments, instead of every dependency: a lazy dependency only another job asks for, such as a terminal emulator that builds with exactly one Zig, no longer stops the Zig master leg. The package cache key changes with it.
- The package ships its CHANGELOG, beside the README and LICENSE.
- The README reads in the packages' order: install, usage, design, API, scope, built with, testing, licence.
- The generated matrices pass Zig 0.17's `-Doptimize=debug`, `safe`, `fast` and `small`; regenerate a caller's with `zig build plan`.

### Fixed

- Under `zig build` the test runner no longer writes the seed line on a passing run. Zig 0.17's build runner shows any stderr of a successful run step under `failed command:` (its `Run` step keeps the command it records before spawning), so every package's passing `zig build test` read as failed. A direct run still prints the seed; failures name it. `preflight_order.init` takes `announce`.

- The test runner says which tests called `std.testing.fuzz`, so `zig build test --fuzz`
  finds them: a build learns its fuzz tests from an unfuzzed run first, where the runner
  answered that none was one, and every fuzzing session ended with `no fuzz tests found`.

- Hosted external-tool setup has three attempts, each bounded by a five-minute step timeout, so a hung `apt-get update` cannot consume the whole job. Zig master's step deadlines total less than its job timeout, keeping a hung advisory job from cancelling an otherwise successful run. The master suite uses `test-job-timeout` as a step deadline capped at twenty minutes; blocking job timeouts keep their configured values.

- The format and source checks pass over the `zig-out` and `zig-pkg` directories a build of its own under a checked directory keeps beside its manifest, such as a conformance build's under `conformance/`; a run of that build no longer fails the next lint on a package it fetched.
- A dispatched fast tier compares the branch with `origin/main` from their merge base, not with `HEAD^`: a docs-only last commit no longer skips the gate for the code before it.
- The structure check fails on a source gantry could not read, which gave the graph none of its imports.
- Tests run git without the user's or the system's configuration.
- The full tier's ThreadSanitizer job leaves the source checks to their own job, as every other test job does.
- `catch unreachable` and `std.debug.print` checks skip the configured `test_support`, not always `src/testing/`.

[Unreleased]: https://github.com/pedronaugusto/preflight/commits/main
