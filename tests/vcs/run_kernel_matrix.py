"""One owned VCS workload matrix, native waits and one terminal notification."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--job-dir', type=Path, default=root/'qualification/kernel-matrix-corrected-cra-v1')
args = parser.parse_args()
job = args.job_dir.resolve()
job.mkdir(exist_ok=False)
thread = '01a19e3b-3c2d-7aa2-91de-5915f2585a32'
identity = {'pid': os.getpid(), 'start_ticks': Path('/proc/self/stat').read_text().split()[21],
            'thread': thread, 'job': str(job), 'notification_armed': True}
(job/'worker.json').write_text(json.dumps(identity, indent=2)+'\n')
sources = [root/'tests/vcs/kernel_system_execution_tb.sv', root/'rtl/kernel_ddr_adapter.sv',
           root/'tests/vcs/generate_kernel_fixture.py']
(job/'source-hashes.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest()
                                               for p in sources}, indent=2)+'\n')
result = {'state': 'running', 'cases': []}

def run(command, logfile):
    with logfile.open('x') as log:
        child = subprocess.Popen(command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
        (job/'active-child.json').write_text(json.dumps({'pid':child.pid,
            'start_ticks':Path(f'/proc/{child.pid}/stat').read_text().split()[21],
            'command':command}, indent=2)+'\n')
        return child.wait()

try:
    rc = run(['python3',str(root/'tools/prepare_corrected_kernel.py'),
              str(job/'kernel-inputs')],job/'prepare.log')
    if rc:
        raise RuntimeError('Corrected source preparation failed')
    hashes = json.loads((job/'kernel-inputs/source-hashes.json').read_text())
    hashes.update(json.loads((job/'source-hashes.json').read_text()))
    (job/'source-hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
    result['completion_accounting'] = 'delayed_snapshot_v1'
    result['physical_acceptance'] = False
    command = ['vcs','-full64','-sverilog','-timescale=1ns/1ps',
               '+define+KERNEL_DDR_ASSERTIONS','-top','kernel_system_execution_tb',
               '-f',str(job/'kernel-inputs/sources.f'),
               str(root/'rtl/kernel_ddr_adapter.sv'),str(sources[0]),
               '-Mdir='+str(job/'csrc'),'-o',str(job/'simv')]
    result['compile_exit'] = run(command,job/'compile.log')
    if result['compile_exit']:
        raise RuntimeError('VCS compile failed; inspect compile.log')
    for count in [1,3,17,257,4093,65537,1000003]:
        case = job/str(count)
        case.mkdir()
        rc = run(['python3',str(sources[2]),'--count',str(count),'--output',str(case)],case/'fixture.log')
        if rc:
            raise RuntimeError(f'fixture generation failed for {count}')
        command = ['vcs-run',str(job/'simv'),f'+COUNT={count}',
                   '+INPUT='+str(case/'kernel_execution_input.hex'),
                   '+EXPECTED='+str(case/'kernel_execution_expected.hex')]
        rc = run(command,case/'simulation.log')
        text = (case/'simulation.log').read_text()
        passed = re.findall(r'^PASS actual kernels count='+str(count)+r' .*$',text,re.M)
        traffic = re.findall(r'^PASS actual kernels count=([0-9]+) reads=([0-9]+) writes=([0-9]+) returns=([0-9]+) cycles=([0-9]+)$',text,re.M)
        exact_traffic = len(traffic)==1 and tuple(map(int,traffic[0][:4])) == (count,4*count,2*count,4*count)
        accepted = rc == 0 and len(passed) == 1 and exact_traffic and not re.search(r'Fatal:|Error!|Error-\[',text)
        result['cases'].append({'count':count,'exit_code':rc,'accepted':accepted,'pass_lines':passed})
        (job/'checkpoint.json').write_text(json.dumps(result,indent=2)+'\n')
        if not accepted:
            raise RuntimeError(f'functional acceptance failed for {count}; retained original logs')
    if any(hashlib.sha256(Path(path).read_bytes()).hexdigest()!=digest for path,digest in hashes.items()):
        raise RuntimeError('Source changed during qualification')
    result['source_hashes_reverified'] = True
    result['state']='passed'
except Exception as exc:
    result['state']='intervention'
    result['error']=str(exc)
finally:
    (job/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    message = f'VCS generated-kernel matrix {result["state"]}. Inspect {job}/result.json and native logs; simulation only, no physical acceptance. Do not duplicate or relaunch on unknown continuity.'
    queued = subprocess.run(['codex','queue','--thread',thread,'--message',message],capture_output=True,text=True)
    (job/'notification.json').write_text(json.dumps({'exit_code':queued.returncode,
        'stdout':queued.stdout,'stderr':queued.stderr},indent=2)+'\n')
