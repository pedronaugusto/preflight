# Toolchain profile batch evidence

This batch starts from published preflight `b28046cc22055fcd32640117fc0e6965283a8ae5`.
It retains that owner's cross-object/native SDK, caller regeneration, literal
input and supported legacy lint fixes. F04 remains deferred to glint.
Shakedown measuring/comparison is pinned to published green main
`9357a9ab398ac25fa8a408a71e77a124bc51d311`; gantry remains
`76b1366323da4700bc0dcd3e24f2d7c4ee0e0ce9`. No consumer package is changed.

## Regression evidence

Tests were added before implementation, using native Zig 0.17.0. The measuring
consumer failed because `bench-build` was absent; the hardened consumer failed
because Config had no hardened field; the configured-facts consumer failed
because `facts` was absent. The separate hardened planner regression reported
expected 3 native jobs, found 0. The final named tests live in
`src/checks/integration.zig` and `src/checks/matrix.zig` and pass. These are new
behavior failures, not performance thresholds.

Targeted validation covers the three consumers, protocol/configuration parsing,
benchmark driver failures, native job planning, retained owner cross and caller
regressions, and benchmark contracts. Native `check`, `lint`, `bench-build` and
sample lint pass. The hosted correctness gates run the full suite; ordinary CI
compiles benchmarks with smoke disabled and never compares timing thresholds.

Actual allocator evidence is a consumer that runs hardened successfully, then
frees std.testing.allocator storage and writes through a volatile pointer. Its
hardened run fails with std's write-after-free diagnostic, retaining allocator
ownership in the existing runner. This is evidence of that defect class, not a
raw-pointer lifetime proof. No custom allocator or startup allocation policy is
introduced.

The native preflight `hardened-fuzz` campaign executed 1,051 inputs, 46 unique
inputs, and 1,067/27,789 instrumented coverage points (3.84%). The sample campaign
executed 2,002 inputs and reached 447/9,276 (4.82%). Seeds include valid serialized
configuration and malformed protocol bytes; Zig retains corpus and coverage in
its own cache. Hosted jobs retain the fuzzer cache for seven days. These are
executed bounded campaigns, not compile-only checks or comprehensive coverage.

On Apple M3 macOS, `hardened-tsan` fails explicitly: native x86_64 Linux is
required. Hosted native Linux jobs execute actual LLVM TSan concurrent tests.
The Linux integration regression first requires the synchronized consumer to
succeed, then requires a real intentional race to fail with a data-race diagnostic.
Sanitizer startup errors remain failures. No unsupported host produces green.
Safety-on uses configured Debug/ReleaseSafe modules; Zig's installed fuzz rebuild
lowers the same configured modules with fuzz instrumentation. No measured unsafe
hot-loop exception was added in this batch.

## Source of configured facts

The primary references are installed Zig 0.17.0 `compiler/Maker.zig`,
`compiler/configurer.zig`, `std/zig/Server.zig`, `std/zig/Client.zig`, and
`std/Build/Configuration.zig`. Build-system handshake v1 and the configuration
notification are distinct from compiler messages. The configuration file is read
while the child lives; clean exit can delete a poisoned file. The supported exit
message ends the session without requesting artifact execution.

This native serialized internal format is version-gated, not a stable external
API. The adapter validates its references and bounds before invoking std's loader.
It reports module identities/import maps, step dependencies, test artifacts,
package owners, options, lazy dependencies, generated sources, targets and native
framework requests. The generated consumer regression maps a real WriteFile test
root to its imported configured module and forwards its selected optimization.
A local snapshot with ci-lint disabled has 114 steps, 93 modules and six test
artifacts; those counts describe that configuration, not a package invariant.

Lint uses compiler-derived test roots and embedded generated source content.
Dynamic producer content unavailable at configure time fails clearly when lint
requires it. There is no guessed-root fallback. The source-level analyzed graph
is not supplied by this protocol; gantry still owns semantic boundary declarations.
The canonical object planner continues to consume actual std.Build modules,
including both benchmark graphs, while native SDK links retain original artifacts.

Protocol/configuration tests cover chunked input, every truncated prefix,
unknown/compiler frames, wrong versions, excessive lengths, malformed storage,
reference bounds, allocation failures, child signals, cancellation, and real exit
write faults. Driver tests cover invalid options, truncated/malformed JSONL,
nonzero/signal exits and output failure. Frame/body/path/total bounds are
64 frames, 8 MiB, 32 KiB and 64 MiB respectively; I/O inactivity timeout is
120 seconds. Unsupported compiler versions and unavailable generated content
fail explicitly. Benchmark child capture is bounded to 64 MiB per stream and
600 seconds, and provenance must match actual base/candidate commits.

## Matched build-time costs

[Raw JSONL](measurements/toolchain-profile-2026-10-08/) includes all samples and
published shakedown comparisons. Native ReleaseFast, Zig 0.17.0, Apple M3/macOS,
same baseline CPU target, identical benchmark callbacks and green dependencies
were used for both core revisions. The base was an immutable detached checkout
of published b28046c; the candidate core was `86c24c2de2fec83b38b30699787d83807cb66585`.
The identical new measuring harness was linked outside the base sources because
the old revision has no bench-build API. Five pairs reverse order on alternate
pairs and run from fresh directories. All 15 comparisons are within measured
noise; the cold first pair is retained, not discarded to claim an improvement.

Representative pair 2, nanoseconds per operation:

| Workload | Base best / median | Candidate best / median | Change / noise |
| --- | --- | --- | --- |
| Quality scan, 100 functions, parsed input | 460542 / 466042 | 460365 / 464729 | -0.282% / 12.684% |
| Length scan, same input | 22311 / 22539 | 22355 / 22603 | +0.283% / 7.363% |
| Seven-target offline caller generation | 58357 / 58465 | 58642 / 58724 | +0.443% / 4.185% |

The public bench-ab command also ran end to end: three immutable interleaved
pairs, base 86c24c2, candidate `8e1f9793870d8554125450f0372a32e71c2b87e4`, program
workflow, row caller generation. Its three changes (-0.266%, +0.498%, +1.818%)
remain within noise. This validates the public orchestration separately from the
published-main core comparison. Every measurement reports actual commit, Zig,
host CPU, OS, batch and clock resolution; no speed pass/fail gate exists.

On that candidate, the entire loaded graph is kept observable. The same real
configured bytes cost trusted std-loader best/median 234/260 ns versus bounded
adapter 7,923/9,018 ns per load: roughly 8.8 us median validation cost, which is
retained for correctness. This isolates loading, not compiler configuration.
A separate warm `zig build facts -Dci-lint=false` process took 0.22 s wall,
0.11 s user, 0.09 s system; it includes compiler configuration/process/JSON work
and is a single observation, not a comparative claim.

Napkin cost: ordinary workflow planning adds one opt-in lookup; enabled profiles
add three real native jobs per tier. Validation is bounded by serialized steps,
imports and extra storage with deduplicated reference traversal. It runs once
per configured facts request, outside runtime hot paths. Source scans and caller
generation show no measured difference beyond noise; no required safety or
correctness check was weakened for performance.

## Hosted correction evidence

FAST 37842704932 on 121ccd8 failed before campaigns ran: the hosted wrapper
repeated ci-bench-smoke=false (Zig then parsed a list), and the canonical sample
omitted its benchmark configuration. Both failures are retained as failing-before
integration tests in the following regression commit. The runner now emits that
control once; the sample declares its existing benchmark. No sanitizer, campaign,
artifact-retention requirement or correctness gate was weakened.

FAST 37844576624 on 927b0e8 executed native hardened tests and LLVM TSan
successfully. The default x86_64 fuzz backend produced a coverage file with zero
PCs, so hardened test artifacts now explicitly select LLVM before Zig's fuzz
rebuild. Uploads use the actual configured local cache, not the package cwd.
A retained legacy custom-step regression also caught an unsupported injected
smoke option: the runner now queries compiler-derived available options before
adding that control. All three regressions fail before and pass after the fix.
The probe adds one configure-only protocol request per hosted execution; the
0.22 s warm facts observation above indicates its measured local scale, rather than
claiming zero orchestration cost. No fallback graph, timing threshold, unsupported
sanitizer success or compile-only campaign was introduced.
