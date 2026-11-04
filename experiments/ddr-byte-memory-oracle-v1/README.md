# Masked-write memory oracle

The two-round workload writes all 15 nonempty byte masks to each of 16 DWORDs
at `0x3000–0x303f`. Its last write to each DWORD uses mask 15, with data
`0xafc19237 XOR (240 + 15 * (slot + 1))`.

`repair.py SOURCE OUTPUT` adds those expected bytes to the existing full-memory
oracle. Every surrounding byte and kernel-output check remains intact. This
fixture correction requires a new integration run before acceptance.
