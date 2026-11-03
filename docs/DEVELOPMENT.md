# Development

Use VCS for RTL simulation and Lean 4.19 for formal models. Host snapshot tests
use `tests/fixtures/generated-kernel-abi.json`; that fixture is not image identity
or a hardware admission certificate. Runtime headers are pinned by the Git submodule.

Compiler-generated kernel RTL and Quartus libraries must be supplied locally for
source-bound ABI extraction and full VCS integration. `tools/prepare_corrected_kernel.py`
currently consumes retained compiler inputs under `qualification/` and the CRA
source packet under `reviews/`; those generated/private inputs are excluded.
The public host snapshot checks and driver fault tests require neither tree.

The production executor requires verified image/source association, exclusive
CRA access, ordered device writes, non-replayed read-clear operations, and
independent retirement of all kernel and DMA references. Its injected transport
has no default MMIO implementation. Never infer retirement from reset or an IRQ.

`experiments/dma-status-v2` contains an unadopted finite-lifecycle candidate.
Its source-bound generator requires the original vendor engine/controller/FIFO
and source packet supplied explicitly. Preserve vendor notices and obtain
licensed tools separately. Existing file-level licenses continue to apply;
this repository does not relicense third-party components.

Keep reviews tied to exact commits and paths. Validate changes locally before
adoption. Do not post conversations, credentials, host inventories or build dumps.
