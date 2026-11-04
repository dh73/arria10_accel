# DMA status reset guard

Invalidates coherent DMA-status snapshots when the producer resets. After the
producer has been armed, reset history remains latched until common cold reset;
restarted counters cannot certify that earlier work drained.

`dma_status_reset_guard.sv` wraps
`../full-platform-native-v2/dma_custody_status_cdc.sv`. `tb.sv` covers startup,
short reset pulses, a stopped destination clock, retained invalidation, and
common-reset recovery. `../../formal/lean/DmaStatusResetGuard.lean` proves the
corresponding event-model retention invariant.

Hardware integration must supply the real producer reset, meet asynchronous
clear pulse-width requirements, and constrain the CDC paths. Common reset
requires externally coordinated epoch recovery. This guard does not establish
whole-platform reset containment or transaction settlement.
