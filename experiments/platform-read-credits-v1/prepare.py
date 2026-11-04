"""Expose separate kernel and shared read credits in an isolated source candidate.
Defaults remain eight. No compile, job launch, or acceptance is implied.
"""
from pathlib import Path
import hashlib,json,sys
source=Path(sys.argv[1]).resolve();out=Path(sys.argv[2]).resolve()
pins=json.loads((source/'sources.json').read_text())
names=['pcie_ed_platform.v','full_platform_kernel_control.sv',
       'dma_memory_path_initialized_candidate.sv','dma_memory_path_unaligned_candidate.sv']
texts={};inputs={}
for name in names:
 matches=[source/name] if str(source/name) in pins else [Path(p) for p in pins if Path(p).name==name]
 assert len(matches)==1,(name,matches)
 p=matches[0];raw=p.read_bytes();assert hashlib.sha256(raw).hexdigest()==pins[str(p)]
 texts[name]=raw.decode();inputs[str(p)]=pins[str(p)]
def edit(name,a,b):
 assert texts[name].count(a)==1,(name,a)
 texts[name]=texts[name].replace(a,b)
e='pcie_ed_platform.v';c='full_platform_kernel_control.sv'
i='dma_memory_path_initialized_candidate.sv';m='dma_memory_path_unaligned_candidate.sv'
edit(e,'module pcie_ed #(\n','module pcie_ed #(\n parameter int KERNEL_READ_DEPTH=8, SHARED_READ_DEPTH=8,\n')
edit(e,'dma_memory_path_initialized_candidate #(',
     'dma_memory_path_initialized_candidate #(.SHARED_READ_DEPTH(SHARED_READ_DEPTH),')
edit(e,'full_platform_kernel_control #(\n',
     'full_platform_kernel_control #(\n .KERNEL_READ_DEPTH(KERNEL_READ_DEPTH),\n')
edit(c,'module full_platform_kernel_control #(\n',
     'module full_platform_kernel_control #(\n parameter int KERNEL_READ_DEPTH=8,\n')
edit(c,'kernel_ddr_address_width_adapter #(',
     'kernel_ddr_address_width_adapter #(.READ_DEPTH(KERNEL_READ_DEPTH),')
edit(i,'module dma_memory_path_initialized_candidate #(',
     'module dma_memory_path_initialized_candidate #(parameter int SHARED_READ_DEPTH=8, ')
edit(i,'dma_memory_path_unaligned_candidate path (',
     'dma_memory_path_unaligned_candidate #(.SHARED_READ_DEPTH(SHARED_READ_DEPTH)) path (')
edit(m,'module dma_memory_path_unaligned_candidate (',
     'module dma_memory_path_unaligned_candidate #(parameter int SHARED_READ_DEPTH=8) (')
edit(m,'arria10_dma_ddr_mux owner_mux (',
     'arria10_dma_ddr_mux #(.READ_DEPTH(SHARED_READ_DEPTH)) owner_mux (')
out.mkdir(exist_ok=False,parents=True)
for name,text in texts.items():(out/name).write_text(text)
(out/'manifest.json').write_text(json.dumps({'source_sha256':inputs,
 'output_sha256':{n:hashlib.sha256((out/n).read_bytes()).hexdigest() for n in names},
 'defaults':{'kernel_read_depth':8,'shared_read_depth':8},
 'native_elaboration':False,'physical_acceptance':False},indent=2)+'\n')
print('Prepared kernel and shared credits through four source levels; defaults unchanged.')
