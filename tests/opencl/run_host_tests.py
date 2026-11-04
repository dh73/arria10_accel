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
    for key in ('FAIL_AT','DUPLICATE','BAD_BINARY','CORRUPT','BAD_TIME','BAD_ALIGN','CORRUPT_PASS','SMALL_ALLOC','SMALL_MEMORY','TIMER_RESOLUTION','BAD_TRANSFER_TIME'):clean.pop(key,None)
    r=subprocess.run(command,env=dict(clean,**env),text=True,capture_output=True)
    (build/(name+'.log')).write_text(r.stdout+r.stderr)
    assert r.returncode==expected,(name,r.returncode,r.stderr)
    m=re.search(r'FAKE_AUDIT calls=(\d+) live=0 injected=([01])',r.stderr)
    assert m,(name,r.stderr)
    if 'FAIL_AT' in env:assert m[2]=='1'
    return r,int(m[1])
r,total=run('success',{},0)
assert r.stdout.count('OPENCL_DEVICE_DATA_PASS count=')==7
timings=re.findall(r'OPENCL_KERNEL_TIMING count=(\d+) pass1_ns=100 pass2_ns=200 span_ns=350 algorithm_bytes=(\d+) algorithm_GBps=([\d.e+-]+)',r.stdout)
assert len(timings)==7
for n,byte_count,rate in timings:
    assert int(byte_count)==int(n)*24
    assert abs(float(rate)-int(byte_count)/350) <= max(1e-6,int(byte_count)/350*1e-5)
for value in (1,2,3):run(f'bad-time-{value}',{'BAD_TIME':str(value)},1)
run('timer-boundary',{'TIMER_RESOLUTION':'100'},0)
for value in (0,101):
    r,_=run('timer-reject-'+str(value),{'TIMER_RESOLUTION':str(value)},1)
    assert 'algorithm_GBps=' not in r.stdout
for i in range(1,total+1):run(f'failure-{i}',{'FAIL_AT':str(i)},1)
for key in ('DUPLICATE','BAD_BINARY','CORRUPT'):run(key.lower(),{key:'1'},1)
command.append('--streaming')
r,stream_calls=run('stream-success',{},0)
rows=re.findall(r'OPENCL_STREAM_DATA_PASS kernel=(copy|triad) count=(\d+) elapsed_ns=200 algorithm_bytes=(\d+) algorithm_GBps=([\d.e+-]+)',r.stdout)
assert len(rows)==14
transfers=re.findall(r'OPENCL_TRANSFER_TIMING direction=(h2d|d2h)(?: kernel=(?:copy|triad))? count=(\d+) bytes=(\d+) elapsed_ns=(\d+) payload_GBps=([\d.e+-]+)',r.stdout)
assert len(transfers)==28
for direction,n,byte_count,elapsed,rate in transfers:
    assert int(byte_count)==int(n)*4
    assert int(elapsed)==(200 if direction=='h2d' else 300)
    assert abs(float(rate)-int(byte_count)/int(elapsed))<=max(1e-6,int(byte_count)/int(elapsed)*1e-5)
for value in (1,2,3):run('transfer-time-'+str(value),{'BAD_TRANSFER_TIME':str(value)},1)

for kind,n,byte_count,rate in rows:
    assert int(byte_count)==int(n)*(8 if kind=='copy' else 12)
    assert abs(float(rate)-int(byte_count)/200)<=max(1e-6,int(byte_count)/200*1e-5)
run('stream-timer-boundary',{'TIMER_RESOLUTION':'200'},0)
r,_=run('stream-timer-below',{'TIMER_RESOLUTION':'201'},1)
assert 'algorithm_GBps=' not in r.stdout
for i in range(1,stream_calls+1):run(f'stream-failure-{i}',{'FAIL_AT':str(i)},1)
for key in ('DUPLICATE','BAD_BINARY','CORRUPT','BAD_ALIGN'):run('stream-'+key.lower(),{key:'1'},1)
for value in (1,2):run(f'stream-bad-time-{value}',{'BAD_TIME':str(value)},1)
for value in (3,4):run(f'stream-corrupt-pass-{value}',{'CORRUPT_PASS':str(value)},1)
stream_command=list(command)
command.extend(['--count','33'])
r,_=run('explicit-count',{},0)
assert r.stdout.count('OPENCL_STREAM_DATA_PASS')==2 and 'count=33' in r.stdout
for key in ('SMALL_ALLOC','SMALL_MEMORY'):run(key.lower(),{key:'1'},1)
for index,value in enumerate(('0','-1','+1','1x',' 1','4294967296')):
    command[:]=stream_command+['--count',value]
    run('invalid-count-'+str(index),{},1)
command[:]=stream_command+['--count','4294967295']
r,_=run('count-device-overflow',{},1)
assert 'exceed reported' in r.stderr
for index,suffix in enumerate((['--count'],['--streaming'],['--count','1','--count','2'],['--unknown'])):
    command[:]=stream_command+suffix
    run('invalid-options-'+str(index),{},1)
for label,count,env,expected in [('allocation-equal',16,{'SMALL_ALLOC':'1'},0),('allocation-over',17,{'SMALL_ALLOC':'1'},1),('aggregate-below',5,{'SMALL_MEMORY':'1'},0),('aggregate-over',6,{'SMALL_MEMORY':'1'},1)]:
    command[:]=stream_command+['--count',str(count)]
    run(label,env,expected)
command[:]=stream_command
result={'state':'passed','injected_call_failures':total,'streaming_injected_call_failures':stream_calls,'configurable_count_checks':True,'device_allocation_boundaries':True,'extra_failures':['duplicate identity','invalid binary status','corrupt output','zero/reversed/overlapping timing'],'scope':'Actual host with synchronous fake runtime; compiled correctness bodies and reference streaming arithmetic','real_runtime':False,'physical_acceptance':False}
(build/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
