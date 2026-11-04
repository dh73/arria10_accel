import unittest
from prepare import bind

class BindingTests(unittest.TestCase):
    def test_byte_order_source_selection_and_rebinding(self):
        source = bytes(range(32)).hex()
        build = bytes(range(32, 64)).hex()
        manifest = {'source_sha256': source, 'build_sha256': build,
                    'abi': {'kernels': [{'name': 'k_Copy'}, {'name': 'k_Triad'}],
                            'source_sha256': {
                                'kernel_hdl/k_Copy/k_Copy_function_cra_agent.sv': 'ab'*32,
                                'kernel_hdl/k_Triad/k_Triad_function_cra_agent.sv': 'cd'*32}}}
        top = 'parameter logic [255:0] PLATFORM_SOURCE_ID=0,PLATFORM_BUILD_ID=0,PLATFORM_COPY_SHA=0,PLATFORM_TRIAD_SHA=0;'
        bound, values = bind(top, manifest)
        self.assertEqual(int(values['SOURCE_ID'],16).to_bytes(32,'little').hex(), source)
        self.assertEqual(int(values['BUILD_ID'],16).to_bytes(32,'little').hex(), build)
        self.assertEqual(values['COPY_SHA'], 'ab'*32)
        self.assertEqual(values['TRIAD_SHA'], 'cd'*32)
        for malformed in (bound, top + top, top.replace('PLATFORM_BUILD_ID=0','PLATFORM_BUILD_ID=1')):
            with self.assertRaises(ValueError): bind(malformed, manifest)

if __name__ == '__main__': unittest.main()
