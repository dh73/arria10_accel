"""Internalize PIPE simulation ports in a physical-shell candidate.
This is source preparation, not synthesis or proof of physical reset/closure.
Exact generated ES3 HIP dependencies must be qualified before implementation.
"""
from pathlib import Path
import re,json,hashlib,sys
source,out=map(Path,sys.argv[1:]);s=source.read_text();head,body=s.split(');',1)
kept=[];internal=[];removed=[]
pattern=re.compile(r'\s*(input|output)\s+wire\s*(\[[^]]+\])?\s*(\w+)\s*,?\s*(?://.*)?$')
for line in head.splitlines():
    m=pattern.fullmatch(line)
    if m and (m[3].startswith('pipe_sim_only_') or m[3] in ['hip_ctrl_test_in','hip_ctrl_simu_mode_pipe']):
        direction,width,name=m[1],m[2] or '',m[3]
        internal.append(f"wire {width} {name}"+(" = '0;" if direction=='input' else ';'))
        removed.append({'name':name,'direction':direction,'width':width})
    else:kept.append(line)
assert len(removed)==213 and sum(x['direction']=='input' for x in removed)==75
assert head.count('module platform_c126_shell #(')==1
newhead='\n'.join(kept).replace('module platform_c126_shell #(','module platform_c126_hardware_io #(')
# Keep every independent safety input; no fake admission/reset certificate.
for name in ['platform_health_valid','platform_reset_containment_valid','platform_upstream_closed','common_cold_reset_n']:
    assert name in newhead,name
out.mkdir(exist_ok=False);f=out/'platform_c126_hardware_io.sv'
f.write_text(newhead+');\n'+ '\n'.join(internal)+'\n'+body)
(out/'result.json').write_text(json.dumps({'state':'prepared','source':str(source.resolve()),'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'output_sha256':hashlib.sha256(f.read_bytes()).hexdigest(),'internalized':removed,'native_elaboration':False,'physical_acceptance':False,'requires':['exact ES3 generated HIP hardware-mode qualification','conditioned reset and upstream closure implementation','synthesis fit and all-corner timing']},indent=2)+'\n')
print('Internalized',len(removed),'simulation/control exports; independent safety inputs retained')
