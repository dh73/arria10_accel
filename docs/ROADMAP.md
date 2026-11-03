# Implementation roadmap

1. Qualify exact ES3/P12-27065R electrical constraints, recovery assets and the populated-interface inventory.
2. Close continuous DMA owner reuse and status identity; validate payload retirement, error custody and stale acknowledgements with VCS and Lean.
3. Resolve C126 reset/status timing using actual pin/arc semantics; retain internal recovery/removal checks and require routed closure.
4. Integrate the qualified PCIe/DDR shell, image identity and production host transport. Keep driver admission disabled until retirement and removal containment are established.
5. Pin a compatible compiler/BSP/Quartus/runtime tuple; build hardware SYCL images and validate physical DDR/ECC, bidirectional DMA and kernel results against independent oracles.
6. Qualify every populated external interface with appropriate fixtures, then test contention, reconfiguration, cold boot and recovery.

The DMA status v2 candidate is experimental: finite owner generations exhaust
after 4,080 allocations per fenced reset epoch. Its passing finite tests do not
establish continuous operation. C126 currently fails overall timing closure.
Physical acceptance and complete platform support remain outstanding.
