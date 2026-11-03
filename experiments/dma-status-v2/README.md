# DMA status contract candidate-v2

This separate candidate changes no immutable source, peer checkout, production driver or FPGA image. **Production contract_valid remains false.** No hardware readiness is claimed.

## Generate and run

Run from the repository root, passing the actual immutable files explicitly:

```sh
python3 experiments/dma-status-v2/tools/build_candidate.py \
  --source-packet /path/to/retained-source-packet.txt \
  --read-engine qualification/read-dma-retirement-v1/source/altpcieav_dma_rd.sv \
  --fifo qualification/read-dma-retirement-v1/source/altpcie_fifo.sv \
  --controller qualification/read-dma-retirement-v1/source/altpcie_dynamic_control.sv \
  --out experiments/dma-status-v2/generated

python3 experiments/dma-status-v2/tests/run_vcs.py \
  --engine experiments/dma-status-v2/generated/altpcieav_dma_rd_candidate_v2.sv \
  --controller experiments/dma-status-v2/generated/altpcie_dynamic_control_candidate_v2.sv \
  --fifo experiments/dma-status-v2/generated/altpcie_fifo.sv \
  --quartus-simlib /absolute/quartus-23.1std/eda/sim_lib --vcs vcs --runner vcs-run

gcc -std=c11 -Wall -Wextra -Werror -pedantic \
  -I experiments/dma-status-v2/tests/host_stubs \
  experiments/dma-status-v2/tests/host_status_v2_test.c \
  experiments/dma-status-v2/host/aclpci_dma_request.c -o /tmp/dma_host_v2_test
/tmp/dma_host_v2_test

LEAN_BIN=/absolute/lean-4.19.0-linux/bin/lean \
  sh experiments/dma-status-v2/formal/check_lean.sh
```

Use the actual read-engine basename if different. The packet SHA-256 must equal `1b6eb7ecffd7758ca5d0c1e12a29fe9036dc806428137fc5e2f3d87222c988f5`. Whole read-engine/FIFO token equality is required, ignoring only comments/whitespace. A copy of the original is transformed, preserving its license and OEM pragma. The unchanged vendor FIFO is copied. Output must be a new directory; there is no overwrite option.

Only supplied controller regions are transformed. All legacy status consumers are inventoried; an active omitted consumer of a removed FIFO/DCM signal causes refusal naming its signal and line. Supply those exact statements and their surrounding logic if refused. Unchanged omitted regions are not qualified by copying them.

## Retirement and finite storage

Acceptance reserves one of sixteen owners with full8-bit ID; a live duplicate ID backpressures. The slot follows descriptor FIFO, PCIe tag, completion capture, command FIFO and active Avalon command. Real MRd/tag-release events account read debt. Accepted completion headers add command debt; only a command's final accepted Avalon beat removes it. Issuer closed plus both debts zero permits success, including when status becomes eligible after data has already drained.

Successful publication follows admission order. A sixteen-entry order FIFO advances only on the exact success ACK after local flag and optional MSI acceptance. Earlier errors quarantine their owners and block later success, while error reports remain transmissible. This preserves the last-ID implication locally; host visibility remains a shell gate.

The payload writer waits for an entire command's data, uses an idle/pipe gap between bursts, and never prefetches across a command boundary. The original completion parser still requires complete CplDs buffered upstream; receive gaps tested here are between packets only.

Finite storage: sixteen owners, existing sixteen-command FIFO with its eight-entry admission threshold, one held engine status, and sixteen controller status entries. Header admission leaves room for capture and active-command debt. Errors never free owners, even after diagnostics drain. A slot generation increments through1..255 and never wraps; all slots eventually exhaust after at most4080 allocations per fenced reset epoch.

## Wire and host status

| Bits | v2 meaning |
|---|---|
|31:28|Exactly2|
|27:24|Cumulative causes: master-disabled1, pause2, abort4, flush8|
|23:16|Nonzero slot generation|
|15:12|Owner slot|
|11|Local retirement; never host visibility or a PCIe drain certificate|
|10,9,8|Terminal, error, success|
|7:0|Full ID, including fetch IDs128..255|

PF0 only: old function bits become generation. Success is cause0/flags11:8=0xd. Pause is cause2/flags0. Fatal causes set terminal+error, clear success; this implementation always clears their local-retirement bit. Abort/flush do not imply no future writes: issued completions continue draining. Repeated identical causes are coalesced; new cause bits survive backpressure and generate cumulative records. Independent simultaneous events retain distinct identities.

Controls use load&&ready; hold data while not ready. Pause/abort target the active issuer; flush cancels every unsealed accepted owner, retaining queued identities. Resume overrides pause when both set. Denied arbitration no longer consumes a tag.

The sink writes exact host flag1 only for exact success; other valid data statuses are written literally to their own row regardless ctrl[0]. Fetch success/errors use separate channels; IDs>=128 never alias data rows. Malformed words remain held under sticky fault. Base/MSI configuration is captured on status admission; keep table configuration stable until publication.

## Integration boundaries

Connect engine RdDmaTxData_o/Valid_o to controller DmaRxData_i/Valid_i; controller DmaRxReady_o to engine RdDmaTxReady_i; controller DmaAckValid_o/Data_o to engine RdDmaAckValid_i/Data_i. Honor RdDMACntrlReady_o. Keep FetchStatusReady_i=0 until omitted fetch consumers can accept sanitized success. Store/handle diagnostic words before asserting StatusDiagnosticReady_i; errors produce no retirement ACK.

Expose ContractFault_o and StatusProtocolFault_o independently. Invalid headers are rejected before payload creation. Fault stops new allocations, MRds and status selections; an already-held locally retired success is not retracted by an unrelated fault.

Reset clears bookkeeping, not external transactions or mappings. Before readmission, independently fence old completions, posted writes, MSI, ACKs and host-table reuse. Generation restarts and cannot distinguish cross-reset stale traffic. A byte-identical illegal completion after PCIe-tag reuse also carries no owner epoch; valid completion lifecycle remains an explicit shell assumption.

Supported regression profile:256-bit data,32byte enables, burst width5,16 nonextended tags/tagwidth4,160-bit descriptors,266-bit RX/260-bit TX, native scfifo, PF0 READ_CONTROL=1. Matrix uses MRRS128 and256-byte descriptors. Other lengths, alignments, MRRS and configurations need acceptance tests.

Host files are isolated derivatives of supplied request-owner code. Use existing batch/mapping dependencies. harvest_locked_v2.inc replaces only the supplied function in a candidate copy of its driver; include aclpci_dma_status_v2.h and the candidate owner. Omitted initialization, IRQ, submit/remove and build files are not patched or claimed inspected. Harvest scans all owned rows for nonzero!=1, permanently faults and retains mappings. Only qualified exact last flag1 reaches dma_rmb and ordinary retirement. The fault-retirement helper has no automatic caller and requires independent no-future-DMA/no-late-status evidence.

## Actual validation and remaining gates

Portable strict C compile/execution PASS; Python syntax PASS; Lean4.19 model base/step/induction PASS. VCS invocation returned77 because vcs is unavailable: no RTL compile/simulation pass is claimed. The immutable packet path is absent here, so complete source generation was not executed.

37 planned VCS cases:24payload;2disabled-master;6control/reuse/fetch; owner/sink units;3actual engine/controller error cases programmed through registers. No force. Tests cover simultaneous events, held outputs, finite queues, reused IDs, generation exhaustion, local reset and flag/MSI ordering. They do not prove FIFO ordering or fairness. See formal/VALIDATION.md.

Remaining gates: full generation and VCS matrix with vendor models; RTL event/counter/FIFO refinement; progress under fair drains; omitted fetch/controller paths; HIP posted ordering/host visibility; Linux mapping lifetime; coordinated reset; synthesis/fit/timing; and installed ASUS image identification. Hardware access is unavailable.
