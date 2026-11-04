"""Bind the retained C126 reset conditioner into an isolated hardware shell.

Clock-good remains an explicit independently qualified input. This integration
neither certifies clock monitoring nor the whole-platform reset epoch contract.
"""
from pathlib import Path
import argparse
import hashlib
import json

p = argparse.ArgumentParser()
p.add_argument('--shell', type=Path, required=True)
p.add_argument('--conditioner', type=Path, required=True)
p.add_argument('--out', type=Path, required=True)
p.add_argument('--hold-ref-cycles', type=int, required=True)
a = p.parse_args()
if a.hold_ref_cycles < 1:
    p.error('hold-ref-cycles must be positive and externally justified')
s = a.shell.read_text()
old = ' input wire  ddr_global_reset_n,'
assert s.count(old) == 1, 'expected exact external EMIF reset interface'
assert s.count('.global_reset_n(ddr_global_reset_n)') == 1
assert 'module c126_reset_release #' in a.conditioner.read_text()
# Do not consume or replace the independent common-cold-reset/epoch contract.
for port in ['common_cold_reset_n', 'platform_reset_containment_valid',
             'platform_health_valid']:
    assert port in s
s = s.replace(old, ' input wire ddr_external_reset_n,ddr_ref_clock_good,')
marker = 'wire  emif_cal_success;'
assert s.count(marker) == 1
binding = f'''// Clock qualification is external; never infer it from EMIF calibration.
wire ddr_global_reset_n;
c126_reset_release #(.ALLOW_RELEASE(1'b1),
 .HOLD_REF_CYCLES({a.hold_ref_cycles})) platform_ddr_release(
 .ref_clk(ddr_ref_clk),.external_reset_n(ddr_external_reset_n),
 .ref_clock_good(ddr_ref_clock_good),.global_reset_n(ddr_global_reset_n));
'''
s = s.replace(marker, binding + marker)
a.out.mkdir(parents=True, exist_ok=False)
(a.out / 'platform_c126_hardware_io.sv').write_text(s)
(a.out / 'c126_reset_release.sv').write_bytes(a.conditioner.read_bytes())
def sha(f): return hashlib.sha256(f.read_bytes()).hexdigest()
(a.out / 'result.json').write_text(json.dumps({
    'state': 'prepared', 'inputs': {str(f.resolve()): sha(f) for f in
                                  [a.shell, a.conditioner]},
    'outputs': {f.name: sha(f) for f in a.out.glob('*.sv')},
    'hold_ref_cycles': a.hold_ref_cycles,
    'native_elaboration': False, 'physical_acceptance': False,
    'remaining': ['independent ref-clock-good producer and board binding',
                  'combined-shell exact reset-path constraints and all-corner STA',
                  'whole-platform reset containment and epoch recovery']
}, indent=2) + '\n')
