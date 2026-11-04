# Managed reset composition

Combines the quarantine sequencer with three target-clock reset receipts.
Every recovery epoch requires fresh boundary-flush acknowledgements and an
observed reset edge in each target domain. Retained receipts or flush levels
cannot authorize another epoch. A stopped target clock holds recovery closed.

All boundary acknowledgements and requests must be coherent in `monitor_clk`.
The environment must supply real closure, drain and boundary-flush certificates;
reset observation alone does not establish those properties. Certificates must
remain asserted through release. Configuration reset is distinct from runtime
reset and must reset both ends of each receipt handshake.

The test uses independent clocks and checks stopped-clock recovery, stale and
partial flush rejection, and two successive recovery epochs. Boundary
certificates are fixtures; full-shell and physical recovery remain separate.
