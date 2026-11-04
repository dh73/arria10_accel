# Read-only reset diagnostics

The block exposes signature `0x52534401` at offset 0 and one coherent status
DWORD at offset 4. Status bits 0–7 report snapshot-epoch validity, external
containment, DMA snapshot validity, DMA epoch loss, shared-path fault,
initialization failure, ECC interrupt and memory readiness. Upper bits are zero.
These observations grant no admission, reset or drain authority.

Writes, partial reads and invalid offsets are rejected. Diagnostics remain
readable after an invalid access. The independent-clock test checks all 256
status combinations and exactly 263 accepted bus commands.

The prepared BAR2 route occupies bytes 1088–1095. Its containing-frontend
qualification is separate from the passing block/CDC test; physical access
and whole-platform acceptance remain open.
