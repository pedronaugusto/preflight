import os
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'checks'))
import run

class Ziglint(unittest.TestCase):
    def test_exception_matches_source_rule_and_detail_and_cannot_grow(self):
        previous=Path.cwd()
        with tempfile.TemporaryDirectory() as directory:
            try:
                os.chdir(directory)
                Path('value.zig').write_text('const existing = @import("other.zig").value;\n')
                output='Z028: value.zig:1: inline import\n'
                exception={'rule':'Z028','path':'value.zig','source':'const existing = @import("other.zig").value;','detail':'inline import','reason':'existing declaration retained during migration'}
                self.assertEqual([],run.ziglint_findings(output,[exception]))
                self.assertTrue(run.ziglint_findings(output+output,[exception]))
                Path('value.zig').write_text('const changed = @import("other.zig").value;\n')
                self.assertTrue(run.ziglint_findings(output,[exception]))
            finally: os.chdir(previous)
    def test_exception_requires_reason_and_unknown_failure_is_not_hidden(self):
        self.assertTrue(run.ziglint_findings('internal error\n',[]))
        self.assertTrue(run.ziglint_findings('',[{'reason':''}]))
