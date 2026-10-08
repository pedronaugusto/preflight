# Owner batch regression record

Published baseline: `9af905ed85cab6dbb19d9431c65ee3f41fbaa74d`.
The regression-only commits `1d1734d` through `24a1f05` retain that production
implementation. All commands use Zig 0.17.0. `-Dci-lint=false` below isolates
local regressions; hosted correctness gates retain lint.

| Item | Failing before | Passing after |
| --- | --- | --- |
| Cross objects / native SDK links | At `1d1734d`, `zig build test -Dci-lint=false -Dtest-filter='owner cross'`: foreign macOS test, helper and benchmark linking cannot find Security/CoreFoundation. | The expanded fixture emits foreign objects with explicit target/CPU, rejects separately broken tests/helpers/benchmarks/transitive native sources, links and executes original native artifacts using Security/CoreFoundation, links explicit x86_64-macos with an SDK, and rejects an unresolved native symbol. |
| Caller regeneration | At `1d1734d`, `zig build test -Dci-lint=false -Dtest-filter='owner caller'`: the clean consumer has no `plan` step. | The same clean-consumer interface replaces a stale reusable-workflow pin, reproduces every tier matrix, repeats byte identically and needs neither Python nor a consumer Zig generator. Unit regressions cover malformed inputs, symlink/traversal refusal, write faults and every allocation failure with shakedown NoResize. |
| Incomplete lint analysis | At `24a1f05`, `zig build test -Dci-lint=false -Dtest-filter='owner allowed finding'`: the real file-ledger exception accepts a flushed diagnostic followed by SIGKILL, incorrectly leaving zero errors. | Signal death, cancellation, real input failure, partial JSON/text, bounded truncation and capture faults fail. Exact exception report parsing still accepts matching diagnostics independently. Every invocation of the pinned tool fails closed because completion cannot be certified. |

Final targeted selection passed 28/28 tests:

```sh
zig build test -Dci-lint=false \
  -Dtest-filter='owner ' -Dtest-filter='checks.matrix' \
  -Dtest-filter='caller generation' -Dtest-filter='caller output' \
  -Dtest-filter='generated caller' -Dtest-filter='SDK artifacts' \
  -Dtest-filter='hosted tool setup' --summary all
zig build check --summary all
```

On macOS, set `SDKROOT` to the installed Xcode SDK to include the explicit-target
native SDK fixture. Hosted setup discovers that SDK and passes `-Dci-sdk`.

The canonical consumer API is:

```sh
# After updating build.zig.zon's immutable preflight dependency:
zig build plan -- --workflow .github/workflows/ci.yml
```

Preflight owns the Zig implementation, template, input dialect and matrices.
`ci-check` emits objects; `ci-link` links the unchanged native artifact graph;
`ci-build` links portable tests on their native SDK runner before shard replay.
No foreign object result certifies native linking or execution.

## Landing blocker: pinned ziglint completion contract

In [ziglint main.zig at the immutable pin](https://github.com/pedronaugusto/ziglint/blob/924b6b5dbc5848ceef77ebccc42470efdf7a1dc4/src/main.zig),
invalid arguments and findings both return 1; an inaccessible input can print an
error and return 0; directory walking can silently stop; the final stderr flush
failure is discarded. There is no documented complete-analysis marker/protocol.
The regression invokes the actual pinned artifact on a missing input and proves
its misleading exit 0. Exit status, nonempty output and accepted exceptions
cannot establish completion. Even apparently clean output cannot establish it.

Consequently `zig build lint` remains red with a precise completion-unavailable
error and no finding suppression bypass. This batch cannot land until the owner
provides a completion-aware ziglint/glint contract in that tool's own repository.
That repository change and downstream consumer repins are outside this batch.
Existing lint integrations that expect a successful old-tool invocation cannot
pass under this contract; they must be restored when completion is certifiable.

The benchmark `zig build bench` includes offline all-tier caller rendering.
For seven targets it emits about 12 KB per render. Its cost is build-time input
validation and JSON/template generation, not a package runtime hot path; there
was no prior supported caller-generator implementation for a matched runtime A/B.

Final local ReleaseFast measurements (1,000 renders each): 58.35, 59.08 and
58.04 microseconds/render, 12,016 bytes. The separately timed benchmark build
run measured 58.57 microseconds/render. These are local measurements, not CI
performance gates. Two final self-regenerations produced the same SHA-256:
`3d46c960b13f1f12d8b581059601248646f917644f50932cc237dee7d8305547`.
The no-findings fixture was additionally rerun without a suppression ledger;
its four-test selection passed and isolates the completion failure alone.
