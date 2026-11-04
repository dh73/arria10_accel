"""Carry kernel/shared read credits through the current physical hierarchy."""
from pathlib import Path
import argparse,hashlib,json,re
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',type=Path,required=True)
p.add_argument('--out',type=Path,required=True)
a=p.parse_args();source=a.source.resolve();out=a.out.resolve()
qsf=(source/'platform.qsf').read_text();paths=[Path(x) for x in re.findall(r'\{([^{}]+)\}',qsf)]
names=['platform_c126_hardware_io.sv','full_platform_kernel_control.sv','dma_memory_path_initialized_candidate.sv','dma_memory_path_unaligned_candidate.sv']
text={};original={};pins={}
for name in names:
 matches=[f for f in paths if f.name==name];assert len(matches)==1,(name,matches)
 f=matches[0];original[name]=f;text[name]=f.read_text();pins[str(f)]=hashlib.sha256(f.read_bytes()).hexdigest()
def edit(n,x,y):
 assert text[n].count(x)==1,(n,x)
 text[n]=text[n].replace(x,y)
e,c,i,m=names
edit(e,'module platform_c126_hardware_io #(\n','module platform_c126_hardware_io #(\n parameter int KERNEL_READ_DEPTH=64, SHARED_READ_DEPTH=64,\n')
edit(e,'dma_memory_path_initialized_candidate #(', 'dma_memory_path_initialized_candidate #(.SHARED_READ_DEPTH(SHARED_READ_DEPTH),')
edit(e,'full_platform_kernel_control #(\n','full_platform_kernel_control #(\n .KERNEL_READ_DEPTH(KERNEL_READ_DEPTH),\n')
edit(e,'arria10_dma_ddr_mux #(.READ_DEPTH(64)) byte_core_mux(', 'arria10_dma_ddr_mux #(.READ_DEPTH(SHARED_READ_DEPTH)) byte_core_mux(')
edit(c,'module full_platform_kernel_control #(\n','module full_platform_kernel_control #(\n parameter int KERNEL_READ_DEPTH=8,\n')
edit(c,'kernel_ddr_address_width_adapter #(', 'kernel_ddr_address_width_adapter #(.READ_DEPTH(KERNEL_READ_DEPTH),')
edit(i,'module dma_memory_path_initialized_candidate #(', 'module dma_memory_path_initialized_candidate #(parameter int SHARED_READ_DEPTH=8, ')
edit(i,'dma_memory_path_unaligned_candidate path (','dma_memory_path_unaligned_candidate #(.SHARED_READ_DEPTH(SHARED_READ_DEPTH)) path (')
edit(m,'module dma_memory_path_unaligned_candidate (','module dma_memory_path_unaligned_candidate #(parameter int SHARED_READ_DEPTH=8) (')
edit(m,'arria10_dma_ddr_mux owner_mux (','arria10_dma_ddr_mux #(.READ_DEPTH(SHARED_READ_DEPTH)) owner_mux (')
# Source/build identity must be regenerated after this source change.
assert 'PLATFORM_SOURCE_ID=0' in text[e] and 'PLATFORM_BUILD_ID=0' in text[e]
out.mkdir(exist_ok=False)
for n,t in text.items():
 (out/n).write_text(t);qsf=qsf.replace(str(original[n]),str(out/n))
(out/'platform.qsf').write_text(qsf)
(out/'result.json').write_text(json.dumps({'state':'prepared','source_pins':pins,'top_defaults':{'kernel':64,'shared':64},'physical_acceptance':False,'identity_rebinding_required':True},indent=2)+'\n')
