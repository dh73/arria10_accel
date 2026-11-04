import sys
import tempfile
from pathlib import Path
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools'))
from kernel_memory_contract import extract

class ContractTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)
        self.xml='<board><global_mem><interface port="mem" type="agent" width="64" address="0x0" size="0x800000000"/></global_mem></board>'
        self.rtl='module kernel_system (\n'+',\n'.join(
            d+' logic '+('['+str(w-1)+':0] ' if w>1 else '')+'mem_'+n
            for n,d,w in [('address','output',35),('writedata','output',64),('readdata','input',64),('byteenable','output',8),('read','output',1),('write','output',1),('waitrequest','input',1),('readdatavalid','input',1),('writeack','input',1),('burstcount','output',1)])+'\n); endmodule\n'
    def run_extract(self):
        (self.path/'ipinterfaces.xml').write_text(self.xml)
        (self.path/'kernel_system.sv').write_text(self.rtl)
        return extract(self.path)
    def test_dimensions_not_physical_capacity(self):
        x=self.run_extract();m=x['memories'][0]
        self.assertEqual((m['data_bits'],m['address_bits'],m['burstcount_bits']),(64,35,1))
        self.assertEqual(m['model_size'],1<<35);self.assertFalse(m['physical_capacity_verified'])
    def test_xml_width_disagrees(self):
        self.xml=self.xml.replace('width="64"','width="512"')
        with self.assertRaisesRegex(ValueError,'width mismatch'):self.run_extract()
    def test_return_width_disagrees(self):
        self.rtl=self.rtl.replace('[63:0] mem_readdata','[31:0] mem_readdata')
        with self.assertRaisesRegex(ValueError,'width mismatch'):self.run_extract()
    def test_byte_masks_disagree(self):
        self.rtl=self.rtl.replace('[7:0] mem_byteenable','[3:0] mem_byteenable')
        with self.assertRaisesRegex(ValueError,'width mismatch'):self.run_extract()
    def test_wrong_direction(self):
        self.rtl=self.rtl.replace('input logic mem_writeack','output logic mem_writeack')
        with self.assertRaisesRegex(ValueError,'direction'):self.run_extract()
    def test_duplicate_port(self):
        self.rtl=self.rtl.replace('\n);',', output logic mem_read\n);')
        with self.assertRaisesRegex(ValueError,'ambiguous'):self.run_extract()
    def test_internal_wire_cannot_replace_port(self):
        self.rtl=self.rtl.replace('input logic mem_writeack,','').replace('endmodule','input logic mem_writeack; endmodule')
        with self.assertRaisesRegex(ValueError,'missing'):self.run_extract()
    def test_duplicate_memory(self):
        self.xml=self.xml.replace('</global_mem>','<interface port="mem" type="agent" width="64" address="0" size="1"/></global_mem>')
        with self.assertRaisesRegex(ValueError,'duplicate'):self.run_extract()
    def test_empty_memory(self):
        self.xml='<board/>'
        with self.assertRaisesRegex(ValueError,'no memory'):self.run_extract()

if __name__=='__main__':unittest.main()
