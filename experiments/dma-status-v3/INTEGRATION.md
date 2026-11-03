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

The application candidate elaborates with its retained hierarchy at default
parameters. Width warnings remain: FIFO occupancy narrowing, the predecoded
tag's ninth bit, write-reset vector truncation, and write/CRA interface widths.
These require exact-configuration and reachable-range validation before
behavioral acceptance. In particular, a depth-16 FIFO exposes a five-bit count;
a four-bit consumer would observe zero at occupancy 16 if that state is reached.
Elaboration alone does not prove the flow-control invariant excludes it.

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

`tests/adapt_side_fifo.py --source ../dma-status-v2/tests/read_dma_candidate_v2_tb.sv --output /new/path/read_dma_side_fifo_v3_tb.sv`
derives a read-only producer test with the actual depth-16 FIFO and the
application's registered input stage. Compile the generated test with the v3
read engine, owner, status package, unchanged FIFO and memory models. Run
`+SCENARIO=0 +N=8 +MODE=0` through `+MODE=5`.
The test blocks downstream reads until near-full occupancy, verifies issue
stops during a held stall, then drains intermittently. It checks all 16 request
headers for loss/reordering, checks the full five-bit occupancy stays below
16, and retains payload/status/receipt checks. It does not model RXM/TXS
writers or prove the shared arbiter's occupancy bound. Execution results are
separate from this test definition.

All six modes pass with 16 ordered request headers, 64 accepted payload beats
and eight terminal completions per mode. The highest observed occupancy is
14 in every case; the producer stops issuing during sustained downstream
backpressure. This is finite read-producer coverage, not an all-state bound
or validation with competing RXM/TXS writers.
