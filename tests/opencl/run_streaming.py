#!/usr/bin/env python3
"""Host arithmetic/boundary tests of the actual 512-bit OpenCL vector bodies."""
import argparse
from pathlib import Path
import subprocess
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--build',type=Path,required=True)
p.add_argument('--clang',default='clang')
p.add_argument('--cxx',default='c++')
a=p.parse_args();root=Path(__file__).resolve().parents[2];b=a.build.resolve();b.mkdir(parents=True,exist_ok=True)
subprocess.run([a.clang,'-x','cl','-cl-std=CL1.2','-O2','-Wall','-Wextra','-Werror','-c',str(root/'apps/opencl/streaming.cl'),'-o',str(b/'streaming.o')],check=True)
subprocess.run([a.cxx,'-std=c++17','-O2','-Wall','-Wextra','-Werror',str(root/'tests/opencl/test_streaming.cpp'),str(b/'streaming.o'),'-o',str(b/'test')],check=True)
r=subprocess.run([str(b/'test')],capture_output=True,text=True,check=True)
(b/'native.log').write_text(r.stdout+r.stderr)
assert r.stdout.strip()=='OPENCL_STREAM_BODY_PASS counts=70 kernels=2 scales=5'
print(r.stdout,end='')
