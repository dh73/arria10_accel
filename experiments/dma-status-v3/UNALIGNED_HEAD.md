# D2H unaligned-head adapter

The adapter accepts the producer's DWORD-aligned head commands while preserving
byte-lane masks, returned data order and original fault addresses. It normalizes
only the backend beat address. Source transformations require exact input hashes.

## Source-derived mapping

In the supplied `altpcieav_dma_wr_readmem_2.sv`, `cur_src_addr_reg` is loaded
from the unmodified source descriptor. `SEND_HEAD` emits that original byte
address, burstcount one and a mask indexed by `hold_src_addr_reg[4:0]`.
For example, source offset 4 and length one DWORD produce mask `0x000000f0`.
The return is stored as a full 256-bit word; the forwarded TLP descriptor
retains the original source offset. Thus the enables and returned bytes use
aligned-beat lanes. Right-shifting the returned payload would break this
interface. The downstream TLP generator is not supplied or qualified here.

Let `A` be the original byte address, `B = A & ~31`, and `k` a byte lane.
For backend beat `i`, the byte address is `B + 32*i`, line index is that
address divided by 64, and byte lane is `32*((B/32+i)%2) + k`.
The accepted command mask selects `k` unchanged on every beat. The corresponding
256-bit half-line is returned unchanged. Disabled response bytes are unspecified.

Only the backend address expression is normalized. Both PCIe and user-domain
header registers retain `A`; every existing fault path therefore retains the
original diagnostic address. The captured mask, toggle handoff, ownership,
quarantine, health/reset logic and state machines are unchanged.

## Strict command contract

| Command | Admission |
| --- | --- |
| H2D write | Existing 32-byte alignment, count 1..16 and original 65-bit aperture check; per-beat write enables unchanged. |
| Aligned D2H read | Count 1..16; arbitrary 32-bit command mask, including zero, remains compatible. |
| Unaligned D2H read | DWORD-aligned address, count exactly one, nonempty mask, and no enabled bit below `A[4:0]`. Sparse/sub-DWORD masks above the start are allowed. |
| Every D2H read | `zero_extend_65(B) + 32*count <= 0x80000000` before backend address narrowing. |

Non-DWORD reads, unaligned multi-beat reads, unaligned zero masks, masks selecting
bytes below the requested start, count zero/greater than 16, high addresses and
crossing commands are rejected with waitrequest asserted and sticky fault code
1. No backend request is generated for a rejected command. No mask or address
is silently repaired to make a malformed command legal. For instance,
`A=0x7ffffffc`, count 1, mask `0xf0000000` is valid because its normalized
exclusive endpoint equals 2 GiB. `A=0x7fffffe0`, count 2 is invalid.

Command legality is not whole-descriptor admission. The payload interface has
no descriptor length or destination input. Native descriptor legality assumes
a positive DWORD count, DWORD-aligned source/destination as required by the
surrounding DMA protocol, a source range wholly inside the aperture, and a
legal destination range for the retained PCIe packetizer. The supplied readmem
producer does not establish those admission checks. An illegal descriptor at
`0x7ffffffc`, length two DWORDs can return its valid first head before its next
command at `0x80000000` faults. Tests distinguish this from atomic rejection
of an individual crossing command. Destination descriptor fields are checked
for preservation, not for downstream PCIe packetization correctness.

Descriptor-table traffic must still be demultiplexed before the payload adapter.
The previous routing requirement and H2D alignment are not relaxed. Common cold
reset remains the only ownership-quarantine release. Quiesced still denotes
transport ownership empty, not physical DDR write visibility.

## Build and run on the actual VCS host

Choose a new output directory. Supply the unchanged mask candidate (SHA256
`399ac47d8137c3d175b30ffcf90cd405fd3d91edd0a6bb3c79f16ecb9200923d`) or original
adapter (SHA256 `a7a66662e3d15497cf24ade5ce672733104eadbeb670175b542adab6c409c06c`).

```sh
python3 experiments/dma-status-v3/tools/build_payload_unaligned.py \
  --source "$PRIVATE_MASK_CANDIDATE" \
  --output "$NEW_PRIVATE_PAYLOAD_SV"

python3 experiments/dma-status-v3/tests/run_unaligned_vcs.py \
  --suite all --payload "$PRIVATE_MASK_CANDIDATE" \
  --mux "$RETAINED_DDR_MUX" --producer "$RETAINED_WR_READMEM" \
  --fifo "$ACTUAL_ALTPCIE_FIFO" --quartus-simlib "$QUARTUS_SIMLIB" \
  --build-dir "$NEW_PRIVATE_VCS_DIRECTORY" --vcs vcs --runner vcs-run
```

Those variables denote actual private paths, not downloadable public assets.
Use `--runner=` for direct execution of VCS's compiled `simv`. The runner pins
the producer and mux to the supplied hashes. It records actual FIFO/model
hashes without claiming a supplied hash for those absent dependencies. The
existing project VCS runner uses `altera_mf.v` and `220model.v`; those provide
the needed `altsyncram` and `lpm_add_sub`. The exact `altpcie_fifo` implementation
and any dependencies it instantiates must also be supplied. An additional
actual dependency filelist can be passed with `--extra-filelist`.

`--suite regression` derives private copies of the retained aligned mask and
H2D/readback/contention tests, changing only the instantiated candidate name.
`--suite witness` runs the unchanged negative witness against the old candidate.
`--suite direct` runs the new address/mask/error/quarantine/contention tests.
`--suite native` runs the actual retained producer into the corrected composition.
All selects all four groups. Each runs seeds 1, 17 and 73 by default; repeatable
`--seed` options select other seeds. No simulator substitute, runtime cap or RAM
cap is imposed. Every invocation requires a fresh output directory.
`--sim-arg=+DMA_MAX_RESPONSE_DELAY=N` varies direct-test response delays;
`--sim-arg=+RESPONSE_DELAY=N` varies native-test delays. The default finite
matrix is not a proof for every possible latency.

The new native harness checks producer head/body/tail segmentation, command
masks, original addresses, destination/source descriptor fields, enabled return
lanes and the actual producer's raw data RAM. It varies source/destination
DWORD offsets independently, exercises 32/64/512-byte boundaries and subsequent
body boundaries, and tests aperture edges. The direct harness checks sparse
masks, held commands, delayed responses, two-owner contention, H2D partial
writes and full byte-scoreboard preservation, plus fatal epoch behavior.

For additional native length coverage, use `--sim-arg=+DESCRIPTOR_DWORDS=N`.
It exercises that additional length at every DWORD source offset; the only
argument bound is the existing 18-bit descriptor-field range, 1..262143.
The retained producer has a separate inherited corner case: `adjusted_dw`
and `adjusted_dw_reg` are 18 bits, while computing descriptor DWORD count plus
source DWORD offset. A sum of 262144 or greater wraps before calculating the
completion beat count. For example, length 262143 at source offset 4 exercises
this issue. No descriptor-format/admission source was supplied to establish
that such combinations are excluded. This patch neither changes that frozen
producer nor silently caps descriptor lengths; full native maximal-length
completion remains a stated gap. Adapter admission is independent of length
and retains all legal segmented commands.

`proofs/UnalignedHead.lean` is a checked pure arithmetic mapping proof
for Lean 4.19.0, with explicit mask/range assumptions. It is not an
RTL or stateful proof and makes no base/step claim. Check it with:

```sh
lean +leanprover/lean4:v4.19.0 experiments/dma-status-v3/proofs/UnalignedHead.lean
```

## Validation

VCS passed seeds 1, 17 and 73 for both new suites:

| Suite | Per-seed coverage |
| --- | --- |
| Direct adapter/mux | 492 cases, 370 rejections, 3 quarantine cases; 1229 DMA commands and 955 read responses |
| Actual retained D2H producer | 414 positive and 7 negative descriptors; 915 producer commands and 3731 checked backend returns/raw-buffer words |

The aligned-mask and H2D/readback regressions also pass all three seeds. The
old-candidate negative witness remains reproducible. Lean 4.19 passes the
stateless lane mapping and aperture lemmas. Source hashes were rechecked.

This validates finite producer/adapter/mux behavior. Maximum-length retirement,
downstream packetization, descriptor admission, full-parent integration, CDC
constraints, DDR visibility and physical board acceptance remain open. The
separate [count correction](READMEM_COUNT.md) addresses the identified
maximum-length arithmetic overflow and needs combined native qualification.
