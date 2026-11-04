import copy
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
from kernel_memory_contract import extract, qualify_opencl_byte_addresses, OPENCL_BYTE_ADDRESS_SHA256
class AddressProfileTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
  self.source=Path(self.tmp.name)
  original=ROOT/'qualification/opencl-stream-compile-v1/retrieved/streaming'
  for name in OPENCL_BYTE_ADDRESS_SHA256:
   p=self.source/name;p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(original/name,p)
 def test_exact_units_only(self):
  r=qualify_opencl_byte_addresses(self.source,extract(self.source))
  self.assertEqual(r['memories'][0]['address_units'],'bytes')
  self.assertEqual(r['memories'][0]['address_bits'],41)
  self.assertFalse(r['physical_acceptance'])
  self.assertFalse(r['memories'][0]['physical_capacity_verified'])
 def test_changed_chain_rejected(self):
  r=extract(self.source);p=self.source/'ip/lsu_ic_top.sv';p.write_text(p.read_text()+'\n')
  with self.assertRaises(ValueError):qualify_opencl_byte_addresses(self.source,r)
 def test_forged_report_rejected(self):
  r=copy.deepcopy(extract(self.source));r['memories'][0]['address_bits']=35
  with self.assertRaises(ValueError):qualify_opencl_byte_addresses(self.source,r)
if __name__=='__main__':unittest.main()
