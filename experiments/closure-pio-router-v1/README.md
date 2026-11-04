# BAR2 closure routing

Routes BAR2 offsets 832–879 to the PCIe-clock closure mailbox and forwards other
accesses to the normal control crossing. Local accesses retain the normal path's
single-outstanding backpressure so responses cannot overtake an outstanding read.

The test holds a normal read at the destination, presents a closure read behind
it, and checks exactly one response from each path without collision. It also
uses a nonzero HIP-relative address base. This validates the router with the
actual control crossing, not full HIP receive ordering or physical operation.
