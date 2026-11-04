# Single-message DMA interrupts

`single_msi_tasks.svh` configures one MSI message, matching the driver's
interrupt mode. Each upload/download uses distinct interrupt data and a poisoned
host target. Receipt of the expected interrupt must follow the final descriptor
status write.

Two retained platform workloads passed all four interrupt phases, eight kernel
launches and 16 KiB of host comparisons. Native root-port simulation uses
behavioral DDR; physical interrupt delivery and Linux IRQ handling remain open.
