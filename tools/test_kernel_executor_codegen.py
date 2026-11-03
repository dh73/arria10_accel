"""Source-contract tests. Synthetic extractor fixtures are not RTL execution."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

from kernel_abi import extract
from kernel_executor_codegen import render, unique_object, validate

ROOT = Path(__file__).resolve().parent.parent
SNAPSHOT = ROOT / 'tests/fixtures/generated-kernel-abi.json'


def fixture(root, abi):
    """Minimal text exercising the real extractor's XML/RTL tracing patterns."""
    xml = ET.Element('ROOT')
    (root / 'kernel_system.sv').write_text(
        'logic [5:0] sys_cra_ring_address;\n'
        'assign sys_cra_ring_address = kernel_cra_address >> 3;\n')
    for k in abi['kernels']:
        directory = root / 'kernel_hdl' / k['name']
        directory.mkdir(parents=True)
        wrapper = directory / (k['name'] + '_function_wrapper.sv')
        agent_name = k['name'] + '_function_cra_agent'
        kernel = ET.SubElement(xml, 'KERNEL', kname=k['name'],
                               filename=wrapper.relative_to(root).as_posix())
        ET.SubElement(kernel, 'INTERFACE', port='cra', width='64', type='agent',
                      base_address=str(k['base']), size=str(k['size']), cosim_name=agent_name)
        rtl = ["assign Start_address_ref_q = 5'b00001;",
               "assign Status_address_ref_q = 5'b00000;",
               "assign finish_counter_addr_q = 5'b00110;",
               'assign clear_finish_counter_pre_comp_q = is_finish_counter_addr_q & avs_cra_read;',
               'assign padded_finish_counter_q = {const_finish_counter_padding_q, finish_counter_NO_SHIFT_REG_q};',
               'reg [1:0] finish_counter_NO_SHIFT_REG_q;',
               'assign status_self_update_q = {padding, compute_finished_q, start_bit_computation_q};']
        selected = []
        for i, a in enumerate(k['arguments']):
            ET.SubElement(kernel, 'ARGUMENT', name=a['name'], size='8',
                          is_streaming='false', opencl_type_category=a['kind'])
            selected.append('assign arg_%s_select_b = kernel_arguments[%d:%d];' %
                            (a['name'], i * 64 + 63, i * 64))
            for half in (0, 1):
                n = 2 * i + half
                rtl += ['// arguments_%d_buffered(REG' % n,
                        "else if (enable%d == 1'b1)" % n,
                        'assign enable%d = compare%d & avs_cra_write;' % (n, n),
                        "assign compare%d = $unsigned(avs_cra_address == ref%d ? 1'b1 : 1'b0);" % (n, n),
                        "assign ref%d = 5'b%s;" % (n, format(a['byte_offset'] // 8, '05b'))]
        wrapper.write_text('\n'.join(selected))
        (directory / (agent_name + '.sv')).write_text('\n'.join(rtl))
    ET.ElementTree(xml).write(root / 'fixture.bc.xml')


class CodegenTests(unittest.TestCase):
    def setUp(self):
        self.abi = json.loads(SNAPSHOT.read_text(), object_pairs_hook=unique_object)

    def test_snapshot_identity_and_shape(self):
        data = render(self.abi, True)
        self.assertIn('SourceValidation::SuppliedSnapshot', data)
        for path, digest in self.abi['source_sha256'].items():
            self.assertIn(path, data)
            self.assertIn(digest, data)
        self.assertEqual(data.count('"arg_count"'), 2)

    def test_mutated_contract_rejected(self):
        mutations = [
            lambda a: a.update(cra_aperture_bytes=1024),
            lambda a: a.update(schema=True),
            lambda a: a['kernels'].pop(),
            lambda a: a['kernels'][1].update(base=0),
            lambda a: a['kernels'][0].update(start_offset=16),
            lambda a: a['kernels'][0].update(finish_count_clear_on_read=False),
            lambda a: a['kernels'][0].update(finish_count_bits=3),
            lambda a: a['kernels'][0]['arguments'][1].update(name='arg_count'),
            lambda a: a['kernels'][0]['arguments'][1].update(byte_offset=128),
            lambda a: a['kernels'][0]['arguments'][0].update(size=True),
            lambda a: a['kernels'][0]['arguments'][0].update(kind='UNKNOWN'),
            lambda a: a['source_sha256'].update({'../escape': '0' * 64}),
            lambda a: a['source_sha256'].update({'kernel_system.sv': 'bad'}),
            lambda a: a.update(scope='physical image verified'),
            lambda a: a['kernels'][0].update(completion_accounting='unknown'),
            lambda a: a['kernels'][0].update(completion_accounting='delayed_snapshot_v1'),
        ]
        for mutation in mutations:
            value = copy.deepcopy(self.abi)
            mutation(value)
            with self.assertRaises(ValueError):
                validate(value)

    def test_duplicate_json_keys_rejected(self):
        with self.assertRaises(ValueError):
            json.loads('{"schema":1,"schema":1}', object_pairs_hook=unique_object)

    def test_real_extractor_is_used(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            fixture(root, self.abi)
            actual = extract(root)
            self.assertEqual(actual['kernels'], self.abi['kernels'])
            self.assertEqual(actual['source_sha256']['kernel_system.sv'],
                             hashlib.sha256((root / 'kernel_system.sv').read_bytes()).hexdigest())
            output = root / 'abi.inc'
            result = subprocess.run([sys.executable, str(ROOT / 'tools/kernel_executor_codegen.py'),
                                     '--source', str(root), '--output', str(output)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.read_text(), render(actual, False))
            self.assertIn('SourceValidation::Reextracted', output.read_text())

    def test_xml_rtl_order_and_half_mismatch_rejected(self):
        for filename, before, after in (
            ('Pass1Kernel_function_wrapper.sv', '[127:64]', '[191:128]'),
            ('Pass1Kernel_function_cra_agent.sv', "assign ref1 = 5'b10000;", "assign ref1 = 5'b10001;"),
            ('Pass1Kernel_function_cra_agent.sv', 'reg [1:0] finish_counter', 'reg [2:0] finish_counter'),
        ):
            with self.subTest(filename=filename, before=before), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                fixture(root, self.abi)
                target = root / 'kernel_hdl/Pass1Kernel' / filename
                original = target.read_text()
                self.assertIn(before, original)
                target.write_text(original.replace(before, after))
                output = root / 'abi.inc'
                output.write_text('previous valid build product')
                result = subprocess.run([sys.executable, str(ROOT / 'tools/kernel_executor_codegen.py'),
                                         '--source', str(root), '--output', str(output)],
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output.read_text(), 'previous valid build product')


if __name__ == '__main__':
    unittest.main()
