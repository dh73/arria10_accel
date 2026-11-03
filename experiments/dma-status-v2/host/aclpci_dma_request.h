/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_DMA_REQUEST_H
#define ACLPCI_DMA_REQUEST_H
#include "aclpci_dma_batch.h"
enum aclpci_request_phase {
    ACLPCI_REQUEST_READY,
    ACLPCI_REQUEST_BUILT,
    ACLPCI_REQUEST_IN_FLIGHT,
    ACLPCI_REQUEST_TERMINAL,
};
/* Caller serializes ALL operations, including IRQ-deferred retirement and
 * stop/remove. A hardware-facing wrapper must validate completion status and
 * preserve coherent tables/device context until this owner is releasable. */
struct aclpci_dma_request {
    struct aclpci_user_dma *mapping;
    struct aclpci_batch_cursor cursor, pending;
    enum aclpci_request_phase phase;
    unsigned int first_id, count;
    u64 sequence;
    bool device_to_host, stop, may_have_written;
    bool fault_latched;
    int result;
};
int aclpci_dma_request_init(struct aclpci_dma_request *request,
    struct aclpci_user_dma *mapping, u64 device_address,
    unsigned int first_id, bool device_to_host);
int aclpci_dma_request_build(struct aclpci_dma_request *request,
    struct aclpci_batch_descriptor *table);
/* Reserve ownership BEFORE MMIO doorbell under the submission/stop lock.
 * Ambiguous delivery remains IN_FLIGHT, never retried or released. */
int aclpci_dma_request_submit(struct aclpci_dma_request *request, u64 *ticket);
/* Only after hardware-qualified table success and dma_rmb(). A faulted owner
 * cannot be repaired by a later success flag or ordinary retirement call. */
int aclpci_dma_request_retire(struct aclpci_dma_request *request, u64 ticket);
/* Preserve mapping, ticket, and IN_FLIGHT phase. First error wins. */
int aclpci_dma_request_latch_error(struct aclpci_dma_request *request,
    u64 ticket, int error);
/* The caller must independently establish no future DMA reads/writes and no
 * late status/MSI for this request, fencing its lifetime identity and ticket.
 * Decoder, abort, reset, IRQ, read-back, timeout, and elapsed time MUST NOT call
 * this API as retirement evidence. No production caller is added by v2. */
int aclpci_dma_request_confirm_fault_retirement(struct aclpci_dma_request *request,
    u64 ticket);
void aclpci_dma_request_stop(struct aclpci_dma_request *request);
int aclpci_dma_request_release(struct aclpci_dma_request *request);
#endif
