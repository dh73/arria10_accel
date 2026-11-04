# Descriptor-fetch return fabric

This candidate carries descriptor ownership through completion processing and
routes returned table entries to the read or write descriptor consumer.

## Layout

| Directory | Contents |
| --- | --- |
| `rtl/` | Return routing and producer metadata/debt logic |
| `tools/` | Source-pinned producer, controller and hierarchy transformations |
| `tests/` | Native producer/route/consumer regression and launcher |
| `formal/` | Abstract ownership, destination-debt and closure proofs |

## Data and completion contract

Admission captures `{epoch32, token20, base64, count8}`. The token contains
`{generation8, slot4, id8}`. This record accompanies the descriptor, issuing tag,
completion header, queued command and active burst. Queued work retains its
original identity across tag or slot reuse. Descriptor and command FIFO widths
are 288 and 199 bits; the command slot remains at bits `[74:71]`.

The 256-bit return route uses 64-bit addresses and 65-bit interval checks.
Payload occupies the existing 2-GiB aperture. Read and write descriptor tables
occupy separate 8-KiB windows at `0x80000000` and `0x80002000`. The entry ordinal
is `(accepted_beat_address - admitted_base) / 32`. Table writes require aligned,
complete 32-byte entries and matching route, epoch and admitted interval.

There is no posted table-write buffer: producer acceptance coincides with the
selected consumer's acceptance. A retained `FetchEnd` offer follows issuance
closure and settlement of that owner's read and command debts. Status readiness
and unrelated owners do not gate this offer. Successful table commit additionally
requires complete, unpoisoned coverage and the matching status/receipt protocol.

The containing hierarchy connects metadata, both table destinations and
`FetchEnd` internally. Untagged legacy table writes are blocked and faulted.
Route faults veto same-edge consumer success. Unattributable faults use token
zero. The existing write mover remains a separate integration dependency.

## Identity and recovery requirements

Generation wraps from `ff` to `1`. Reuse requires prior read/command settlement,
accepted closure, completed receipt and drained consumer storage. Finite tokens
do not authenticate PCIe returns: stale traffic after wire-tag reuse must be
excluded by the transport contract. Reset requires an independently established
transport fence; changing an epoch alone is insufficient.

Unsupported error completions and malformed headers retain outstanding debt and
contain the fault. Recoverable error, timeout and link-loss handling still need
an explicit upstream cancellation/drain contract and retained host-visible cause.
No universal error-path liveness is established.

## Known ordering defect

The current consumer can interleave descriptors from two committed tables for
one destination: tables `[0,1]` and `[2,3]` can emit `[0,2,1,3]`. Bank selection
rotates after each descriptor instead of retaining the oldest table until its
last accepted copier beat. The focused original-source witness observes
`expected=1 actual=2`; the component regressions below did not close this case.

A separate candidate queues tables per destination at issue acceptance and
advances only after the accepted final copier beat. Its focused consumer test
passes; controller/native-engine/FIFO composition remains unqualified. The
candidate is not adopted here. Production use requires ordered table delivery
in addition to the ownership and recovery conditions above.

## Build

The builder checks exact source identities and writes generated derivatives to
a new directory outside this repository. Supply the original source inputs:

```sh
python3 experiments/dma-fetch-return-v5/tools/build.py \
  --engine "$FETCH_V4_ENGINE" --out "$FETCH_RETURN_WORK/generated"
```

For the containing hierarchy, also supply `--controller`, `--write-controller`,
`--control-wrapper`, `--app-wrapper`, `--parent`, `--configured` and `--route`.
The configured target is `c10_configured_fetch_return_v5`. All hierarchy inputs
are required together. Exact hashes are enforced by the transformation scripts.

## Validation

The native regression observes emitted read requests and supplies host completion
packets to the producer. Its fourteen scenarios cover split/interleaved returns,
backpressure, partial abort drains, route/ordinal/epoch faults, late data/status,
finite-token recurrence, fenced reset and tag reuse with older queued commands.
The fixture contains the producer, owner, FIFOs, route, consumer and status sink;
it does not establish whole-parent behavior or host visibility.

Run the model with Lean 4.19.0:

```sh
lean experiments/dma-fetch-return-v5/formal/ReturnFabric.lean
```

The twelve checked theorems include BASE, STEP, reachable-state induction,
retained debt, address/ordinal consistency, closure and finite-generation
recurrence. Their axiom audit contains only `propext` where required. These
proofs concern the abstract model; RTL refinement, simultaneous-event
serialization, transport fencing and liveness remain separate obligations.

Source-pinned producer and complete hierarchy generation pass. The containing
hierarchy elaborates all 357 modules with 108 verified source hashes; its
port-width and connection warning signatures match the preceding hierarchy.
All fourteen native producer/route/consumer scenarios pass. Thirteen pass in
the combined run; the collision case passes separately after aligning the
clocked replay stimulus with status release. The remaining stimuli and RTL
are unchanged. This is component composition, not full-parent simulation.
Driver admission remains disabled. Production integration still requires error recovery, combined
bidirectional DMA, DDR visibility, reset/timing closure and physical validation.
