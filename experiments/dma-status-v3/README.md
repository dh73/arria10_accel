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
