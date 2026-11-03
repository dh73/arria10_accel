# Reset closure diagnostic

Isolated fitted-database inspection and before/after timing comparison for the
C126 memory example. The candidate scopes an external-reset exception to one
verified synchronous data pin. Hard-IP reset obligations remain unresolved.

The package contains a source-bound staging driver, pin/arc diagnostics, scoped
constraints, timing comparison, a soft-counter testbench and negative controls.
Twenty-two package checks pass. The unmodified generated soft calibration
counter and synchronizer pass a 37-edge RTL test covering sampled assertion and
deassertion, an ignored between-edge pulse, calibration completion and reset.
This validates deterministic sampling, not metastability or hard-IP reset safety.
Native timing validation remains pending.

Status outputs remain timed by default. Observation-only treatment is an
explicit mode and does not establish physical pin or board qualification.
