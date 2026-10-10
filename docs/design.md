# Preflight design

Preflight owns repository gates, build and process orchestration, and the canonical hosted workflow planner. Gantry owns semantic architecture checks. Code-level rules belong to glint, which preflight runs for the repository: which files, with which imports and under which policy are preflight's; what a rule finds is glint's.

## Code rules

Preflight runs glint as a library in its own process, in one in-memory project, not as a child process. A child would need a result protocol to be told from a crash, and the repository's path dialect (which files are test code, which a vendored fork, which have a lower function ceiling) has no surface in a command line that treats every file alike. In-process, a file that cannot be read is an error, a panic is a failed step, and the verdict is read from the report itself, so no outcome has to be recovered from text or a receipt. The cost is that glint's runtime, and aegis under it, is built for every repository's checks.

Files are the repository's `glint_paths`, or the shipped `sources` and the directories a repository keeps code in beside them. Selection is separate from `sources` because `sources` is the set `.paths` ships and must list; a benchmark is gated without being shipped. Every import is resolved from the build's configuration, the same facts the structure and toolchain checks use: `std` from the compiler's library, a relative path as itself, a named module as the configuration binds it in each module that compiles the file. A name two modules bind to different files, or none binds, stays unresolved, never guessed. The cost is one read of every file the selection imports, standard library included, once per run.

The policy is the group review's. Z026 (a discarded error needs its reason) and the style rules are reported, and a package gates each as it becomes clean: glint's Z026 finds about three times the sites the fork's did and the review's order is reported, then gated. glint's `gate` couples two things: a finding fails, and a site the rule could not decide makes the run incomplete. That is right for a rule that can decide every site it names (a cast, a discarded error, a function's length) and for the aegis rules, which a repository adopts knowing what they cannot see. It is wrong for deprecated calls and debug prints: glint resolves a call through a receiver of unknown type to nothing, and a run that must resolve every call never completes. Those two are *findings* in the default policy: glint reports them, any finding fails, and the calls it could not resolve are counted and are not a verdict. A repository may still gate them in glint's sense by naming them.

A run is complete or it is not a pass. The run fails on a file that does not parse or lower, on an exhausted fact budget, on a site a gating rule could not decide, on a file that cannot be read, and on a suppression that suppresses nothing (the default; a repository may turn it off). A finding the policy allows never hides one of these. This closes the review's finding F04, which the ziglint fork could not close: it had no outcome for an analysis that stopped. There is no profile to select: the default policy is preflight's, a repository amends it rule by rule, and a setting preflight cannot honour fails by name rather than turn a gate off.

Exceptions are glint's inline `glint-ignore` with a reason, one site each. The exact-match ledgers (`ziglint_exceptions`, `unreachable_exceptions`, `debug_print_exceptions`) and their shrinking budget retire with the tool they were for. A retired key fails the repository that still names it.

## Configured builds and target projection

`addCi` consumes the caller's actual `std.Build` graph. Foreign target checks project configured artifacts to objects, including test, helper, benchmark and transitive native-source modules. Native `ci-link` and portable test-build steps retain the original artifacts and their SDK libraries/frameworks. Object compilation certifies compilation; only native linking and execution certify those operations. Benchmark modules include the selected ordinary graph, which `ci-check` compiles in Debug, and the separate ReleaseFast graph, which `ci-check-bench` compiles: a benchmark's optimizing compile outweighs every other object of its target, so the fast tier leaves it to the merge tier.

The checks are one binary per runner kind, built once per commit by `zig build toolchain` and passed to every job and to the build as `-Dci-checks`; a build without the option compiles them from source (`tool.zig`). One job per run owns the build, so the only compile of the checks in a run is the one a commit has not had yet.

The `facts` adapter asks the installed Zig 0.17.0 compiler/build runner to configure through `zig build --listen=-`. Build-system handshake version 1 and configuration notifications differ from compiler messages. The serialized configuration is read while the child lives, then the supported exit message ends the session without requesting artifact execution. Both compiling and invoked compiler versions are exact gates; this native internal format is not a stable external API.

Facts preserve configured module identities and scoped imports, step dependencies and artifact/test roots, package owners, options, lazy dependencies, generated/source path identities, target flags and native framework requests. They describe the configured artifact graph, not the compiler's analyzed source-level graph. Gantry declarations remain its owner. Lint reads these configured test roots and embedded WriteFile source content; unavailable dynamic producer content fails clearly when required. It never substitutes the old handwritten root reconstruction. CLI configuration options are replayed; unsupported non-CLI inputs fail rather than implying parity.

The adapter validates native serialized storage before calling std's loader. Frames are bounded to 64 messages and 8 MiB each; paths/strings to 32 KiB; protocol accumulation, each child capture stream and the configuration file each to 64 MiB. Validation limits traversal to one million words/references and depth 64, with deduplicated references. I/O inactivity is bounded to 120 seconds. Unknown messages, wrong versions, malformed indices/tags/flags, truncation, cancellation, child signal/nonzero exit and reader/writer failures are infrastructure failures. None falls back to guessed facts.

## Measurement ownership

`Config.bench` configures ReleaseFast programs, injects the published shakedown module and actual commit/physical host CPU/OS provenance, and installs shakedown's comparator. Callbacks describe work and observable results. Shakedown owns warmup, clock resolution, batching, samples, statistics, JSONL and noise comparison. Preflight owns artifact builds and child processes; it implements no timer or statistical algorithm.

`bench-build` only builds. `bench` explicitly measures. Local `test` runs each program once with `--smoke`, invoking each row once; ordinary hosted CI disables those executions and compiles benchmarks. `bench-ab` requires a clean candidate and a caller-selected immutable base/program/row, builds the detached base in owned temporary storage, and alternates base/candidate order with fresh working directories. Both revisions must implement the benchmark contract; earlier revisions fail rather than being patched. Provenance is checked against actual commits and Zig. Invalid inputs, signal/nonzero exit, malformed/truncated JSONL, smoke output, capture/output failures and child timeout fail infrastructure. Capture is bounded to 64 MiB per stream and execution to 600 seconds. Comparisons report changes and noise without timing pass/fail thresholds.

## Opt-in hardened profile

A caller enables `Config.hardened` and the canonical workflow's hardened option. Selected test artifacts retain Debug or use ReleaseSafe, with LLVM selected for native instrumentation. Normal builds retain caller-selected modes. Safety remains on; any source loop exception requires its own measured justification. This design does not force startup allocation policy onto callers or police source text with regexes.

`hardened` executes tests. `hardened-fuzz` executes Zig 0.17's bounded native fuzzer on eligible 64-bit non-Windows hosts. Dedicated test steps must execute tests, and absent fuzz tests fail the campaign. Callers supply seeds through std.testing.fuzz; Zig owns corpus, failing-input reproduction and instrumented coverage. Hosted jobs retain the actual configured local-cache fuzz directory for seven days, including on failure. Reported campaign coverage is not a comprehensive-coverage guarantee.

`hardened-tsan` executes LLVM ThreadSanitizer tests only on native x86_64 Linux; every selected module must be eligible. Unsupported hosts and sanitizer startup failures fail explicitly. The existing test runner retains std.testing.allocator ownership and std SafeAllocator's write-after-free checking. Regression consumers exercise an actual freed-storage write and, on Linux, a real intentional race alongside a synchronized control. No custom allocator, verifier, future language feature or additional package prerequisite is introduced.

## Canonical orchestration and costs

One Zig planner owns every workflow tier and matrix; callers regenerate through `zig build plan`. CI controls have one declaration owner, including early root lazy-discovery returns. A caller-provided `Config.timings_enabled` retains its existing option ownership: preflight uses that value without declaring a second `ci-timings` option. Declarative repository facts stay with the caller. Hardened opt-in adds three native jobs to the release tier; ordinary planning adds one option lookup. The hosted runner queries compiler-derived available options before injecting benchmark smoke control, preserving older custom steps that never declare it. That costs one configure-only request per execution. Serialized validation scales with configured storage and references, outside package runtime hot paths. Matched measurements belong in private trials beside their driver; correctness and required safety checks are retained regardless of their cost.

Runner protocol, timeout, test ordering, allocation ownership and portable shard records remain separate from benchmark measurement. The runtime build dependency closure remains unchanged; shakedown is lazy test/benchmark support. Configuration and driver fault tests use deterministic child/input/output failures, rather than timing thresholds.


Cross projections retain each compile step's expected-error union and diagnostic limit. Zig's build runner owns matching (`contains`, `exact`, `starts_with`, `stderr_contains`) and failure outcomes. Deliberate failures do not request emitted binaries, since Zig returns after matching rather than producing a file. Positive projections still emit objects; original native artifacts retain their diagnostic and SDK-link contracts. The integration fixture exercises expected failures, wrong diagnostics and unexpected success across Linux, both macOS architectures and both Windows architectures, with a positive object beside each rejection.

## The linked graph and tooling

A package has two graphs. The linked graph is what its artifacts link; tooling edges are what
only its CI uses (the checker, test support it pins), lazy, so a project depending on the
package never fetches them. A tool is a program that reads the package and links none of it,
so it may be built with any revision of anything, the package itself included: a tool checks
itself with the revision of itself it pins, and a library it uses moves without waiting for it.
The pins of the tooling graph may therefore form cycles; the linked graph may not.

`lint` holds every artifact the package's build configures to one revision of each package,
the package under test included, and to no cycle between packages. A package cannot pin its own
commit, so a cycle back to it always shows as a second revision of it; a dependency bound to
the package's own module (test support built on its types) is one copy and no pin, and is
neither. Programs built from another package's sources are that package's tools and not
counted. The check reads Zig's configuration of the build, by package hash and module import
table, not manifests, so a revision that an injected module or a dependency's pin brings is
seen where it is linked. A family of packages whose tools check each other stays a DAG to every
consumer this way, and its moves are a release train: re-pin in dependency order, each landing
on its own green run.

What preflight adds to an artifact obeys the same rule. The test runner, its shard order and its
watchdog link std alone; benchmarks and fuzzing measure through the package's own shakedown,
declared by the package. Nothing of preflight's pins reaches a package's artifact.

A nested manifest (a fixture's, a conformance build's) pins each package the root also pins
exactly as the root does; the check names the drift. A fixture generated at build time from the
root's dependency, as `addConsumerCheck` makes one, cannot drift at all.

## Generated caller

The caller is generated whole from `ci/workflow.json`: the gate call with every tier's matrices,
the package's declared jobs among them, the triggers, the concurrency groups and, with `land`,
the landing job. A package's own job is a build step with hosts, tiers, a directory and a setup
step, run by the gate's job with its setup and caches, so its refs, inputs and `needs` cannot go
stale and a landing waits for it like any job of the gate. The generator refuses to replace a
caller holding a job the configuration does not declare. Landing is one caller job that needs the
gate and alone holds write permission; without `land` the caller asks for none, since a reusable
workflow cannot be granted more than its caller holds whatever its jobs' conditions say.

## Shard and watchdog boundaries

`Shard.init` and `Shard.parse` establish a nonzero count and an index below it.
`assign` rechecks those contracts because Zig permits direct field construction,
checks that `count * sizeof(f64)` fits before load allocation, and rejects unequal
name/weight lengths before allocating or indexing. The modules link std alone: they
are compiled into every package's test binaries, where any package they imported could
be a second copy beside the package's own.

The build helper retains `std.Io.Duration` through `TestTimeout.duration`, validates
the generated options' `u64` nanosecond range and exports that schema once; the runner
reads it back as a `std.Io.Duration`. The disabled
watchdog remains zero; nonpositive custom durations retain their one-nanosecond
floor. Missing reasons and oversized custom durations fail configuration.

The watchdog owns an awake-clock deadline and only observes an atomic completion
flag. The test thread publishes completion, wakes it and joins before reclaiming
storage. There is no lock beside borrowed data: a spin guard cannot implement this
futex publication/wait protocol. Std clock-tagged timestamp comparison and timeout
values keep clock and scale together.

Under the build runner's protocol a passing test run and a passing lint write nothing: Zig 0.17
shows any stderr of a passing build step under a "failed command:" line. A failure names its
seed, and lint prints all it held when it fails.
