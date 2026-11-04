"""Bind shell stop to epoch loss and retain diagnostics until cold reset."""
import argparse
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',required=True,type=Path)
p.add_argument('--out',required=True,type=Path)
a=p.parse_args();src=a.source.resolve();out=a.out.resolve()
top=src/'platform_c126_hardware_io.sv';text=top.read_text()
if 'PLATFORM_SOURCE_ID=0' not in text or 'PLATFORM_BUILD_ID=0' not in text:
 raise ValueError('Rebind identities after preparing an unbound template')
ports=' input wire platform_external_stop,platform_clear_valid,\n input wire [15:0] platform_clear_mask,\n'
anchor='wire platform_health_epoch_lost;'
if text.count(ports)!=1 or text.count(anchor)!=1:raise ValueError('Unexpected control declarations')
text=text.replace(ports,'').replace(anchor,anchor+'''
// BAR2 QUIESCE remains the host stop path. Epoch loss independently stops work.
wire platform_external_stop=platform_health_epoch_lost;
// Preserve fault-pending diagnostics until coordinated cold reset.
wire platform_clear_valid=1'b0;
wire [15:0] platform_clear_mask=16'b0;''')
qtext=(src/'platform.qsf').read_text()
if qtext.count(str(top))!=1:raise ValueError('Ambiguous shell source')
out.mkdir(exist_ok=False)
(out/top.name).write_text(text)
(out/'platform.qsf').write_text(qtext.replace(str(top),str(out/top.name)))
