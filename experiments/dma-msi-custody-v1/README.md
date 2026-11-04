# DMA completion interrupt custody

`tb.sv` checks the platform status sink with queued successful and failed
completions. It verifies flag-before-interrupt ordering, captured 64-bit interrupt
addresses and 16-bit data, stability under backpressure, interrupt-disable
behavior, and four-phase success receipt custody. Error completions interrupt
without producing a success receipt.

The expected trace contains seven accepted writes and three success receipts.
This is a sink-level test; endpoint delivery and operating-system interrupt
handling require separate integration tests.
