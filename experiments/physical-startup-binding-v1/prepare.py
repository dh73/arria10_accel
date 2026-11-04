"""Bind the configuration-only hold into an isolated DDR startup candidate."""
import argparse,hashlib,json
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',type=Path,required=True)
p.add_argument('--hold-source',type=Path,required=True)
p.add_argument('--out',type=Path,required=True)
a=p.parse_args();root=Path(__file__).resolve().parents[2]
src=a.source.resolve();out=a.out.resolve();hold=a.hold_source.resolve()
top=src/'platform_c126_hardware_io.sv';qsf=src/'platform.qsf'
text=top.read_text()
marker=' input wire ddr_external_reset_n,\n'
assert text.count(marker)==1
text=text.replace(marker,'')
marker='wire ddr_ref_clock_good;'
assert text.count(marker)==1
text=text.replace(marker,'''// Configuration-only bootstrap. Runtime epoch recovery is separate.
wire ddr_external_reset_n;
configuration_startup_hold #(.HOLD_CYCLES(41503)) configuration_hold(
 .clk(board_pins_free_clk),.hold_complete(ddr_external_reset_n));
'''+marker)
assert 'PLATFORM_SOURCE_ID=0' in text and 'PLATFORM_BUILD_ID=0' in text
settings=root/'constraints/es3_configuration_startup.qsf'
qtext=qsf.read_text().replace(str(top),str(out/top.name))
qtext+='\nset_global_assignment -name SYSTEMVERILOG_FILE {'+str(out/hold.name)+'}\n'
qtext+='source {'+str(settings)+'}\n'
out.mkdir(exist_ok=False)
(out/top.name).write_text(text);(out/hold.name).write_bytes(hold.read_bytes())
(out/'platform.qsf').write_text(qtext)
pins={str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in [top,qsf,hold,settings]}
(out/'result.json').write_text(json.dumps({'state':'prepared','inputs':pins,'hold_cycles':41503,'runtime_recovery_implemented':False,'identity_rebinding_required':True,'physical_acceptance':False},indent=2)+'\n')
