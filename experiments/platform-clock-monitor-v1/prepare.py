"""Bind the qualified digital monitor into an isolated 150/50 MHz shell candidate."""
import argparse,json,hashlib
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--shell',type=Path,required=True)
p.add_argument('--qualification',type=Path,required=True)
p.add_argument('--out',type=Path,required=True)
a=p.parse_args()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
r=json.loads((a.qualification/'result.json').read_text());assert r['state']=='passed'
pins=json.loads((a.qualification/'sources.json').read_text())
for f,h in pins.items():assert sha(Path(f))==h,f
monitor=next(Path(f) for f in pins if Path(f).name=='reference_clock_monitor.sv')
s=a.shell.read_text()
old=' input wire ddr_external_reset_n,ddr_ref_clock_good,'
assert s.count(old)==1
s=s.replace(old,' input wire ddr_external_reset_n,\n output wire ddr_clock_fault,')
marker='wire ddr_global_reset_n;';assert s.count(marker)==1
s=s.replace(marker,'''// Digital cadence only: independent 50 MHz board clock and 150 MHz DDR
// reference are required. Board frequency/CDC/STA remain implementation gates.
wire ddr_ref_clock_good;
reference_clock_monitor #(.DIV_LOG2(6),.MIN_TICKS(9),.MAX_TICKS(13),
 .GOOD_INTERVALS(3)) ddr_clock_monitor(
 .ref_clk(ddr_ref_clk),.monitor_clk(board_pins_free_clk),
 .reset_n(ddr_external_reset_n),.qualified(ddr_ref_clock_good),.fault(ddr_clock_fault));
'''+marker)
a.out.mkdir(exist_ok=False)
(a.out/'platform_c126_hardware_io.sv').write_text(s)
(a.out/monitor.name).write_bytes(monitor.read_bytes())
(a.out/'result.json').write_text(json.dumps({'state':'prepared','inputs':{str(a.shell.resolve()):sha(a.shell),str(monitor):sha(monitor)},'outputs':{f.name:sha(f) for f in a.out.glob('*.sv')},'physical_acceptance':False,'remaining':['physical 150/50 MHz frequency and independent-clock qualification','monitor CDC constraints and reset recovery/removal','full platform reset containment and health producers','combined elaboration fit timing']},indent=2)+'\n')
