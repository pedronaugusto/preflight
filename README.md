# preflight

preflight gives a Zig package one local gate and one hosted gate. The build helper
runs format, gantry structure rules, [glint](https://github.com/pedronaugusto/glint)'s
code rules, namespace layout, documented snippets and test imports, then the package's tests.
It is a build dependency; a consumer's module never imports it.

**WIP:** hardened checks are opt-in and the configured-build adapter supports Zig 0.17.0 and Zig 0.18.0-dev master builds. Neither test campaigns nor sanitizer runs prove raw-pointer lifetimes.

## Install

Requires Zig 0.17.0. Add preflight as a build dependency pinned by commit:
`zig fetch --save git+https://github.com/pedronaugusto/preflight#<commit>`.

See [the design](docs/design.md) for ownership and invariants.

## Usage

Adopting preflight takes three steps and no configuration file:

1. Pin it lazily, so a project that depends on yours never fetches it:
   `zig fetch --save=preflight git+https://github.com/pedronaugusto/preflight#<commit>`,
   then add `.lazy = true` to the entry in `build.zig.zon`.
2. In `build.zig`, after creating the test step:

   ```zig
   if (b.lazyImport(@This(), "preflight")) |preflight| preflight.addCi(b, .{ .tests = test_step });
   ```

3. Generate the hosted workflow: `mkdir -p .github/workflows && zig build plan -- --workflow .github/workflows/ci.yml`.

Pull requests then run the merge tier (source checks and the Debug suite on Linux, macOS
and Windows), a dispatch runs the tier it names, and a nightly run takes the full matrix.
Every option has a default: `ci/preflight.json` chooses what the source checks read and
hold, `ci/workflow.json` what the hosted gate runs, and `ci/layers.zig` a source layering
to enforce; a project needs none of them to start. [sample/zero](sample/zero) is such a
project, and preflight's own gate runs it on every host.

`addCi` adds the steps its gate runs by name (`lint`, `ci`, `ci-check`, `ci-check-bench`,
`ci-link`, `ci-build`, `ci-run`, `plan`, `facts`, `cache`, `docs`, `deprecations`,
`check-imports`, and with their options `bench`, `bench-build`, `bench-ab`, `fuzz`,
`hardened`, `hardened-fuzz`, `hardened-tsan`, `check-consumer`). A package that already has a
step by one of those names keeps it, and its tests fail with a message naming the step to
rename, since the gate would otherwise run the package's step in place of its own.

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
arguments are for running it from `zig-out/bench` by hand, and each run has a
fresh, empty working directory for the fixtures it writes;
`zig build test` runs each once with `--smoke`, built in the test's mode, where a
program runs every point once at its smallest size. A repository with a `bench/`
directory and no `.bench` fails its tests by name.

`preflight.addConsumerCheck(b, .{ .package = "name", .program = b.path("ci/consumer.zig") })`
adds `check-consumer`: it builds a generated project that depends on the package
by path with fetching off and a Zig cache of its own, so the build a consumer gets
cannot reach the package's CI dependencies or anything cached for them. `.modules` names the modules the program imports,
and `.packages` the dependencies the package itself needs. `.options` gives the package
the options a consumer would (`.{ .name = "http", .value = .{ .flag = false } }` builds it
without its optional HTTP), so that a feature a package makes optional is built both ways.
The consumer builds
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
test edge. Every path pattern uses gantry's dialect, git's globs as sweep reads them: `*`,
`?` and brackets stay within one path component, `**` standing as a whole component
spans components (`src/**` is what lies under `src`), `\` escapes, and a pattern without
`/` matches the file name. A layer pattern with no wildcard, bracket or escape names one
file. The structure check compiles each pattern once.

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

### Code rules

The code rules are glint's, and `zig build lint` runs them as a library: preflight
reads the files, classifies them, resolves each import the way the configured build
does and hands glint its policy in one project. Nothing is parsed twice and
no child process stands between a finding and the gate.

**Files.** `glint_paths` names the files and directories to check; a path that is
not there fails. Without it the selection is `sources` and, where they exist,
`examples`, `ci`, `conformance`, `bench` and `build.zig`. It is separate from
`sources`, which stays the shipped roots `.paths` must list, so benchmarks,
examples and CI code are linted and gated without shipping.

**Imports.** `std` is the standard library of the Zig that builds the package. A
relative file is itself. A named module is what the configured build binds the
name to in each module that compiles the file; two modules that bind one name
differently leave it unresolved, and so does a name the build does not bind.
That is how glint recognizes aegis in a package: by the module the build gives
it, at any revision that keeps its public names.

**Policy.** preflight's default, which a repository amends:

| Rule | Weight |
|---|---|
| Z003 syntax, Z013 dead import, P001 cast reasons, P002 safety-off reasons, P003 function length, P004 `catch unreachable` | gate |
| Z011 deprecated call, P005 debug print | finding: any finding fails, and a call glint cannot resolve is counted, not a verdict |
| Z026 discarded error, Z012, Z016, Z001, Z005, Z006, Z009, Z014, Z031, Z032 | report, until a package is clean under them and gates them itself |
| Z024 line length, P006 disallowed declarations, D001 dead declarations | off (P006 gates once `disallowed` names something) |

`gate` is glint's: a finding fails the run, and so does any site the rule could
not decide. A *finding* rule fails on what glint finds and does not fail on the
calls it could not resolve: a call through a receiver of unknown type is not a
verdict either way. Casts are the four pointer casts in production code
(`@constCast`, `@ptrCast`, `@alignCast`, `@intFromPtr`), each with a nonempty
`// safe: <reason>` on its line; test support (`test_support`) is code the package
writes, so its casts need the reason as well. A `vendored` file is exempt from the
cast and length rules and names its upstream and how the fork is verified.

**A repository amends the policy** in the `glint` object of `ci/preflight.json`:

```json
"glint": {
  "rules": [{"id": "A004", "level": "gate"}, {"id": "Z006", "level": "gate"}],
  "casts": "pointer", "cast_scope": "production",
  "strict_suppressions": true, "fact_budget": 4000000, "max_line_length": 100,
  "disallowed": [{"source": "src/io.zig", "declaration": "write", "reason": "...", "replacement": "..."}]
}
```

`rules` sets a rule to `off`, `report` or `gate` (the aegis rules A001 to A005 are off
until a repository names them); an unknown or removed id fails. There is no profile:
the default policy is preflight's, and a deviation is a visible line. `function_limit`
(120), `function_limits` (a lower ceiling by path) and `function_exceptions` (an exact
`path:function`, a ceiling and a reason; growth fails, and one that names no function
fails) stay at the top level.

**An analysis that did not finish is not a pass.** The run fails when a selected file
does not parse or lower, when glint ran out of its fact budget, when a gating rule
could not decide a site, when a file cannot be read, and, with `strict_suppressions`
(the default), when a suppression suppresses nothing. A finding that policy allows
never hides one of these.

**Suppression** is glint's: one real comment, one site, a reason,
`// glint-ignore: Z026 -- cleanup after a failure the caller already gets`. There are
no ledgers: `ziglint_exceptions`, `unreachable_exceptions`, `debug_print_exceptions`,
`ziglint_paths` and `glint_config` are retired, and a repository that still names one
fails by name, so that no gate is believed that is not there.

Assertion counts per function and package appear in the run summary as a report,
without affecting the gate.

Layout exceptions likewise name their exact member set and a reason.
`zig build docs -- usage` renders a configured region for updating its block.
`zig build cache` preserves fetched packages and tools when pruning build products.

### Measuring and comparison

`Config.bench` injects `shakedown` and `preflight_bench_options` (`commit`, physical build-host `cpu`, `os`). Its imports callback is optional. Benchmark programs call published `shakedown.bench.run` with named `Row(Context, WorkloadError)` callbacks and an explicit workload error set, workload units and observable results. Shakedown owns warmup, clock resolution, batching, samples, statistics, JSONL and comparison noise; preflight owns builds and child processes. [The sample](sample/bench/sum.zig) is a complete consumer.

`zig build bench-build` compiles ReleaseFast programs and the published `shakedown-bench-compare` tool, executing nothing. `zig build bench` manually measures them. Local `zig build test` invokes each program once with `--smoke`; each row does its one smoke invocation. Hosted orchestration passes `-Dci-bench-smoke=false` and compiles benches without timing gates. Smoke rows cannot be compared as measurements.

From a clean Git checkout, select a commit and workload:

```sh
zig build bench-ab -- --base <commit> --program workflow --row 'caller generation' --pairs 5 --output .zig-cache/measurements
```

The driver resolves an immutable base, clones it beneath the caller's `.zig-cache`, builds each revision's `bench-build`, then alternates base/candidate order between pairs, with fresh working directories. It delegates every pair to shakedown's comparator, preserving raw JSONL with `--output`. Both revisions must implement `bench-build` and the selected program's `--row` contract; earlier revisions fail explicitly rather than being patched. Candidate tracked edits and untracked source files are refused; use an ignored output directory for repeated runs. Provenance must match both Git commits. Source archives report `source-archive` rather than inventing a commit. CPU provenance names the physical build host, separate from a selected target's CPU; native executions are required for comparisons. Unknown, missing or duplicate options, nonzero/signal exits, timeouts, capture limits, malformed/truncated JSONL, smoke output and output failures fail infrastructure. Changes beyond observed noise are reports, never speed pass/fail thresholds.

### Fuzzing

Fuzzing is continuous and off the landing path: no landing fuzzes. `zig build fuzz`
runs shakedown's `shakedown-fuzz` over the package's `check` properties, as many sessions
of `zig build test --fuzz=<limit>` as it is given, with the fuzzer's corpora in a store
outside the repository and every failure shrunk to the tape to add to the property's
`.regressions`: `zig build fuzz -- --limit 50M --sessions 4 --store ~/fuzz`. It fuzzes
`Config.fuzz_step`, which a package sets to opt in: a step whose every test binary has a
property (the fuzzer refuses a binary with none). The fuzzer and the properties are the
package's own shakedown, which it declares; a package that sets no `fuzz_step` has no `fuzz`
step and fetches nothing for one. The fuzzing,
the corpora and the shrinking are shakedown's; preflight wires the step.

What is not fuzzed is visible. `zig build lint` reports, without failing, the parsers of
untrusted input the package exports with no fuzz target: public functions named as
parsers (`parse…`, `decode…`, `deserialize…`, `unpack…`, `unmarshal…`, `fromBytes…`)
that take bytes or a reader, and any named under `fuzz.parsers` in `ci/preflight.json`. A
parser is fuzzed when a test that runs a `check` property or `std.testing.fuzz` reaches it
by name, a few calls deep. `fuzz.trusted` names a parser whose input is the package's own,
with the reason: `"fuzz": { "trusted": { "parseCache": "the package's own cache file" } }`.

### Hardened profile

Opt in with `Config.hardened = .{ .fuzz_step = "profile-tests", .tsan_step = "profile-tests", .fuzz_iterations = 1000 }`, and `"hardened": true` in `ci/workflow.json`, then regenerate the caller. Dedicated steps must execute tests. Defaults select `test`, so a package without fuzz tests receives Zig's `no fuzz tests found` failure rather than a compile-only green campaign.

`zig build hardened` runs the ordinary suite with `-Dci-hardened=true`; its test modules use Debug or ReleaseSafe with the LLVM backend selected explicitly for native sanitizer and fuzz instrumentation. Normal build modes remain caller-selected. A measured source loop can explicitly disable safety at its boundary, with its reason and matched measurements; this batch adds no such exceptions. Source-site rules belong to glint, architectural rules to gantry. No startup-allocation policy is forced on a consumer.

`zig build hardened-fuzz` executes the installed Zig 0.17 bounded native fuzzer, with caller options forwarded. The current compiler supports native 64-bit non-Windows hosts; foreign targets and unsupported backends must fail execution. Seed corpora belong in `std.testing.fuzz` options. Zig reports campaign counts and instrumented coverage, retains corpus/coverage beneath `.zig-cache/v`, and reports failing inputs and reproduction details. Hosted jobs retain the actual configured local-cache v directory, including on failure, for seven days. Preserve those files and the printed test seed when reproducing; accumulated coverage is not a coverage guarantee.

`zig build hardened-tsan` compiles with LLVM ThreadSanitizer and executes the selected tests on native x86_64 Linux. Every selected module's target is checked. Other hosts fail with an explicit eligibility message. The sample executes real concurrent tests; preflight's Linux regression first runs a synchronized consumer, then requires a real intentional-race diagnostic. Sanitizer startup failures remain failures. The existing test runner continues to own `std.testing.allocator`, using std's SafeAllocator with `check_write_after_free = true`; a real consumer test frees storage and writes through it to prove detection. There is no substitute allocator, verifier or future language feature.

### Configured build facts

`zig build facts -D<name>=<value>` reports the actual configured build as JSON, naming the Zig that produced it: compiler module identities and scoped import tables, artifact steps and dependencies, configured options, package owners/hashes, discovered lazy dependencies, test-root descriptors, source/generated path identities, target flags and native framework requests. Additional configuration flags can follow `--`. Lint takes its test roots from those facts; `ci/preflight.json` still selects sources and policies. Embedded WriteFile test sources are read from the compiler configuration, without executing or guessing generator paths. Dynamic producer content is unavailable at configure time and is reported as generated; if lint requires that content it fails `GeneratedTestRootUnavailable` rather than substituting handwritten roots.

This adapter reads the installed `lib/compiler/Maker.zig`, `configurer.zig`, `std/zig/{Server,Client}.zig` and `std/Build/Configuration.zig` contracts: `zig build --listen=-` sends build-system handshake version 1 and a serialized configuration-file path. Compiler `zig_version` messages are a different protocol. The file is read while the child lives, because poisoned configurations are deleted on clean exit; the adapter then sends the supported exit message. It requests no artifact execution. Zig configuration is a native serialized internal format, **not a stable external API**, and does not provide the compiler's analyzed source-level dependency graph. Gantry still owns source boundaries and their declarations. `ci-check` already projects the configured `std.Build` graph directly; that compiler-owned graph remains its source, and `ci-link` retains native SDK linking.

Compiling and invoked Zig must be the same build, and one `src/zig_version.zig` names the builds the adapter is verified on: the 0.17.0 release and master builds leading to 0.18.0 (`0.18.0-dev.<n>`), whose configuration format and protocol are the same today; any other Zig is refused with a message naming them. The protocol version must be 1. Unknown/version-mismatched messages, configuration failures, malformed lengths/indices/tags/reserved fields, truncation, child signals/nonzero exits, cancellation, capture/write failures and budget exhaustion are explicit failures. Limits are 64 frames, 8 MiB per frame, 32 KiB paths/strings, 64 MiB each for protocol accumulation, each capture stream and the configuration file, one million validation words/references and 64 nested decoding levels. No failure falls back to the previous guessed root list. Unsupported non-CLI build inputs are refused because their configuration cannot be faithfully replayed.

### Test runs

Packages with relocatable test binaries can set `.portable_tests = true` in the
build helper and `compile_once: true` in `ci/workflow.json`. Each destination runner links its tests with the native SDK; shards download
and execute those binaries through
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
runs. A direct run prints the seed; under `zig build` a passing run prints
nothing, each failure line names the seed, and a crash shows it as the failed
command's `--seed`. Set `PREFLIGHT_TEST_SEED` to reproduce an order. Direct
test binaries also accept `--seed=<number>`.
Custom runners can import `preflight_order`, whose `init` seeds, selects the
shard's tests and orders them, and `preflight_timings` to record durations;
`preflight_runner_options` carries the recorded durations and the record's name.
Test runs carry no environment from the build: Zig keeps a run's environment in
its cached configuration, so the runner reads the shard and seed when it runs.
Test artifacts that share a root module share its runner options and timing record.

### Hosted gate

The gate has four tiers. Each one runs more than the one before it:

- **local**: the tests a change touches, run by hand while working. Not CI.
- **fast**: three kinds of Ubuntu job that run side by side: the source checks, the
  Linux Debug suite in as many shards as `fast_shards` asks for, and an object
  compile of every configured cross target (macOS and Windows among them) in as
  many jobs as `cross_jobs` asks for. Test, helper and public-module objects are
  compiled for each target, and the benchmarks in Debug. This proves compilation,
  not linking.
- **merge**: the gate a change passes to reach main, four jobs: the source checks and
  the Debug suite on Linux, macOS and Windows (sharded as configured). It is the
  required status check of a pull request, and with `land` it moves main.
- **release**: the full matrix, nightly and before a cut: every mode on every host
  (Debug and ReleaseSafe everywhere, ReleaseFast on Linux), ReleaseSmall, every
  cross target with the ReleaseFast benchmarks, the SDK links, TSan and the
  hardened checks where configured, and the Debug suite on Linux with Zig master.

The release tier also runs the Debug suite on Linux with Zig master,
the next release in development. That job never blocks: the run's summary
reports its result, and a break is a note for the next port's rewrite table.
The setup action takes `zig-version` (0.17.0, or master), and its cache keys
carry it. The shared workflow runs external-tool setup separately, with up to
three attempts of five minutes each. A hung `apt-get update` therefore expires
at a step deadline and can be retried. Exhausted attempts fail blocking jobs.
Every Zig master step has a deadline, with their total below its job timeout,
so a hang remains an advisory failure and the blocking jobs decide the run's
conclusion. The master suite uses `test-job-timeout` as its step deadline, capped at twenty
minutes to preserve that budget.

Call `.github/workflows/zig.yml` pinned by the same commit as the package. Pass
that commit as `preflight-ref` and the tier as `tier`. The sample caller in this
repository shows the trigger and concurrency policy:

- Work-branch pushes start no run. Dispatch runs the tier it names, fast by default.
- Pull requests and merge queue candidates run the merge tier, which is the gate to
  require as a status check.
- A schedule runs the release tier nightly.
- The caller owns one concurrency group per branch, with cancellation enabled
  for work branches and disabled for main's status job.

The options of `ci/workflow.json`, all off or defaulted in a new project. Any other key is
refused, so a misspelt option fails the plan instead of quietly changing nothing.

- `land` (default `false`): the caller gains a `land` job and a `land` dispatch input. A
  merge-tier dispatch whose gate is green fast-forwards main to the commit it tested, with the
  run's own token and never forced; a main that moved since fails the job and says so. That job
  alone may write, and only to move main; without `land` nothing in the caller asks for more than
  read. The token's push starts no run, so a landing is tested once. Dispatch with
  `-f land=false` to test without landing.
- `attest` (default `false`): a push to main runs a cheap job that looks for the proof artifact a
  merge or release run left for its exact SHA, and fails without one. For repositories that push
  to main by hand.
- `nightly` (default: the release tier at `23 3 * * *` UTC): `false` for no schedule, or
  `{ "cron": "5 1 * * 0", "tier": "merge" }` for another time or tier. The run also warms main's caches.
- `jobs`: the package's own jobs, each a build step the gate runs beside its own:

  ```json
  {"jobs": [
    {"name": "conformance", "step": "test", "directory": "conformance", "os": ["ubuntu-latest", "macos-latest"]},
    {"name": "report formats", "step": "check-reports", "setup": "reports-setup", "tiers": ["merge", "release"]},
    {"name": "corpus sizes", "step": "check-sizes", "tiers": ["fast", "merge", "release"], "setup": false, "timeout": 30}
  ]}
  ```

  `os` defaults to Ubuntu and `tiers` to merge and release; `args` holds whitespace-free `-D`
  flags (the package's `build_args` are its own builds', not a declared job's); `directory` is
  relative to the repository and defaults to the package; `setup` runs the package's
  `setup_step` (true, the default), nothing (false) or a step of the job's own; `timeout` is
  in minutes. A declared job has the gate's setup, caches and toolchain, and a landing waits for
  it. Work that is not a check, such as a measurement dispatched by hand, belongs in a workflow
  of its own.
- `targets`, `build_args`, `shards`, `fast_shards`, `cross_jobs`, `cross_seconds`,
  `compile_once`, `portable_hosts`, `hardened`: what the tiers build and run, described below.
- `compile_step` (default `check`): the step the release tier's ReleaseSmall job compiles.
- `setup_step`: a build step that installs the package's external tools, run before its tests
  with three attempts of five minutes; `before_tests_step`: a step run before the tests.
- `windows_git_latest`: upgrade Git for Windows first.
- `test_job_timeout`, `windows_job_timeout`, `source_job_timeout`, `cross_job_timeout`:
  minutes, 20 by default.

`ci/workflow.json` is the declarative input, and the caller is wholly generated from it:
both reusable-workflow references, the checkout pin, triggers, concurrency policy, the
seven tier matrices with the declared jobs, and the landing. Regenerate it with:

```sh
zig build plan -- --workflow .github/workflows/ci.yml
```

First refresh preflight in `build.zig.zon` to the intended published commit.
The generator reads that manifest's full immutable preflight URL pin; it never
uses an old workflow's pin. It refuses to replace a caller holding a job the
configuration does not declare, naming it, so nothing is dropped unseen. It replaces one relative `.yml` or `.yaml` file,
refuses traversal and symlinks, and renders/validates all inputs before opening
it. Its parent directories must already exist. Repeated generation is byte
identical. There is no package-local planner or Python dependency. This is an
offline regeneration write, not a crash-atomic or durable publication API.
`--working-directory <relative-directory>` supports a nested package, and
`--manifest <file>` selects its manifest. Preflight alone uses `--self` to call
its own reusable workflows at `github.sha`. Its self-caller gates the sample:

```sh
zig build plan -- --self --workflow .github/workflows/ci.yml --config sample/ci/workflow.json --working-directory sample
```

`zig build plan -- --tier <tier> --output <file>` still emits the matrix records
for inspecting a plan; it appends hosted-output records and is separate from
single-file workflow replacement. `--workflow` renders every tier and cannot
be combined with `--output`. Consumer repositories keep only declarative inputs
and their generated caller, never copied planner code or consumer plan dumps.

### The linked graph

A package has two graphs. Its *linked* graph is the code an artifact of it links: its own
modules and what they import. Its *tooling* edges are the packages only its CI and checks
use: preflight itself, a linter, test support it pins for its own tests. A tooling edge is
a lazy dependency only CI steps ask for, so a project depending on the package never fetches
it, the way Cargo and Go leave out a dependency's dev-dependencies. A tool is a separate
program: it reads the package and links none of it, so it may be built with any revision of
anything, including an older one of the package it checks. That is how a tool checks itself:
its CI runs the revision of itself it pins, and moving a library the tool uses never waits for
the tool to move.

`lint` reads the configured build and holds every artifact the package builds to two rules,
for any project:

- **One revision of each package.** Two revisions of a package in one artifact are two sets
  of types that do not unify, and two sets of any state it holds once per program. The message
  names the package, both revisions and who pulls each:

  ```
  core is linked in 2 revisions:
    core-0.1.0-rsxouifg... pulled by net, store
    core-0.1.0-rsxoutrd... pulled by testkit
  ```

- **No cycle between packages.** A package linked by another must not link it back: then a
  move of either ripples through both. The package under test is held to both rules as much as
  any other. It cannot pin its own commit, so a second revision of itself in its own artifact is
  always a cycle through a dependency's pin, and it is reported as one:

  ```
  the linked packages form a cycle: core -> testkit -> core
  ```

A test dependency that is built on the package's own types (test doubles taking the package's
ids, say) is the usual way in. It must take the package's own module, bound by the build script,
instead of its own pin of the package: the dependency offers an option to leave its pin unfetched
and a way to give it the module, and the package's test modules and benchmarks import that one
copy. An import into the package's own module is one copy and no pin, so it is neither a second
revision nor a cycle. Programs built in the package's graph from another package's sources
(a checker's own tools) are not the package's artifacts and are not counted.

What preflight adds to a package's artifacts follows the same rule. Its test runner, shard
order and watchdog link std alone; benchmarks and fuzzing measure through the package's own
`shakedown`, which the package declares, and are refused by name when it does not. Nothing
of preflight's own pins reaches a package's artifact.

`revision_exceptions` in `ci/preflight.json` maps a package to the reason two of its
revisions may meet, for a case the package cannot fix, such as a dependency it does not own
that pins another revision.

Every other manifest in the repository, a fixture's or a conformance build's, must pin each
package the root manifest also pins exactly as the root does: a fixture with its own pin goes
stale at the next re-pin and tests a revision nothing ships. Better, a fixture takes the
package from the root's dependency at build time, as `addConsumerCheck` does, and cannot drift.

### Hosted gate options

Targets are strings or objects with `target`, optional `cpu`, and optional
`args` (an array of `-D` feature flags). `build_args` supplies flags to every
host and target; target/CPU configuration belongs in its explicit fields.
For example:

```json
{"compile_once":true,"build_args":["-Dfeature=true"],"targets":[{"target":"x86_64-macos","cpu":"baseline","args":["-Dtrust-store=true"]},"aarch64-macos","x86_64-windows-gnu"]}
```

These flags must be individual whitespace-free `-D` arguments. Malformed
triples, arrays, CPUs, shard counts, booleans and portable-host declarations are
refused. `windows_git_latest` controls the shared Windows Git setup. A
workflow-level `test_timeout` is refused: `Config.test_timeout` bounds each test.
`fast_shards` splits the Linux Debug tests; the source checks and the cross
compile are jobs of their own. `cross_jobs` sets how many jobs share the cross
targets, and `cross_seconds` how many seconds of compiling each may hold. Static jobs explicitly distinguish `execute`, `objects`,
`link` and `replay` operations. `compile_once` enables the separate native link
and shard replay matrices; it never moves SDK linking to Linux.

`ci-check` emits objects for the configured test graph, installed artifacts,
the `check` graph and public modules, the benchmarks in Debug,
helpers, generated inputs and transitive native libraries. `ci-check-bench` emits
the benchmarks as they are built to run, in ReleaseFast: the release tier
compile them for every target, and the fast tier does not, since that optimizing
compile takes longer than all the other objects together. The compile
projection carries target, CPU, optimization and source/header options; SDK
link requests stay on the original native modules. Zig resolves framework and
system-library names even in object mode, so those link-only requests are not
passed to the compile projection. `ci-link` links the original artifacts without
running them; `ci`, `test` and portable `ci-build` retain their required libraries
and framework declarations. No compile-only success certifies a native link.
On macOS the shared setup discovers `SDKROOT` and passes its identity as an
explicit build option, so configuration caches cannot retain another SDK; `-Dci-sdk=<SDK path>` is an explicit
local build option for native links, including an explicit macOS target or CPU.
The SDK search paths also reach transitive native dependencies. Foreign object
jobs do not require an Apple SDK.

The first job of a fast run filters changes. A dispatched branch whose commits since
it left `origin/main` touch only Markdown outside `src`, LICENSE or images runs the
documented-snippet check alone. Mixed changes, source Markdown and an unavailable base
keep the test gate. A pull request, a merge queue entry and the release tier always
run the whole gate, documentation or not: what a landing passes does not depend on a
path filter.

`"shards": {"windows": 5, "macos": 2}` runs each mode on that host as so many
jobs. Every job compiles the whole suite once, or downloads it with
`compile_once`, and the test runner picks its share of the test cases: longest
first onto the least-loaded shard, by the seconds recorded for that target in
`ci/durations.json`. A test with no record weighs the mean of those with one;
without records the split is by count. Every shard computes the same split, so
each test runs exactly once. A package's own jobs are declared in `ci/workflow.json`
`jobs` and run in the tiers they name (see the options below).
Cross targets are dealt out to as many Linux jobs as hold `cross_seconds` (200) of
compiling each, longest target first onto the job with the least, each target keeping
its optional CPU and flags. A target costs what the last release run measured
of it (`ci/costs.json`, which the run's proof artifact carries beside
`ci/durations.json`), and 90 s, or the mean of the others, where none did. `cross_jobs`
fixes the count instead. The checks run on their host's baseline CPU target, so a
binary built once serves every runner model.

Every job takes the checks as a binary, and none compiles them. The first job of a
run, `toolchain`, builds `preflight` for Linux, macOS and Windows with `zig build
toolchain` (about a minute apiece, cross compiled in one job), or takes the build
that preflight's own run made of the pinned commit: that run keeps it ninety days as
the artifact `toolchain-<commit>`, and a caller reads it from there. The other
jobs download the run's copy and put it on the path; their `fetch`, `prepare` and
`run` are its subcommands, and its `run` hands the build it starts as `-Dci-checks`,
which `addCi` takes in place of compiling the checks (a build without the option
compiles them, as local runs do). The Zig master leg builds its own, since the checks
read the configuration of the Zig that compiled them.

Fetched packages, what Zig builds for itself and pinned external tools have separate
caches; what a job builds of the package is kept in none, since the next run changes
the sources and a gigabyte of objects per job evicted the rest of the repository's
caches. What Zig builds for itself is the build runner and each target's runtime,
which every `zig build` compiles first, for the CPU model it runs on (the hosted runners
have several, and a runner built on one is of no use on another, so the cache is keyed
by the model) and which a run on main renews weekly in the `warm` job, on a few runners
of each kind, together with the package's external tools: a branch sees the caches of main
and its own, so its first jobs restore the runner instead of compiling it, and the tools
instead of building them.
Each job fetches what its own build asks for: it configures the build with the
job's arguments (`zig build --list-steps`) and builds nothing, retrying three times
with backoff, as tool setup does. Zig compiles the build script of every package a
manifest names once it is in the package cache, lazy and unasked for or not, so a
dependency only one job needs, such as the emulator a conformance job feeds, is named
in a build of its own under `conformance/`, with its own manifest, and that job runs
there (`working-directory: conformance` for the setup and the build). Named in the
package's own manifest, even behind an option, it would reach every build of the
package, and of a program on it, whose cache holds it: the Zig master leg among them.
The format and source checks pass over the `zig-out` and `zig-pkg` such a build keeps
beside its manifest. `zig build ci-setup` may install a repository's external tools
into the cached runner temp directory.

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
| `addCi(b, Config)` | Adds `lint`, `ci`, object `ci-check`, native `ci-link`, `plan`, `facts`, `check-imports`, `docs`, `cache` and `deprecations`; optional bench and hardened steps |
| `Config`, `TestTimeout`, `Bench`, `Hardened` | The gate's paths, shard records, watchdog, test log level and benchmarks |
| `addConsumerCheck(b, ConsumerOptions)` | Adds `check-consumer` |
| `addCheck(b, name, source)` | Builds, tests and runs a repository check program as step `name` |

A test runner of a package's own can import `preflight_order` and
`preflight_timings`. `preflight_order.init(io, init, args, tests, durations)` seeds,
selects the shard's tests and orders them, returning `InitError` for a seed that is no
`u32`, a shard that is not `i/n` or durations of the wrong shape. Its `weigh` and
`assign` are the shard split by themselves. `Shard` holds a zero-based `index` below a
nonzero `count`; construct one with `Shard.init(index, count)` or parse hosted `i/n` text.
These modules link std alone, as everything preflight adds to a test binary does.
`assign` rejects invalid shards, overflowing load-storage counts or unequal name/weight lengths in every build
mode. `TestTimeout.duration()` returns a checked `std.Io.Duration`; a custom bound
above `u64` nanoseconds fails configuration. Public waits keep std's Io vocabulary. `preflight_timings.Recorder.init(io,
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
Cross object validation retains a compile step's `expect_errors` and diagnostic
limit. Zig matches the caller's expected diagnostics; wrong diagnostics and
unexpected success fail. Expected-failure steps request no emitted binary.
Ordinary positive artifacts still emit objects, and native SDK links retain the
original artifact graph.

glint and gantry are lazy build dependencies, built in ReleaseSafe for the checks and used
as libraries; the checks are a tool, and nothing of them reaches a package's artifacts.

## Rules a package declares

A package's own token and reference rules are ordinary gantry rules in its `ci/layers.zig`,
next to its layers; packages that only tests may import are `test_dependencies` in
`ci/preflight.json`, which no production file may import.

Gantry owns path syntax, compilation and matching. Preflight compiles configured
patterns through `gantry.rules.Globs`, returning malformed-pattern errors even for
empty sources or after an earlier pattern matches. It has no direct sweep dependency.
Generic Zig lint rules belong to glint: Z009 owns file-name case, Z011 gates
deprecations and Z013 dead private imports. Gantry's declaration liveness still
reports an import in a declaration nothing reaches. The `deprecations` command remains
a separately invoked codemod and does not run as a lint gate.

## Licence

MIT. See [LICENSE](LICENSE).
