# DMA owner reuse candidate

Four-phase acknowledgement closes status custody before reusing an owner slot.
The sink holds a receipt until consumed, withdraws it, then waits for consumed
to return low. The owner releases its slot only after receipt withdrawal.

Includes RTL, source transforms, regression tests and a formal accounting model.
Generation wrap relies on the connected producer lifecycle; the token alone
cannot distinguish an injected replay after full recurrence. Errors retain owners.

The controller transform replaces the complete ingress region, including
synthesis directives. The controller is read-side only; write-side integration,
common reset, physical retirement and board qualification remain open.

## Validation

Four simulation tops and all 46 cases pass, including 12,256 lifecycles without
reset and three generation wraps per slot. Cases cover held, stale and malformed
receipts; payload retirement; errors; and actual controller receipt handling.
The formal transition model passes base, step and reachable-state obligations;
this is not RTL equivalence or physical acceptance.

The synthesis-boundary correction preserves all simulation tokens and passes
nine transformation regressions. Native synthesis and containing-shell
integration remain unqualified. Production DMA admission remains disabled.
