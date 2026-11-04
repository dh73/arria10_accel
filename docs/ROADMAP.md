# Implementation roadmap

1. Qualify exact ES3/P12-27065R electrical constraints, recovery assets and the populated-interface inventory.
2. Complete the DMA fabric described below, preserving separate read/write controllers, common reset and real fetch/diagnostic acceptance.
3. Resolve C126 reset/status timing using actual pin/arc semantics; retain internal recovery/removal checks and require routed closure.
4. Integrate the qualified PCIe/DDR shell, image identity and production host transport. Keep driver admission disabled until retirement and removal containment are established.
5. Pin a compatible compiler, board-support and runtime configuration; build hardware SYCL images and validate physical DDR/ECC, bidirectional DMA and kernel results against independent oracles.
6. Qualify every populated external interface with appropriate fixtures, then test contention, reconfiguration, cold boot and recovery.

## Current full-hierarchy boundary

The combined candidate now completes both DMA directions through the full
root-port hierarchy with endpoint memory. The shared receive dispatch fix passes
two 128-byte comparisons and two 256-byte comparisons. The larger test poisons
host destinations and checks both status slots in each direction, with
per-descriptor reporting explicitly enabled. Nine isolated dispatch and producer
regressions also pass, including unrelated BAR/TXS traffic and malformed returns.

These are finite simulation results with pinned FIFO models, not physical DDR,
board, bandwidth or cross-version model equivalence. Next: broaden full-hierarchy
coverage to contention, reset/error containment and descriptor reuse, then
integrate initialized DDR and the production transport.
Candidate descriptor tables use `0x80000000` and `0x80002000`, outside the 2-GiB
payload aperture. The legacy reference fixture uses different table addresses;
candidate tests must select the candidate layout explicitly.

## DMA integration sequence

* Carry the admitted fetch token, epoch and descriptor ordinal through actual
  PCIe completions, queued write commands and both descriptor-table destinations.
  Produce token-bound closure only after the last destination acceptance,
  including partial/error returns. The v4 consumer and containing hierarchy are
  qualified separately. The v5 candidate now carries metadata through native
  return commands and internalizes both table destinations and closure. Fourteen
  producer/route/consumer scenarios pass, and its 357-module hierarchy elaborates.
  The combined root-port fixture now covers aligned sequential transfers;
  concurrent, reset/error and broader whole-parent behavior remain open.
* Connect the corrected D2H count producer and unaligned payload path through
  the actual aligner and packet generator. Check emitted packets against an
  independent destination-byte oracle under stalls, ring wraps and maximum
  descriptor lengths. Native wrapper/adapter/mux simulation now passes 6,672
  descriptors and 423,250 packets per seed through output FIFO enqueue/dequeue.
  The actual write-controller/packetizer/DCM sink composition now also passes:
  6,801 descriptors and 423,475 packets per stress seed, nine original-defect
  witnesses, twelve corrected runs and fifteen abstract proof obligations.
  Reserved completion capacity, saved metadata and accepted status/MSI retirement
  are checked locally. The containing derivative elaborates 357 modules with
  retirement diagnostics exposed and no new design-warning signatures. PCIe
  host delivery is checked in the finite root-port fixture above; physical
  delivery and broader full-parent coverage remain open.
* Compose both directions with DDR initialization, arbitration and supervision.
  Establish reset epochs, error custody, diagnostic storage, interrupt behavior
  and host-visible retirement before connecting the production transport.

The reusable v3 owner and v4 fetch consumer supersede the v2 candidate's finite
allocation limit in component experiments. Token reuse still requires exclusion
of stale returns and coordinated reset; these contracts need full-fabric tests.
The driver enforces DMA/PIO memory apertures and compiles on both host kernels,
but production admission remains disabled. C126 still lacks overall timing
closure. Physical acceptance and complete platform support remain outstanding.

## Shell identity

The read-only identity block, host decoder and source/build association generator
pass host tests and native RTL-to-C++ transcript checks. Thirteen abstract Lean
obligations cover publication, invalidation and sequence exhaustion. The block
has no default BAR and grants no admission. Integration still needs a real
management decode, coordinated session/reset context and driver-backed device
custody; the current FPGA image remains unidentified.

## Controller validation correction

Five historical fetch-controller simulation passes are withdrawn: their logs
contain an unsupported FIFO-model family error that the old result parser
missed. All five controller cases now pass requalification with compatible
models and strict diagnostic checks; 22 input hashes and the native logs were
verified. The 24 consumer cases and abstract proof remain separate evidence.
Use the new controller qualification rather than the original contaminated runs.
The combined hierarchy has the finite coverage stated above. Original review inputs and logs
remain preserved.
