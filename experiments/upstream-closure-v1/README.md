# Upstream closure mailbox

An ordered closure marker binds the full host context and closure round.
A held request/acknowledgement handshake consumes closure before reopening;
stale rounds, partial writes and context changes fail closed.

The host must close software publication before sending the marker and issue
hardware STOP only after acknowledgement. Closure is not DMA drain. PCIe
ordering, coordinated reset and integration with admission remain separate
requirements.
