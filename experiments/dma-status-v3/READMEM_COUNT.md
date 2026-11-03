# D2H completion beat count

The retained producer uses an 18-bit `adjusted_dw` intermediate for an
18-bit descriptor DWORD count plus a source offset of zero through seven
DWORDs. This wraps for 28 combinations near the maximum length. For example,
262143 DWORDs at offset one requires 32768 returned beats, but the old sum
wraps to zero.

`tools/build_readmem_count.py` creates a separate private derivative from the
exact retained source. It widens the intermediate and its register to 19 bits
and includes the new high bit in both branches of the rounded beat count.
The maximum sum is 262150 and the maximum beat count is 32769, which fits
the existing 16-bit count FIFO. Descriptor width and pipeline timing are
unchanged. No smaller descriptor-length limit is introduced.

```sh
python3 experiments/dma-status-v3/tools/build_readmem_count.py \
  --source retained_producer.sv --output new_count_candidate.sv
lean experiments/dma-status-v3/proofs/ReadmemCount.lean
```

The transformer requires the exact input hash, preserves all other bytes,
and refuses an existing output. The arithmetic model covers every positive
18-bit length and all eight DWORD offsets: 2097144 pairs, 28 old mismatches,
zero corrected mismatches. Lean 4.19 establishes sum/count bounds, positive
count, and minimal covering beat count. These are stateless arithmetic
results, not RTL refinement or completion-liveness proofs.

The actual producer count pipeline also passes VCS with forced operand
registers over all 2097144 combinations. The unchanged producer independently
reproduces the zero-count overflow. This fixture instantiates the producer and
its real dependencies; it does not exercise descriptor ingress or retirement.
The fixture is `tests/readmem_count_tb.sv`.

For combined producer/payload qualification, use `tests/run_unaligned_vcs.py`
with `--suite native --correct-producer-count` and
`--sim-arg=+DESCRIPTOR_DWORDS=262143`, plus the input paths documented in
[UNALIGNED_HEAD.md](UNALIGNED_HEAD.md). The runner derives the correction from
the exact original source and records both identities. This exercises maximum
length at every DWORD offset in both half-lines as well as the existing native
matrix. The combined run passes seeds 1, 17 and 73: 430 positive and seven
negative descriptors per seed, including maximum length at all 16 source
offsets. It checks producer completion, exact returned beat counts, raw data
RAM and descriptor/completion FIFO consumption. Each seed checks 528031
backend returns and 33711 producer commands. This establishes finite fixture
retirement; downstream packetization, full-parent integration and physical
acceptance remain open.
