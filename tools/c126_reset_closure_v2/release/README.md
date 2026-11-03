# Conditional reset release

A three-stage reference-clock synchronizer followed by a configurable hold
interval. Assertion propagates asynchronously; release occurs after N+3
qualified rising edges. Release defaults disabled and the hold duration has no
board-specific default. A missing duration fails simulation and holds reset in
synthesis.

The reference clock must run independently of memory reset. An external monitor
must lower `ref_clock_good` on clock loss; this circuit cannot detect a stopped
clock by itself. Input pulse widths, physical synchronizer behavior, power-on
reset and every receiving hard-IP domain require separate qualification.

The deterministic model's base, step and reachable-state theorem pass Lean
4.19.0 without unproved axioms. The RTL fixture passes 71 checks over 63 clock
edges, including interrupted release, stopped-clock assertion and clock-good
loss. The invalid-duration fixture fails at time zero as intended. These results
do not establish model-to-RTL equivalence, metastability behavior or hard-IP
reset safety. The module is not connected to the board design.

```sh
python3 tools/c126_reset_closure_v2/release/run_release_tests.py \
  --work /new/output/directory --vcs /path/to/vcs --lean /path/to/lean
```

Use `--only lean` or `--only vcs` for an independent validation. The runner
checks native diagnostics as well as exit codes: this simulator may return zero
after the expected negative-control fatal. No additional timing exception is
included with this module.
