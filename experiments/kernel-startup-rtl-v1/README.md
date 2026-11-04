# Kernel startup composition

The C startup sequencer provisions context, settles the initial writeback fence,
and submits START through the BAR2/CDC platform-control testbench. The bridge
uses the testbench's `startup_get` and `startup_put` tasks.

Four reset-separated startup epochs pass with context-loss and drain checks.
This is RTL composition evidence; device admission and physical operation remain
separate requirements.
