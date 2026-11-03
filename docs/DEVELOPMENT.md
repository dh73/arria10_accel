# Components

The host executor serializes kernel launches and retains buffer ownership until
independent retirement evidence establishes that all accesses have finished.
The Linux driver provides descriptor batching, mapping lifetime management,
interrupt handling and fault containment.

DMA admission checks the complete request against an image-qualified memory
aperture before register access or page pinning. Unknown capacity denies all
requests. `formal/lean/DmaRange.lean` proves subrange containment and the base
and step obligations for bounded cursor advancement; the batch builder must
still establish that each descriptor lies within its admitted request.
The PIO global-memory and raw memory-window paths enforce the same aperture,
including aligned segment-register writes and partially populated final windows.
Capacity changes require closed admission and the device semaphore followed by
the DMA lock. These checks do not establish the attached image's actual capacity.

The RTL connects DDR initialization, memory adaptation and platform supervision.
Tests cover host error paths, memory traffic, completion accounting and reset
behavior. Formal models describe ownership and accounting invariants.

`experiments/dma-status-v2` contains a finite-lifecycle DMA candidate. It remains
separate from the production driver and requires further integration work.
