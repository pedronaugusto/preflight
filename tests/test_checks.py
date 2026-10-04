import os
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'checks'))
import run
import matrix

class Checks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.previous = Path.cwd()
        os.chdir(self.temp.name)
        self.config = {'sources': ['src'], 'test_roots': ['src/root.zig']}
    def tearDown(self):
        os.chdir(self.previous)
        self.temp.cleanup()
    def source(self, name, text):
        path = Path(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path
    def test_cast_requires_nonempty_reason_on_same_line(self):
        path = self.source('src/value.zig', 'const p = @ptrCast(x); // safe: \n')
        self.assertEqual(1, len(run.cast_policy([path], {})))
        path.write_text('const p = @ptrCast(x); // safe: same representation\n')
        self.assertEqual([], run.cast_policy([path], {}))
    def test_reason_inside_string_does_not_justify_cast(self):
        path = self.source('src/value.zig', 'const x = @ptrCast("// safe: hidden");\n')
        self.assertEqual(1, len(run.cast_policy([path], {})))
    def test_literals_comments_and_test_blocks_are_excluded(self):
        path = self.source('src/value.zig', 'const word = "@ptrCast(x)";\n// @ptrCast(x)\ntest "cast" {\n const p = @ptrCast(x);\n}\n')
        self.assertEqual([], run.cast_policy([path], {}))
    def test_vendored_needs_provenance(self):
        path = self.source('src/vendor.zig', 'const p = @ptrCast(x);\n')
        self.assertTrue(run.cast_policy([path], {'vendored': {'src/vendor.zig': ''}}))
        self.assertEqual([], run.cast_policy([path], {'vendored': {'src/vendor.zig': 'std fork verified byte for byte'}}))
    def test_namespace_entry_and_test_support(self):
        a = self.source('src/Namespace/a.zig', '')
        b = self.source('src/Namespace/b.zig', '')
        self.assertEqual(1, len(run.layout([a, b], self.config)))
        self.source('src/namespace.zig', '')
        self.assertEqual([], run.layout([a, b], self.config))
        other = self.source('src/Other/one.zig', '')
        tests = self.source('src/Other/other_test.zig', '')
        support = self.source('src/testing/a.zig', '')
        support_b = self.source('src/testing/b.zig', '')
        self.assertEqual([], run.layout([other, tests, support, support_b], self.config))
    def test_function_span_ignores_literal_braces_and_exception_cannot_grow(self):
        path = self.source('src/a.zig', 'pub fn value() void {\n const x = "{";\n // }\n}\n')
        self.assertEqual([('value', 1, 4)], list(run.lengths.functions(path)))
        self.assertEqual(1, len(run.function_lengths([path], {'function_limit': 3})))
        config = {'function_limit': 3, 'function_exceptions': {'src/a.zig:value': {'lines': 4, 'reason': 'dispatch table'}}}
        self.assertEqual([], run.function_lengths([path], config))
        path.write_text('fn value() void {\n\n\n\n}\n')
        self.assertTrue(run.function_lengths([path], config))
    def test_docs_match_and_drift(self):
        self.source('examples/usage.zig', 'const example = @import("example");\nfn main() void {\n // --- README:usage ---\n const x = 1;\n // --- README:usage ---\n}\n')
        generator = {'source': 'examples/usage.zig', 'region': 'usage', 'module': 'example'}
        Path('README.md').write_text('<!-- BEGIN GENERATED usage -->\n' + run.snippet(**generator) + '<!-- END GENERATED -->\n')
        self.assertEqual([], run.docs({'docs': {'usage': generator}}))
        Path('README.md').write_text('<!-- BEGIN GENERATED usage -->\nstale\n<!-- END GENERATED -->\n')
        self.assertEqual(1, len(run.docs({'docs': {'usage': generator}})))
        with self.assertRaises(ValueError): run.snippet('examples/usage.zig', 'missing', 'example')
    def test_reach_uses_test_blocks_and_aliases(self):
        root = self.source('src/root.zig', 'const value = @import("value.zig");\ntest {\n _ = value;\n}\n')
        value = self.source('src/value.zig', 'test "checked" {}\n')
        self.assertEqual([], run.test_imports([root, value], self.config))
        root.write_text('const value = @import("value.zig");\n')
        self.assertEqual(1, len(run.test_imports([root, value], self.config)))
    def test_production_cannot_import_test_files(self):
        root = self.source('src/root.zig', 'const value = @import("value_test.zig");\n')
        self.assertTrue(run.test_imports([root], self.config))

class Matrix(unittest.TestCase):
    def test_fast_has_three_hosts_and_lint(self):
        jobs = matrix.matrix({'targets': ['unused'], 'sanitizer': 'test'}, False)['include']
        self.assertEqual(4, len(jobs))
        self.assertEqual(set(matrix.HOSTS), {j['os'] for j in jobs if j['step'] == 'ci'})
        self.assertTrue(all('Release' not in j['args'] for j in jobs))
    def test_full_covers_each_case_once_per_mode_and_all_targets(self):
        config = {'windows_shards': [{'name': str(i), 'seconds': i + 1} for i in range(13)], 'shard_jobs': 3, 'targets': ['aarch64-linux-gnu', {'target': 'x86_64-linux-gnu', 'cpu': 'x86_64_v2'}], 'sanitizer': 'unit'}
        jobs = matrix.matrix(config, True)['include']
        for mode in ['Debug', 'ReleaseSafe']:
            covered = [c for j in jobs if j['os'] == 'windows-latest' and mode in j['args'] for c in j['cases'].split()]
            self.assertEqual(sorted(str(i) for i in range(13)), sorted(covered))
        self.assertTrue(any('-Dcpu=x86_64_v2' in j['args'] for j in jobs))
        self.assertTrue(any(j['step'] == 'unit' for j in jobs))
        self.assertTrue(any('-Doptimize=ReleaseFast' in j['args'] for j in jobs))
    def test_balanced_assignment(self):
        groups = matrix.balance([{'name': str(n), 'seconds': n} for n in range(1, 7)], 3)
        self.assertEqual([7, 7, 7], [sum(int(c) for c in g) for g in groups])
    def test_trigger_and_concurrency_contract(self):
        root = Path(__file__).resolve().parents[1]
        caller = (root / '.github/workflows/ci.yml').read_text()
        shared = (root / '.github/workflows/zig.yml').read_text()
        self.assertNotIn('  push:', caller)
        self.assertIn('  merge_group:', caller)
        self.assertIn('cancel-in-progress: true', caller)
        self.assertNotIn('concurrency:', shared)
        self.assertIn('workflow_call:', shared)
        self.assertIn('Cache compiled builds', shared)
if __name__ == '__main__': unittest.main()
