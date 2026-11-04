# Descriptor-control admission gate

A single retained control offer separates graceful stop from DMA session validity.
Stop rejects admission of new writes while an already captured write completes.
Status reads remain available. Address, data and byte enables stay captured until
the downstream handshake; the upstream master must hold its request until its
own handshake. A common reset terminates both sides' protocol epoch.

`write_owned` includes a same-edge capture. `stop_ack` additionally requires an
external `upstream_closed` certificate covering host reservations and transport
handoffs. Neither output certifies payload drain or PCIe posted-write settlement.

The component test exercises a stalled write across stop, blocked later writes,
status reads while stopped, missing upstream closure and unknown permission.
Integration with the actual descriptor controllers remains a separate gate.
