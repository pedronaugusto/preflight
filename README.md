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

## Repository facts

`ci/layers.zig` declares gantry's layers, required paths, entries, named modules,
reference rules and optional owned tokens. The shared runner checks the graph,
reports scan failures and refuses a file with zero or multiple layer owners.
Gantry remains the language-neutral graph library; these runners belong here.

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
inside test blocks. Production declarations cannot import test files.

Generated Markdown blocks retain their visible generator labels. Their source,
region, module import and whether that import is shown are facts in the JSON
configuration. Other generated blocks may use an explicit argument-array command.
Missing markers, stale blocks and failed generators fail the gate.

## Hosted gate

Call `.github/workflows/zig.yml` pinned by the same commit as the package. Pass
that commit as `preflight-ref`, and `full: true` for a merge candidate. The sample
caller in this repository shows the trigger and concurrency policy:

- Work-branch pushes start no run. Dispatch requests Debug on Linux, macOS and
  Windows plus source checks; its `full` input requests the entire gate.
- PR merge candidates and merge queue candidates run the full tier. Main runs
  only on schedule, so merging a candidate never repeats its gate.
- The caller owns one concurrency group per branch, with cancellation enabled.

`ci/workflow.json` names cross targets and optional CPUs, the compile step, test
timeout, sanitizer step and Windows cases with duration weights. The full tier
adds ReleaseSafe on each host, ReleaseFast on Linux, ReleaseSmall, every cross
target and TSan where supported. Named Windows cases are assigned once per mode
using longest-processing-time-first balancing. Repository-specific jobs stay in
the caller and use the same full-tier condition.

Fetched packages, compiled builds and pinned external tools have separate caches.
Dependency fetches and tool setup retry three times with backoff. `ci/setup.sh`
may install a repository's external tools into the cached runner temp directory.

The design uses GitHub's standard [reusable workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows):
repository facts stay with the caller and common mechanics have one owner.

## Development

Requires Zig 0.16.0 and Python 3. Run `zig build test` for the check regression
suite, and `cd sample && zig build ci` to exercise the helper on a tiny package.
ziglint is pinned to v0.5.3's commit, with all rules except Z024 as in tycho;
`zig fmt` owns line formatting. `PREFLIGHT_ZIGLINT` selects an already built copy.

MIT licensed.
