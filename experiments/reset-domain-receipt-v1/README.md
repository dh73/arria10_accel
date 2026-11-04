# Reset edge receipt

A toggle handshake records a fresh target-clock edge with local reset asserted.
The monitor rejects overlapping requests and holds each receipt until the next
request. A stopped target clock cannot acknowledge a reset.

`request` must be synchronous to `monitor_clk`. `target_reset_n` describes the
reset seen by target-domain logic. Both handshake halves use the same qualified
configuration reset; local runtime reset must not clear their protocol state.
Allow configuration-reset release to synchronize before issuing requests.

The receipt establishes a sampled reset edge, not traffic drain or hard-IP
flush. A recovery controller must first isolate producers, retain closure and
drain certificates, and account for every external response source. Physical
CDC and reset timing require separate implementation checks.

The test covers a stopped target clock, two successive requests, retained and
invalidated receipts, and sticky rejection of overlapping requests.
