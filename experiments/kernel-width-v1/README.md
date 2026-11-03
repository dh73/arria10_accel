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
support is established. Mixed traffic, wide error/quiesce stress, compiler-port binding,
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
