# Full-width supervisor fault capture

Parameterizes the supervisor diagnostic address width, default 35 bits.
The isolated test covers 32, 35 and 41 bits, each high address bit, sticky
first-fault preservation through later faults and clears, unavailable address
metadata, and cold reset. Control state transitions are unchanged.

This candidate does not widen parent wiring or host CSR serialization.
