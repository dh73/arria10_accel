# D2H packetizer qualification

The candidate composes the native write wrapper, count-corrected read producer,
aligner and packet generator with the unaligned payload adapter and memory mux.
The fixture decodes output packets at FIFO enqueue and dequeue and compares every
enabled payload byte against an independent source-address oracle.

## Status correction

The original packet generator announces descriptor completion one cycle before
its registered final packet beat reaches the output FIFO. `build_packetizer.py`
registers status and descriptor ID alongside that output stage. It preserves
synchronous reset and checks exact input hashes before transformation. The
aligner remains byte-for-byte unchanged.

The status contract is final-beat enqueue, conditional on packet ownership and
FIFO capacity. It is not PCIe delivery or host-memory visibility. The fixture
checks the final EOP, descriptor ID, byte count and available FIFO capacity on
the status edge. No downstream per-beat ready signal is invented.

## Observed results

The original early-status failure and corrected single-descriptor control were
each checked across three seeds. The corrected full matrix passed seeds 1, 17
and 73, with these counts per seed:

| Measurement | Count |
| --- | ---: |
| Descriptors / successful statuses | 6,672 |
| Packets | 423,250 |
| Backend returns / raw writes / raw releases | 2,212,776 |
| Aligned writes / returned credits | 2,628,698 |
| Raw / aligned sequence-counter wraps | 2,160 / 2,567 |

Coverage includes 64 maximum-length descriptors per seed, all source/destination
DWORD offsets, both source half-lines, 128/256-byte payload sizes, 4 KiB splits,
32/64-bit destination addresses and crossing 4 GiB. Side traffic, competing
memory requests, delayed responses and output backpressure remain active.

Three quarantine cases also pass: an out-of-range descriptor can return its
valid head before the following command faults. This establishes sticky command
quarantine without successful descriptor status, not atomic descriptor rejection.

## Reproduction and limits

`tests/run_packetizer_vcs.py --help` lists the required private input files and
new output directory. `--suite all` runs the original status witness, corrected
status control, full matrix and quarantine. `--prepare-only` records source
hashes and commands without execution. The transformer distributes no generated
implementation files.

The fixture explicitly selects Arria 10 for the header-FIFO simulation model.
Descriptor ingress emits a ready-gated pulse: the native FIFO writes on valid
alone. A retained ready/valid controller requires the separate ingress adapter.
Native errors, including `Error!`, invalidate a run even when process exit is zero.

Full controller/parent composition, CDC/timing, host retirement, physical DDR/ECC,
PCIe delivery and board acceptance remain open. The fixture's FIFO and memory
response models do not establish those properties.
