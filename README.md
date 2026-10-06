# preflight

preflight gives a Zig package one local gate and one hosted gate. The build helper
runs format, gantry structure rules, ziglint, namespace layout, cast reasons,
function length, documented snippets and test imports, then the package's tests.
It is a build dependency; a consumer's module never imports it.

## Usage

Add preflight as a build dependency in `build.zig.zon`, pinned by commit. In
`build.zig`, after creating the test step:

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

`preflight.addConsumerCheck(b, .{ .package = "name", .program = b.path("ci/consumer.zig") })`
adds `check-consumer`: it builds a generated project that depends on the package
by path with fetching off and a Zig cache of its own, so the build a consumer gets
cannot reach the package's CI dependencies or anything cached for them. `.modules` names the modules the program imports,
`.packages` the dependencies the package itself needs, and `.use_llvm` names a
public function of the package's `build.zig`, `fn (std.Build.ResolvedTarget,
std.builtin.OptimizeMode) ?bool`, which the consumer's build calls for the target
and mode it builds, as a user's build would. The consumer builds for the host in Debug. `preflight.addCheck(b, name, source)` builds a
repository check program, runs its tests, then runs it from the repository root
as step `name`.

## Repository facts

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
or comptime member, a field, `main` or a test, is unused and fails. Gantry remains the language-neutral graph library;
these runners belong here.

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
Tests must be reachable from a configured root through imports or aliases named
inside test blocks.

Generated Markdown blocks retain their visible generator labels. Their source,
region, module import and whether that import is shown are facts in the JSON
configuration. Other generated blocks may use an explicit `zig build` argument-array command.
Missing markers, stale blocks and failed generators fail the gate.

## Hosted gate

Call `.github/workflows/zig.yml` pinned by the same commit as the package. Pass
that commit as `preflight-ref`, and `full: true` for a merge candidate. The sample
caller in this repository shows the trigger and concurrency policy:

- Work-branch pushes start no run. Dispatch requests source checks and the full Linux Debug suite in one Ubuntu
  job, then compiles the test binaries for macOS, Windows and every configured
  cross target; its `full`
  input requests the entire gate.
- PR merge candidates and merge queue candidates run the full tier. A main push
  verifies a successful full run for its exact SHA and its full-tier proof artifact.
  It reports green without repeating tests; absent evidence fails visibly.
- The caller owns one concurrency group per branch, with cancellation enabled
  for work branches and disabled for main's status job. No scheduled runs are enabled.

`ci/workflow.json` names cross targets and optional CPUs, the compile step,
sanitizer step and shard counts. A `test_timeout` there is refused: the watchdog
bounds each test. The full tier
adds ReleaseSafe on each host, ReleaseFast on Linux, ReleaseSmall, every cross
target and TSan where supported. Static full-tier matrices are generated locally from `ci/workflow.json` with
`zig build plan -- --full true --output <file>` and passed as `full-matrix`,
`compile-matrix` and `run-matrix` inputs; `compile-once` enables the latter two.
Regenerate these inputs when changing the configuration. Fast runs execute only on Linux. `ci-check` compiles the test graph without
executing it, including packages whose full-tier cross step only builds a library.
Callers generate `fast-matrix` with `zig build plan -- --full false --output <file>`.
`fast_shards` splits Linux Debug across that many Ubuntu jobs; the first owns
source checks and the other-target compile bundle.

A shared `skip` job filters changes before FAST. Changes touching only Markdown
outside `src`, LICENSE or images run the documented-snippet check alone. Mixed
changes, source Markdown and unavailable diff bases retain the test gate. FULL
merge candidates always keep the complete gate, including docs-only candidates.

`"shards": {"windows": 5, "macos": 2}` runs each mode on that host as so many
jobs. Every job compiles the whole suite once, or downloads it with
`compile_once`, and the test runner picks its share of the test cases: longest
first onto the least-loaded shard, by the seconds recorded for that target in
`ci/durations.json`. A test with no record weighs the mean of those with one;
without records the split is by count. Every shard computes the same split, so
each test runs exactly once. Repository-specific jobs stay in the caller and use
the same full-tier condition.
Cross targets run in one Linux job, retaining each target and optional CPU while
sharing setup and compiled products. The checker uses its host's baseline CPU
target so its cached executable is reusable across hosted runner CPU models.

Fetched packages, compiled builds and pinned external tools have separate caches.
Dependency fetches and tool setup retry three times with backoff. `zig build ci-setup`
may install a repository's external tools into the cached runner temp directory.

The design uses GitHub's standard [reusable workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows):
repository facts stay with the caller and common mechanics have one owner.

## Development

Requires Zig 0.17.0. Run `zig build test` for the check regression
suite, and `cd sample && zig build ci` to exercise the helper on a tiny package.
preflight gates itself: `ci/layers.zig` and `ci/preflight.json` hold its own
structure, and `zig build verify` runs its lint, tests and format check.
ziglint is pinned to its v0.5.3 ported to Zig 0.17 (pedronaugusto/ziglint, branch
`zig-0.17`), with all rules except Z024 as in tycho;
`zig fmt` owns line formatting. The linter is a pinned Zig build dependency.

MIT licensed.

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

Packages with relocatable test binaries can set `.portable_tests = true` in the
build helper and `compile_once: true` in `ci/workflow.json`. Linux then builds
macOS and Windows tests; those runners download and execute the binaries through
Zig's test protocol, retaining per-test timeouts and custom watchdogs. Helpers or
fixtures compiled with absolute runner paths must be made relocatable first.
An artifact upload drops the permission to run; preflight restores it before execution. The native matrix stays
available for comparing elapsed time and runner minutes against this path.

The full tier records each test's duration through Zig's test protocol. Its
profile job folds the records into `ci/durations.json`, keeping targets the run
did not measure, and uploads it as the `preflight-full-<sha>` proof artifact.
`gh run download <run> -n preflight-full-<sha> -D ci` refreshes the package's
copy. From a package root, `zig build --build-file <preflight>/build.zig
-Drepo-root=. profile -- --input <dir>` folds local or downloaded records into
`ci/durations.json` in place.
The shared runner shuffles test order using the test seed on full, fast and local
CI gates. It prints the seed, including on failure; set `PREFLIGHT_TEST_SEED` to
reproduce an order. Direct test binaries also accept `--seed=<number>`.
Custom runners can import `preflight_order`, whose `init` seeds, selects the
shard's tests and orders them, and `preflight_timings` to record durations;
`preflight_runner_options` carries the recorded durations and the record's name.
Test runs carry no environment from the build: Zig keeps a run's environment in
its cached configuration, so the runner reads the shard and seed when it runs.
Test artifacts that share a root module share its runner options and timing record.
