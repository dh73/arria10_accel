"""Compose qualified write retirement into an isolated v5 configured hierarchy."""
import argparse
import hashlib
import json
from pathlib import Path
from build import build_controller, build_tx, once

PINS = {'dma_control_fetch_return_v5.sv': 'df49c63cf397c5023f67b66c030fae71dda4d0683ddb6da8da94c3f9106fcd00', 'c10_fetch_parent_return_v5.sv': '7b5a6490a18d150f4f8d867294e8b953b3b8872824414b8c129dd0b194e173fa', 'c10_configured_fetch_return_v5.sv': 'dd671d6699c7f26fe1154d54ddbe02daf94cc18935753dad2737505073c9656b', 'altpcie_dynamic_control_write_v4.sv': '019de60946a09d16053a8cf15148a5fcbea700b1f4c9c44fd12e0485cbdabd65', 'controller_tx_v4.svh': 'dd0291be6e02508db0243112552451de33bc4d82a08487c60f8bd10a0a851fa1'}
D2H_PINS = {'altpcieav_dma_wr_readmem_2.sv': '5a6eb7dc706e78098481b7c5e11b77460c580831ba6ab2f8b9cca13626adbadd', 'altpcieav_dma_wr_tlpgen_2.sv': '80d6d7e596455e6aa7fe67799e6b1d73c605026208fe76a3c1524833e42189c3'}
PORTS = """output wire CandidateWrRetireFault_o,
output wire [31:0] CandidateWrRetireFaultData_o,
output wire [7:0] CandidateWrRetireExpectedId_o,
output wire CandidateWrRetireBusy_o,
"""
CONNECTIONS = """.CandidateWrRetireFault_o(CandidateWrRetireFault_o),
.CandidateWrRetireFaultData_o(CandidateWrRetireFaultData_o),
.CandidateWrRetireExpectedId_o(CandidateWrRetireExpectedId_o),
.CandidateWrRetireBusy_o(CandidateWrRetireBusy_o),
"""
def checked(path, digest):
    raw=path.read_bytes()
    if hashlib.sha256(raw).hexdigest()!=digest:
        raise ValueError('source pin mismatch: '+str(path))
    return raw

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--fetch-generated',type=Path,required=True)
    p.add_argument('--d2h-generated',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True)
    a=p.parse_args()
    src={n:checked(a.fetch_generated/n,h) for n,h in PINS.items()}
    native={n:checked(a.d2h_generated/n,h) for n,h in D2H_PINS.items()}
    data={p.name:p.read_bytes() for p in a.fetch_generated.iterdir() if p.is_file()}
    for name in list(PINS)[:3]:
        text=src[name].decode()
        text=once(text,'output wire CandidateFetchFault_o,',PORTS+'output wire CandidateFetchFault_o,')
        if name!='dma_control_fetch_return_v5.sv':
            text=once(text,'.CandidateFetchFault_o(CandidateFetchFault_o),',CONNECTIONS+'.CandidateFetchFault_o(CandidateFetchFault_o),')
        else:
            text=once(text,'altpcie_dynamic_control_write_v4 #','altpcie_dynamic_control_write_d2h_v1 #')
            text=once(text,') write_control            (',') write_control            (\n.RetireFault_o(CandidateWrRetireFault_o),\n.RetireFaultData_o(CandidateWrRetireFaultData_o),\n.RetireExpectedId_o(CandidateWrRetireExpectedId_o),\n.RetireBusy_o(CandidateWrRetireBusy_o),')
        if name=='c10_fetch_parent_return_v5.sv':
            text=once(text,'.AvWrDmaRxValid_i               (dma_control_0_wrdma_tx_valid               ),','.AvWrDmaRxValid_i               (dma_control_0_wrdma_tx_valid && dma_control_0_wrdma_tx_ready),')
        data[name]=text.encode()
    data['altpcie_dynamic_control_write_d2h_v1.sv']=build_controller(src['altpcie_dynamic_control_write_v4.sv']).replace(b'"controller_tx_v4.svh"',b'"controller_tx_d2h_v1.svh"')
    data['controller_tx_d2h_v1.svh']=build_tx(src['controller_tx_v4.svh'])
    data['controller_retirement_v1.svh']=Path(__file__).with_name('controller_retirement_v1.svh').read_bytes()
    data.update(native)
    a.out.mkdir(parents=True,exist_ok=False)
    for name,raw in data.items(): (a.out/name).write_bytes(raw)
    (a.out/'d2h-integration.json').write_text(json.dumps({'fetch_inputs':PINS,'d2h_inputs':D2H_PINS,'outputs':{n:hashlib.sha256(v).hexdigest() for n,v in data.items()},'physical_acceptance':False,'simulation_acceptance':False},indent=2)+'\n')
if __name__=='__main__': main()
