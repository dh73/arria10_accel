# Containing-shell integration

`tools/build_control_wrapper.py --source /path/to/dma_controller.sv --output DIR`
generates the read-side wrapper candidate from the exact retained source hash.
It exposes receipt, status-ready, fetch-acceptance and diagnostic channels,
passes `DMA_WIDTH` explicitly, and retains the complete write-controller tail
unchanged. The output directory must be new. Containing-parent wiring and
native qualification remain outstanding; generation alone is not acceptance.

The generated controller wrapper elaborates with the actual v3 read controller,
unchanged original write controller and FIFO models. Both reported port-count
warnings concern the unused FIFO `eccstatus` output; no FIFO input is missing.
This result covers elaboration only, not handshake behavior or hardware.

`tools/build_app_wrapper.py --source /path/to/altpcieav_256_app.sv --output DIR`
generates the matching application wrapper. It retains `Rstn_i[6]`, the
existing disabled control-load input, and the complete write-mover/downstream
logic. Completer-only mode drives the added outputs inactive.

The parent must connect these new channels directly alongside the existing
status data/valid path:

| Controller wrapper | Application wrapper |
| --- | --- |
| `RdStatusReady_o` | `RdStatusReady_i` |
| `RdReceiptValid_o` | `RdReceiptValid_i` |
| `RdReceiptData_o` | `RdReceiptData_i` |
| `RdReceiptConsumed_i` | `RdReceiptConsumed_o` |

Controller fetch/diagnostic acceptance inputs still require real consumers.
Application `RdContractFault_o` and controller fault outputs require retained
host-visible handling. Exposing them does not implement that handling.

`tools/build_parent_wrapper.py --source /path/to/pcie_parent.v --output DIR`
connects these four channels in the source-pinned HIP parent and exposes fetch
acceptance, diagnostics and faults as `CandidateRd*` ports. It supports only
internal-controller 256-bit AVMM DMA. Its simulation guard rejects other
configurations; synthesis configuration and full-parent elaboration remain
unqualified. Existing PCIe, descriptor and payload connections are retained.

The retained shell connects the read mover and controller through
`dut_rd_ast_tx_data` and `dut_rd_ast_tx_valid`. It has no status-ready or
receipt-return wires. Replacing the two leaf modules alone is insufficient.

| Boundary | Required change |
| --- | --- |
| `dma_control` in `dma_controller.sv` | Replace only `read_control` with the v3 controller. Preserve the original `READ_CONTROL=0` write controller and descriptor-fetch interconnect. |
| `altpcieav_256_app` | Replace the read mover and expose status-ready, receipt-valid/data, consumed and fault signals. Preserve the write mover. |
| Parent HIP wrapper | Connect the new channels between the two containing modules; retain the existing descriptor and payload paths. |
| Fetch completion | Derive acceptance from the real fetch consumer. Do not tie ready high without proving that consumer can accept every offered completion. |
| Diagnostic completion | Provide retained error storage and host-visible cause/descriptor identity before acknowledging consumption. Do not discard errors. |

Both containing modules use `coreclkout_hip`. The controller takes
`app_rstn[9]`; the read mover takes `app_rstn[6]`. The retained reset generator
uses `ACTIVE_RESET=0`, `WIDTH_RST=10`, `LOCK_TIME_CNT_WIDTH=1` and assigns all
ten output bits from the same `rs_meta[2]` value on each clock edge. This
establishes a shared logical reset source, not physical reset-skew closure or
safe retirement during link loss.

Integration acceptance must exercise the actual containing modules, including
the unchanged write controller, descriptor fetch, status backpressure, held
receipts, error retention, reset and token recurrence. Component tests do not
establish those properties for the shell. Physical payload visibility and
host-removal containment remain separate requirements; DMA admission stays
disabled.
