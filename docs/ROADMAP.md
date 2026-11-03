# Implementation roadmap

1. Qualify exact ES3/P12-27065R electrical constraints, recovery assets and the populated-interface inventory.
2. Integrate the reuse handshake into the containing DMA shell, preserving separate read/write controllers, common reset and real fetch/diagnostic acceptance. Reuse, payload retirement and error custody now have component simulation and formal-model coverage.
3. Resolve C126 reset/status timing using actual pin/arc semantics; retain internal recovery/removal checks and require routed closure.
4. Integrate the qualified PCIe/DDR shell, image identity and production host transport. Keep driver admission disabled until retirement and removal containment are established.
5. Pin a compatible compiler, board-support and runtime configuration; build hardware SYCL images and validate physical DDR/ECC, bidirectional DMA and kernel results against independent oracles.
6. Qualify every populated external interface with appropriate fixtures, then test contention, reconfiguration, cold boot and recovery.

The DMA status v2 candidate is experimental: finite owner generations exhaust
after 4,080 allocations per fenced reset epoch. Its passing finite tests do not
establish continuous operation. C126 currently fails overall timing closure.
Physical acceptance and complete platform support remain outstanding.
