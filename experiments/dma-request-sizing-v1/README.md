# Read-request sizing

A request transfers `min(remaining, mrrs, page)` DWORDs. `page` is the
DWORD distance to the next 4 KiB boundary. Inputs describe the same current
request; a registered selection from an earlier remaining count is insufficient.

## Proof ledger

| Obligation | Assumptions | Result |
| --- | --- | --- |
| Remaining, MRRS and page bounds | Natural-number inputs | Proven |
| Positive request and decreasing remainder | All three inputs positive | Proven |
| BASE conservation | Zero issued | Proven |
| STEP conservation | Issued + remaining = total; one accepted request | Proven |
| No 4 KiB crossing | DWORD offset below 1024 | Proven |
| Stale-selector counterexample | Selected length 1000, limit 32 | Violates bound |

State is `(issued, remaining)`. Each accepted request increments issued and
subtracts the same amount from remaining. These arithmetic obligations do not
prove RTL refinement, finite-register sizing, address-update timing, tag custody,
or completion handling. The observed oversized request motivates the contract;
its pipeline cause still requires the native trace.

Validate with Lean 4.19.0:

```sh
lean experiments/dma-request-sizing-v1/formal/RequestSizing.lean
```

The checked STEP, positivity and page-boundary proofs use only `propext` and
`Quot.sound`; no admitted theorem is used.
