import json
from pathlib import Path
import tempfile
import unittest

import c126_preflight as tool

ROOT = Path(__file__).resolve().parents[2]


class DesignClosureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.report = (ROOT / 'qualification/c126-es3-v1/reports/snapshot/ed_synth.sta.rpt').read_text()
        lines = cls.report.splitlines()
        start = next(i for i,l in enumerate(lines) if l.startswith(';') and
                     [s.strip() for s in l.split(';')[1:-1]] == ['Design Closure Summary'])
        end = next(i for i in range(start+4,len(lines)) if lines[i] == '')
        cls.table = '\n'.join(lines[start:end]) + '\n'

    def test_actual_compile_zero_is_failed_closure(self):
        result = tool.design_closure(self.report)
        self.assertEqual(result['state'], 'failed')
        self.assertEqual(result['flags']['Timing Closure'], 'Pass')
        self.assertEqual(result['flags']['Unconstrained Paths'], 'Fail')

    def test_missing_duplicated_and_inconsistent_report(self):
        for text in ('', self.table+self.table, self.table.replace('Hold Summary','Other Row'),
                     '\n'.join(self.table.splitlines()[:-1]),
                     self.table.replace('Result Flag','Unknown Header')):
            self.assertEqual(tool.design_closure(text)['state'], 'unknown')
        # An overall Pass cannot override an explicitly failing child gate.
        text = self.table.replace('; Fail', '; Pass', 1)
        self.assertEqual(tool.design_closure(text)['state'], 'failed')

    def test_wrapper_preserves_native_exit_and_enforces_closure(self):
        for report, native_exit, expected in ((self.table,0,2),
                   (self.table.replace('Fail','Pass'),0,0), (self.table,7,7)):
            with self.subTest(native_exit=native_exit,expected=expected), tempfile.TemporaryDirectory() as d:
                root = Path(d); snap=root/'snapshot';snap.mkdir()
                fake=root/'quartus'
                fake.write_text('#!/usr/bin/env python3\nfrom pathlib import Path\n'
                                + 'Path("ed_synth.sta.rpt").write_text('+repr(report)+')\n'
                                + 'raise SystemExit('+str(native_exit)+')\n')
                fake.chmod(0o755)
                rc=tool.run_quartus_compile(snap,root,project='ed_synth',quartus_sh=str(fake))
                self.assertEqual(rc,expected)
                result=json.loads((root/'build-result.json').read_text())
                self.assertEqual(result['exit_code'],native_exit)
                self.assertEqual(result['wrapper_exit_code'],expected)
                self.assertFalse(result['physical_acceptance_claimed'])
                with self.assertRaises(tool.PreflightError):
                    tool.run_quartus_compile(snap,root,project='ed_synth',quartus_sh=str(fake))


if __name__ == '__main__':
    unittest.main()
