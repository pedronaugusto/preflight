"""Exercise the actual gantry runner against disposable package fixtures."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class Structure(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve() / 'sample'
        shutil.copytree(ROOT / 'sample', self.root, ignore=shutil.ignore_patterns('.zig-cache', 'zig-out', 'zig-pkg'))
        manifest = self.root / 'build.zig.zon'
        manifest.write_text(manifest.read_text().replace('.path = ".."', '.path = ' + json.dumps(os.path.relpath(ROOT, self.root))))
    def tearDown(self):
        self.temp.cleanup()
    def check(self):
        return subprocess.run(['zig', 'build', 'check-imports'], cwd=self.root, text=True, capture_output=True)
    def test_valid_structure(self):
        result = self.check()
        self.assertEqual(0, result.returncode, result.stderr)
    def test_undeclared_import_fails(self):
        source = self.root / 'src/sample.zig'
        source.write_text(source.read_text() + '\nconst unknown = @import("undeclared_fixture");\n')
        result = self.check()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('named dependencies', result.stderr)
    def test_duplicate_layer_owner_fails(self):
        layers = self.root / 'ci/layers.zig'
        text = layers.read_text().replace('[_][]const u8{"src/sample.zig"}', '[_][]const u8{ "src/sample.zig", "src/sample.zig" }')
        layers.write_text(text)
        result = self.check()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('multiple layers', result.stderr)
