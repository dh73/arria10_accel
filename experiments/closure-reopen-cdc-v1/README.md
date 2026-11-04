# Closure reopen crossing

A supervisor consumption pulse becomes a held round request to the PCIe closure
mailbox. Admission readiness waits for acknowledgment and its return to idle.
Overlapping consumption fails closed; coordinated cold reset restarts round one.

The test uses independent clocks and the actual closure mailbox. It covers two
rounds, a delayed acknowledgment, overlapping consumption and reset in flight.
Physical CDC constraints, reset containment and full-platform admission wiring
remain integration requirements.
