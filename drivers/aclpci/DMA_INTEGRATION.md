# Historical ACL PCIe DMA integration

## Admission and the missing hardware contract

The supplied historical register/descriptor ABI is implemented. Production
admission is deliberately blocked: aclpci_dma_init() leaves contract_valid false,
probe leaves io_blocked true, and no module parameter, PCI ID, or user command
can change that. Probe does not enable bus mastering, install an IRQ, or program
DMA registers in this mode. Metadata/status commands remain available. Memory
I/O returns -EOPNOTSUPP. The six supplied mapping/batch/request files remain
unchanged and are now linked and called by the actual driver's DMA path.

A future reviewed, kernel-owned shell integration must establish all of these
before enabling admission; setting a Boolean based on PCI IDs is insufficient:

* The endpoint is initially quiescent, with no inherited descriptor fetches,
  status writes, or other host-memory transactions.
* Historical table layout, FIFO programming, LAST_PTR progression, 4-KiB
  boundaries and completion value 1 have the semantics assumed here.
* Writing 1 to the current direction's current last-ID status word retires
  every transaction for that table, including host writes and descriptor/status
  accesses. Those writes precede the IRQ. No previous table can write a late
  status word after its retirement, including when IDs wrap or requests change.
  Software tickets are not transmitted to hardware and cannot prove this.
* Device removal, suspend, reset and reprogramming cannot revoke the device's
  DMA/IOMMU context or permit reuse before all endpoint DMA is independently
  contained. This includes initiators outside this descriptor engine.
* For kernel-completion IRQs, userspace clears the completion cause before
  explicitly rearming ENABLE_KERNEL_IRQ, as required by the historical ABI.

The packet supplies neither an abort/drain acknowledgement nor a trustworthy
post-programming qualification mechanism. This patch invents neither. There is
no reset-as-drain, bus-master-disable-as-drain, timeout, polling loop, or forced
unpin. No hardware was loaded, bound or programmed during development.

The match table remains vendor 1172, original class/mask and subsystem
1172:0001. Probe rechecks those same restrictions, including dynamic-ID probes.
The reported 1172:2494 / 1172:a151 image is UNKNOWN and mismatched.

## Ownership and ordering

The device semaphore serializes syscalls, open/close, save and remove. The DMA
mutex serializes request construction, submission, worker retirement and stop.
The worker never takes the device semaphore.

Submission validates and pins/maps the whole range in the submitting task's
mm, retaining that mm and the DMA device. It preflights every table before the
first doorbell, then reserves request ownership and submits the first table in
the syscall. Allocation, pinning, mapping, range, direction and preflight
failures return synchronously without an asynchronous completion notification.

One request owner spans all tables. The coherent layout stays 512 bytes of
status followed by 128 descriptors of 32 bytes. Descriptors use dma_map_page
addresses on every endianness. dma_wmb() orders zeroed status and descriptors
before publication. The worker validates direction, bounded current last ID,
and exact little-endian status 1, then uses dma_rmb() before retirement.
Mapping release also performs the original-direction DMA unmap before exposing
the final completion. Device-to-host pages are dirtied conservatively if any
batch might have been published.

IRQ processing never clears a descriptor status word, retires a request, or
caches a request pointer/ticket. queue_work() coalesces or requeues a current-state
rescan, including an IRQ arriving during the callback. Hardware IRQ delivery is
still a hardware requirement; DMA_UPDATE provides an explicit one-shot rescan.
There is no timer or hardware polling loop.

A malformed nonzero status or invalid status-index bookkeeping permanently
faults admission and retains the request, even if a later value becomes 1.
Stop cancels future batches, not the currently owned DMA transaction.

A request retains a task_struct reference, a signal payload snapshot and an
independent reference-counted file context. It never relies on the current
worker's mm or a raw task/file pointer. The context holds a device-state
reference and an additional module reference beyond struct file's lifetime.
Its destructor neither takes the semaphore nor flushes the workqueue.

Final notification is ordered under the DMA mutex before a subsequent request
can be admitted. The legacy signal number and si_int payload remain unchanged;
si_errno carries a positive asynchronous errno. There is one notification
attempt after qualified final release. An exited task or signal-delivery error
cannot be promised a delivered signal; there is no duplicate retry, and the
completion result remains queryable until the next accepted request.

## ABI-visible behavior

* Accepted asynchronous DMA still returns zero.
* GET_DMA_IDLE_STATUS copies u32 0 while active or 1 after successful completion.
  A latched asynchronous error is returned as a negative syscall errno, never
  converted into a nonzero unsigned "idle" value.
* DMA_STOP returns -EINPROGRESS while an in-flight table remains owned.
  After its qualified retirement the request reports -ECANCELED.
* PIN_USER_ADDR, UNPIN_USER_ADDR and GET_PHYS_PTR_FROM_VIRT return -EOPNOTSUPP.
  Obsolete standalone GUP functions are removed.
* Unmeasured GET_PCI_GEN/GET_PCI_NUM_LANES return -EOPNOTSUPP; cached zeros
  are not advertised as measured link data.
* PR and FPGA-manager reprogramming return -EOPNOTSUPP pending the missing shell
  contract. Direct writes overlapping known DMA, IRQ, PR or reset registers are
  rejected, so raw BAR I/O cannot bypass ownership.
* SAVE requires qualified idle state. It blocks new I/O, releases the IRQ,
  clears BME only after that quiescence check, and saves a BME-clear snapshot.
  It invalidates shell qualification even on failure. LOAD returns -EINVAL
  without a saved state or -EOPNOTSUPP with one: blindly restoring/retraining an
  unqualified image would be unsafe. No false success is reported.
* Normal PIO and DMA admission exclude an owned request. BAR bounds include
  offset plus length, failed user copies do not write stack garbage, and the
  memory-window shadow updates only after a successful single-copy write.
  A PIO fallback spanning a hardware window returns -ERANGE.
* Every I/O through an existing file after remove returns -ENODEV before BAR
  access; close still releases its software context.

## Close, remove and allocation failure

DMA/work/coherent tables initialize before IRQ registration and cdev publication.
Probe failures unwind only acquired resources. IRQ release masks and flushes
the MMIO mask, synchronizes/frees the actual requested IRQ, then disables MSI.
It does not free DMA state. The worker can never race IRQ access to freed tables.

Last close masks the kernel notification source and requests cancellation.
It does not destroy the DMA workqueue or release an in-flight mapping. The IRQ
and worker remain available to process a real final status after close.

Remove marks the software device offline and unpublishes the cdev, stops future
batches, removes IRQ producers, performs one final nonpolling status rescan,
and flushes work without holding the DMA mutex. Qualified idle state permits
normal table/BAR/resource cleanup. Open contexts retain the offline allocation.

Unknown retirement keeps the original state reference, mapping, pages, mm,
coherent tables, workqueue, BAR reservations and device reference, and pins
the module. A module-wide quarantine rejects later probes, including a new
pci_dev allocated for a hot-remove/rescan of the same function.

This retention is damage containment, NOT proof of safe PCI removal. Linux's
PCI remove callback cannot reject removal; get_device/pci_dev_get do not pin an
IOMMU domain. suppress_bind_attrs removes the ordinary sysfs bind/unbind
interface, but cannot prevent hot removal, forced unload, core detach or
platform reconfiguration. An already-running unknown DMA transaction can
therefore outlive the kernel DMA context despite retained driver memory.
There is no production reclaim/recovery path for quarantine. The default
blocked admission is essential until an external shell/platform contract
solves that limitation.

## Executable tests

From the repository root:

    sh drivers/aclpci/tests/run-integration.sh

For AddressSanitizer plus UndefinedBehaviorSanitizer:

    ASAN_OPTIONS=detect_leaks=0 \
    CFLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer' \
    sh drivers/aclpci/tests/run-integration.sh

The runner compiles actual production mapping, batch, request, DMA, file-I/O
and lifecycle C with mocked kernel services/MMIO. Thirteen suites exercise
partial failure unwind, all 1024 aligned offsets, a 260-page/four-table transfer,
direction/status/ticket validation, IRQ requeue during a running worker,
notification deduplication, real last-close ownership, protected raw accesses,
14 lifecycle allocation/IRQ/publication failure stages, offline file lifetime,
IRQ ordering and permanent unknown-drain quarantine/reprobe refusal.

These are executable fault tests, not source-token assertions or native kernel
proofs. The shims model API behavior and selected interleavings, not the real
scheduler, DMA coherency, IOMMU or omitted original command/PR code. Hardware
contracts are test assumptions, not established by passing these tests.
Quarantined fake resources are reclaimed only by explicit test-fixture cleanup
outside production code after retention is checked.

Fresh runs with GCC 13.3.0 passed all thirteen suites, also under ASan/UBSan
with leak detection disabled. Default LeakSanitizer could not inspect the
environment's /proc task state; no LeakSanitizer pass is claimed. Explicit
resource ownership counters passed. No local kernel build tree, VCS or Jasper
executable was available. No native target build, module load, hardware test,
Jasper proof or new Lean proof was performed.

## Native target build, without loading

The original repository must supply its unchanged command/PR/queue sources,
complete hardware/export headers, version.h and other original dependencies.
This patch changes only supplied command-function excerpts; it does not
reconstruct omitted definitions.

    git apply --check implementation.patch
    git apply implementation.patch
    sh drivers/aclpci/tests/run-integration.sh
    aclpci_krel=7.2.14-200.fc44.x86_64
    aclpci_kdir=/usr/src/kernels/"$aclpci_krel"
    test -r "$aclpci_kdir/Makefile"
    make -C "$aclpci_kdir" M="$PWD/drivers/aclpci" W=1 modules
    modinfo -F vermagic drivers/aclpci/altr_aclpci_cvp_drv.ko

The installed development tree must exactly match the stated Fedora kernel.
Resolve any additional build failure using that tree and the actual omitted
sources; mocks are not substitutes for native ABI checks. No install, modprobe,
insmod, bind, new_id, reset or programming command is part of this procedure.

All original per-file license notices are retained. The six component files
retain BSD-3-Clause notices; the linked module remains MODULE_LICENSE("GPL").
account_locked_vm is GPL-only, so this Linux module must remain GPL-compatible.

API references: https://docs.kernel.org/core-api/dma-api-howto.html and
https://docs.kernel.org/core-api/pin_user_pages.html .

## Supplied-text integrity limitation

Eleven reconstructed full-file baselines reproduce their supplied SHA-256.
The literal aclpci_fileio.c text was independently reconstructed twice, with
identical bytes and SHA-256
593e18b78c64033d50ca0b27c7d5b23d3146529f2ccc2aed5e8219a0d83a47cf,
which differs from the advertised 99e7bf2f556ee679de6428efb2294f58ac52f8845b47a15e425cfd16dcb149f3.
Patch context uses the supplied literal text, not an inferred unseen revision.
Apply-check must therefore be run against the actual checkout. The original
source-packet path was not available here and its whole-file digest was not
verified. Omitted command regions are preserved; only shown excerpts change.
