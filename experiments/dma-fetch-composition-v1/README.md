# Descriptor-fetch controller composition

This isolated composition connects the read engine, owner queues, return route,
read controller, table consumer/copier, status sink and write controller.
Both controllers receive real register writes. Host memory, completion packets,
payload memory and host status writes are test endpoints. Write descriptors
reach the write controller's output; D2H execution is outside this fixture.

## Changes

- Per-destination table queues preserve admission order until each table's final
  copier beat is accepted. Other destinations remain eligible. Failed table
  heads retain custody; no cancellation or fabricated completion is introduced.
- Read-request length uses the current minimum of remaining DWORDs, MRRS
  boundary and page boundary. This removes a stale registered selection that
  emitted 1,000 DWORDs against a 32-DWORD limit after a page transition.

The builder checks source identities, regenerates the existing return fabric,
and applies both transformations in a new output directory outside Git.
`--witness-original` retains the original table consumer but **includes the
request-sizing correction**, allowing the ordering defect to be reached.
Original inputs are never edited.

## Layout

| Directory | Contents |
| --- | --- |
| `rtl/` | Composed controller/engine interface |
| `tools/` | Source-pinned generation and isolated transformations |
| `tests/` | Independent byte/order scoreboards, native runner and tooling tests |

Generate with existing private source inputs:

```sh
python3 experiments/dma-fetch-composition-v1/tools/build.py \
  --engine "$FETCH_V4_ENGINE" --v5-generated "$FETCH_V5_GENERATED" \
  --out "$COMPOSITION_OUTPUT"
python3 -m unittest discover \
  -s experiments/dma-fetch-composition-v1/tests -p test_tools.py
```

The native runner accepts explicit compiler, launcher, FIFO and model paths.
Run its `--help` for argument details. Output must be outside every Git checkout.
The separate `--consumer-order-only` fixture does not instantiate the native
engine and is not a substitute for the composition test.

## Validated scope

Two native compilations and ten directed composition cases pass. The original
consumer witness reports `expected=4 actual=0`; its repaired counterpart passes.

| Case | Checked behavior |
| --- | --- |
| Mixed traffic | Actual read payload/table overlap, both controllers, stalls and status writes |
| Queued ring wrap | Two committed full tables, 4 KiB crossing, ordered execution and third wrap |
| FIFO/table credit | Native descriptor FIFO and all table banks occupied; release drains 512 entries |
| Master disable / abort | Issued prefix drains with retained cause and ownership; no false success |
| Malformed / unattributable return | Fault containment without invented cancellation |
| Status collision | Replay fault cannot escape as committed success |
| Owner reuse | 16,321 controller lifecycles, full-token recurrence after prior custody closes |
| Fenced reset | Observed transport/owner/receipt settlement before a new epoch |

The fixture observes actual handshakes and does not force controller states or
retirement events. These finite tests do not prove universal liveness or RTL
refinement. All-MRRS/unaligned sizing, address-pipeline review, D2H composition,
full-parent behavior, host visibility, timing and physical acceptance remain
open. Production admission remains disabled.
