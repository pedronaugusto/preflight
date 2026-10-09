# Preflight design

Preflight owns repository gates, build and process orchestration, and the canonical hosted workflow planner. Gantry owns semantic architecture checks. Code-level rules belong to glint; the current supported ziglint behavior remains available until that integration supplies reliable completion outcomes. The legacy tool can silently omit traversal or final-flush failures, so F04 remains open. Independently observable input, signal, cancellation and capture failures still fail the gate.

## Configured builds and target projection

`addCi` consumes the caller's actual `std.Build` graph. Foreign target checks project configured artifacts to objects, including test, helper, benchmark and transitive native-source modules. Native `ci-link` and portable test-build steps retain the original artifacts and their SDK libraries/frameworks. Object compilation certifies compilation; only native linking and execution certify those operations. Benchmark modules include the selected ordinary graph and the separate ReleaseFast graph.

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

One Zig planner owns every workflow tier and matrix; callers regenerate through `zig build plan`. CI controls have one declaration owner, including early root lazy-discovery returns. A caller-provided `Config.timings_enabled` retains its existing option ownership: preflight uses that value without declaring a second `ci-timings` option. Declarative repository facts stay with the caller. Hardened opt-in adds three native jobs per enabled tier; ordinary planning adds one option lookup. The hosted runner queries compiler-derived available options before injecting benchmark smoke control, preserving older custom steps that never declare it. That costs one configure-only request per execution. Serialized validation scales with configured storage and references, outside package runtime hot paths. Matched measurements belong in private trials beside their driver; correctness and required safety checks are retained regardless of their cost.

Runner protocol, timeout, test ordering, allocation ownership and portable shard records remain separate from benchmark measurement. The runtime build dependency closure remains unchanged; shakedown is lazy test/benchmark support. Configuration and driver fault tests use deterministic child/input/output failures, rather than timing thresholds.


The own-tree toolchain gate consumes Zig 0.17.0's resolved `package_map`, dependency-name-to-hash mappings and actual module import tables. Native LazyPath arguments retain generated-source producers. Gantry supplies manifest dependency and source import facts (including dead and test-only references); preflight applies the repository closure policy and follows those facts recursively in their configured module context. Exported build-helper source, the installed command and public rules are production roots. Configured test artifacts supply separate test roots, so tests in a production file are visited only in their test artifact's binding context. A manifest's lazy flag is never treated as test scope.

The gate validates immutable git revisions, declared content hashes against resolved hashes and canonical remote family names against fetched manifest identities. All materialized declaration dependencies are checked recursively, including different published bootstrap versions. Unmaterialized lazy bootstrap entries are named as such and cannot supply production facts. Runtime family edges descend aegis/sweep, glint, gantry, preflight; test-support and pinned lazy bootstrap edges are separate. Required source, identity, binding, version, parser and output failures remain errors. Source reachability is gantry's current lexical/declaration analysis, not a claim of Zig compiler semantic reachability; unsupported recovered constructs fail clearly. Configure internals and the build protocol are distinct version-gated source-of-facts adapters, neither a stable external graph API. Closure scanning is an own-gate cost outside consumer runtime; no dependency or consumer changes are needed.

Cross projections retain each compile step's expected-error union and diagnostic limit. Zig's build runner owns matching (`contains`, `exact`, `starts_with`, `stderr_contains`) and failure outcomes. Deliberate failures do not request emitted binaries, since Zig returns after matching rather than producing a file. Positive projections still emit objects; original native artifacts retain their diagnostic and SDK-link contracts. The integration fixture exercises expected failures, wrong diagnostics and unexpected success across Linux, both macOS architectures and both Windows architectures, with a positive object beside each rejection.

## Shard and watchdog boundaries

Aegis is the std-only scalar safety leaf used by test-order and watchdog modules.
`ShardIndex` and `ShardCount` retain `usize` layout but cannot be interchanged.
`Shard.init` and `Shard.parse` establish a nonzero count and an index below it.
`assign` rechecks those contracts because Zig permits direct field construction,
checks that `count * sizeof(f64)` fits before load allocation, and rejects unequal
name/weight lengths before allocating or indexing. Its measured inner loop uses
raw shard positions in that one domain after validation; the storage bound also
proves `start + step` cannot overflow. Test indices remain native slice positions.

The build helper retains `std.Io.Duration` through `TestTimeout.duration`, validates
the generated options' `u64` nanosecond range and exports that schema once. The
published aegis build helper does not export scalar namespaces to build scripts;
the runtime runner wraps the generated value in aegis `Duration(.nanosecond, u64)`.
Conversion to the public std wait vocabulary is explicit and checked. The disabled
watchdog remains zero; nonpositive custom durations retain their one-nanosecond
floor. Missing reasons and oversized custom durations fail configuration.

The watchdog owns an awake-clock deadline and only observes an atomic completion
flag. The test thread publishes completion, wakes it and joins before reclaiming
storage. There is no lock beside borrowed data: a spin guard cannot implement this
futex publication/wait protocol. Std clock-tagged timestamp comparison and timeout
values keep clock and scale together. No guard, confined state or borrowed lock
capability enters the public API. Raw-site comments state the permitted reason at
the retained parser, generated-schema, one-owner naming and measured-loop sites.

The package config declares Glint A004 at `gate` for the adopted scalar domains.
Its source root is `src`, with tests inside it under the same rule; `sources`
stays the shipped roots, which `.paths` must list, so the benchmarks under
`bench` are outside this declaration until Glint can select roots a fetched
package does not ship. The index/count relation is a reasoned safe-type-internals
exception at the one representation comparison. The declaration takes effect
once Glint accepts the setting and its gating policy: published Preflight still
invokes ziglint, and published Glint admits A004 only in report mode.

The toolchain closure follows the `test` blocks of a test artifact's root module
and not those of the modules it imports, as the compiler builds them. A
dependency's embedded tests may name modules, such as shakedown, that only its own
test build binds; they are not part of the consumer's closure, and the gate neither
binds nor exempts them.
