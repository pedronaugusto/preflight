import os
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'checks'))
import run

class Lexical(unittest.TestCase):
    def test_blank_line_before_test_does_not_hide_import(self):
        previous = Path.cwd()
        with tempfile.TemporaryDirectory() as directory:
            try:
                os.chdir(directory)
                Path('src').mkdir()
                Path('src/root.zig').write_text('\n\ntest {\n _ = @import("value.zig");\n}\n')
                Path('src/value.zig').write_text('test "covered" {}\n')
                self.assertEqual([], run.test_imports([Path('src/root.zig'),Path('src/value.zig')], {'test_roots':['src/root.zig']}))
            finally:
                os.chdir(previous)
    def test_import_in_string_is_not_a_source_import(self):
        previous = Path.cwd()
        with tempfile.TemporaryDirectory() as directory:
            try:
                os.chdir(directory)
                Path('root.zig').write_text('test "fixture" {\n const source = "@import(\\"fake.zig\\")";\n}\n')
                self.assertEqual([],run.test_imports([Path('root.zig')],{'test_roots':['root.zig']}))
            finally:
                os.chdir(previous)
