"""Internalize domain validity only; retain externally settled cold reset/containment."""
import argparse,hashlib,json
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--shell',required=True,type=Path)
p.add_argument('--out',required=True,type=Path)
a=p.parse_args()
s=a.shell.read_text()
old=' input wire platform_health_valid,platform_reset_containment_valid,'
assert s.count(old)==1
s=s.replace(old,' input wire platform_reset_containment_valid,')
faults=['.shared_mux_fault(sim_mux_fault || sim_fault)',
        '.shared_mux_fault(sim_mux_fault || sim_fault || byte_mux_fault)']
selected=[f for f in faults if s.count(f)==1]
assert len(selected)==1
fault=selected[0]
s=s.replace(fault,fault[:-1]+' || platform_health_epoch_lost)')
marker='full_platform_kernel_control #('
assert s.count(marker)==1
for signal in ['emif_user_clk','emif_user_reset_n','dut_app_nreset_status_reset','ddr_ref_clock_good','common_cold_reset_n']:
 assert signal in s,signal
s=s.replace(marker,'''// Valid health snapshot epoch; errors remain visible through supervisor status.
wire platform_health_valid;
wire platform_health_epoch_lost;
platform_domain_health health_producer(
 .kernel_clk(emif_user_clk),.common_cold_reset_n(common_cold_reset_n),
 .hip_reset_n(dut_app_nreset_status_reset),.backend_reset_n(emif_user_reset_n),
 .ref_clock_good(ddr_ref_clock_good),.health_valid(platform_health_valid),
 .epoch_lost(platform_health_epoch_lost));
'''+marker)
a.out.mkdir(parents=True,exist_ok=False)
(a.out/'platform_c126_hardware_io.sv').write_text(s)
module=Path(__file__).with_name('platform_domain_health.sv')
(a.out/module.name).write_bytes(module.read_bytes())
def sha(f):return hashlib.sha256(f.read_bytes()).hexdigest()
(a.out/'result.json').write_text(json.dumps({'state':'prepared','inputs':{str(f.resolve()):sha(f) for f in [a.shell,module]},'outputs':{f.name:sha(f) for f in a.out.glob('*.sv')},'physical_acceptance':False,'remaining_external_inputs':['common_cold_reset_n: externally settled epoch','platform_reset_containment_valid: host transaction/reset guarantee','ddr_external_reset_n: board reset binding','ddr_ref_clock_good: independently qualified reference']},indent=2)+'\n')
