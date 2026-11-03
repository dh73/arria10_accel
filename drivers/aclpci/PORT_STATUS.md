# In-progress ASUS kernel port

Copied from the preserved official Intel historical source at
`third_party/fpga-partial-reconfig-16.1/ref_designs/a10_pcie_devkit_cvp/software/driver`.
Original per-file license notices are retained. This is an unfinished port;
do not run the inherited install scripts or load this module as a qualified
compute driver. Matching hardware ABI and safe DMA lifetime are still open.

Current integration,2026-11-03: review fb429072 is adopted after resolving
two context conflicts and two native API issues. Full source now connects
mapping/batch/request ownership to submission, IRQ/worker, close and remove.
Local W=1 compilation/modpost/module linking pass against
4.18.0-553.180.1.el8_10.x86_64 headers. The13 integration suites pass normally
and under ASan/UBSan with leak detection; four original component suites pass.
See DMA_INTEGRATION.md and reviews/driver-integration-v1/adoption.json.

The native correction uses pci_channel_offline, so frozen as well as permanently
failed PCI channels avoid IRQ MMIO. A regression exercises this behavior.
SIZE_MAX>>1 retains the actual signed-return representability bound where
SSIZE_MAX is unavailable. It adds no arbitrary workload cap.

The default system GCC8 and toolset15 installations lack sanitizer runtimes.
Sanitized validation instead used the existing complete Questa GCC10.3 toolchain
and its matching runtimes; no host compiler or runtime installation was changed.

Actual ASUS Fedora kernel compilation now passes for this integration:
qualification/driver-fedora-v1/result.json records native make W=1 modules,
kernel7.2.14-200.fc44.x86_64, exit0, unchanged source hashes, completed modpost
and linked altr_aclpci_cvp_drv.ko. Build log and module were retrieved locally.
Unused-constant/prototype warnings remain; BTF was skipped without vmlinux.
No module installation, load, binding or hardware test was performed.
The candidate module was not copied into the production source or loaded.
Hardware admission deliberately remains blocked (`contract_valid=false`):
current-image identity, table retirement/no-late-write guarantees and safe PCI
removal/IOMMU containment are not supplied. Retained software ownership alone
cannot preserve a DMA domain through PCI core removal. Do not remove this gate
merely because host tests or compilation pass.

Historical initial port changes and validation (superseded where stated):

- Replace removed timeval/do_gettimeofday telemetry with monotonic nanoseconds
  from ktime_get_ns. This changes diagnostic timing only, not DMA control.
- Use kernel_siginfo, including initializer pointer and sizeof, and explicit
  sched/signal.h for kernel signal delivery.
- Use dma_set_mask_and_coherent and check its combined return value, retaining
  the original64-bit requirement. Previously coherent-mask failure was ignored.
- Use current class_create signature and remove obsolete
  MODULE_SUPPORTED_DEVICE; the PCI match table is unchanged.

Actual ASUS builds use kernel7.2.14-200.fc44.x86_64. Logs01–03 are retained in
`qualification/aclpci-port-v1`. Build03 compiles aclpci.o and aclpci_fileio.o,
then fails in aclpci_dma.o on removed PCI_DMA_FROMDEVICE/PCI_DMA_TODEVICE names.
The full module has not built. Kernel/compiler package mismatch and prototype
warnings remain visible.

The DMA source bypasses mapping on little-endian systems and uses page_to_phys.
It also uses obsolete task/mm page pinning and has incomplete error unwind.
These require substantive changes, not compatibility macros. Web implementation
review1a8e5485-c3e1-4e42-9dbc-642698cfaa2f has a frozen current-source packet plus
actual kernel header declarations and requests a complete mapping/lifetime patch.
That original review is terminal invalid_reply (sandbox link instead of literal
patch); no code was adopted. Its request/response remain preserved.

New integration request fb429072-303f-461b-ad41-90e50678e563 binds the current
mapping/batching/request-owner components plus the old driver paths and asks
for their actual IRQ/worker/close/remove integration. It is a new source packet,
not a replay of the rejected original. reviews/driver-integration-v1 holds the
immutable question,15 source pins and submission. Native waiter returned an
unreadable-original attention and exited. One same-original read retained
waiting/Send1/CHAT_SCOPE_CHANGED, no payload. After verifying the waiter dead,
one local inotify exact-record subscriber was armed and process/fd-verified;
it returns a terminal/material event to this thread without browser polling.
That event has now arrived; guarded original DONE and literal patch hash were
verified. The candidate at reviews/driver-integration-v1/candidate resolves
two textual context conflicts and passes13 executable mock-kernel suites.
The first native local4.18 build failed on missing pci_dev_is_disconnected;
native-build.log retains that error. native-build-v2 records the later SSIZE_MAX
failure; native-build-v3 is successful after the corrections above. Source is
adopted; no module is loaded.
The original source pins, rejected hunks and upstream notices are preserved.
Hardware admission is disabled in the candidate pending actual retirement and
PCI-removal containment contracts. Review is not proof or hardware acceptance.
