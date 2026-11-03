import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from kernel_launch import encode, unique_object
from kernel_abi import extract

SOURCE = ROOT / 'qualification/kernel-system-vcs-v1/source'


class LaunchTest(unittest.TestCase):
    def setUp(self):
        self.kernel = extract(SOURCE)['kernels'][1]
        self.values = {a['name']: 0x0102030405060708 + i
                       for i, a in enumerate(self.kernel['arguments'])}

    def test_second_window_and_literal_wire_bytes(self):
        packet = encode(SOURCE, 'Pass2Kernel', self.values)
        self.assertEqual([w['byte_offset'] for w in packet['writes']],
                         list(range(384, 488, 8)) + [264])
        self.assertEqual(packet['writes'][0]['data_le_hex'], '0807060504030201')
        self.assertEqual(packet['writes'][-1]['data_le_hex'], '0100000000000000')
        self.assertEqual(packet['schema'], 2)
        self.assertEqual(packet['completion'], {'mode': 'read_clear_count',
                         'byte_offset': 304, 'width_bits': 2, 'expected': 1})
        self.assertTrue(all(w['byte_enable'] == 255 for w in packet['writes']))

    def test_argument_dictionary_order_does_not_change_register_order(self):
        reverse = dict(reversed(list(self.values.items())))
        self.assertEqual(encode(SOURCE, 'Pass2Kernel', reverse),
                         encode(SOURCE, 'Pass2Kernel', self.values))

    def test_missing_extra_and_unknown(self):
        with self.assertRaises(ValueError):
            encode(SOURCE, 'missing', self.values)
        for values in ({}, dict(self.values, unrelated=0)):
            with self.assertRaises(ValueError):
                encode(SOURCE, 'Pass2Kernel', values)

    def test_no_truncation_or_coercion(self):
        key = next(iter(self.values))
        for value in (-1, 1 << 64, True, 1.0, '1', None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                encode(SOURCE, 'Pass2Kernel', dict(self.values, **{key: value}))
        packet = encode(SOURCE, 'Pass2Kernel', dict(self.values, **{key: (1 << 64)-1}))
        self.assertEqual(packet['writes'][0]['data_le_hex'], 'ffffffffffffffff')

    def test_duplicate_json_arguments_rejected(self):
        with self.assertRaisesRegex(ValueError, 'duplicate JSON'):
            json.loads('{"arg_count":1,"arg_count":2}', object_pairs_hook=unique_object)


if __name__ == '__main__':
    unittest.main()
