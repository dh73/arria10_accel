# Fetch context binding

A coherent host session and full-width epoch bind one local descriptor token per
coordinated reset. Context loss or change denies admission while preserving the
fetch identity needed by outstanding descriptors. The local token is independent
of the host epoch.

The component test covers high-word epochs, context loss/change, invalid identity
and reset. The Lean transition model proves identity retention and sticky denial
through arbitrary snapshot traces. Physical CDC timing, reset containment and
integrated descriptor retirement require separate validation.
