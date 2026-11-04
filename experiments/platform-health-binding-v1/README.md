# Kernel-domain health binding

The qualifier generates snapshot validity from synchronized common-reset release.
It does not infer DDR readiness. After all monitored domains are released, it
retains HIP reset, backend reset or reference-clock loss, including pulses while
the user clock is stopped. The binding feeds this fault into the supervisor.
Calibration, ECC, initialization and containment keep their independent gates.

The component test covers startup, each domain loss, stopped-clock pulses and
cold recovery. Combined timing and physical containment remain unqualified.
The existing control layer can still invalidate aggregate diagnostics after HIP
reset; this component does not resolve that separate diagnostic-access gap.

`prepare.py --shell SOURCE --out NEW_DIRECTORY` supports the conditioned shell
with or without the byte-readback route. It preserves external cold-epoch
settlement, reset containment, board reset and reference-clock qualification.
