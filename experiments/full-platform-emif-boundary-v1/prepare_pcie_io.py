"""Carry explicit PCIe electrical assignments onto previously matched pins.
No global voltage default, DDR override, timing exception or physical approval.
"""
from pathlib import Path
import hashlib,json,shlex,sys
manifest,out=map(Path,sys.argv[1:])
r=json.loads(manifest.read_text());sources=r['sources']
for f,h in sources.items():
    assert hashlib.sha256(Path(f).read_bytes()).hexdigest()==h,f
provenance=r['provenance'];selected={}
for target,info in provenance.items():
    if 'crosscheck' not in info:continue
    p=Path(info['crosscheck'])
    for line in p.read_text().splitlines():
        if not line.startswith("set_instance_assignment -name IO_STANDARD "):continue
        w=shlex.split(line)
        if len(w)==6 and w[:3]==['set_instance_assignment','-name','IO_STANDARD'] and w[4]=='-to' and w[5]==target:
            assert target not in selected,target
            selected[target]={'standard':w[3],'source':str(p),'pin':r['pins'][target]}
expected={'refclk_clk','pcie_rstn_pin_perst'}|{f'xcvr_{direction}_{kind}{lane}' for direction,kind in [('rx','in'),('tx','out')] for lane in range(8)}
assert set(selected)==expected,(set(selected),expected)
out.mkdir(exist_ok=False)
(out/'pcie_io.qsf').write_text(''.join('set_instance_assignment -name IO_STANDARD {'+v['standard']+'} -to {'+p+'}\n' for p,v in sorted(selected.items())))
(out/'result.json').write_text(json.dumps({'state':'prepared','physical_acceptance':False,'assignments':selected,'source_hashes':sources,'input_manifest_sha256':hashlib.sha256(manifest.read_bytes()).hexdigest(),'output_sha256':hashlib.sha256((out/'pcie_io.qsf').read_bytes()).hexdigest(),'remaining':['DDR IP electrical constraints','board reset and free-running clock selection','bank and all-corner combined implementation checks']},indent=2)+'\n')
print('Prepared',len(selected),'PCIe electrical assignments on matched package pins')
