import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[2]/'tools'))
from kernel_launch import validate_buffer_alignment

class AlignmentTest(unittest.TestCase):
    def check(self, alignment, value, changed=False):
        with tempfile.TemporaryDirectory() as tmp:
            data=('<ROOT><KERNEL name="mangled" kname="copy"><ARGUMENT name="input" '
                  'opencl_type_category="ACL_ARG_MEM_OBJ" size="8" alignment="'+str(alignment)+
                  '"/></KERNEL></ROOT>').encode()
            p=Path(tmp)/'test.bc.xml';p.write_bytes(data)
            abi={'source_sha256':{p.name:hashlib.sha256(data).hexdigest()}}
            if changed:p.write_bytes(data+b' ')
            return validate_buffer_alignment(tmp,abi,'copy',{'input':value})

    def test_power_of_two_boundaries(self):
        for alignment in (1,4,64,1024,4096):
            for value in (0,alignment,3*alignment):
                self.assertEqual(self.check(alignment,value),{'input':alignment})
            if alignment>1:
                for value in (1,alignment-1,alignment+1):
                    with self.assertRaisesRegex(ValueError,'misaligned'):self.check(alignment,value)

    def test_invalid_contract_and_address(self):
        for alignment in (0,-1,3,1023,1<<64):
            with self.assertRaises(ValueError):self.check(alignment,0)
        for value in (-1,1<<64,True,'1024'):
            with self.assertRaises(ValueError):self.check(1024,value)

    def test_changed_xml_refuses(self):
        with self.assertRaisesRegex(ValueError,'changed'):self.check(1024,1024,True)

if __name__=='__main__':unittest.main()
