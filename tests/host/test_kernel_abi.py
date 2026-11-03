import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tools'))
from kernel_abi import extract


class KernelAbiTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name)
        original = ROOT/'qualification/kernel-system-vcs-v1/source'
        manifest = extract(original)
        for relative in manifest['source_sha256']:
            target = self.source/relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original/relative, target)
        self.xml = next(self.source.glob('*.bc.xml'))

    def mutate(self, path, old, new):
        text = path.read_text()
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, 1))

    def test_actual_compiler_contract(self):
        abi = extract(self.source)
        self.assertEqual(abi['cra_aperture_bytes'], 512)
        self.assertEqual([k['base'] for k in abi['kernels']], [0,256])
        for kernel in abi['kernels']:
            self.assertEqual((kernel['start_offset'], kernel['status_offset']), (8,0))
            self.assertEqual(kernel['finish_count_offset'], 48)
            self.assertEqual(kernel['finish_count_bits'], 2)
            self.assertTrue(kernel['finish_count_clear_on_read'])
            self.assertEqual([a['byte_offset'] for a in kernel['arguments']], list(range(128,232,8)))

    def test_rejects_aliasing_window(self):
        self.mutate(self.xml, 'base_address="256"', 'base_address="512"')
        with self.assertRaisesRegex(ValueError, 'aperture'):
            extract(self.source)

    def test_rejects_overlapping_windows(self):
        self.mutate(self.xml, 'base_address="256"', 'base_address="128"')
        with self.assertRaisesRegex(ValueError, 'overlapping kernel'):
            extract(self.source)

    def test_rejects_xml_rtl_argument_mismatch(self):
        path = self.source/'kernel_hdl/Pass1Kernel/Pass1Kernel_function_wrapper.sv'
        self.mutate(path, 'kernel_arguments[63:0]', 'kernel_arguments[127:64]')
        with self.assertRaisesRegex(ValueError, 'argument order'):
            extract(self.source)

    def test_rejects_register_overlap(self):
        path = self.source/'kernel_hdl/Pass1Kernel/Pass1Kernel_function_cra_agent.sv'
        self.mutate(path, "assign dupName_3_address_ref_x_q = 5'b10000;",
                    "assign dupName_3_address_ref_x_q = 5'b00001;")
        with self.assertRaisesRegex(ValueError, 'overlapping/out-of-range'):
            extract(self.source)

    def test_rejects_changed_address_units(self):
        self.mutate(self.source/'kernel_system.sv', 'kernel_cra_address >> 3', 'kernel_cra_address >> 2')
        with self.assertRaisesRegex(ValueError, 'byte-to-word'):
            extract(self.source)

    def test_rejects_changed_completion_side_effect(self):
        path = self.source/'kernel_hdl/Pass1Kernel/Pass1Kernel_function_cra_agent.sv'
        self.mutate(path, 'is_finish_counter_addr_q & avs_cra_read',
                    'is_finish_counter_addr_q & avs_cra_write')
        with self.assertRaisesRegex(ValueError, 'finish counter'):
            extract(self.source)


if __name__ == '__main__':
    unittest.main()
