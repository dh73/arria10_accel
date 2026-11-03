# Reset closure diagnostic

Isolated fitted-database inspection and before/after timing comparison for the
C126 memory example. The candidate scopes an external-reset exception to one
verified synchronous data pin. Hard-IP reset obligations remain unresolved.

The package contains a source-bound staging driver, pin/arc diagnostics, scoped
constraints, timing comparison, a soft-counter testbench and negative controls.
Thirty-two package checks pass. The unmodified generated soft calibration
counter and synchronizer pass a 37-edge RTL test covering sampled assertion and
deassertion, an ignored between-edge pulse, calibration completion and reset.
This validates deterministic sampling, not metastability or hard-IP reset safety.
Baseline diagnostics and retained internal/DDR checks pass across four timing
corners after report-database alignment and signed-budget parsing. The soft-stage candidate passes the before/after comparison at all four
corners: reset endpoints decrease from 22 to 21, while all 1,029 status paths
remain timed. The 21 hard-IP reset contracts and overall closure remain open. Signed budget contributions are parsed separately from final margins and
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

## External hard-reset checks

The collector now records external-input recovery/removal paths for the 21
hard-IP endpoints, checking their entry pins, primitive types, clocks and live
asynchronous arcs. All 21 identities match the captured fitted reset graph.
The assessor requires the returned worst-path matrix to remain identical
before and after the soft-stage exception. Empty path lists and positive slack
do not establish the reset-release contract.

`sta --require-hard-reset-closure` saves the assessment and returns failure
while those contracts remain unresolved. The added collector has local checker
coverage but has not yet run in native timing analysis; the earlier four-corner
soft-stage result does not qualify this additional capture. The signed DDR
budget parser, report-database alignment and canonical pin identity checks
remain intact. No additional timing exception is installed.
