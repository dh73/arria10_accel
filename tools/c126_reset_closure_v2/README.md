# Reset closure diagnostic

Isolated fitted-database inspection and before/after timing comparison for the
C126 memory example. The candidate scopes an external-reset exception to one
verified synchronous data pin. Hard-IP reset obligations remain unresolved.

The package contains a source-bound staging driver, pin/arc diagnostics, scoped
constraints, timing comparison, a soft-counter testbench and negative controls.
Twenty-six package checks pass. The unmodified generated soft calibration
counter and synchronizer pass a 37-edge RTL test covering sampled assertion and
deassertion, an ignored between-edge pulse, calibration completion and reset.
This validates deterministic sampling, not metastability or hard-IP reset safety.
Baseline diagnostics and retained internal/DDR checks pass across four timing
corners after report-database alignment and signed-budget parsing. No candidate
constraint has yet passed the before/after comparison; overall closure remains
open. Signed budget contributions are parsed separately from final margins and
path slacks, which must remain nonnegative.

## Fitted reset connectivity

The retained fitted-netlist diagnostic resolves all 22 assessment endpoints in
17 cells, with matching assessment clocks. Tracing enabled edges from the
external reset reaches these endpoint classes:

| Endpoints | Primitive | Entry pin | Final timing-model arc |
| --- | --- | --- | --- |
| 12 PHY registers | `twentynm_io_12_lane` | `reset_n` | Asynchronous |
| 6 controller registers | `twentynm_tile_ctrl` | `global_reset_n` | Asynchronous |
| 3 auxiliary registers | `twentynm_io_aux` | `core_usr_reset_n` | Asynchronous |
| 1 soft synchronizer stage | `twentynm_ff` | `asdata` | Synchronous |

The auxiliary JTAG register has no observed clock. The other endpoints retain
their distinct reference, PHY and calibration clocks. These are timing-model
observations, not an internal hard-IP synchronization guarantee. Keep the 21
hard-IP recovery/removal obligations open until their release contract is
established; the soft-stage exception must not expand to them.

Status outputs remain timed by default. Observation-only treatment is an
explicit mode and does not establish physical pin or board qualification.
