# Explicit pin comparison

Compare a candidate QSF against an independently selected reference:

```sh
python3 tools/c126/compare_pins.py \
  --candidate candidate.qsf --reference reference.qsf \
  --mapping port-map.json --output comparison.json
```

The optional JSON map pairs every candidate port with one distinct reference
port. Without it, names must match exactly. No mapping is inferred from equal
pins or similar names. Extra reference ports are reported separately.

Exit zero requires matching device names and every mapped package pin. Missing
ports, conflicts, duplicate assignments, dynamic expressions and unsupported
commands fail. Referenced files are listed but never evaluated; this is an
explicit-assignment comparison, not a complete project elaboration. Existing
reports are never overwritten.

Literal differential negative-leg suffixes, such as `refclk(n)` and
`clk[0](n)`, are retained as distinct port names. Swapped positive and negative
pins fail comparison; the tool does not normalize polarity.

Ten regression tests cover conflicts, omissions, duplicate mappings, device
mismatch, differential polarity, unsupported input and source-only acceptance. The retained C126 QSF
self-comparison reads 136 explicit pins; it supplies no independent reference.

```sh
PYTHONPATH=tools/c126 python3 -m unittest discover \
  -s tests/c126 -p test_compare_pins.py -v
```

Source agreement does not verify board revision, daughtercard routing, voltages,
memory geometry, clocks, reset timing or recovery. Those remain separate gates.
