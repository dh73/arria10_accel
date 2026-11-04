#!/usr/bin/env python3
"""Isolated VCS coalescing qualification; immutable per-run sources, no runtime cap."""
import hashlib,json,re,shutil,subprocess,sys
from pathlib import Path
root=Path(__file__).resolve().parent
out=Path(sys.argv[1]).resolve();out.mkdir(parents=True,exist_ok=False)
names=['dma_payload_line_coalescing_candidate.sv','arria10_dma_ddr_mux.sv',
       'dma_memory_path_line_coalescing_candidate.sv','line_coalescing_tb.sv']
sources=[]
for name in names:
    p=out/name;p.write_bytes((root/name).read_bytes());sources.append(p)
report={'source_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
        'runner_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'hardware_qualified':False,'native_pcie_qualified':False,'runs':[]}
def save(): (out/'results.json').write_text(json.dumps(report,indent=2)+'\n')
def run(argv,log,marker=None):
    with (out/log).open('w') as f: rc=subprocess.run(argv,cwd=out,stdout=f,stderr=subprocess.STDOUT).returncode
    text=(out/log).read_text(errors='replace')
    good=rc==0 and not re.search(r'Fatal:|Error!|Error:|Error-\[|Assertion.*failed',text) and (marker is None or marker in text)
    report['runs'].append(dict(argv=argv,log=log,returncode=rc,passed=good));save()
    if not good: raise SystemExit('FAIL '+str(out/log))
binary=out/'simv'
run([shutil.which('vcs'),'-full64','-sverilog','-timescale=1ns/1ps','-assert','svaext',
     '+define+ARRIA10_ASSERTIONS','-top','line_coalescing_tb','-o',str(binary),*[str(p) for p in sources]],'compile.log')
for seed in (1,17,73):
    run([shutil.which('vcs-run'),str(binary),'-no_save',f'+ntb_random_seed={seed}',f'+SEED={seed}'],f'run-{seed}.log','LINE_COALESCING_PASS')
report['passed']=True;save();print('LINE_COALESCING_VCS_PASS '+str(out))
