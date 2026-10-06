# Changelog

## [Unreleased]

### Breaking

- Check layers, cycles and entries over the production graph only. Test code sits in no layer: a test file or `test_support` file listed in `ci/layers.zig` fails as "test source in a layer". Remove test files and test-only layers from the table.
- Ownership reads the layer patterns: every production source matches exactly one layer. `required` only names paths that must exist; it no longer has to list every source.
- New structure rules: "production reaches tests" fails a production edge into test code, and "test layers" fails an inline-test import of a higher layer than its file.
- Fail an import in a declaration nothing reaches (no public, exported or comptime member, field, `main` or test leads to it), in test code too.
- Path patterns use gantry's dialect everywhere, including `test_support` and `function_limits`: `*` no longer crosses `/`. Write `src/testing/**` for nested support; that is now the default.
- The structure runner reads `test_support` from the configured `ci/preflight.json`.
- The source checks no longer refuse a production declaration that imports a test file by name; "production reaches tests" replaces it and lets a declaration only tests reach import test code.
- Pin gantry 441acce, where Zig imports in test context are test edges and `check` returns owned `Findings`.

### Added

- Keep exact exception ledgers shrinking, reject stale debt, check unreachable reasons, debug prints and file case, shuffle tests by seed, and report assertion density.

- Share source checks and fast and full CI gates through Zig alone, with a build helper and a reusable workflow.

- Run fast CI in one stage per host and plan only measured full-tier shards.

### Fixed

- `catch unreachable` and `std.debug.print` checks skip the configured `test_support`, not always `src/testing/`.
