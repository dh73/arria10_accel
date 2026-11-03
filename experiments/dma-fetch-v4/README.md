# Descriptor-fetch consumer v4

Isolated source transformations against `d2067f6136c7afe218ab42a2136e27167ddd0826`.
Source transformations require exact input hashes. Driver admission remains disabled.

## Functional contract

The read controller's old status staging registers had no functional reader.
This candidate replaces that path with `dma_fetch_commit_v4`: 16 independent
table banks, each holding up to 128 executable 160-bit descriptors. A bank is
reserved on the actual controller fetch-TX handshake. The immutable issued
descriptor and first table index are retained. The subsequent **actual owner
admission** binds `{generation[7:0],slot[3:0],full_id[7:0]}` by exact 160-bit
descriptor equality. These events may occur on different clocks because of
intervening application queues. A known unbound request backpressures returns.

DTS carries explicit epoch, token and ordinal sidebands. Each unique ordinal
must be in range, on the correct read/write ingress, with executable descriptor
ID `first+ordinal`. One accepted DTS beat writes one complete descriptor to
quarantine. The old DTS burst FSM and speculative one-cycle FIFO staging are
bypassed. DTS burst count/address do not establish transaction identity.

`FetchEnd*` is a required producer-close handshake. It means all beats for that
token have completed their destination handshakes and no further beats can
arrive. A clean close with incomplete coverage poisons the bank. The producer
must not offer close concurrently with its last unaccepted beat. A returned
owner success alone does not establish this routing/visibility fact.

Only an exact ABI-v2 success, complete coverage, clean close, and absence of
abort/error permit a status handshake. That edge sets a retained committed bit
which enables the actual table-RAM reader. Read fetch IDs 128..191 feed the read
controller FIFO; forwarded write fetch IDs 192..255 feed the write controller
FIFO. No uncommitted descriptor reaches either FIFO. Streaming before whole
fetch success is unsafe here: later fetch failure cannot roll back data DMA
already issued from an earlier descriptor. No independent per-entry commit or
rollback contract is supplied.

Commit transfers functional executable custody to the bank; it does not wait
for FIFO drainage. The generated sink therefore returns the ordinary four-phase
success receipt directly after commit, without `FETCH_FENCE`. A bank/ID remains
reserved until **both** every descriptor has physically entered its destination
FIFO and `valid / consumed / valid-low / consumed-low` has closed. This separates
owner lifetime from buffer lifetime and avoids requiring FIFO drainage before
the head fetch owner can retire. TX queries bank/ID credit before selecting a
fetch; a blocked fetch leaves the data FIFO eligible to drain. Query priority
rotates between pending local and forwarded fetches. The shared copier can stall behind either
destination; progress requires that selected destination eventually accepts.

## Errors, control and reset

Pure PAUSE is retained on the unchanged 32-bit diagnostic channel and does not
poison the table. Terminal MASTER/ABORT/FLUSH diagnostics poison it and retain
identity for matching late payload before close. A separate retained per-bank
local-error channel reports producer-error close, partial clean close, and
precommit abort (reasons 1, 2, 3; with epoch, token, accepted count). Consuming a
diagnostic never clears poison or releases an errored owner. There is no invented
success ACK or unimplemented targeted recovery. Error recovery remains a
separate owner/transport protocol; the current owner retains terminal errors.

Unknown/duplicate/late/wrong-route payload, invalid admission/completion,
postcommit abort, changed epoch, and malformed receipt sequencing latch a sticky
protocol fault with the first offending identity. Invalid payload is not
acknowledged. A newly detected fault vetoes same-edge commit. An already offered
committed copier word stays stable and can finish; later words stop. Fault
containment may cancel an unaccepted controller fetch offer; it is not normal
ready/valid flow control and does not authorize owner/buffer reuse.

The snapshot correction holds TX valid/data through ordinary stalls; fetch
counter and pointer arithmetic advance only on accepted TX/forward ACK. A new
doorbell concurrent with old acceptance remains pending. A newer external
doorbell supersedes an older deferred pointer without replaying it. Configuration
writes wait while a local fetch snapshot/deferred doorbell is pending. Snapshot
metadata determines the issued span even if later registers change.

`READ_CONTROL=0` needs two narrow, explicit corrections: held data TX plus
immutable forwarded-fetch snapshot/accounting, and direct committed-descriptor
FIFO ingress. Its original status/DCM/MSI logic remains byte-preserved outside
those selected regions. The containing wrapper routes external write DTS to
quarantine and connects only committed write descriptors to that ingress.

Clocks and asynchronous active-low resets remain unchanged. `FetchEnable_i`
must assert only after routing/reset containment is established; dropping it
with live banks is a retained fault. The epoch must remain stable while enabled
and must distinguish any still-possible pre-reset traffic. Finite 8-bit owner
generation and 32-bit epoch are not replay authenticators: legal reuse requires
no stale returns after producer close, and coordinated reset/transport fencing.

## Required production wiring and remaining scope

The optional source-pinned shell transformations connect owner admission and
receipt wires, forward first-index metadata, reroute both DTS paths, and expose
all required routing/error ports through the exact configured parent. They do
not manufacture missing fabric semantics. Production must implement:

* Token/epoch/ordinal propagation through the real PCIe completion, command,
  Avalon arbitration and DTS destination paths. Associate metadata at actual
  owner admission; preserve it through every buffer and stall.
* Token-bound producer close after the last **destination** acceptance, including
  pending partial/error returns. It cannot be tied high or derived from elapsed
  cycles. No DDR visibility or arbitrary Avalon-address mapping is inferred.
* Retained host handling of both diagnostic channels, protocol faults, reset
  epochs, and terminal-owner recovery. Error-channel ready requires real storage.

Independent existing constraints remain: the status sink captures header/MSI
publication metadata at status ingress, not per-data-owner admission. Rebasing
those registers while old data operations remain live is not qualified by the
fetch snapshot fix. Full fabric, physical DDR visibility, link-loss containment,
exact-parent behavior, BSP/SYCL/driver readiness and board-image identity remain
unqualified. No global drain is added to disguise these obligations.

## Build and validation

Set `FETCH_V3_CONTROLLER` to the supplied private controller file (SHA256
`08880eb036b19f396e4f9f40675b890574c719454e9a57b88c45c06fe3059a36`).
Set `FETCH_WORK` to a new scratch location, and `QUARTUS_SIMLIB` to the actual
Quartus simulation-library directory containing `altera_mf.v` and `220model.v`.
All commands run from the repository root:

```sh
python3 experiments/dma-fetch-v4/tools/build.py \
  --controller "$FETCH_V3_CONTROLLER" --out "$FETCH_WORK/generated"
python3 experiments/dma-fetch-v4/tests/run_vcs.py --suite core \
  --out "$FETCH_WORK/vcs-core"
python3 experiments/dma-fetch-v4/tests/run_vcs.py --suite controller \
  --generated "$FETCH_WORK/generated" --quartus-simlib "$QUARTUS_SIMLIB" \
  --out "$FETCH_WORK/vcs-controller"
lean --version
lean experiments/dma-fetch-v4/formal/FetchCommit.lean
```

Select Lean 4.19.0 before the last command. The VCS runner provides `--runner`
for a host launcher (empty means direct simv) and `--list` for planned cases.
There is no simulation substitute or execution/resource timeout.

For the write-controller and complete shell candidates, additionally provide
`--write-controller "$FETCH_ORIGINAL_CONTROLLER"`,
`--engine "$FETCH_V3_ENGINE" --engine-manifest "$FETCH_V3_ENGINE_MANIFEST"`,
`--control-wrapper "$FETCH_ORIGINAL_CONTROL_WRAPPER"`,
`--app-wrapper "$FETCH_ORIGINAL_APP_WRAPPER"`,
`--parent "$FETCH_ORIGINAL_PARENT"`, and
`--configured "$FETCH_ORIGINAL_CONFIGURED"` to the builder, using a **new** output
directory. The original write source must regenerate the exact pinned private
v3 controller; shell inputs must pass the existing v3 builders' original-source
hash checks. Compile the optional write-controller test against that output:

```sh
python3 experiments/dma-fetch-v4/tests/run_vcs.py --suite write \
  --generated "$FETCH_FULL_WORK/generated" --quartus-simlib "$QUARTUS_SIMLIB" \
  --fifo "$FETCH_ORIGINAL_FIFO" --out "$FETCH_FULL_WORK/vcs-write"
```

Full-shell native elaboration passes for the exact configured parent and
original device/model hierarchy with the v4 controller, owner, engine and
wrapper derivatives (356 modules). Source hashes were rechecked. The 29 port
width warnings match the prior hierarchy by port, widths, instance and
expression after module-name normalization; existing warnings remain open.
This is elaboration only: return metadata and producer-close behavior still
require full-fabric simulation and implementation.

The VCS benches use the actual transformed controller DCS/DTS/TX interfaces,
actual owner and native FIFO models; command/return stimulus and tagged return
routing remain test abstractions. The separate 320-lifecycle bank test checks
ID/generation reuse, quarantine, errors, backpressure and receipt closure.
All 29 VCS cases pass: 24 consumer cases, four actual read-controller cases,
and one actual write-controller case. The clean read/write fetch case records
three fetches, four read descriptors, two write descriptors and seven closed
receipts. Separate cases cover full 128-entry tables, 320 reuse lifecycles,
256 full-token recurrences, partial/error/late payload, delayed binding,
malformed receipts and doorbell/credit contention.

`FetchCommit.lean` passes Lean 4.19 BASE, exhaustive STEP, reachable induction and
commit/release/reuse theorems for an abstract bound bank. Its `sealed` means
clean closure (RTL `sealed && !poisoned`), and epoch is abstract/unbounded.
Its per-bank fault abstracts retained failure; forensic payload after poisoning
is omitted. The model does not prove delayed binding, RTL refinement, fabric
routing, bounded-token replay exclusion, reset fencing, liveness, or physical
visibility.

The proof was checked without `sorry`; axiom inspection reports only standard
`propext` and `Quot.sound` where used. Its transition assumptions are model
contracts, not established properties of the complete routing fabric.
