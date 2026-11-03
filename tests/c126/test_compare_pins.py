import tempfile
import unittest
from pathlib import Path
from compare_pins import read_map, compare


class PinComparison(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'pins.qsf'

    def parse(self, extra='', device='10AX115S3F45E2SGE3'):
        self.path.write_text(f'set_global_assignment -name DEVICE {device}\n'
                             'set_location_assignment PIN_A1 -to {dq[0]}\n' + extra)
        return read_map(self.path)

    def test_matching_source_is_not_hardware_acceptance(self):
        a = self.parse()
        r = compare(a, a)
        self.assertTrue(r['source_comparison_pass'])
        self.assertFalse(r['physical_acceptance'])

    def test_missing_and_conflicting(self):
        a = self.parse('set_location_assignment PIN_B2 -to dq[1]\n')
        b = self.parse()
        b['pins']['dq[0]'] = 'PIN_C3'
        r = compare(a, b)
        self.assertEqual(len(r['missing']), 1)
        self.assertEqual(len(r['conflicts']), 1)
        self.assertFalse(r['source_comparison_pass'])

    def test_different_silicon_fails_even_with_identical_pins(self):
        a = self.parse()
        b = self.parse(device='10AX115S2F45I1SG')
        r = compare(a, b)
        self.assertTrue(r['explicit_map_match'])
        self.assertFalse(r['source_comparison_pass'])

    def test_explicit_rename(self):
        a = self.parse()
        b = dict(a, pins={'DDR_DQ[0]': 'PIN_A1', 'unused': 'PIN_D4'})
        r = compare(a, b, {'dq[0]': 'DDR_DQ[0]'})
        self.assertTrue(r['source_comparison_pass'])
        self.assertEqual(r['reference_extra_ports'], ['unused'])

    def test_no_inferred_mapping(self):
        a = self.parse()
        with self.assertRaises(ValueError): compare(a, a, {})
        b = self.parse('set_location_assignment PIN_B2 -to dq[1]\n')
        with self.assertRaises(ValueError): compare(b, b, {'dq[0]': 'x', 'dq[1]': 'x'})

    def test_ambiguous_or_dynamic_sources_rejected(self):
        bad = ['set_location_assignment PIN_B2 -to dq[0]',
               'set_location_assignment PIN_A1 -to dq[1]',
               'set_location_assignment PIN_B2 -to dq[*]',
               'source other.qsf', 'exec touch SHOULD_NOT_EXIST',
               'set_location_assignment $pin -to dq[1]',
               'set_location_assignment PIN_B2 -to dq[1]; puts hello',
               'set_location_assignment PIN_B2 -to dq[1] -disable',
               'set_global_assignment -name DEVICE duplicate']
        for line in bad:
            with self.subTest(line=line), self.assertRaises(ValueError):
                self.parse(line + '\n')

    def test_dependencies_reported_not_executed(self):
        a = self.parse('set_global_assignment -name QIP_FILE other.qip\n')
        self.assertEqual(a['unevaluated_references'], [{'kind': 'QIP_FILE', 'path': 'other.qip'}])


if __name__ == '__main__': unittest.main()
