# Kernel closure protocol composition

The actual C sequencer drives the closure mailbox through a simulation bridge.
Two successive rounds, a stale round, and uncertain completion at all 30 I/O
boundaries pass without replay. The mailbox test also checks malformed writes
and context faults.

This validates protocol composition, not the PCIe transport or physical device.
