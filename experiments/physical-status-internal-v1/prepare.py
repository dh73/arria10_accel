"""Keep platform status inside the fabric and select the board indicators."""
import argparse
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',required=True,type=Path)
p.add_argument('--out',required=True,type=Path)
a=p.parse_args()
src=a.source.resolve(); out=a.out.resolve()
top=src/'platform_c126_hardware_io.sv'
text=top.read_text()
if 'PLATFORM_SOURCE_ID=0' not in text or 'PLATFORM_BUILD_ID=0' not in text:
    raise ValueError('Use an unbound source template; regenerate identity after preparation')
status=''' output wire platform_release_ready,platform_fault,platform_fence_ready,platform_fence_fault,
 output wire platform_writeback_drained,platform_cmd_ready,platform_cmd_done,platform_cmd_accepted,
 output wire [3:0] platform_cmd_reason,
 output wire [2:0] platform_state,platform_phase,
 output wire [15:0] platform_fault_history,
 output wire platform_launch_owned,platform_write_pending,platform_kernel_idle,platform_kernel_stop_ack,
'''
clock_fault=' output wire ddr_clock_fault,\n'
anchor="wire [31:0] hip_ctrl_test_in = '0;"
for value in (status,clock_fault,anchor):
    if text.count(value)!=1: raise ValueError('Unexpected physical shell declaration')
wires='\n'.join(line.replace(' output wire','wire').rstrip(',')+';' for line in status.splitlines())
text=text.replace(status,'').replace(clock_fault,'').replace(anchor,'wire ddr_clock_fault;\n'+wires+'\n'+anchor)
# Control/reset inputs and all instantiated connections remain unchanged.
qtext=(src/'platform.qsf').read_text()
if qtext.count(str(top))!=1: raise ValueError('Ambiguous top source assignment')
indicators=Path(__file__).resolve().parents[2]/'constraints/es3_pcie_indicators.qsf'
if str(indicators) in qtext: raise ValueError('Indicator constraints already selected')
qtext=qtext.replace(str(top),str(out/top.name))+'\nsource {'+str(indicators)+'}\n'
out.mkdir(exist_ok=False)
(out/top.name).write_text(text)
(out/'platform.qsf').write_text(qtext)
