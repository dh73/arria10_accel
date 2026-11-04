"""Stage the non-aliasing generated kernels in the retained PCIe workload."""
from pathlib import Path
import hashlib,json,re
R=Path(__file__).resolve().parents[2]
base=R/'qualification/full-platform-fetch-context-v1'
sim=R/'qualification/sycl-stream-restrict-sim-v1'
gen=R/'qualification/sycl-stream-restrict-local-v1/work/workload-es3-early.prj'
cra=R/'qualification/sycl-stream-restrict-cra-v1'
out=R/'qualification/full-platform-restrict-v1'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
pins=json.loads((base/'sources.json').read_text())
assert json.loads((base/'result.json').read_text())['state']=='passed'
assert all(sha(Path(p))==h for p,h in pins.items())
sp=json.loads((sim/'sources.json').read_text())
assert json.loads((sim/'result.json').read_text())['state']=='passed'
assert all(sha(Path(p))==h for p,h in sp.items())
manifest=json.loads((cra/'candidate.json').read_text())
for f in manifest['files']:
 assert sha(cra/(f['kernel']+'_function_cra_agent.sv'))==f['candidate_sha256']
out.mkdir(exist_ok=False)
for name in pins:
 p=Path(name)
 if p.is_relative_to(base):
  q=out/p.relative_to(base);q.parent.mkdir(parents=True,exist_ok=True)
  q.write_bytes(p.read_bytes().replace(str(base).encode(),str(out).encode()));q.chmod(p.stat().st_mode&0o777)
for name in ['synopsys_sim.setup','vhdlan-container.sh','route_vlogan.py','build.sh','run_native.py','worker.py','commands.json','routing.json','bin/vlogan','bin/vhdlan']:
 p=base/name;q=out/name;q.parent.mkdir(parents=True,exist_ok=True)
 q.write_text(p.read_text().replace(str(base),str(out)).replace('Full platform bound fetch context v1','Full platform restrict kernels v1'));q.chmod(p.stat().st_mode&0o777)
(out/'models').symlink_to((base/'models').resolve(),target_is_directory=True)
(out/'bin/vcs').symlink_to('/home/diego1/bin/scripts/vcf')
r=json.loads((out/'routing.json').read_text())
oldgen=str(R/'qualification/sycl-stream-vector-v1/retrieved/workload-es3-early.prj')
oldcra=str(R/'qualification/full-platform-sycl-vector-cra-fixed-v1/cra-overlay')
r['extra']=[s for s in r['extra'] if oldgen not in s and oldcra not in s]
r['extra'].append('+incdir+'+str(gen/'ip'))
files=re.findall(r'set_global_assignment -name (?:SYSTEMVERILOG_FILE|VERILOG_FILE) \[file join \$::quartus\(qip_path\) "([^"]+)"\]',(gen/'kernel_system.qip').read_text())
for f in dict.fromkeys(files):
 p=gen/f
 if p.name.endswith('_function_cra_agent.sv'):p=cra/p.name
 assert p.is_file();r['extra'].append(str(p))
(out/'routing.json').write_text(json.dumps(r,indent=2)+'\n')
oldhash=['813cfa3c23f5dd12153a739d797ed6269cb0d011399e1dee2200fb11b1af7d28','99945ded8689c9fea99e3208fc87df774e95a50f3073951d428d1c510e31e30d']
for name in ['kernel_launch_custody_profiles.sv','pcie_ed_tb_platform.v']:
 p=out/name;s=p.read_text()
 for old,f in zip(oldhash,manifest['files']):
  prefix="SOURCE_PROFILE==3? 256'h" if name=='kernel_launch_custody_profiles.sv' else "256'h"
  assert s.count(prefix+old)==1;s=s.replace(prefix+old,prefix+f['candidate_sha256'])
 p.write_text(s)
# Bind arguments from the new XML/RTL extraction, not the older vector layout.
args=(sim/'stream_launch.svh').read_text().replace('write_arg_csr(', 'kernel_pio_write(bar_table,')
args=args.replace("64'(count)","64'd2045").replace("64'(first_input)","64'h1000").replace("64'(stride+64)","64'h4000").replace("64'(output_base)","(base==0?64'h4000:64'h6000)")
p=out/'platform-bfm.sv';s=p.read_text();start=s.index('case(base)',s.index('COUNT_BASELINE_NOT_ZERO'));end=s.index('endcase',start)+len('endcase');p.write_text(s[:start]+args+s[end:])
(out/'sys_description.hex').write_bytes((gen/'sim/sys_description.hex').read_bytes())
# Run only after the exact new CRA race qualification passes.
p=out/'worker.py';s=p.read_text().replace("    result['suite_exits'] = []",f"    assert json.loads(Path({str(cra/'result.json')!r}).read_text())['state']=='passed'\n    result['suite_exits'] = []");p.write_text(s)
newpins={p:h for p,h in pins.items() if not Path(p).is_relative_to(base) and oldgen not in p and oldcra not in p}
for name in r['extra']:
 if not name.startswith('+'):newpins[name]=sha(Path(name))
for p in out.rglob('*'):
 if p.is_file() and not p.is_symlink():newpins[str(p)]=sha(p)
(out/'sources.json').write_text(json.dumps(newpins,indent=2)+'\n')
(out/'preparation.json').write_text(json.dumps({'state':'prepared_not_launched','base':str(base),'prerequisite':str(cra/'result.json'),'pins':len(newpins),'physical_acceptance':False},indent=2)+'\n')
print('Prepared',len(newpins),'pins; CRA qualification required before launch')
