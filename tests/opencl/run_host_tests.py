#!/usr/bin/env python3
"""Exercise the actual binary host against an instrumented fake runtime."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--build',type=Path,required=True)
p.add_argument('--opencl-include',type=Path,required=True)
p.add_argument('--clang',default='clang')
p.add_argument('--cxx',default='c++')
a=p.parse_args();root=Path(__file__).resolve().parents[2];build=a.build.resolve();build.mkdir(parents=True,exist_ok=True)
subprocess.run([a.clang,'-x','cl','-cl-std=CL1.2','-O2','-c',str(root/'apps/opencl/correctness.cl'),'-o',str(build/'kernels.o')],check=True)
subprocess.run([a.cxx,'-std=c++17','-O2','-Wall','-Wextra','-Werror','-I'+str(a.opencl_include),'-I'+str(root/'include'),str(root/'apps/opencl/host.cpp'),str(root/'tests/opencl/fake_runtime.cpp'),str(build/'kernels.o'),'-o',str(build/'host')],check=True)
(build/'fixture.bin').write_bytes(b'FAKE TEST ONLY')
command=[str(build/'host'),'--physical',str(build/'fixture.bin'),'fixture','fixture-device']
def run(name,env,expected):
    clean=os.environ.copy()
    for key in ('FAIL_AT','DUPLICATE','BAD_BINARY','CORRUPT'):clean.pop(key,None)
    r=subprocess.run(command,env=dict(clean,**env),text=True,capture_output=True)
    (build/(name+'.log')).write_text(r.stdout+r.stderr)
    assert r.returncode==expected,(name,r.returncode,r.stderr)
    m=re.search(r'FAKE_AUDIT calls=(\d+) live=0 injected=([01])',r.stderr)
    assert m,(name,r.stderr)
    if 'FAIL_AT' in env:assert m[2]=='1'
    return r,int(m[1])
r,total=run('success',{},0)
assert r.stdout.count('OPENCL_DEVICE_DATA_PASS count=')==7
for i in range(1,total+1):run(f'failure-{i}',{'FAIL_AT':str(i)},1)
for key in ('DUPLICATE','BAD_BINARY','CORRUPT'):run(key.lower(),{key:'1'},1)
result={'state':'passed','injected_call_failures':total,'extra_failures':['duplicate identity','invalid binary status','corrupt output'],'scope':'Synchronous fake runtime, actual host and compiled kernel bodies','real_runtime':False,'physical_acceptance':False}
(build/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
