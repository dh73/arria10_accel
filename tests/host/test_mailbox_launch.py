import sys
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
from mailbox_launch import encode,transaction
from kernel_launch import encode as direct
SOURCE=ROOT/'qualification/sycl-stream-vector-v1/retrieved/workload-es3-early.prj'

class MailboxLaunchTest(unittest.TestCase):
    def test_packed_launch_matches_source_words(self):
        values=dict(arg_count=128,arg_src=0xff4,arg_dst=0x1400)
        base=0x100000100
        packet=encode(SOURCE,'a10_streaming_Copy',values,base,packed=True)
        original=direct(SOURCE,'a10_streaming_Copy',values,packed=True)
        words=[]
        for command in packet['commands']:
            writes=command['write32']
            self.assertEqual([w['byte_offset']-base for w in writes],[0,4,8,12,16])
            v=[int.from_bytes(bytes.fromhex(w['data_le_hex']),'little') for w in writes]
            self.assertEqual(v[4],1)
            words.append((v[0],v[1]|(v[2]<<32),v[3]))
            self.assertFalse(command['replay_after_unknown_acknowledgement'])
            self.assertTrue(command['completion']['posted_write_fence_required'])
        self.assertEqual(words,[(w['byte_offset'],int.from_bytes(bytes.fromhex(w['data_le_hex']),'little'),w['byte_enable']) for w in original['writes']])
        self.assertEqual(words[-1],(8,1,255))
        completion=packet['completion_read']
        self.assertEqual([(w['byte_offset']-base,w['data_le_hex']) for w in completion['write32']],[(0,'30000000'),(16,'02000000')])
        self.assertEqual(completion['result_read32'],[base+24,base+28])

    def test_invalid_aperture_target_or_value(self):
        for base in [-1,True,3,(1<<64)-31]:
            with self.assertRaises(ValueError):transaction(base,0)
        for target in [-1,True,4,512]:
            with self.assertRaises(ValueError):transaction(0,target)
        for value in [-1,True,1<<64]:
            with self.assertRaises(ValueError):transaction(0,8,value=value)
        for mask in [0,True,256]:
            with self.assertRaises(ValueError):transaction(0,8,value=1,mask=mask)

if __name__=='__main__':unittest.main()
