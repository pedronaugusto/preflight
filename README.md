# preflight

preflight gives a Zig package one local gate and one hosted gate. The build helper
runs format, gantry structure rules, ziglint, namespace layout, cast reasons,
function length, documented snippets and test imports, then the package's tests.
It is a build dependency; a consumer's module never imports it.

## Install

Requires Zig 0.17.0. Add preflight as a build dependency pinned by commit:
`zig fetch --save git+https://github.com/pedronaugusto/preflight#<commit>`.

## Usage

In `build.zig`, after creating the test step:

```zig
const preflight = @import("preflight");
// Inside build(b), after assembling test_step:
preflight.addCi(b, .{ .tests = test_step });
```

`zig build lint` runs source checks. `zig build ci` checks sources before running
tests. A watchdog in the shared test runner fails a test that runs longer than
120 s, its Io teardown included, by name, phase and seed, in local runs too. A
package that needs another bound says why: `.test_timeout = .{ .bound = .{ .limit =
.fromSeconds(30), .reason = "..." } }`, or `.{ .off = "..." }` for a test runner of its
own or a single-threaded build, which otherwise fail the build by name. preflight
passes the build runner no `--test-timeout`; one given by hand bounds each test there
too. `.test_log_level = .info` prints a library's `std.log.info` lines in its tests,
where Zig's runner prints `.warn` and above. `zig build check-imports -- --audit` exposes gantry's graph for inspection.
`-Dci-lint=false` lets the hosted optimization and shard jobs use the source job's
result; the default local gate always checks sources.
Compiled caches never skip test execution: each gate runs the test binaries even
when their build products are already available.

A package with benchmarks gives them to `addCi` as `.bench = .{ .programs = &.{.{ .name
= "scan", .source = "bench/scan.zig" }}, .imports = imports, .target = target,
.optimize = optimize }`, where `imports(b, target, optimize)` builds the modules a
program imports in that mode. `zig build bench` builds every program in ReleaseFast
under `zig-out/bench` and runs the timed ones one after another with no arguments
(`.timed = false` leaves out a tool such as a fixture writer); a program's own
arguments are for running it from `zig-out/bench` by hand;
`zig build test` runs each once with `--smoke`, built in the test's mode, where a
program runs every point once and reads no clock. A repository with a `bench/`
directory and no `.bench` fails its tests by name.

`preflight.addConsumerCheck(b, .{ .package = "name", .program = b.path("ci/consumer.zig") })`
adds `check-consumer`: it builds a generated project that depends on the package
by path with fetching off and a Zig cache of its own, so the build a consumer gets
cannot reach the package's CI dependencies or anything cached for them. `.modules` names the modules the program imports,
and `.packages` the dependencies the package itself needs. The consumer builds
for the host in Debug. `preflight.addCheck(b, name, source)` builds a
repository check program, runs its tests, then runs it from the repository root
as step `name`.

## Design

### Repository facts

`ci/layers.zig` declares gantry's layers, required paths, entries, named modules,
reference rules and optional owned tokens. Layers order production sources only.
The shared runner checks layers, cycles and entries over the production graph,
the edges a non-test build compiles, and refuses a production file with zero or
multiple layers. Test code is in no layer, so a test file may import anything;
no production edge may reach test code, and an import in an inline test may not
reach a higher layer than its file. A glob such as `src/report/**` covers the
production files under it and passes over the test files beside them; a literal
pattern naming a test file fails. An entry that is test code fails too, since the
entry rule reads only the production graph. Required paths, reference rules and owned
tokens hold for every file. The runner walks the `sources` roots, as lint does. An
import gantry marks dead, in a declaration nothing reaches from a public, exported
or comptime member, a field, `main` or a test, is unused and fails. A file gantry
could not read as its language fails too, since it gave the graph none of its imports.
Gantry remains the language-neutral graph library; these runners belong here.

A namespace file that publishes the files of its own directory declares those
imports in `ci/layers.zig` as `reexports`, each a `.{ .from = "src/odb.zig", .to =
"src/odb/bitmap.zig" }`. Layers and cycles read the implementation without them;
every other rule reads them. A declared re-export that is no production import, or
whose file lies outside the namespace's directory, fails. A package names the
packages only its tests may import in `ci/preflight.json` `test_dependencies`, such
as a library of test doubles taken as a lazy dependency; an import of one outside
test code fails.

Test code has one definition, shared by the source checks and the structure
runner: files named `*_test.zig`, `test_*.zig` or `tests.zig`, and the
`test_support` patterns (`src/testing/**` by default). Gantry classifies the
rest: an import inside a test block, or in a declaration only tests reach, is a
test edge. Every path pattern uses gantry's dialect: `*` stays within one path
component, `**` spans components, and a pattern without `/` matches the file name.

`ci/preflight.json` names source directories, test roots, test support, README
regions and extra repository checks. A `vendored` exemption must name its upstream
and how the fork is verified. Function exceptions name an exact file and function,
a reason and the current line ceiling; growth fails. The normal limit is 120,
with lower per-path `function_limits` for shared folds. Casts require a nonempty
`// safe:` comment on their own line. Strings cannot supply that comment.

A namespace containing two or more implementation files has one adjacent entry:
`src/parser.zig` beside `src/parser/`. Case-insensitive matching accommodates
existing Zig type namespaces; tests and configured test support do not count.
Every file with tests is named by a test block a configured root reaches: the
alias itself (`_ = corpus;`), a whole `@import("corpus.zig")`, or
`refAllDecls(@This())` over a public alias. A member a test happens to use
(`corpus.seed()`) does not name the file: its tests would last only as long as that
use.

`build.zig.zon`'s `.paths` ships exactly what a fetched package needs: `build.zig`,
`build.zig.zon`, the source roots, `LICENSE`, `README.md` and `CHANGELOG.md`.
Benchmarks, CI, examples and workflows stay in the repository. A further path a
consumer's build reads is named in `ci/preflight.json` `shipped` with its reason.

Generated Markdown blocks retain their visible generator labels. Their source,
region, module import and whether that import is shown are facts in the JSON
configuration. Other generated blocks may use an explicit `zig build` argument-array command.
Missing markers, stale blocks and failed generators fail the gate.

### Ledgers

Existing ziglint findings may be recorded in a repository's `ziglint_exceptions`
file with their rule, path, exact source line, diagnostic and reason. The allowance
is consumed once per finding: duplicates, changed code and new findings fail.
This records migration debt without disabling a rule or admitting growth.
On branches, git supplies the PR base ledger (or main locally). Every exception
must already exist there; removals are allowed. Unused exceptions fail on every
branch, including main. Git renames preserve allowances only when the rule,
source and diagnostic still match exactly. Hosted checks fetch the base history;
`PREFLIGHT_LEDGER_BASE` can select an explicit base for a local reproduction.

Zig sources also reject `catch unreachable` without a nonempty
`// unreachable: <why>` on the same or preceding line, and `std.debug.print`
outside test blocks and test code. Files with top-level fields
use TitleCase; other files use snake_case or lowercase. Existing findings use
independent `unreachable_exceptions`, `debug_print_exceptions` and
`file_name_exceptions` JSON ledgers with the same five fields and shrinking
budget as ziglint. Assertion counts per function and package appear in the run
summary as a report, without affecting the gate.

The reusable workflow's `adopt` input defaults to false. For a package's first
adoption it can initialize an absent source ledger only from exact findings
already present in the base source, with the reason
`existing at gate adoption; burned down in the cleanup pass`. Existing ledgers
always retain the shrinking budget, even when this input is enabled.
`zig build findings -Drepo-root=<package>` prints the new source findings as JSON
for preparing an initial ledger; it does not change the package or approve debt.

Layout exceptions likewise name their exact member set and a reason.
`zig build docs -- usage` renders a configured region for updating its block.
`zig build cache` preserves fetched packages and tools when pruning build products.

### Test runs

Packages with relocatable test binaries can set `.portable_tests = true` in the
build helper and `compile_once: true` in `ci/workflow.json`. Linux then builds
macOS and Windows tests; those runners download and execute the binaries through
Zig's test protocol, retaining per-test timeouts and custom watchdogs. Helpers or
fixtures compiled with absolute runner paths must be made relocatable first.
An artifact upload drops the permission to run; preflight restores it before execution. The native matrix stays
available for comparing elapsed time and runner minutes against this path.

A tier records the durations of every host and mode it executes, through Zig's
test protocol. In the merge and release tiers, the profile job folds the records
into `ci/durations.json`, keeping the columns the run did not measure. It uploads
the result as the proof artifact, `preflight-merge-<sha>` or `preflight-release-<sha>`.
`gh run download <run> -n preflight-merge-<sha> -D ci` refreshes the package's
copy. From a package root, `zig build --build-file <preflight>/build.zig
-Drepo-root=. profile -- --input <dir>` folds local or downloaded records into
`ci/durations.json` in place.
The shared runner shuffles test order using the test seed in every tier and in local
runs. It prints the seed, including on failure; set `PREFLIGHT_TEST_SEED` to
reproduce an order. Direct test binaries also accept `--seed=<number>`.
Custom runners can import `preflight_order`, whose `init` seeds, selects the
shard's tests and orders them, and `preflight_timings` to record durations;
`preflight_runner_options` carries the recorded durations and the record's name.
Test runs carry no environment from the build: Zig keeps a run's environment in
its cached configuration, so the runner reads the shard and seed when it runs.
Test artifacts that share a root module share its runner options and timing record.

### Hosted gate

The gate has four tiers. Each one runs more than the one before it:

- **local**: the tests a change touches, run by hand while working. Not CI.
- **fast**: the source checks and the Linux Debug suite in one Ubuntu job, which
  also compiles the test binaries for macOS, Windows and every configured cross
  target without running them.
- **merge**: fast, plus the Debug suite run on macOS and Windows, sharded as
  configured. It runs once per wave, on the candidate for main.
- **release**: every mode on every host (Debug and ReleaseSafe everywhere,
  ReleaseFast on Linux), ReleaseSmall, every cross target and TSan where
  supported. It runs before a release cut, or by hand when a wave touched
  threading or platform code.

The merge and release tiers also run the Debug suite on Linux with Zig master,
the next release in development. That job never blocks: the run's summary
reports its result, and a break is a note for the next port's rewrite table.
The setup action takes `zig-version` (0.17.0, or master), and its cache keys
carry it.

Call `.github/workflows/zig.yml` pinned by the same commit as the package. Pass
that commit as `preflight-ref` and the tier as `tier`. The sample caller in this
repository shows the trigger and concurrency policy:

- Work-branch pushes start no run. Dispatch runs the tier it names, fast by default.
- PR merge candidates and merge queue candidates run the merge tier. A main push
  checks for a successful merge or release run on its exact SHA, with its proof
  artifact. It reports green without repeating tests; if there is no proof, it fails.
- The caller owns one concurrency group per branch, with cancellation enabled
  for work branches and disabled for main's status job. No scheduled runs are enabled.

`ci/workflow.json` names cross targets and optional CPUs, the compile step,
sanitizer step and shard counts. A `test_timeout` there is refused: the watchdog
bounds each test. The matrices are static, generated locally from
`ci/workflow.json` with `zig build plan -- --tier <tier> --output <file>`:
`fast-matrix` for fast; `merge-matrix`, `merge-compile-matrix` and
`merge-run-matrix` for merge; `release-matrix`, `release-compile-matrix` and
`release-run-matrix` for release. `compile-once` enables the compile and run
matrices. Regenerate them when the configuration changes. `ci-check` compiles the
test graph without executing it, including packages whose release-tier cross step
only builds a library. `fast_shards` splits Linux Debug across that many Ubuntu
jobs, in the fast and merge tiers. The first job owns the source checks and the
compile bundle for the other targets.

A shared `skip` job filters changes before the fast tier. Changes touching only
Markdown outside `src`, LICENSE or images run the documented-snippet check alone.
The change is the branch since it left its base, as a pull request shows it:
the pull request's or merge queue's base, or `origin/main` for a dispatch, never
the last commit alone. Mixed changes, source Markdown and unavailable diff bases
keep the test gate.
Merge and release candidates always keep the whole gate, docs-only or not.

`"shards": {"windows": 5, "macos": 2}` runs each mode on that host as so many
jobs. Every job compiles the whole suite once, or downloads it with
`compile_once`, and the test runner picks its share of the test cases: longest
first onto the least-loaded shard, by the seconds recorded for that target in
`ci/durations.json`. A test with no record weighs the mean of those with one;
without records the split is by count. Every shard computes the same split, so
each test runs exactly once. Repository-specific jobs stay in the caller and run
on the tiers they belong to.
Cross targets run in one Linux job, retaining each target and optional CPU while
sharing setup and compiled products. The checker uses its host's baseline CPU
target so its cached executable is reusable across hosted runner CPU models.

Fetched packages, compiled builds and pinned external tools have separate caches.
Each job fetches what its own build asks for: it configures the build with the
job's arguments (`zig build --list-steps`) and builds nothing, retrying three times
with backoff, as tool setup does. Zig compiles the build script of every package in
its cache, so a lazy dependency only another job asks for never reaches the Zig
master leg. A package asks for such a dependency only behind an option that job
sets (`-Dconformance` for an emulator its conformance job feeds), since Zig marks a
lazy dependency needed for the whole invocation, whichever step asked for it. `zig build ci-setup`
may install a repository's external tools into the cached runner temp directory.

The design uses GitHub's standard [reusable workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows):
repository facts stay with the caller and common mechanics have one owner.

### Following std's deprecations

`zig build deprecations` lists every reference to something the Zig release
that builds the package deprecated, with the rewrite that replaces it, and
`zig build deprecations -- --write` applies them and formats the files it
changed. It reads std's source from that Zig. A deprecated alias, such as
`pub const indexOf = find;`, needs nothing more: `std.mem.indexOf` becomes
`std.mem.find`. The rest are in a table per release, checked against that std
before anything is rewritten:

- `std.fmt.allocPrint(a, ...)` becomes `a.print(...)`, its sentinel variant
  `a.printSentinel(...)`. A first argument that is not a plain name or call
  keeps the function form, `std.mem.Allocator.print(...)`.
- `std.fmt.bufPrint` becomes `std.mem.print`, `bufPrintSentinel`
  `std.mem.printSentinel`, and `std.fs.path` becomes `std.Io.Dir.path`.
- `std.mem.copyForwards(T, dest, source)` and `copyBackwards` become
  `@memmove(dest[0..source.len], source)` when `source` is a name.
- `b.lazyDependency(...) orelse x` becomes `b.dependencyLazy(...) catch x` for
  `b` declared as `*std.Build`.
- A deprecated `std.Build.Step.Run` method whose body only calls its
  replacement becomes that call: `run.addArtifactArg(exe)` becomes
  `run.addArtifactArg2(exe, .{})`, `run.addPrefixedDirectoryArg(p, dir)`
  `run.addDirectoryArg2(dir, .{ .prefix = p })`. Arguments that would run in
  another order are left for a person unless all but one are names or
  literals.
- `@import("builtin")`'s `os`, `cpu`, `abi` and `object_format` become
  `target.os`, `target.cpu`, `target.abi` and `target.ofmt`, and `mode`
  becomes `optimize`. The compiler writes that module, so these are checked
  against the compiler that built preflight.

Names resolve through the file's own aliases (`const mem = std.mem;`) and
through the types of values: a parameter or variable declared with a std type,
`std.ArrayList(u8)` included, or initialized by a std method,
`const run = b.addRunArtifact(exe);`. A method std aliases on such a value
moves with it: `list.getLastOrNull()` becomes `list.last()`. A deprecated
`pub const Debug: @This() = .debug;` is followed to `.debug`. An
alias the rewrites leave unused is removed. A rewrite that would delete a
comment is left for a person, as is any deprecated reference the table cannot
move; both are listed as `by hand`. Files that do not parse are skipped and
named. Build output, `zig-pkg` and hidden directories are not read; name files
or directories after `--` to read only those.

## API

`build.zig` exports what a package's own `build.zig` calls:

| Declaration | What it does |
|---|---|
| `addCi(b, Config)` | Adds `lint`, `ci`, `ci-check`, `check-imports`, `docs`, `cache` and `deprecations` |
| `Config`, `TestTimeout`, `Bench` | The gate's paths, shard records, watchdog, test log level and benchmarks |
| `addConsumerCheck(b, ConsumerOptions)` | Adds `check-consumer` |
| `addCheck(b, name, source)` | Builds, tests and runs a repository check program as step `name` |

A test runner of a package's own can import `preflight_order` and
`preflight_timings`. `preflight_order.init(io, init, args, tests, durations)` seeds,
selects the shard's tests and orders them, returning `InitError` for a seed that is no
`u32`, a shard that is not `i/n` or durations of the wrong shape. Its `weigh` and
`assign` are the shard split by themselves. `preflight_timings.Recorder.init(io,
environ, stem, key)` opens the timing record, `record(io, name, nanoseconds, status)`
appends one test and `deinit(io)` closes it; the recorder keeps no `Io`.

## Scope

- It is a build dependency only: no module a consumer compiles imports it.
- It does not format code: `zig fmt` does, and the gate checks the result.
- It starts no containers and schedules no runs.
- It rewrites code only when asked, with `zig build deprecations -- --write`.
- It does not pick the files a gate checks: `ci/preflight.json` names them.

## Built with

**tycho**, every coding agent in one folder (in development), and the Zig packages it
is built from.

## Testing

Run `zig build test` for the check regression suite, and `cd sample && zig build ci` to exercise the helper on a tiny package.
preflight gates itself: `ci/layers.zig` and `ci/preflight.json` hold its own
structure, and `zig build verify` runs its lint, tests and format check.
ziglint is pinned to its v0.5.3 ported to Zig 0.17 (pedronaugusto/ziglint, branch
`zig-0.17`, commit 924b6b5), with all rules except Z024 as in tycho;
`zig fmt` owns line formatting. The linter is a pinned Zig build dependency.

## Licence

MIT. See [LICENSE](LICENSE).
