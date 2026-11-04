"""Prepare isolated synthesis assignments from pinned platform and ES3 IP sources."""
import argparse,hashlib,json,re
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--base',type=Path,required=True)
p.add_argument('--shell',type=Path,required=True)
p.add_argument('--hip',type=Path,required=True)
p.add_argument('--out',type=Path,required=True)
p.add_argument('--include-pins',type=Path,required=True)
a=p.parse_args();base=a.base.resolve();shell=a.shell.resolve();hip=a.hip.resolve();out=a.out.resolve()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
pins=json.loads((base/'sources.json').read_text())
assert json.loads((base/'result.json').read_text())['state']=='passed'
for f,h in pins.items():assert sha(Path(f))==h,f
binding=json.loads((shell/'binding-audit.json').read_text())
for f,h in binding['files'].items():assert sha(Path(f))==h,f
route=json.loads((base/'routing.json').read_text())
# Preserve the native IP's library and metadata assignments. Resolve its original
# relative paths before relocating the fragment; substitute only the two engines.
qip=hip.read_text();replaced=[];dependencies={str(hip):sha(hip)}
engines={Path(k).name:Path(v) for k,v in route['replacements'].items()
         if Path(k).name in ('altpcieav_dma_wr_readmem_2.sv','altpcieav_dma_wr_tlpgen_2.sv')}
assert len(engines)==2
pattern=r'\[file join \$::quartus\(qip_path\) "([^"\n]+)"\]'
def resolve(m):
 f=(hip.parent/m[1]).resolve();assert f.is_file(),f
 dependencies[str(f)]=sha(f)
 if f.name in engines:
  replaced.append(f.name);f=engines[f.name];assert str(f) in pins and sha(f)==pins[str(f)]
 dependencies[str(f)]=sha(f)
 assert not any(c in str(f) for c in '{}\n')
 return '{'+str(f)+'}'
qip=re.sub(pattern,resolve,qip);assert sorted(replaced)==sorted(engines)
assert '$::quartus(qip_path)' not in qip
out.mkdir(exist_ok=False)
(out/'hip.qip').write_text(qip)
lines=['set_global_assignment -name FAMILY {Arria 10}',
 'set_global_assignment -name DEVICE 10AX115S3F45E2SGE3',
 'set_global_assignment -name TOP_LEVEL_ENTITY platform_c126_hardware_io',
 'source {'+str(Path(next(f for f in binding['files'] if f.endswith('board_constraints.qsf'))))+'}',
 'set_global_assignment -name QIP_FILE {'+str(out/'hip.qip')+'}']
include_dir=Path(route['include']).resolve()
include_pins=json.loads(a.include_pins.read_text())
lines.append('set_global_assignment -name SEARCH_PATH {'+str(include_dir)+'}')
for f in include_dir.glob('*.svh'):
 assert str(f) in include_pins and sha(f)==include_pins[str(f)],f
 dependencies[str(f)]=sha(f)
for entry in route['extra']:
 if entry.startswith('+incdir+'):
  lines.append('set_global_assignment -name SEARCH_PATH {'+entry[len('+incdir+'):]+'}');continue
 f=Path(entry);assert str(f) in pins
 if f.name=='shell_identity_v2.sv':
  original=f.read_text()
  fixed,count=re.subn(r'(?m)^(  input  )logic',r'\1wire logic',original)
  assert count==14
  dependencies[str(f)]=sha(f)
  f=out/f.name;f.write_text(fixed)
 kind={'.sv':'SYSTEMVERILOG_FILE','.v':'VERILOG_FILE'}[f.suffix]
 lines.append('set_global_assignment -name '+kind+' {'+str(f)+'}');dependencies[str(f)]=sha(f)
for name in ('platform_c126_hardware_io.sv','c126_reset_release.sv'):
 f=shell/name;dependencies[str(f)]=sha(f)
 lines.append('set_global_assignment -name SYSTEMVERILOG_FILE {'+str(f)+'}')
(out/'platform.qsf').write_text('\n'.join(lines)+'\n')
rom=base/'sys_description.hex';assert str(rom) in pins and sha(rom)==pins[str(rom)]
(out/'sys_description.hex').write_bytes(rom.read_bytes());dependencies[str(rom)]=sha(rom)
(out/'platform.qpf').write_text('PROJECT_REVISION = "platform"\n')
(out/'result.json').write_text(json.dumps({'state':'prepared','source_pins':dependencies,'hip_engine_replacements':replaced,'native_elaboration':False,'physical_acceptance':False,'remaining':['physical health/reset producers','native combined elaboration','fit and all-corner timing']},indent=2)+'\n')
print('Prepared synthesis project with',len(dependencies),'pinned direct dependencies')
