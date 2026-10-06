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
tests. `zig build check-imports -- --audit` exposes gantry's graph for inspection.
`-Dci-lint=false` lets the hosted optimization and shard jobs use the source job's
result; the default local gate always checks sources.
Compiled caches never skip test execution: each gate runs the test binaries even
when their build products are already available.

## Repository facts

`ci/layers.zig` declares gantry's layers, required paths, entries, named modules,
reference rules and optional owned tokens. Layers order production sources only.
The shared runner checks layers, cycles and entries over the production graph,
the edges a non-test build compiles, and refuses a production file with zero or
multiple layers. Test code is in no layer, so a test file may import anything;
no production edge may reach test code, and an import in an inline test may not
reach a higher layer than its file. Required paths, reference rules and owned
tokens hold for every file. Gantry remains the language-neutral graph library;
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
inside test blocks. An import in a declaration nothing reaches, from a public,
exported or comptime member, a field, `main` or a test, is unused and fails.

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

`ci/workflow.json` names cross targets and optional CPUs, the compile step, test
timeout, sanitizer step and Windows cases with duration weights. The full tier
adds ReleaseSafe on each host, ReleaseFast on Linux, ReleaseSmall, every cross
target and TSan where supported. Static full-tier matrices are generated locally from `ci/workflow.json` with
`zig build plan -- --full true --output <file>` and passed as `full-matrix`,
`compile-matrix` and `run-matrix` inputs; `compile-once` enables the latter two.
Regenerate these inputs when changing the configuration. Only callers whose
Windows shards use measured weights set `measured-plan: true`, retaining the
full-tier planning job. Fast runs execute only on Linux. `ci-check` compiles the test graph without
executing it, including packages whose full-tier cross step only builds a library.
Callers generate `fast-matrix` with `zig build plan -- --full false --output <file>`.
`fast_linux_shards` and `fast_linux_jobs` balance measured families across Ubuntu
jobs; exactly one shard owns source checks and the other-target compile bundle.
Shards may record timings for the next measured balance.

A shared `skip` job filters changes before FAST. Changes touching only Markdown
outside `src`, LICENSE or images run the documented-snippet check alone. Mixed
changes, source Markdown and unavailable diff bases retain the test gate. FULL
merge candidates always keep the complete gate, including docs-only candidates.

Named Windows cases are assigned once per mode
using longest-processing-time-first balancing. Repository-specific jobs stay in
the caller and use the same full-tier condition.
An optional shard `priority` runs a core family before its bundled comparisons
while preserving the measured load balance.
Cross targets run in one Linux job, retaining each target and optional CPU while
sharing setup and compiled products. The checker uses its host's baseline CPU
target so its cached executable is reusable across hosted runner CPU models.

Fetched packages, compiled builds and pinned external tools have separate caches.
Dependency fetches and tool setup retry three times with backoff. `zig build ci-setup`
may install a repository's external tools into the cached runner temp directory.

The design uses GitHub's standard [reusable workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows):
repository facts stay with the caller and common mechanics have one owner.

## Development

Requires Zig 0.16.0. Run `zig build test` for the check regression
suite, and `cd sample && zig build ci` to exercise the helper on a tiny package.
ziglint is pinned to v0.5.3's commit, with all rules except Z024 as in tycho;
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
Upload permissions are restored by Zig before execution. The native matrix stays
available for comparing elapsed time and runner minutes against this path.

The full tier records each test's duration through Zig's test protocol, caches
the summary and balances the next full Windows shards using the measured totals.
The shared runner shuffles test order using the test seed on full, fast and local
CI gates. It prints the seed, including on failure; set `PREFLIGHT_TEST_SEED` to
reproduce an order. Direct test binaries also accept `--seed=<number>`.
Custom runners retain their watchdogs and can import `preflight_order` to use
the same seeded permutation, and `preflight_timings` to record durations.
`zig build ci-linux -- --musl --optimize ReleaseSafe` runs the package's Dockerfile
when explicitly requested; `--cgroup true` requests its privileged cgroup gate.
