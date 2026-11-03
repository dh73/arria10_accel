# Width-parametric DDR adapter candidate

The source-pinned transformation retains the existing single-beat, ordered
adapter protocol and extends its data/byte-enable storage and lane mapping to
64, 128, 256 or 512 bits. Requests must align to their port width and remain
inside the 2 GiB payload aperture. No cache or cross-client coalescing is added.
A full-width request can use all 64 backend bytes; the existing scalar compiled
kernel still has a 64-bit port and receives no automatic bandwidth increase.

`formal/WidthBounds.lean` has nine checked arithmetic obligations: supported
width positivity, lane/byte containment, line address range, aperture end bound,
address reconstruction, and byte-cursor initialization/step/address safety.
These are not RTL refinement or a replacement for native behavioral tests.

The native qualification uses the existing scalar regression at three queue
depths and a byte oracle at all four widths, with sustained and stalled streams.
It measures accepted commands, enabled bytes and transported line bytes.
All three scalar regressions and sixteen width/read/write/stall streams pass.
Each unstalled stream completes 257 commands in 258 cycles. The 512-bit case
transports 16,448 line bytes and enables 10,976 bytes under the mixed-mask
workload. This establishes command throughput in the zero-latency backend
fixture, not full-mask peak bandwidth. No physical throughput or compiler-wide-port
support is established. Mixed traffic, per-response wide ECC testing, compiler-port binding,
CDC/timing, real memory arbitration and hardware measurements remain required.

## Reproduce a width test

Use a fresh output directory and the pinned original adapter. Set `WIDTH` to
64, 128, 256 or 512; supply the installed compiler and simulation launcher.

```sh
mkdir "$OUT"
python3 experiments/kernel-width-v1/build.py --source rtl/kernel_ddr_adapter.sv --out "$OUT/adapter.sv"
"$RTL_COMPILER" -full64 -sverilog -timescale=1ns/1ps +define+KERNEL_DDR_ASSERTIONS -top width_tb -pvalue+width_tb.W="$WIDTH" "$OUT/adapter.sv" experiments/kernel-width-v1/tb.sv -Mdir="$OUT/csrc" -o "$OUT/simv"
"$RTL_RUNNER" "$OUT/simv" -no_save
"$LEAN_419" experiments/kernel-width-v1/formal/WidthBounds.lean
```

Require the exact `WIDTH_ADAPTER_PASS width=...` line and reject native fatal
or error diagnostics even when the executable exits zero. The byte oracle checks
command ordering, every enabled write byte, read data and line byte enables.
The scalar regression additionally checks retained faults, zero-latency replies,
queue wrap, simultaneous push/pop, quiesce, stalls and coordinated reset.

## Delayed-response and fault stress

`stress_tb.sv` passes at all four widths with three-cycle ordered read replies,
full byte enables, and independent command/byte oracles. Each unstalled stream
completes 257 writes in 258 cycles or 257 reads in 261 cycles, including fill and
drain. At 512 bits all 16,448 transported bytes are enabled. These fixture
measurements do not establish physical memory latency or achievable clock rate.

The same runs check a stalled write remains held through quiesce and a backend
ECC interrupt, drains exactly once after acceptance, retains the sticky fault,
and rejects a misaligned request with its address context after coordinated reset.
Per-response ECC, mixed traffic and physical reset behavior remain separate gates.
Use the reproduction command above with top `width_stress_tb`, parameter
`width_stress_tb.W`, and `stress_tb.sv`; require `WIDTH_STRESS_PASS width=...`.
