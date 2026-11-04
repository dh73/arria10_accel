# Driver-command mailbox integration

Runs the host mailbox sequencer and PCIe command adapter against the mailbox
and clock-crossing RTL. The syscall fixture checks BAR, offset, size and endian
fields before forwarding each transaction. The CRA endpoint is synthetic.

Checks masked writes, two read-clear transactions, and an accepted start whose
acknowledgement is lost. The host retains uncertainty and never repeats it.
The test completes four commands with exactly one start.

Uses `../mailbox-host-rtl-v1/tb.sv`. No physical device or kernel driver is loaded.
