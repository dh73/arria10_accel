import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tools'))
from kernel_abi import extract
from packed_kernel_args import encode

SOURCE = ROOT/'qualification/sycl-stream-wide-v1/retrieved/workload-es3-early.prj'

class PackedArgumentsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.src = Path(self.tmp.name)
        for f in extract(SOURCE, packed=True)['source_sha256']:
            p = self.src/f
            p.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SOURCE/f, p)

    def test_real_packed_pointer_crosses_words(self):
        abi = extract(self.src, packed=True)
        k = abi['kernels'][0]
        self.assertEqual(abi['schema'], 2)
        words = encode(k, dict(arg_count=17, arg_dst=0x1234567887654321,
                               arg_src=0x1122334455667788))
        self.assertEqual(words, [
            dict(address=128,value=0x8765432100000011,byteenable=255),
            dict(address=136,value=0x5566778812345678,byteenable=255),
            dict(address=144,value=0x11223344,byteenable=15)])
        self.assertEqual([a['size'] for a in abi['kernels'][1]['arguments']], [4,8,8,8,4])

    def test_unqualified_size_and_names_rejected(self):
        k = extract(self.src, packed=True)['kernels'][0]
        with self.assertRaises(ValueError): encode(k, dict(arg_count=1,arg_dst=0))
        for value in (-1,1<<32,True):
            with self.assertRaises(ValueError):
                encode(k,dict(arg_count=value,arg_dst=0,arg_src=0))

    def test_write_lane_mutation_rejected(self):
        p = self.src/'kernel_hdl/a10_streaming_Copy/a10_streaming_Copy_function_cra_agent.sv'
        s=p.read_text();old='assign bus_high_b = avs_cra_writedata[63:32];'
        self.assertIn(old,s)
        p.write_text(s.replace(old,'assign bus_high_b = avs_cra_writedata[31:0];'))
        with self.assertRaisesRegex(ValueError,'mask lane mismatch'): extract(self.src,packed=True)

    def test_xml_order_mutation_rejected(self):
        p=self.src/'kernel_hdl/a10_streaming_Copy/a10_streaming_Copy_function_wrapper.sv'
        s=p.read_text();self.assertIn('kernel_arguments[95:32]',s)
        p.write_text(s.replace('kernel_arguments[95:32]','kernel_arguments[159:96]'))
        with self.assertRaisesRegex(ValueError,'argument order'): extract(self.src,packed=True)

    def test_launch_orders_masked_arguments_before_start(self):
        from kernel_launch import encode as launch
        values=dict(arg_count=17,arg_dst=0x1080,arg_src=0x40)
        packet=launch(self.src,'a10_streaming_Copy',values,packed=True)
        self.assertEqual([w['byte_offset'] for w in packet['writes']], [128,136,144,8])
        self.assertEqual([w['byte_enable'] for w in packet['writes']], [255,255,15,255])
        self.assertEqual(packet['writes'][-1]['data_le_hex'], '0100000000000000')
        self.assertEqual(packet, launch(self.src,'a10_streaming_Copy',dict(reversed(list(values.items()))),packed=True))
        self.assertEqual(packet['completion']['byte_offset'],48)

    def test_legacy_mode_stays_strict(self):
        with self.assertRaisesRegex(ValueError,'argument size'): extract(self.src)

if __name__ == '__main__': unittest.main()
