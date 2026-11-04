"""Extend the retained full-memory oracle for two masked-write rounds."""
from pathlib import Path
import argparse,hashlib,json,re

def repair(source):
 marker='  if(sim_memory[byte_addr/64][8*(byte_addr%64)+:8]!==expected[8*(byte_addr%4)+:8])'
 assert source.count(marker)==1
 assert 'final begin : opencl_full_memory_oracle' in source
 # Each slot receives masks 1..15. The final mask writes all four bytes.
 # Second round sequence = 240 + 15*(slot+1), independent of DUT memory.
 expected="  if(byte_addr>=12288 && byte_addr<12352)expected=32'hafc19237 ^ (240+15*(1+(byte_addr-12288)/4));\n"
 return source.replace(marker,expected+marker)

def main():
 p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
 data=a.source.read_text();new=repair(data)
 with a.output.open('x') as f:f.write(new)
 print(json.dumps({'source_sha256':hashlib.sha256(data.encode()).hexdigest(),'output_sha256':hashlib.sha256(new.encode()).hexdigest(),'expected_write_range':[12288,12352]}))
if __name__=='__main__':main()
