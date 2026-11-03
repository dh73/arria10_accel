# Components

The host executor serializes kernel launches and retains buffer ownership until
independent retirement evidence establishes that all accesses have finished.
The Linux driver provides descriptor batching, mapping lifetime management,
interrupt handling and fault containment.

The RTL connects DDR initialization, memory adaptation and platform supervision.
Tests cover host error paths, memory traffic, completion accounting and reset
behavior. Formal models describe ownership and accounting invariants.

`experiments/dma-status-v2` contains a finite-lifecycle DMA candidate. It remains
separate from the production driver and requires further integration work.
