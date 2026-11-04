# Host-assisted writeback fence

One fence per coordinated cold-reset epoch. The driver reads READY through an
ordered, non-relaxed MMIO transaction, echoes the captured session/epoch, then
commits. Local producer and TX drain must remain asserted throughout; any later
debt or context change invalidates settlement and latches a fault.

| Byte offset | Read | Write |
|---|---|---|
| 0 | READY bit 0, SETTLED bit 1, FAULT bit 2 | Invalid |
| 4–24 | Six context DWORDs, least significant first: epoch then session | Echo corresponding DWORD |
| 28 | Invalid | Commit `0xa10f0001` after all six echoes |

All accesses require four byte enables and DWORD alignment. Commit before the
READY read, partial/stale echoes and malformed accesses fail closed. The driver
must retain exclusive context ownership; reset requires a fresh context and
independent containment of old DMA.

The component test passes valid acknowledgement and rejects late producer work,
missing READY read, partial echo, stale epoch and context changes. Actual BAR2,
driver and transport ordering integration remain unqualified. This module cannot
establish ordering from a synthetic read stimulus or local FIFO emptiness.
