# DMA status candidate v2

Experimental descriptor-bound retirement and status handling with sixteen owner
slots. Success requires completed payload accounting; errors retain ownership
and preserve descriptor identity. Status publication and acknowledgement are
separate operations.

The candidate includes RTL, host decoding, transformation scripts, tests and a
formal model. Eight-bit owner generations do not wrap, limiting operation to
4,080 allocations per fenced reset epoch. Continuous reuse and physical
integration remain open. Production DMA admission stays disabled.
