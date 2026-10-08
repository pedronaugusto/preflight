# F04 tool contract required before landing

This is an owner handoff, not an implemented or supported ziglint protocol.
The preflight batch is incomplete until a real tool contract is published,
its green immutable revision is pinned, and completed runs are accepted again.
No glint migration or consumer edits belong to this batch.

## Published state checked on 2026-10-08

- ziglint `main`: `66709a408f2ea9ac1de91a438a83b13f4691a941`.
- Family `zig-0.17`: `924b6b5dbc5848ceef77ebccc42470efdf7a1dc4`, already pinned;
  its CI run 37638100567 succeeded.
- Main is 13 commits behind that family revision. It is not a newer completion
  fix. Its README has no completion or machine-report option.
- `build.zig` exposes the executable and `addLint`, which expects exit 0. It
  exports no library module supplying an analysis-completion result.

The three failed preflight runs have different causes:

| FAST | Candidate | Actual failure |
| --- | --- | --- |
| 37811856948 | 4fa94138ee524b987193ac06843a66c39c4002a8 | Self-caller selected `.` instead of `sample`; configured fetch rejected `-Doptimize=debug`. Fixed and regression retained in 62a75fe / 6c27975. |
| 37813130980 | 6c27975143e59abcfc8359015515948786e03ebc | Bootstrap/setup succeeded. The temporary fail-closed lint implementation rejected exit 0 because the tool cannot expose completion. |
| 37814193507 | 86c53b20af6e6ea77aa1c3fed66cac491ae6cb45 | Same F04 completion barrier, after source-quality checks; no additional tool or caller failure. |

## Why preflight cannot certify the current CLI

In the pinned source, `src/main.zig` returns 1 both for invalid arguments and
completed findings. `lintPath`, directory open/walk setup, and `lintFileSimple`
can report an input error and return zero findings. `walker.next(io) catch null`
turns a traversal error into EOF, and path/allocation failures skip files.
The deferred `stderr.flush() catch {}` discards output failure.

Further, `ModuleGraph.addModulePublic` drops errors, graph reads can return
success without a module, and `Linter.report` can discard a diagnostic on
allocation failure. Preflight receives only termination and captured bytes;
completed-clean and incomplete-with-lost-output can have exactly the same
observable exit 0 and empty output. Re-enumerating files, reading them first,
parsing emitted text, accepting a ledger, or wrapping process exit cannot
recover that distinction. Importing private source files or copying the CLI
would create an unsupported second tool adapter and still lose those errors.

## Minimum file-level semantic changes in ziglint

The owner must publish a supported completion contract. One minimal design is
a documented three-outcome CLI contract: 0 means completed without findings;
1 means completed with findings; 2 means input/tool/infrastructure failure.
Signals and cancellation never count as completion. This is a proposed change,
not permission to interpret the existing pin's exit values that way.

1. `src/main.zig`: separate argument errors from findings; explicitly propagate
   file stat/open/read, directory walk, path join and file-list append failures.
   Use `while (try walker.next(io))` rather than swallowing errors. Do not
   degrade a failed module-graph construction/addition to simple linting and
   certify full analysis. Propagate configuration/standard-library detection
   errors rather than defaulting after a failure. Replace success-path deferred
   ignored flush with an explicit checked flush **before** returning 0 or 1;
   help/version also check their output flush. Any analysis or flush error must
   take the failure outcome, even after printing legitimate findings. Catch all
   analysis errors at the CLI boundary: do not let an error escape `main` and
   receive the Zig startup code's generic exit 1 (which would alias findings).
2. `src/ModuleGraph.zig`: make `addModulePublic` fallible; propagate stat/read,
   parse-allocation and recursively imported-module infrastructure failures.
   Distinguish documented unsupported import resolution from failed I/O or
   allocation. Ensure failed initialization cleans its partial graph.
3. `src/Config.zig`: preserve missing optional config as normal, but propagate
   permission/read/cancellation/malformed-existing-config errors. Do not convert
   every access error into absence or parsing failure into defaults.
4. `src/Linter.zig`: expose analysis failure to its caller. Diagnostic append,
   parse-diagnostic rendering, parent-map allocation, contexts, identifier/import
   maps and other rule allocations must not silently produce a complete result.
   Error-return propagation or one shared analysis-failure state is sufficient;
   changing the rules themselves is unnecessary.
5. `src/TypeResolver.zig` and `src/doc_comments.zig`: propagate allocation and
   relevant realpath/I/O failures to that same analysis result, preserving
   intentional unsupported/unresolved semantic results as distinct values.
6. `README.md`: document the outcomes and exactly which successful invocation
   certifies analysis completion, including input/traversal/flush failure and
   partial diagnostic behavior. A versioned machine completion record is also
   acceptable if it has the same checked-error guarantees; a trailer added to
   the current swallowing implementation would not suffice.

Tool-owned regressions must first fail at 924b6b5: completed clean; completed
findings; invalid arguments; missing/unreadable input; failed traversal after
an earlier finding; allocation failure dropping a finding; output write/flush
failure after an earlier finding; and cancellation. A completed findings run
must remain distinct from every failure. Test allocation failure across all
analysis helpers, not only final diagnostic append.

After a supported green revision exists, preflight can use that exact contract,
validate termination/completion independently of its suppression ledger, accept
completed clean and exactly allowed findings, and retain its real signal,
cancellation, input-error, partial text/JSON, output-limit and capture-failure
regressions. Only then dispatch FAST and MERGE on the same final candidate and
fast-forward main with all correctness gates green.
