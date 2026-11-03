# Isolated D2H controller composition v1

Base: `dh73/arria10_accel` commit
`570167571021e0ae59ac4893c478933694011599`.

This experiment connects the actual v4 write controller's DCS/DTS interfaces,
its native descriptor output, the full write wrapper, count-corrected producer,
unaligned payload adapter, retained-owner memory mux, aligner, packet generator,
real packet output FIFO, native completion return, and controller DCM/MSI writes.
The independent backend is a backpressured address-dependent memory responder.
The independent DCM sink checks every offered and accepted address/data/enable
and its order. Fetch Req/Ack and committed DTS injection are the containing
boundary; H2D fetch-return correctness is outside this experiment.

`production_driver_contract_valid=false` remains mandatory. Packet enqueue,
simulated FIFO dequeue, and an accepted DCM write are three local events. None
establishes PCIe posted-write visibility in host memory.

## Repair

The supplied controller has an uncredited 128-entry status FIFO and no incoming
status ready signal. Its write request ignores incoming `dma_status_reg[8]`, its
DCM success data is always 1, and its held write address follows live header
registers. The original `ep_last_to_rc[8]` is an endpoint/MSI marker, not the
incoming completion bit. The derivative never uses that repacked bit as success.

`controller_retirement_v1.svh` replaces only the source-bound status/DCM tail:

* Reserve one of 128 metadata entries when `v4_tx_fire` admits a descriptor.
  A completed descriptor changes from pending to completed ownership without
  allocating another entry. Full capacity backpressures descriptor admission.
* Save ID, header-plus-ID status address, reporting policy, endpoint marker,
  MSI enable, MSI address, and MSI data. A live ID cannot be admitted again.
* Validate the exact native success word against the next saved expected ID.
  A failure or unexpected status retains its raw 32 bits and expected ID,
  latches a fault, and stops admission. It never generates a success for the
  received failure ID. Earlier validated completions may still drain, preserving
  any already-held DCM request.
* Return ownership only after the accepted status write and, when required,
  accepted MSI write. With `ctrl[0]=0`, a completed non-endpoint explicitly
  retires without a DCM write, matching the existing selective-reporting policy.
* Block configuration changes while DTS, an issued descriptor, or an endpoint
  marker remains owned. The gate includes concurrent DTS activity. Distinct
  doorbells can queue; duplicate live endpoints and an occupied original saved
  doorbell slot backpressure instead of overwriting metadata.
* Reset `dma_status_valid_reg` to zero. Preserve the controller's asynchronous
  active-low reset, the native wrapper's synchronous `Srst_i`, and the existing
  two-clock payload path. A common reset cancels owners; it does not retire them.

New explicitly owned observation ports are `RetireFault_o`,
`RetireFaultData_o[31:0]`, `RetireExpectedId_o[7:0]`, and `RetireBusy_o`.
`RetireBusy_o` reports retained reservations, not all queued DTS/fetch work.
These are ports of this derivative, not claimed vendor ports or invented DCS
registers. A production containing block must wire fault containment and reset.

The native pulse adapter is exactly
`WrDmaRxValid_i = controller_valid && native_ready`. The controller still holds
its offer through backpressure. No frozen v4/fetch or ingress bench is edited.

## Files and byte identity

`build.py` checks the exact supplied controller, TX include, and frozen full
packetizer bench before making isolated derivatives. `run.py` additionally pins
every reused transformer and its transitive imports before executing them.
Original bytes are never normalized or overwritten. Generated licensed RTL is
written only to the required fresh private build directory, never to this tree.

Important private pins:

| Input | SHA-256 |
| --- | --- |
| Supplied actual v4 write controller | `019de60946a09d16053a8cf15148a5fcbea700b1f4c9c44fd12e0485cbdabd65` |
| Full native write wrapper | `5faf8d9c622e7aeff2f3f77b94e3dddd9b6cac17272892a8b5493412986ee4fe` |
| Original native producer | `9658fce313dc40ea278021747923137a9cad5fc3df344ecc6818e63e010aef54` |
| Required corrected producer | `5a6eb7dc706e78098481b7c5e11b77460c580831ba6ab2f8b9cca13626adbadd` |
| Native FIFO | `8270ffb30fa3b75eaefd6d3d403335f04dbb0f13c894d35e9f6a6668f29f4bf8` |

Both producer inputs are accepted only at these exact hashes; the old input is
transformed and the resulting corrected hash is checked. The qualified status
register, count, and unaligned transforms remain unchanged. The aligner and
wrapper retain exact source bytes. The inherited explicit header-FIFO Arria 10
simulation override remains; use compatible 23.1 standard models for the legacy
controller FIFOs. No diagnostic is suppressed to accommodate incompatible models.

`build_bench` preserves the complete `accept_packet_word` task, both enqueue and
dequeue byte oracles, the actual memory-path wiring, and the native read/return,
metadata, raw-credit, aligned-credit, side-traffic and core-contention monitors.
It replaces synthetic descriptor submission with DCS/DTS, instantiates the real
source-pinned 32-entry output FIFO, adds the independent DCM oracle, and inserts
the new stimulus. No producer/aligner/packetizer/IP dependency is stubbed.

## Simulation cases

| Case | Required result |
| --- | --- |
| `capacity-witness` | Original controller offers a status FIFO write at count 128 while DCM is held; unique `D2H_ORIGINAL_STATUS_CAPACITY count=128` before the overflow edge. |
| `failure-witness` | A real native completion is fault-injected to raw `0x7d`; original writes 1 to header+500 despite admitted ID 3. Unique `D2H_ORIGINAL_FALSE_SUCCESS`. |
| `base-witness` | Original held DCM address follows a later DCS header write. Unique `D2H_ORIGINAL_BASE_RETARGET`. |
| `stress` | Corrected 128 reservations saturate, a reused ID waits, status arrives during a stalled write, configuration stalls, saved MSI survives live input changes, then the full prior payload matrix runs through DCS/DTS. |
| `failure` | Corrected raw failure/expected ID remain visible, failed ownership is retained, and no success write is made. Memory-path quiescence does not retire that owner. |
| `reset` | Reset cancels an owner whose DCM write is held; the next epoch reuses its ID with another header address and no stale success. |
| `selective` | Interleaved IDs, repeated generations, reporting/MSI on/off, and a full saved doorbell slot with a later held doorbell through table-boundary handoff: 208 descriptors, 12 fetch ACKs, 204 status writes, eight MSI writes. |

Default seeds are 1, 17, and 73. The stress case includes the 6,672-descriptor
prior matrix after its 129-descriptor capacity phase: 6,801 descriptors per seed
without the optional extra lengths. It includes the full 18-bit length 262143,
all DWORD offsets, both half-lines, both MPS values, 3DW/4DW headers, 4KiB splits,
crossing 4GiB, ring wraps, side traffic, core contention, and memory/output stalls.
All seven cases passed with seeds 1, 17, and 73: nine original-defect witnesses and twelve corrected-design runs. Each stress run completed 6,801 descriptors and 423,475 packets.

All completion accounting uses handshakes or native status. Final checks first
close DTS-to-native admission, then check every native/output owner and expected
DCM transaction. Empty queues help establish quiescence after those events;
they never create a retirement. There is no simulation timeout, shortened
descriptor limit, bounded oracle RAM, or retry. Adversarial response/grant delays
and the reset pulse width are stimulus, not retirement evidence.

## Commands

Check the transformations and command-line interface:

```sh
python3 experiments/dma-d2h-composition-v1/test_tools.py -v
python3 experiments/dma-d2h-composition-v1/run.py --help
```

Set the following shell variables to your actual retained files and a NEW private
output directory. They are input requirements, not paths assumed to exist here.

```sh
python3 experiments/dma-d2h-composition-v1/run.py \
  --controller "$D2H_V4_CONTROLLER" \
  --payload "$D2H_PAYLOAD_SOURCE" --mux "$D2H_MUX_SOURCE" \
  --producer "$D2H_PRODUCER_SOURCE" --fifo "$D2H_FIFO_SOURCE" \
  --wrapper "$D2H_WRAPPER_SOURCE" --aligner "$D2H_ALIGNER_SOURCE" \
  --tlpgen "$D2H_TLPGEN_SOURCE" --quartus-simlib "$QUARTUS_231_STDSIMLIB" \
  --vcs "$VCS_COMMAND" --runner "$VCS_RUN_COMMAND" \
  --suite all --build-dir "$D2H_NEW_PRIVATE_BUILD" \
  --check-lean --lean "$LEAN_419_COMMAND"
```

`--vcs` and `--runner` accept command vectors parsed without a shell, preserving
launcher symlink identity. `--runner=` executes the compiled `simv` directly.
`--prepare-only` validates sources and writes compile/run commands without any
tool execution. `--suite stress --seed 1` selects one positive run. The emitted
`result.json` contains the exact argv and whether each command was attempted.
The native runtime may exit zero after `$fatal`; the runner accepts an original
witness only with its one expected diagnostic in its one native Fatal block.
Any other `Error!`, `Error:`, `Error-[...]`, fatal or assertion failure rejects
the run, including compilation with exit zero.

Lean may also be run separately:

```sh
lean --version  # must identify 4.19.0
lean experiments/dma-d2h-composition-v1/Contract.lean
```

## Formal obligations and finite accepted contract

`Contract.lean` is an unbounded transition model candidate for
`reserved = pending + completed <= 128`, simultaneous admission/status/retirement,
no-ready status capacity, full admission backpressure, expected ID/address
mapping, metadata holding, and waiting for MSI acceptance before retirement.
It is not a translation proof of this RTL. The supplied SVA checks counter and
ring-pointer correspondence, live IDs, checked-completion ownership, held DCM
signals and fault retention. Simulation of assertions is not an unbounded proof.

The accepted descriptor domain has IDs 0..127, DWORD-aligned addresses, lengths
1..262143 DWORDs, an in-range source aperture, and nonwrapping destination and
status-header apertures. Native status must occur exactly once, in issue order,
at final enqueue under the packet ownership/capacity contract. Endpoint doorbells
must precede the intended occurrence: an older unadmitted same-ID descriptor
cannot remain in the copier/DTS stream when a future-generation endpoint is
armed. Distinct queued endpoints within the current generation and reuse after
prior retirement are exercised. Arbitrary overlapping-table generations and
arbitrarily late duplicate status after ID reuse are not claimed; the native
status ABI carries no epoch. Common reset must flush all producers and consumers.
MSI snapshotting is an admission-time policy in this experiment. Production
programming must serialize MSI reconfiguration with outstanding owners or supply
an explicit mask/abort policy; changing live inputs in this fixture tests saved
metadata and does not establish PCIe global MSI-disable compliance.

Required downstream qualification includes shared arbitration/order of payload
and status/MSI posted writes, suitable PCIe attributes/routing/traffic class,
the real posted-write/host-observation boundary, driver/DMA memory ordering and
cache visibility, reset/abort containment, complete H2D table-copy integration,
and physical DDR/CDC/timing/BSP behavior. A DCM handshake is only local sink
acceptance; even if this entire fixture passes, it cannot make the production
driver contract valid by itself.

## Qualified scope

All 21 native runs passed their exact outcome checks. The original-defect cases
reproduced status-capacity overflow, false success and held-address retargeting;
the corrected cases passed stress, failure retention, common reset and selective
reporting. All 21 input source pins were unchanged after execution.

The 15 Lean 4.19 obligations, including initialization, transition preservation
and reachable-state validity, passed with only standard Lean axioms. These prove
the abstract model; RTL refinement and host visibility remain open.

Next integrate the descriptor-fetch return path and this controller into the
containing parent, route retained faults to supervision, and validate shared
payload/status ordering. Full-parent simulation and physical acceptance are
not established. Production driver admission remains disabled.

## Containing hierarchy

`integrate_parent.py` creates a separate derivative of the pinned v5 fetch
hierarchy. It installs the qualified write controller, count/status producer,
and accepted-valid pulse connection. Four retained retirement diagnostic/busy
outputs are carried through the configured top. The read controller retains
its original TX include; the write controller uses its own corrected include.

```sh
python3 experiments/dma-d2h-composition-v1/integrate_parent.py \
  --fetch-generated "$FETCH_GENERATED" --d2h-generated "$D2H_GENERATED" \
  --out "$NEW_PARENT_DIRECTORY"
```

The configured derivative elaborates 357 modules with 107 source pins checked
and no new design-warning signatures. Existing warnings remain unresolved.
This does not qualify bidirectional simulation, fault handling by a containing
supervisor, posted-write ordering or host visibility.
