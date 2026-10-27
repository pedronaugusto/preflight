# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- preflight's own suite runs on Windows in the release tier, in two shards, so its Windows reds are seen before a release; on Linux it has 30 minutes.

### Fixed

- Two expressions Zig 0.18 refuses as ambiguous operator precedence are parenthesized as Zig 0.17 reads them: `cross_seconds`'s check (`(number(budget) orelse 0) > 0`) and the runner's environment block length.
- Files are named with `/` on Windows too. Zig keeps a module's paths with `\` there (`std.Build.Graph.dupePath`), and lint took them as they came: a Windows package's compiled-never-run artifact was named `src\compiled.zig` beside its `src/compiled.zig` read from disk, so the two never met, the empty-run-root failure named `src\empty.zig`, a file of another package reached through the checked one was named with both separators, and `facts` printed `src\\sample.zig`. Every path the configured build hands over is named once, at the facts adapter, as lint names files.
- The gate prints the tests counted per root wherever the build keeps its cache. It read the counts from the package's own `.zig-cache`, while the count is written into the build's cache, which `--cache-dir` or `ZIG_LOCAL_CACHE_DIR` can put anywhere: a hosted job names the workspace's, so a package in a subdirectory (preflight's sample jobs) printed no counts. The gate names the file in `PREFLIGHT_COUNTS`, and the count writes there.
- A test's environment holds none of preflight's controls (the variables named `PREFLIGHT_` and something). A build a test starts inherited the run's shard and ran its share of its own tests alone, passing with the rest unrun, and the hosted job's deadline and key with it. preflight's runner reads its controls before the first test and gives the tests an environment without them (on Windows, where the environment is the process's own, they leave it).
- On Windows, a configured build that fails mid-protocol (a refused write, a frame too long, a timeout) is reported, where preflight waited for it forever: the build is ended before its output's readers are, since Windows waits for every pending read of a pipe the build still holds and a build waiting for its next message never ends one (the build protocol fault test, which ran into the 300 s watchdog on windows-latest).
- Checkouts keep LF line endings again (`* text=auto eol=lf`): 0.16.0 replaced the line in `.gitattributes` with the CHANGELOG's merge rule, so a Windows checkout of the sample projects had CRLF and failed `zig fmt --check`.

## [0.18.2] - 2026-10-27

### Changed

- Pins aegis 0.2.1, the 0.2 line: `SecretBytes` holds no allocator.
- glint reads a package's ranges at the pointer widths of the targets `ci/workflow.json` names and of the machine the tests run on (glint's `pointer_widths`): a `u32` count times a small constant widened to `usize` is A010's finding only where a target has a 32-bit `usize` (cloak's `wasm32-freestanding`), never for a package whose targets are all 64-bit (relic). A package that names no targets is read at both widths, as before.
- The hardened jobs are sized as the test jobs are: `hardened`, `hardened-fuzz` and `hardened-tsan` take `test_job_timeout`, where they had a fixed 20 minutes; `hardened` splits into the Linux jobs' shards and `hardened-tsan` into `shards.tsan`'s (else the Linux count), each running its share as the test jobs do; the fuzz campaign stays one job. relic's suite ran past 20 minutes under ThreadSanitizer in one job.
- Pins glint 0.7.1, gantry 0.3.1, bay 0.2.2 and ensign 0.3.1.

### Fixed

- The riscv64 job installs `qemu-system-riscv` where the runner's Ubuntu has it (26.04, the hosted `ubuntu-latest` since October 2026, ships `qemu-system-riscv64` in a package of its own), else `qemu-system-misc`, and fails the install step when no `qemu-system-riscv64` is on the PATH. It failed later, at `preflight-vm: starting qemu-system-riscv64: FileNotFound`.
- `src/main.zig` parenthesizes `mode | ((mode & 0o444) >> 2)`, which Zig master refuses as ambiguous precedence.
- The VM's cpio reader refuses an archive cut short after a member whose data ends unaligned, where the next read underflowed past the end and stopped the program, and checks a name's length against what is left before adding it to a position.
- A hosted job's deadline (`PREFLIGHT_STARTED` plus `PREFLIGHT_JOB_TIMEOUT` minutes) is computed checked: values past `i64`'s seconds are `InvalidJobTimeout` or `InvalidJobStart`, not an overflow.
- preflight's own lint under glint 0.7.1 reports nothing: configuration counts convert checked (`fact_budget`, `function_limits`, a ceiling's `sites`), and each remaining site says why it is safe where it is.
- The lint's release-mode check reads what the default build installs: an artifact an install step copies out. It read every compile below the install step, so a test the default build compiles in ReleaseFast (shuttle runs its suite again optimized, where its switch's bugs were found) failed the lint as if it shipped.

## [0.18.1] - 2026-10-25

### Fixed

- `gate` runs the jobs that say the same on any machine here, whatever this machine's system: the source checks and documented snippets, and the compiles of named targets. It ran them only where the hosted gate's runner system was, Linux, so a release gated on one Mac ran no source checks: bay 0.1.21 went out green with its lint red. A caller that gates on several machines sets `PREFLIGHT_PORTABLE=elsewhere` for all but the one that runs them, and they run once; any other value is refused. ReleaseSmall's compile and the SDK links stay their runner's system's, and a declared job runs as declared.
- The list of every finding (`.zig-cache/preflight-lint/findings.txt`) named a vendored file's carried danger sites like failing ones, though they never counted against the gate; each now ends `(vendored: carried by <upstream>'s verification)`. (cloak-c read its fiat files' 79 carried A019 sites as failures.)

## [0.18.0] - 2026-10-25

### Breaking

- The default policy weighs glint's aegis pack in every repository (aegis's design §7). A001-A005 and the danger rules A007, A008, A011, A014-A017 and A019 are findings. The rules that read the input or peer fact (A006, A009, A010, A012, A013, A018, A020) and A021 (lock order) are reported until a fresh sample of each shows its noise near zero. A danger site uses aegis's type or carries `// aegis: <reason>: <why>`.
- The hardened profile is every package's: `Config.hardened` defaults to it (null only in a configuration that runs no native tests), and the planner schedules the hardened jobs in the release tier whatever `ci/workflow.json` says (`"hardened"` may only be `true`). A package with nothing to fuzz writes `.fuzz_step = null`.
- An installed artifact the build makes ReleaseFast or ReleaseSmall, when the caller chose no mode, fails the lint unless `Config.release_fast` names it with its measurement.
- The default policy holds every package's production code to aegis's whole-file read (P006, beside the durability door): std 0.17's `Dir.readFileAlloc` and `readFileAllocOptions` lose a cancel that lands on the file's length, so `aegis.own.readFile` (or `readFileSentinel`) reads a file whole, with a limit the caller gives.
- P001, P002 and P004 leave the default policy with glint 0.7.0, folded into A010 (a conversion of input; the safe build every package ships checks the program's own), A019 and A013. A repository naming one in `glint.rules` is told where its sites went. `glint.casts` and `glint.cast_scope` are retired.
- A `vendored` entry names the upstream file it keeps: `{"upstream": ..., "verification": ..., "sha256": ...}`, the SHA-256 of the upstream's copy, where it was one string. While the file is that copy, its verification is the reason every danger site in it carries, as an escape's is for its line, and the run counts them by file; an undecided site in it still is one. A changed file fails the run: it is the package's own code, and its sites need their own reasons. It stays exempt from the house style.

### Added

- preflight depends on aegis, and reads every file whole through `aegis.own.readFile`: its checks and the programs it builds (consumer, nested, structure, the test machine's guest and host) take aegis as a module, and its build helpers reach the read through aegis's `build.zig`, which a build runner compiles only as far as it is used.
- `glint.peer_writers`: the functions a package owns whose result writes to a peer, A018's sinks; a lint reads its own and its dependencies'.
- A `fix` step (`preflight lint --fix`): glint's deterministic fixes written into the package's sources, then the lint's report of the run before them.
- `glint.unresolved`: a finding rule's ceiling of undecided sites, none by default. Above it the run fails, and below it the run asks for the ceiling to come down.
- The run prints every aegis escape with the rules it covers, a count by rule and reason, and all of them in `.zig-cache/preflight-lint/escapes.txt`. A line of findings, escapes and undecided sites by rule follows the glint summary. Where a rule finds more than the 25 printed, every finding is in `.zig-cache/preflight-lint/findings.txt`.
- A malformed suppression or escape is an incomplete site at its comment.
- `vm_packages` takes a package from Alpine's edge, with its build stated exactly (`git@edge=2.56.0-r0`), for a package newer than the release the machine is: edge joins the release's repositories under its tag, signed by the same keys, when an entry names it. An edge entry without `=` and a version, or another tag, is refused by name; when edge has moved on from the build named, apk fails making the machine, naming the package. relic holds its tests to git 2.56.0, which Alpine 3.24 does not have (2.54.0).

### Changed

- `bench-ab` reads its arguments through ensign, as preflight's own command line does: `zig build bench-ab -- --help` lists them, and a mistake is named with the flag it concerns. A flag given twice takes its last value; it was refused.
- A ThreadSanitizer build records and reads its test durations in a column of its own (`linux-debug-tsan`, `preflight_order.key`), where it shared the column of the same mode without it and could not record without overwriting that column's times. A declared TSan job balances its shards by its own times once it records them (`-Dci-timings=true` in its `args`).

### Fixed

- The consumer check of a package whose own build holds preflight (without bay) gives the consumer preflight and what preflight depends on, which a consumer of that package fetches: aegis, now that preflight depends on it. A package reached by path is read where it is, never copied among the consumer's packages.
- `preflight profile` named nothing when a job's timing record was not JSON: it failed with a bare `error: SyntaxError` (chronicle's and morse's nightlies of 2026-10-24, on preflight 0.5, which merged every job's records into one directory and so could interleave two). It now names the file and line, `profile: <dir>/<file>.ndjson:3: not a JSON record (SyntaxError)`, and a record without its seconds the same way; a durations or costs file that is not JSON is named too.
- A test that crashes no longer erases the timing records of the tests run before it. Zig starts the test process again after a crash, and each new process truncated the shard's record, so a run with crashes or watchdog kills kept only the tests after the last one: relic's windows-11-arm and riscv64 jobs recorded 1 test of 2000. The record is now cleared once per run, when the build asks for the tests (`preflight_timings.Recorder.begin`, which a custom runner calls where its run begins), and a restarted process appends to it.
- A configuration that is there and cannot be read (`ci/preflight.json`, `ci/workflow.json`) is the error, where any failure to reach it read as no file and every option at its default; and a value of the wrong type is `InvalidConfiguration` (`"compile_step": 3` ran `check`), only an absent or `null` one taking the default.
- The glint check and the API surface give glint the run's `Io` (glint 0.6.0's `Options.io`), so a canceled run ends with `Canceled` at the next file glint builds or lints, where it ran the whole project out; a cancel there was reported as the run not finishing, a failure.

## [0.17.3] - 2026-10-25

### Fixed

- Lint takes a test root in a directory the repository keeps beside what it ships (`ci`, `examples`, `conformance`, `bench`, as glint already lints them) and follows its imports there, without that directory joining `sources`. A package whose only Zig is its repository checks, a C library's, failed with "configure test_roots" unless it shipped `ci/`. Only the shipped files' tests must still be reached.
- Every instance of the checked package in a development build is the package. A build that makes the package once per configuration (`b.dependency(name, args)` with other arguments) gave lint whichever instance came first, and when that was one only built, no test counted and lint failed with `MissingConfiguredTestRoot`.
- The local gate leaves `hardened-fuzz` to another machine on a host where Zig's fuzzer does not run, Windows or a 32-bit one, and names why, as it does `hardened-tsan`. It ran the job there, where `hardened-fuzz` fails by design, so every local release of a package with `.hardened` on Windows went red.
- The suite compiles on Windows: two tests named a child killed by `SIGKILL`, which Windows' signal set in Zig 0.17 lacks, so `zig build test` failed to compile there before any test ran. They name `SIGTERM`, which every system has; what they check is unchanged.

## [0.17.2] - 2026-10-24

### Fixed

- The test runner compiles for OpenBSD: it copied its protocol streams with `F_DUPFD_CLOEXEC`, which Zig 0.17's OpenBSD table lacks, so a package whose cross compile builds its tests for x86_64-openbsd failed there (cloak's, in the family's re-pin train). It carries OpenBSD's value, 10, where std has none.

## [0.17.1] - 2026-10-24

### Changed

- Pins glint 0.5.2, gantry 0.2.11, bay 0.1.19 and ensign 0.2.4.

## [0.17.0] - 2026-10-24

### Breaking

- `generate` makes the caller, in place of `plan -- --workflow <path>`: it finds the package's caller under `.github/workflows` and writes it again where it is, or writes `.github/workflows/ci.yml` at the repository's top when there is none, and leaves a current one as it is (`bay generate`, `zig build generate` without bay; `--self`, `--config`, `--working-directory`, `--manifest` and `--drop` as `plan` took them). The caller's first line records it as `<config>: bay generate`, with what it was given beyond the defaults, so generating it again needs no flags; a caller `plan` generated is still found, and the gate refuses it until it is generated again. `plan` keeps the tier matrices (`--tier`, `--output`). A train (`bay --workspace release`, bay 0.1.18) runs `generate` after moving a member's pins, so the caller follows the preflight the member pins.

## [0.16.0] - 2026-10-22

### Breaking

- Releasing is bay's (`bay release`, bay 0.1.16): preflight verifies and neither versions, tags nor pushes. `release`, `land`, `ready`, `publish` and `version` are gone, with their steps, the caller's `land` job and dispatch input, `.github/actions/land`, and `zig.yml`'s `package-directory` input and `version` output. `ci/workflow.json`'s `land`, `release` and `programs_step` are refused as unknown keys: drop them, and generate the caller again (`plan -- --workflow`), which drops its `land` job.
- The gate checks, before any job, what a release needs beside the jobs: the caller as `plan` generates it (as before), the manifest's version as the CHANGELOG's newest release, and the CHANGELOG against the API diff since the last `v*` tag: a change to the public surface needs an entry in `[Unreleased]` or in a release made since, a removed or changed public declaration a breaking one (`### Breaking` or `### Removed`). The lint checks the last two on every commit. CHANGELOG.md is read with bay's `changelog` module, so an entry under no group is refused with its line.

### Changed

- The gate runs the planned jobs in the directory the package's caller runs its gate in when given no `--working-directory`, so preflight's own gate needs none.
- Pins bay 0.1.16, whose `changelog` module the checks read CHANGELOG.md with.

## [0.15.2] - 2026-10-22

### Fixed

- The riscv64 job installs QEMU's system emulation without its recommended packages (`--no-install-recommends`): the GUI, SPICE, OpenGL and network-boot extras made the download 87 MB, which a slow mirror took past the step's five minutes (relic's nightly, 4 min 47 s at 303 kB/s). The OpenSBI firmware `-bios default` boots comes with `qemu-system-data`, a dependency.

## [0.15.1] - 2026-10-22

### Fixed

- A test's bound scales under ThreadSanitizer however the tests are built with it: a package's own option that sets a test module's `sanitize_thread` too, where only `-Dci-tsan` did, so such a run held its heavy tests to the unscaled bound (`hardened.sanitizesThreads`).
- ThreadSanitizer runs on macOS too, x86_64 and aarch64, where Zig 0.17 ships its runtime: `-Dci-tsan`, `hardened-tsan` and the local runner's choice of jobs, where only Linux was taken (`hardened.sanitized`).

## [0.15.0] - 2026-10-22

### Breaking

- The lint fails a test artifact compiled and never run: a root file whose test artifacts no run under a step CI runs (`ci`, the fuzz and hardened steps, the release tier's own jobs, `extra_checks`) runs, named with its artifacts. Such a root no longer counts as one, so a file only it reaches has unreachable tests too. strand's json and jsonl tests were compiled under `check` and stopped running, 29 of them, while the lint took their roots as reaching them. `lint` takes `--test-step`, which `addCi` passes.
- The tests step counts the tests per root after its runs, and fails a run whose binary holds no test, unfiltered: its tests are in modules it imports, which Zig never runs, or it has none. preflight's runner writes the count when the build asks a binary which tests it holds (`preflight-counts/` in the build's cache, under its `--cache-dir`); a run with no record fails by name. `ci-run` counts the tests it replays the same way.

### Added

- The gate and a hosted job print the counts per root after a step that ran tests (`preflight: tests per root: ...`), into the job's summary too; `counts` is the command the tests step runs.
- `preflight_timings.count` and `preflight_timings.Shard`: the count record a custom runner can write, and the shard part of a record's name.

### Fixed

- A test artifact run by two runs took the second as one of a runner of its own (refused with the watchdog on, and checked for shards): the second run now takes preflight's runner as the first did.

## [0.14.0] - 2026-10-22

### Breaking

- glint 0.5.1 runs the lint, of glint's new 0.5 line: a package that pins glint itself moves to that line, or names it in `.coexist` (gantry 0.2.10 is on 0.5.0). Its aegis pack decides more sites (`anytype` copies where bound, what a generic passes on of its parameter read at each binding, an owner's address given to a function that releases it, whole allocations through callers and returns, types built by `@Struct`/`@Union`/`@Tuple`, function types reflected), so a package gating A001-A005 may now see a finding its sites hid.

### Changed

- A suppression that suppresses nothing is listed where it is, with the incomplete sites (glint's `Report.stale`), where a count was printed.
- A nested build with a manifest of its own (a directory with its own `build.zig.zon`, shakedown's `ci/bench-consumer/`) is left out of the default lint, as the manifest checks already treat it: only its own build compiles its files and binds the modules they import, so its imports would not resolve here.

## [0.13.1] - 2026-10-21

### Added

- The lint refuses a manifest whose `.version` is not CHANGELOG.md's newest release, naming both: a tag of the commit names the one the manifest declares, and a fetch of it names itself by it (uplink 0.9.0 and 0.9.1 were tagged with the manifest at 0.8.7, cut by hand). `publish` refuses the same before it tags or pushes. A package that has released nothing yet has nothing to match.

## [0.13.0] - 2026-10-21

### Breaking

- `ci-build` (and every build of a package with `.portable_tests`, which configures it) refuses a portable test given a path by `addOptionPath`, `addOptionPathDirectory` or `addOptionPathUntracked`: the path is the building runner's, which the runner replaying the tests has not. A program the tests run goes through `addTestProgram`.

### Added

- `addTestProgram(b, options, name, program)`: a program the tests run, named to them as `name` in `options` by its path from the package root (`zig-out/preflight/programs/<file>`), installed before they compile. Portable tests replay with it: the replaying runner downloads it with them and preflight restores its permission to run.

### Fixed

- A `build.zig.zon` that is not UTF-8 crashed the checks that read it (std's char literal parsing reads past a UTF-8 sequence cut short, Zig 0.17.0): every manifest read is refused as not UTF-8 first, and the ones read through `ZonGen` also refuse an AST with errors. gantry's fuzz target found it in gantry's own reader (the 2026-10-21 nightly).
- A portable test given a program by `addOptionPath` failed where it replayed, the path naming the building runner's cache (parley's process tests on every macOS and Windows leg since 2026-10-18, `FileNotFound`). `ci-build` now refuses a portable test given any path by `addOptionPath` (or its directory and untracked kinds), naming `addTestProgram`.

## [0.12.3] - 2026-10-21

### Added

- `deprecations` follows the language's changes as it follows std's: the release's table holds the forms the language dropped, each checked against the parser that built preflight, which must refuse it. A file that does not parse is repaired over its tokens first. 0.17's entry is array repetition: `[_]T{e} ** n` becomes `@as([n]T, @splat(e))`, and a repetition of anything else is listed by hand (`a ** n`), line by line. The summary counts them as `dropped forms`.

### Changed

- preflight's own code follows 0.17's deprecations (`builtin.os` and `builtin.cpu` are `builtin.target.os` and `builtin.target.cpu`), written by `deprecations --write`.

## [0.12.2] - 2026-10-21

### Changed

- The default policy reports glint's D001, a private declaration its file never names: dead code, or a use that went missing. It never fails a run; a package gates it in `glint.rules`.
- The assertion count is glint's: each call counted by the declaration it resolves to (std's `debug.assert`, aegis's `assert` contracts), and calls spelled like one whose callee does not resolve counted apart (`preflight: assertions: N in F functions, A of them with one; U calls spelled like one unresolved`). preflight's own count of the spelling `assert(` goes, and with it the per-function table; a hosted job's summary gets glint's per-file table.

## [0.12.1] - 2026-10-21

### Changed

- glint 0.4.3: comptime path conditions and generic copies decided at the binding (A002), a choice of types per build in the aegis pack, Z006 accepting a declaration a generic reads on its type parameter.

## [0.12.0] - 2026-10-20

### Breaking

- `ci-check` compiles the tests and the public modules a second time linking libc, for each target Zig ships a libc for, unless they link it already, since a consumer may build the package with libc and `builtin.link_libc` selects other code (visor 0.5.7 broke on x86_64-windows-gnu with libc, a path no compile reached). The objects are named `<name>-libc`. A program's libc is its own: the installed artifacts and the benchmarks compile as they are built. A package whose code does not compile with libc fails `ci-check` from this release.

### Added

- A fuzz campaign names a fuzz test two test runs of it would fuzz, before any fuzzer starts: Zig keeps a fuzz test's corpus by the test's name alone, so the second fuzzer panicked mid-campaign ("corpus of ... is in use by another fuzzer"; visor's widget binary held its base tests twice). `fuzz-campaign` gives the build a directory of its own in `PREFLIGHT_FUZZ_NAMES`, where each test run claims its fuzz tests' names in its unfuzzed run, and a name another run holds fails the test, naming both executables.

### Changed

- glint 0.4.2: it decides 134 of the family's 372 undecided aegis-pack sites, so a package can gate A001-A003.
- The lint's summary line counts the incomplete sites always (`N sites incomplete`), and a run with more than the 25 it prints writes every one to `.zig-cache/preflight-lint/incomplete.txt`, named on the line that counts the rest, and in a hosted job into the job's summary too. A survey reading the printed lines undercounted aegis (236 sites, not 18) and strand (79, not 23).

### Fixed

- A test the watchdog ends no longer leaves the processes it started running: the test runner's supervisor runs the tests in a process tree of their own (a process group the tests' process leads on POSIX, a job that ends its processes when it closes on Windows) and ends what is left of it once the tests' process has ended, however it ended, after naming the processes that still hold the tests' output. When the supervisor itself is killed, the tests' process ends its group with it. An integration test's `zig build` once outlived its test and held a fixture cache's lock.

## [0.11.1] - 2026-10-20

### Fixed

- A fuzz test that ends without calling `std.testing.fuzz` in the fuzzing build, as one that skips when `builtin.fuzz` is set does, fails the campaign by name. The build finds its fuzz tests in their unfuzzed build, and a test spends its share of a bounded campaign only inside the fuzzer, so upstream's runner, which returns from such a skip quietly, had the fuzzer select it again forever (visor's `hardened-fuzz` never ended). The runner now serves the fuzzing build itself, upstream's protocol but for that, and gives a test there `std.testing.environ`, which upstream's leaves empty.
- The step a package fuzzes (`fuzz_step`, else the hardened run's) runs its tests on preflight's runner as `tests` does, so a dedicated fuzz step has the watchdog and the check above too.

## [0.11.0] - 2026-10-20

### Breaking

- The default policy holds every package to the family's durability door: P006 gates, in production code, std's sync declarations (`posix.fdatasync`, `posix.syncfs`, `os.linux.fsync`, `os.linux.fdatasync`, `os.linux.syncfs`, `os.linux.IoUring.fsync`, `c.F.FULLFSYNC`, `c.F.BARRIERFSYNC`) and the external functions `fsync`, `fdatasync`, `syncfs`, `FlushFileBuffers`, `NtFlushBuffersFile` and `NtFlushBuffersFileEx` however a program declares them, decided by what each reference resolves to (glint 0.4.1). Its owners, airlock and reactor (whose `Io` backends implement `fileSync`), are named in the entries and carry no suppression; a sync through an `Io` (`std.Io.File.sync`, an atomic file's commit) is the designed path and is not governed. Any other site that must make the call says why with `// glint-ignore: P006 -- <reason>`. The copied `durability belongs to airlock` token rules in `ci/layers.zig` can go.

### Added

- A `glint.disallowed` entry with no `source` names an external function by its symbol, and `scope` (`all` or `production`) leaves test code out. An entry's `owners` name the packages it does not govern; glint is told the checked package by its `build.zig.zon` name.

### Changed

- Pins glint 0.4.1 and gantry 0.2.7, both on glint's 0.4 line, so no `.coexist` is owed.

## [0.10.2] - 2026-10-20

### Fixed

- The consumer check reads `.coexist` as bay writes it (`.{ .name }`); it refused every manifest that named one.

## [0.10.1] - 2026-10-18

### Changed

- The command line is ensign's (0.2.3, a new dependency): one declaration (`src/cli.zig`) gives every command its options, `--help` and the mistakes' messages, which name the nearest option and exit with status 2. Each command takes exactly its options, so one a command ignored before (`gate --date`) is refused; the forms the build's steps and the generated workflows call are held by tests. `plan --full`, refused since `--tier` replaced it, is an unknown option like any other.

## [0.10.0] - 2026-10-17

### Breaking

- A release that removes or changes a public declaration without a `### Breaking` entry is refused (`release`, `ready`, `land`), naming each one. The public surface of the modules the package exports and of its `build.zig` is read with glint's project model, at the last tag and now: a line per declaration (a function's parameter and return types, a field's type, the fields a struct literal must name, what a public constant aliases), following relative imports, aliases and the types a function returning `type` makes. `zig build surface` lists it; `-- --since <tag>` lists what changed.

### Added

- `publish` releases a package's programs: `"programs_step"` in `ci/workflow.json` names the step of its own build that installs them, one per host; `publish` builds it before anything moves, then makes the tag's GitHub release with each file attached and the changelog's entry as its notes.

## [0.9.3] - 2026-10-17

### Changed

- glint 0.2.15 (the aegis contract's five waiting fields, `Atomic`, task contexts, ordered locks and `Counter`; receivers through type information, builtins, destructuring and loop values), which selects aegis 0.1.14.

## [0.9.2] - 2026-10-17

### Fixed

- The Zig master leg puts bay on the path before its setup, whose fetch configures the package's build (`bay dev` for a package bay develops): it failed every night at `preflight fetch` with `FileNotFound`, the `bay` it could not start.

## [0.9.1] - 2026-10-17

### Added

- glint is told the module names a file's build binds in no module that compiles it (`Project.Input.absent`, glint 0.2.14): code that needs one is not compiled in this build, so a call that passes something from it binds nothing. warp's CRC folding, whose x86 kernels are modules only an x86 build has, lints decided on ARM.
- `addConsumerCheck` also checks the consumer's program against the package's own modules in the configured build (an object nothing installs), which tells lint what each name the program imports is: clearance's `ci/consumer.zig` read `clearance` unmapped.

### Changed

- glint 0.2.14.
- The riscv64 machine's runner is passed to a test's run step with `addArtifactArg2`: Zig 0.17 deprecates `addArtifactArg`, which glint 0.2.14 now resolves (Z011).

## [0.9.0] - 2026-10-17

### Breaking

- A process a test started that still holds the tests' output two seconds after they ended fails the run, named with its arguments on Linux and macOS. The build used to wait for it, up to a minute, and then killed the runner outside any test with no name (`test runner failed to respond`, conduit's ThreadSanitizer job); one that let go within the minute passed.

### Fixed

- Serving the build, the test runner runs the tests in a process of its own and keeps the build's streams: the tests' process holds the protocol on descriptors no child inherits, with the null device as stdin and its stderr as stdout, and its output reaches the build through a pipe the runner forwards. A process a test started no longer holds the build's streams, reads the protocol's bytes or writes into it, and a crash's report reaches the build whole. A single-threaded build, or a system that cannot start a process, keeps the tests in one process, with the protocol still moved.

## [0.8.2] - 2026-10-17

### Added

- `vm_packages` in `addCi`'s configuration: the Alpine packages a package's tests need on the riscv64 machine (`-Dci-vm`), such as `git` or `openssl`. Alpine's `apk` installs them on the machine when the build makes it, from the release's own repositories over QEMU's user network, verified by the release's own keys, and the boot image carries them; a build that runs nothing on the machine fetches nothing.

## [0.8.1] - 2026-10-17

### Changed

- Pins glint 0.2.13: A003 follows an owner through `while` and `for` loops and reads one returned held as its caller's; the aegis rules decide receivers through std's lists (`ArrayList(T).items`), `if` and `switch` expressions whose other branches leave, labeled blocks and function pointer fields; A002 finds a copy of an owner that resolves to one by value.

## [0.8.0] - 2026-10-17

### Breaking

- `ready` (and `land`) and `gate` refuse a package whose caller is not what `plan -- --workflow <caller>` generates for its pins and configuration, naming the command that generates it again: a caller left stale has the hosted runs check the package with another preflight than it pins, or other jobs than `ci/workflow.json` declares.

## [0.7.1] - 2026-10-17

### Changed

- Pins glint 0.2.12 (0.2.11's changes with it): the aegis rules know `BlockingGuarded`, `RwGuarded`, `SpinRwGuarded` and their guards, `Condition`, `Once`, `Lazy` and `Confined`; A003 follows a guard lent to a call that hands it back held, checks acquisitions whose failure is caught, and reads a guard's `handOff()` (aegis 0.1.12) as a declared transfer; A001 decides receivers by what the program does with a field (a member read off it, a literal's fields, its use as a truth value or operand). A package that gates A001-A003 and holds these owners now has their releases checked.

## [0.7.0] - 2026-10-17

### Breaking

- A hosted job, and `gate`, refuse a test the step runs without preflight's runner, naming it: one the build gave its tests after `addCi` read them, which ran with no watchdog, shard, timing record or riscv64 machine (conduit's `containment-tests` ran on the riscv64 leg's host, where it cannot). Add it to the tests before `addCi`.
- The runner takes its watchdog as a module of the test, `preflight_watchdog`, as it takes `preflight_order`; preflight's own order and watchdog tests import both so and run under the runner, as the refusal above asks.

### Added

- A hosted test job keeps a deadline, its start and limit less two minutes for its report and upload, and the runner ends a test still running then, named (`preflight: watchdog: <test> was running when the job's time ran out`), where the host would cancel the job and name nothing. The runner reads it from `PREFLIGHT_DEADLINE`, which `preflight run` sets from `PREFLIGHT_STARTED` and `PREFLIGHT_JOB_TIMEOUT`.
- The riscv64 leg records its tests' durations (`-Dci-timings=true`), a column of its own, and splits into `shards.riscv64` jobs balanced by it: emulated, a suite takes several times as long as on a runner (shakedown's passed the job's limit two nights running).

### Fixed

- The release tier's `profile` job failed now and then with `SyntaxError`: it merged every job's timing records into one directory, where jobs on one OS and mode (x86_64 and aarch64, Debug) write records of one name, so one job's records replaced another's and two downloads writing one file at once interleaved it. Each job's records keep a directory of their own.

## [0.6.3] - 2026-10-17

### Added

- A declared job's `shards` splits its test step over that many jobs on each host (`<name> shard i/n`), each running the share `PREFLIGHT_SHARD` names, balanced as the hosts' test jobs are: a sanitizer run of a suite that outgrew one job's time limit.

## [0.6.2] - 2026-10-15

### Changed

- Pins glint 0.2.10: the aegis rules decide receivers inside generics, through the arguments the project's own calls pass, a generic call's result and `@TypeOf`/`@typeInfo`.

## [0.6.1] - 2026-10-15

### Added

- `-Dci-vm`: what a build makes for riscv64 Linux runs on a riscv64 Linux kernel under QEMU's system emulation, booted for each test or program run (about a second): Alpine Linux's kernel and root file system, pinned by hash and fetched only by a build that asks, with preflight's own first process. The program runs as the build's user, with its standard streams as pipes, the host's directories it names at their paths and its scratch directory in the machine's memory, and ends as it ended there, by its exit code or its signal. The watchdog's bound is ten times as long on it.

### Changed

- The release tier's riscv64 job runs its Debug suite on that kernel (`-Dci-vm`; the runner installs `qemu-system-misc`), in place of QEMU's user mode, which emulates one process and not a kernel: a subreaper, pidfds and io_uring failed there and would on no riscv64 machine (shakedown, conduit and reactor pass on the kernel). `gate` runs it where `qemu-system-riscv64` is on the PATH.
- `gate --working-directory <dir>` runs the planned jobs in `dir` and the declared ones in their own directories, as the hosted caller does: preflight gates itself from its root with `--working-directory sample`, where every planned job passed preflight's own build an `-Doptimize` it does not declare.
- Pins alpine_riscv64 V and alpine_riscv64_rootfs V.

## [0.6.0] - 2026-10-15

### Breaking

- The default policy gates Z026: an empty `catch` with no reason written at the site fails the lint, where it was reported. A discarded error is a result nobody read; a best-effort cleanup is a fine reason, silence is not. A repository that wants it reported names it (`{"id": "Z026", "level": "report"}`).

### Changed

- Pins glint 0.2.9.

## [0.5.6] - 2026-10-14

### Changed

- The per-test watchdog's bound is ten times as long under ThreadSanitizer, which runs a test several times slower: a heavy test under the sanitizer was taken for a hang.
- Pins bay 0.1.13, which gives Zig a relative package directory: Zig 0.17 refuses the path dependencies of a package unpacked under an absolute one, which a nested build met in ghostty's `pkg/` (morse's conformance in the VM).
- `gate` runs the source checks and every target's compile on the Linux machine alone, where the hosted gate runs them, since they say the same on any system; a Mac runs its suites and the hardened runs. Each compile of every target was made twice.
- `gate` runs every job it can, where the first failure ended it, and names every job that failed: a red on one leg no longer hides the rest.

## [0.5.5] - 2026-10-14

### Changed

- Pins glint 0.2.8: A002 decides copies of plain vectors, payloads, `if` expressions and labeled blocks.

## [0.5.4] - 2026-10-14

### Changed

- Pins glint 0.2.7: the aegis rules decide receivers reached through arrays, slices, joined literals and generic results written around `T`.

### Fixed

- Lint binds an import to the checked package's own module when the build reaches that package a second time, as a benchmark built in another mode does: the module's root was named by the second package's directory (`.zig-cache/bay/../..`), two modules bound one name to two paths, and every import of it from such a file was left unresolved.

## [0.5.3] - 2026-10-14

### Changed

- `hardened-tsan` runs on aarch64 Linux too, where Zig ships ThreadSanitizer's runtime as on x86_64: a package's race checks run on an ARM Linux machine, where they were refused.

### Added

- A landing by hand, gated on the machines at hand rather than by a hosted run (`ready`, `gate`, `publish`): `ready` makes the landing commit on the branch as `land` makes it in its worktree (rebase, tidy, nested manifests aligned and samples tidied, the caller generated again when its preflight moved, re-pins noted, the release cut and committed); `gate` runs the release tier's jobs this machine can, each as the hosted job runs it, and names the ones it cannot; `publish` pushes the gated commit onto main with its release's tag in one atomic push, never forced, and refuses a tag that names another commit.

## [0.5.2] - 2026-10-14

### Fixed

- The toolchain carries bay 0.1.12, which fetches a package pinned by an archive URL as a build does: under bay 0.1.8 to 0.1.11 a nested build (morse's and visor's conformance) left the emulator's dependencies in Zig's cache with one directory too many, and the build refused every one of them for a hash mismatch.

### Changed

- The aegis rules come from glint 0.2.6, which decides a receiver by the type it resolves to where 0.2.5 left it undecided: a package gating A001-A004 may meet findings at sites that were undecided.
- Pins bay 0.1.12, glint 0.2.6.

## [0.5.1] - 2026-10-14

### Fixed

- An error one test logs fails that test alone: the runner's log counted it in upstream's runner as well, whose count only upstream's own loop resets, so the next test that fuzzed panicked with "error logs detected" and took every test after it in the process down with it (relic's Windows nightly, 2026-10-14).

## [0.5.0] - 2026-10-14

### Breaking

- The hardened run backs `std.testing.allocator` with the package's shakedown's quarantine (`shakedown.alloc.Quarantine`, an inaccessible page after each block, no address reused), one per test, where it took the page allocator: a read or write after free of a block the allocator takes whole faults at the line, in every run. A package with a hardened run declares shakedown.

### Added

- The consumer check reads the graph plain `zig build` fetches for the package, each dependency's manifest as published with no selection over the pins, and fails when it holds a package at two revisions (two lines a package names in `.coexist` aside), naming the package, each revision and who pins it: a package developed with bay is still a plain Zig package, and bay's one selection hid a consumer's two copies (bay 0.1.10 pinned aegis 0.1.5 beside ensign 0.2.1's 0.1.4).
- The unfuzzed-parser report follows calls across the package's files, eight deep, where it looked only in the fuzz test's own file: a property that drives a whole pipeline (gantry's scan, which hands each manifest to its parser) reaches the parsers through it, and they are no longer reported.
- Every package that declares shakedown has the `fuzz` step: it fuzzes `Config.fuzz_step`, else the step the hardened run fuzzes, else `test`, where a package had to name one to have any.
- `land` runs again, up to three times, the jobs of its run that GitHub found no runner for ("The job was not acquired by Runner of type hosted even after multiple attempts", macOS when its runners are short): such a job is cancelled before a step runs and says nothing of the change, where the landing reported it red.
- The release tier runs the Debug and ReleaseSafe suites on GitHub's ARM runners, `ubuntu-24.04-arm` and `windows-11-arm` (Windows on ARM links once and replays, as Windows does), and the Debug suite on riscv64 Linux under QEMU's user mode (`-Dtarget=riscv64-linux-musl -fqemu` on the Linux runner, which installs it). The toolchain carries the checks and bay for both ARM runners; `shards` takes `linux_arm` and `windows_arm`.

### Changed

- Pins bay 0.1.11 and glint 0.2.5.
- preflight's own suite shares one Zig cache across every fixture's build, where each fixture built preflight's checks, its runner and its tools from cold, about a minute apiece: the suite takes 12 minutes on an M-series Mac where it took 25.
- The release tier links a macOS target on Linux, as `link (<target>)`, unless the build for it links a framework: Zig links a macOS program with the libSystem it ships, and only a framework needs Apple's SDK on a Mac. `plan` and `land` read that from the build configured for each macOS target, so a package that links none uses no Mac runner for its links.

### Fixed

- `land` gives every other manifest of the repository (a fixture, a sample) the package's own pin of each package both pin, the drift `lint` reports, so no train syncs them by hand.
- A build that fails to configure when preflight reads its facts says why: what it wrote to stderr is reported with the command, where only `BuildConfigurationFailed` was.
- Every hosted job gives bay the Zig the job installed (`ZIG`), so bay no longer downloads a second copy of it in each job.
- `land` tidies, with bay, each build in the repository that takes the package by `.path` (a sample), as it tidies the package: such a build has the package in its graph, and a pin left behind what the package now asks for (`sample/bay`'s aegis 0.1.3 under glint 0.2.4) failed the landing's run, as bay refuses it.
- `land` on a repository whose default branch does not hold the caller (a new one, its main made first) pushes the branch's caller there alone, in a commit of its own, then lands: GitHub dispatches only a workflow the default branch holds, and the dispatch failed with "HTTP 404: workflow not found on the default branch".
- A program the build makes for the host and the tests run (a table check's generator) is built for the baseline CPU where compile-once replays it: built for the compiling runner's own CPU, it died with an illegal instruction on a runner of another model. Only the replayed artifact's graph is changed; another artifact sharing its modules keeps its CPU.

## [0.4.5] - 2026-10-13

### Fixed

- `addConsumerCheck` gives the consumer's build every package its listed dependencies need in turn, not only the listed ones: with fetching off, a package whose dependency gained one of its own (reactor 0.3.0 on shuttle) failed its consumer check with "package not found".

## [0.4.4] - 2026-10-13

### Changed

- Pins glint 0.2.4.

## [0.4.3] - 2026-10-13

### Fixed

- preflight's own suite: the default-policy test is one test per rule, every fixture's lint shares one build cache (each built preflight's checks from cold in a fresh directory), and its tests are bounded at 300 s with the reason stated, as a cold first build of the checks can pass 120 s on a hosted runner.
- A package's first release is the version its manifest names: with no v* tag before it, `release` bumped it, so a new package could not be released as 0.1.0 without a Breaking entry that was not true.

### Changed

- The Zig master leg takes bay from the toolchain, as every other job does, and sets `ZIG` to Zig master: a package developed with bay ran there with no bay at all, and bay builds with `ZIG` over the manifest's version.
- A change confined to the manifest's `.dev_dependencies` releases nothing, and `land` notes only re-pins of `.dependencies`: no consumer's build reads development pins, so a tool the package develops with moving (preflight, shakedown) lands without a version, where it re-released every package.

## [0.4.2] - 2026-10-13

### Added

- `lint` fails a function of `build.zig` that calls `lazyImport` without an earlier `@setEvalBranchQuota` in it: std's `lazyImport` compares every package of the tree at comptime, and a large tree passes the default 1000 branches.

## [0.4.1] - 2026-10-13

### Added

- `sample/bay`, a project developed with bay that ships with aegis and tests on shakedown, passing aegis's types between them, so its build links one aegis or does not compile, whatever revisions the two pin; preflight's gate runs it on Linux, macOS and Windows.

## [0.4.0] - 2026-10-13

### Breaking

- `revision_exceptions` in `ci/preflight.json` is gone: a package two lines of which may meet in an artifact is named in the manifest's `.coexist`, the field bay reads for the same choice, so one declaration serves both. It allows one revision per line, as bay selects; two on one line are still reported, and a package naming itself is refused. The one-revision message says to build with bay or pin one revision, where it said to bind a dependency by hand.
- A benchmark's `imports` that gives `shakedown` is refused: preflight adds the shakedown the package declares, so a benchmark has it one way.

### Changed

- A generated caller's first line is the `plan` command that wrote it, `--config`, `--working-directory` and `--self` included, and `land` reads its configuration and directory there: a package whose gate runs elsewhere, as preflight's own runs in its sample, lands with no flags. preflight's own caller said it was planned from `ci/workflow.json`, which it was not.
- A nested build (`addNestedBuild`) run from a development build runs through `bay build`, so its graph has one version of each package as the package's does; under `zig build` a shared package's own pins could bring a second revision unnoticed.
- The tests take shakedown as bay gives it, with no `.aegis = .consumer` or `useAegis` binding: bay gives a graph one aegis, so shakedown's is this package's.

## [0.3.4] - 2026-10-12

### Added

- `land` takes `--config` and `--working-directory`, as `plan` does, for a gate configured and run in another directory than the package's: preflight lands itself through its own train.

### Fixed

- `bay land` (`zig build land`) dispatches the merge tier without reading what gh answers. gh 2.100 answers a dispatch with the run's URL, which the landing took for a failure once it had pushed its ref; the run is found by listing, as before.

## [0.3.3] - 2026-10-12

### Fixed

- The test watchdog writes its line without the stderr lock. A test stalled in a crash handler that hangs holds that lock, and the watchdog waited on it too: the run said nothing until the job's own limit ended it.

## [0.3.2] - 2026-10-12

### Fixed

- `hardened-fuzz` fails a campaign whose fuzzer crashed or ran no input. Under `--fuzz=<limit>` Zig prints a failure the fuzzer finds and still exits 0, so every campaign passed; `preflight fuzz-campaign` now runs it and judges it on what the fuzzer leaves in the cache: an input saved to `f/crash` during the run, and the runs the coverage files count.
- The hardened profile leaves a module that takes its artifact's mode taking it, and raises only a mode set apart from Debug to ReleaseSafe. It raised the test runner's own modules too, and Zig gives each mode its own `builtin`, so the runner of a Debug test found no tests: the fuzz campaign started none.

## [0.3.1] - 2026-10-12

### Changed

- Pins bay 0.1.2, which names forks to Zig by absolute path, so a cold development build of a package its own tools pin configures.

## [0.3.0] - 2026-10-12

### Breaking

- `addNestedManifest` is `addNestedBuild(b, package, NestedBuild)`: the nested build is assembled under the cache (its files copied from its directory, its manifest written from the package's own pins, each path dependency made relative to where it is assembled) and run there with `.args`. The step it returns runs the build. It wrote the manifest into the package's tree, which Zig refuses from any package but the root, so it could not work in a development build, where the package is a dependency; nothing is written into the tree now, and no generated file needs ignoring.

## [0.2.2] - 2026-10-12

### Changed

- Pins bay 0.1.1, whose development build runs in the package's directory.

## [0.2.1] - 2026-10-12

### Fixed

- The caller generator and `land` read a preflight pinned by release, `?ref=v0.2.0#<commit>` as `zig fetch` and bay write it; they refused every pin but a bare commit.

## [0.2.0] - 2026-10-12

### Breaking

- Development dependencies through [bay](https://github.com/pedronaugusto/bay). `addCi(b, package, config)` takes two builders: `b`, which owns the steps and their options and declares `preflight` and `shakedown`, and `package`, whose sources, manifest, artifacts and modules are checked. With bay, a package calls it from `dev(b, tools)`, its development build, over the package as a dependency of it; without bay, from `build` as `addCi(b, b, config)`. `addConsumerCheck` and `addCheck` take the package the same way; `addOwnCi` is gone, since preflight's development build finds itself as `preflight`. The tests the gate runs must be a step of `b`.
- A package whose manifest declares `.dev_dependencies` runs through bay: the hosted runner runs its steps and configures its build as `bay dev`, so a step named like one of bay's commands is still the step, the toolchain builds bay beside the checks, and builds the gate starts again (the hardened runs, the benchmark comparison's base, shakedown's fuzzer) go through the same bay. A package without the field runs through `zig build` as before.
- Under bay, the configured build's facts take the checked package's root from the development build's root, which `bay locate --dev` names, so a package developed with bay needs a bay that has `locate`. With one that does not, the read fails with `BayLocateFailed` and what bay said.
- preflight's own shakedown is a dev dependency, and bay a lazy dependency, which the toolchain and preflight's tests build.
- The default policy reports a cast without its written reason (P001) and a function over the reading budget (P003) instead of gating them: they are a house style, which a package gates in its `glint.rules`. What can hide undefined behaviour still gates by default: safety turned off without a reason (P002) and `catch unreachable` without an invariant (P004).
- The merge tier compiles the objects of every configured cross target, as the fast tier does: a landing runs the merge tier alone, so a change can no longer move main past a target it breaks.
- The linked graph is held to one revision of each package and no cycle between packages, the package under test included: a test dependency that links the package back takes the package's own module, bound by the build script. `ci/toolchain.zig`, `check-toolchain` and the toolchain closure policy are gone; this general check replaces them, and preflight needs no `revision_exceptions`. preflight no longer pins aegis.
- Nothing of preflight's own pins reaches a package's artifact. The test runner, `preflight_order` and the watchdog link std alone: `Shard` holds a plain `index` below a nonzero `count` (`Shard.init(index, count)`). Benchmarks and fuzzing use the package's own `shakedown`, which the build that calls `addCi` must declare; `Config.fuzz_step` is opt-in (null by default), and without it there is no `fuzz` step and nothing is fetched for one.
- The family rule sets leave preflight: the `rules` module and `preflight_rules` are gone. Test-only packages are `test_dependencies` in `ci/preflight.json`; token rules are a package's own, in its `ci/layers.zig`.
- `ci/workflow.json` `jobs` declares a package's own CI jobs as build steps (hosts, tiers, directory, arguments, setup step, timeout), rendered into the gate's matrices; a landing waits for them. The generator owns the whole caller and refuses to replace one holding a job the configuration does not declare; the earlier splice of hand-written jobs is gone. `sanitizer` and `sanitizer_job_timeout` are refused: declare the run in `jobs`, or use `hardened`. Every key is validated, and an unknown one (`package` among them) is refused.
- Landing moves into the caller: one `land` job that needs the gate and alone may write, rendered with its input only when `land` is set, so a caller without `land` asks for no write permission (before, every caller pinned to a commit with landing failed to start unless it set `land`). zig.yml loses its `land`, `test-job-timeout` and `windows-job-timeout` inputs. Pull requests queue by number, so two of them never cancel each other or a run on main.
- `addCi` claims a step named `land`, which lands the branch checked out (see Added): a package with a `land` step of its own fails its tests naming it, as with every step preflight claims, until it renames its own.
- The caller's `land` job moves the repository's default branch, whatever its name, as `preflight land` lands onto origin's: it no longer assumes `main`.
- A step name preflight claims that the package already has fails the package's tests with a message naming it, instead of crashing the build.
- attest finds the proof by its artifact name, in whichever workflow file the caller lives, one request per tier.

### Added

- `land` (`zig build land`, `bay land` under bay), the step that lands the branch checked out, for a package whose `ci/workflow.json` sets `land` and `release`. It makes the landing commit in a worktree of its own, detached at the branch, so the branch, its checkout and its tree are never touched: it rebases on origin's default branch moving no other branch, runs `bay tidy` under bay, generates the caller again as `plan` does when it names another preflight than the manifest pins, adds a `### Changed` line naming each dependency pinned at another revision than at the last tag when `[Unreleased]` names none of them (and not when `[Unreleased]` is empty beside other shipped changes, which the release refuses), makes and commits the release, and pushes it to a branch of its own, `land/vX.Y.Z-<commit>` (`land/<branch>-<commit>` with no release). It dispatches the caller's merge tier with `land` through the GitHub CLI, naming origin's repository on every call, prints the run as soon as it is listed and waits, asking gh again through passing failures. Green checks that the default branch holds the tested commit and the tag is on it, moves the branch there when it has not moved, and deletes the attempts at that version no landing needs; what it cannot do after a green run is reported, and the landing stands. Red names the failed jobs, keeps the attempt's branch and leaves everything as it was, so landing again makes the same version. Landing again after a landing whose end the clone missed finishes it.
- A test of preflight's own holds the watchdog's `io_teardown` phase: a test that leaves a task running through its Io teardown fails by name and that phase. A package no longer needs a probe of its own for it.
- `addNestedManifest` writes the `build.zig.zon` of a build nested in the package (a conformance build, a consumer fixture) at build time, taking the packages the root also pins from the root's own manifest, so a nested manifest does not have to be committed or kept in step.
- Versions on landing, opt-in (`release` in `ci/workflow.json`, with `land`): the step `release` gives a package that changed since its last `v*` tag (any file under `.paths`) its next version from the `[Unreleased]` headings, a `### Breaking` entry bumping the minor below 1.0 and the major from 1.0 and anything else the patch, writes it to `build.zig.zon` and cuts the changelog with its link references; an unchanged package gets no release, an empty `[Unreleased]` or an existing tag fails naming the fix. The caller's `land` job tags the landed commit `vX.Y.Z` when the manifest's version has no tag, never moving one.
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
- `package-directory` on the reusable workflow: the package a landing releases when the gate runs in another directory. preflight's own caller names the repository's root, since its gate runs its sample, so preflight is released by its own landing like any package.
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
- Pins glint 0.2.0, gantry 0.2.0, bay 0.1.0 and shakedown 0.2.0.

### Fixed

- A build with benchmarks configures in a linked git worktree. The benchmarks record the commit, and read the branch's ref from the worktree's own git directory, where git does not keep it, so Zig failed the configuration with `FileSystemFailure`.
- The cross compile validates a helper program that a test names by path (an option of `addOptionPath`) as an object, like every other artifact. It linked the program for the target, which fails where the program links a framework and the host has no SDK for it.
- The hosted gate passes `-Dci-sdk` on a macOS runner only to a build that declares it. A declared job's nested build does not, and Zig refused the option. A build that ends before it has said what it configured reports what it wrote to stderr; the gate named only `TruncatedProtocolFrame`.
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
