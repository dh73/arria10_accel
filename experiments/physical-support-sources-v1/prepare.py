"""Select generated synthesis support without replacing the platform or HIP."""
from pathlib import Path
import argparse,hashlib,json,re
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--example',type=Path,required=True)
p.add_argument('--out',type=Path,required=True)
a=p.parse_args();base=a.example.resolve();out=a.out.resolve()
qips=[base/'pcie_ed/pcie_ed.qip',base/'ip/pcie_ed/pcie_ed_DK/pcie_ed_DK.qip',base/'ip/pcie_ed/pcie_ed_MEM/pcie_ed_MEM.qip']
lines=[];pins={};excluded=[];names=[]
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
for qip in qips:
 pins[str(qip)]=sha(qip)
 for line in qip.read_text().splitlines():
  if not re.search(r'-name (?:SYSTEMVERILOG|VERILOG|VHDL|SDC|HEX|MIF)_FILE\b',line):continue
  m=re.search(r'\[file join \$::quartus\(qip_path\) "([^"\n]+)"\]',line)
  assert m,(qip,line)
  f=(qip.parent/m[1]).resolve();assert f.is_file(),f
  if f==base/'pcie_ed/synth/pcie_ed.v':excluded.append(str(f));continue
  assert '/synth/' in str(f) or f.suffix in ['.hex','.mif'],f
  assert 'pcie_ed_DUT' not in str(f),f
  pins[str(f)]=sha(f);names.append(f.name)
  lines.append(line[:m.start()]+'{'+str(f)+'}'+line[m.end():])
assert len(excluded)==1
for name in ['pcie_ed_DK.v','pcie_ed_MEM.v','pcie_ed_altera_mm_interconnect_1920_tjuiyhq.v','pcie_ed_altera_mm_interconnect_1920_gr7o7pi.v','pcie_ed_altera_mm_interconnect_1920_a7gai3y.v','altera_reset_controller.v']:
 assert name in names,name
out.mkdir(exist_ok=False)
(out/'support.qip').write_text('\n'.join(lines)+'\n')
(out/'result.json').write_text(json.dumps({'state':'prepared','source_pins':pins,'excluded_top':excluded,'selected_assignments':len(lines),'physical_acceptance':False},indent=2)+'\n')
print('SUPPORT_SOURCE_PREPARED',len(lines))
