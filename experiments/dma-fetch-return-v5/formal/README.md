# Fetch-return ownership model

`ReturnFabric.lean` models admitted descriptor identity, issuing tags, queued
return commands, destination acceptance and retained closure. The invariant
binds each tag and queued command to its admitted context and requires all
return debt to settle before closure is offered.

Validate with Lean 4.19.0:

```sh
lean experiments/dma-fetch-return-v5/formal/ReturnFabric.lean
```

BASE, STEP, reachable-state induction and nine additional theorems check.
The twelve-theorem axiom audit reports only `propext` where required; four
identity/arithmetic obligations and BASE require no axioms.

Reset assumes an external transport fence. Token recurrence is permitted and
does not prove replay exclusion. Consumer receipt/drainage are explicit reuse
premises. The model does not prove RTL refinement, simultaneous-event ordering,
liveness, PCIe delivery or physical memory visibility.

`ReturnAddress.lean` adds seven checked arithmetic obligations: 65-bit burst
and table bounds, accepted-beat containment, seven-bit ordinal preservation,
aligned-address reconstruction and whole-entry containment. These assume the
stated address/count bounds and do not prove the RTL handshake or counter.

```sh
lean experiments/dma-fetch-return-v5/formal/ReturnAddress.lean
```
