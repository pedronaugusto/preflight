# Owner batch regression record

Published baseline: `9af905ed85cab6dbb19d9431c65ee3f41fbaa74d`.
Regression-only commits `1d1734d` through `24a1f05` retain that production
implementation. Commands use Zig 0.17.0; local `-Dci-lint=false` isolates
regressions. Hosted correctness gates retain lint.

| Retained fix | Immutable failing-before evidence | Passing-after coverage |
| --- | --- | --- |
| Foreign objects and native SDK links | `1d1734d`: `zig build test -Dci-lint=false -Dtest-filter='owner cross'` cannot find Security/CoreFoundation for foreign macOS tests, helpers and benchmarks. | Foreign target/CPU objects include roots, tests, helpers, benchmarks and transitive native sources. Original native artifacts link and execute with frameworks; explicit x86_64-macos SDK linking succeeds and an unresolved native symbol fails. |
| Canonical caller regeneration | `1d1734d`: `zig build test -Dci-lint=false -Dtest-filter='owner caller'` has no supported `plan` step. | Clean consumer fixture needs no Python or local generator; stale pin replacement and every tier matrix reproduce byte identically. Malformed inputs, unsafe output paths, write faults and allocation failures are checked. |
| Independently detectable lint termination | `24a1f05`: `zig build test -Dci-lint=false -Dtest-filter='owner allowed finding'` incorrectly accepts an allowed finding followed by SIGKILL. | Signal death fails independently of ledger acceptance. Completed legacy clean/findings runs remain accepted; cancellation, reported input errors, malformed diagnostics, bounded capture truncation and capture faults fail. |
| Self-caller working directory | `62a75fe`: `zig build test -Dci-lint=false -Dtest-filter='generated caller'` fails its working-directory assertion. | Self-regeneration retains `sample`; consumer default remains its repository root. |
| ReleaseFast benchmark artifacts | `4f56a42`: the cross selection misses a compiler error present only in the separate ReleaseFast benchmark graph. | Both benchmark graphs are collected for object/link validation; native SDK benchmark execution remains covered. |
| Declared lint inputs | `96eaab6`: `zig build test -Dci-lint=false -Dtest-filter='owner explicit lint'` omits the declared missing file from argv. | Missing paths are forwarded to the real tool, malformed declarations fail, and the pinned tool's reported input error fails even with its misleading exit zero. |
| Default input probe errors | `8a06585`: `zig build test -Dci-lint=false -Dtest-filter='owner default lint'` replaces injected AccessDenied with later spawn FileNotFound. | AccessDenied, InputOutput and Canceled propagate before spawning; only absent default paths are skipped. |
| Option-shaped filenames | `c869e5f`: the explicit-input selection receives `--ignore` rather than a literal path. | Such paths receive a `./` prefix and remain literal filenames. |

## Owner decision: F04 is deferred to glint

The retiring pinned ziglint CLI cannot certify complete analysis: input errors
can return zero, directory traversal can silently stop, and final flush failures
are discarded. This batch does not claim reliable completion detection. The
owner's packages-released toolchain decision assigns F04 to glint's outcome
classes and authorizes these remaining preflight fixes to land separately.

Temporary unconditional lint rejection and tests requiring rejection of valid
legacy runs have been removed. Supported pre-existing clean/findings/exception
behavior is restored, with independently detectable termination and capture
failures still enforced. No ziglint/glint repair, consumer edit or gate disabling
is part of this batch. Silent traversal/flush failure remains a known old-tool
limitation until glint replaces it; no exception ledger can establish completion.

## Public interface and validation

After updating the immutable preflight dependency in `build.zig.zon`:

```sh
zig build plan -- --workflow .github/workflows/ci.yml
```

Preflight owns the Zig implementation, single template, declarative input dialect
and all matrices. `ci-check` emits foreign objects; `ci-link` links the original
native graph; `ci-build` links portable tests on their native SDK runner before
shard replay. Object compilation does not certify linking or execution.

Self-regeneration preserves the sample directory:

```sh
zig build plan -- --self --workflow .github/workflows/ci.yml \
  --config sample/ci/workflow.json --working-directory sample
```

Targeted checks include:

```sh
zig build test -Dci-lint=false \
  -Dtest-filter='owner ' -Dtest-filter='checks.matrix' \
  -Dtest-filter='checks.ziglint' -Dtest-filter='caller generation' \
  -Dtest-filter='caller output' -Dtest-filter='generated caller' \
  -Dtest-filter='SDK artifacts' -Dtest-filter='hosted tool setup' --summary all
zig build lint --summary all
zig build check --summary all
```

On macOS, `SDKROOT` selects the installed Xcode SDK for the explicit-target native
fixture. Hosted setup discovers it and passes `-Dci-sdk`. Shakedown is test-only
and lazy, pinned to newest green main `9357a9ab398ac25fa8a408a71e77a124bc51d311`
(FAST 37817170226, MERGE 37818062956). Gantry remains green main `76b1366`.

Public `zig build bench` includes offline all-tier caller rendering: seven targets,
12,016 bytes, 1,000 renders per sample measured 58.35, 59.08 and 58.04 us/render.
This is build-time validation/template generation, with no prior supported caller
API for runtime A/B. Artifact collection visits graph nodes once per target;
input forwarding is linear in path count. Package runtime code is unchanged.
Previous repeated self-regeneration SHA-256:
`a8e605588808f985e2db59be06a09a5be8d51517b77210b27c7e80810751b1b8`.

## Hosted history

All three failed FAST logs were read. `37811856948` on `4fa9413` exposed the
self-caller working-directory error, corrected in `6c27975`. `37813130980` on
`6c27975` and `37814193507` on `86c53b2` passed bootstrap/setup and failed solely
on the temporary unconditional F04 lint rejection. The owner's current decision
supersedes that blocker and its tool-repair handoff. Final remaining correctness
gates must pass before a genuine fast-forward main; automatic main run is canceled.
Cloak C1 and parallax both WAIT per owner instruction, including after landing.

Owner-authorized continuation local results: 37/37 targeted tests and 17/17
build steps passed with the installed macOS SDK. `lint` and `check` each passed
8/8 steps. Two canonical self-regenerations reproduced the recorded workflow
SHA-256 exactly. Legacy clean and allowed findings now pass; actual pinned-tool
missing-input reporting and allowed-finding SIGKILL regressions still fail their
gates as intended. Hosted FAST then exact-head MERGE are required next.
