/* SPDX-License-Identifier: BSD-3-Clause */
#include <linux/errno.h>
#include <linux/string.h>
#include "aclpci_dma_request.h"

int aclpci_dma_request_init(struct aclpci_dma_request *r,
                           struct aclpci_user_dma *mapping, u64 device_address,
                           unsigned int first_id, bool device_to_host)
{
    if (!r || !mapping || !aclpci_user_dma_segments(mapping) ||
        !aclpci_user_dma_matches_direction(mapping, device_to_host) ||
        first_id >= 128 || (device_address & 3))
        return -EINVAL;
    memset(r, 0, sizeof(*r));
    r->mapping = mapping;
    r->cursor.device_address = device_address;
    r->first_id = first_id;
    r->device_to_host = device_to_host;
    r->phase = ACLPCI_REQUEST_READY;
    return 0;
}

int aclpci_dma_request_build(struct aclpci_dma_request *r,
                            struct aclpci_batch_descriptor *table)
{
    int error;

    if (!r || !r->mapping || !table)
        return -EINVAL;
    if (r->phase != ACLPCI_REQUEST_READY || r->stop)
        return -EBUSY;
    error = aclpci_dma_build_batch(r->mapping, &r->cursor, r->first_id,
                                  r->device_to_host, table, &r->count, &r->pending);
    if (error || !r->count) {
        r->result = error ? error : -EINVAL;
        r->phase = ACLPCI_REQUEST_TERMINAL;
        return r->result;
    }
    r->phase = ACLPCI_REQUEST_BUILT;
    return 0;
}

int aclpci_dma_request_submit(struct aclpci_dma_request *r, u64 *ticket)
{
    if (!r || !ticket || !r->mapping)
        return -EINVAL;
    if (r->phase != ACLPCI_REQUEST_BUILT || r->stop)
        return -EBUSY;
    if (r->sequence == ~(u64)0) {
        r->result = -EOVERFLOW;
        r->phase = ACLPCI_REQUEST_TERMINAL;
        return r->result;
    }
    *ticket = ++r->sequence;
    r->phase = ACLPCI_REQUEST_IN_FLIGHT;
    r->may_have_written |= r->device_to_host;
    return 0;
}

int aclpci_dma_request_retire(struct aclpci_dma_request *r, u64 ticket)
{
    if (!r || !r->mapping)
        return -EINVAL;
    if (r->phase != ACLPCI_REQUEST_IN_FLIGHT || ticket != r->sequence)
        return -ESTALE;
    r->cursor = r->pending;
    r->first_id = (r->first_id + r->count) & 127;
    if (r->stop) {
        r->result = -ECANCELED;
        r->phase = ACLPCI_REQUEST_TERMINAL;
    } else if (r->cursor.segment == aclpci_user_dma_segments(r->mapping)) {
        r->result = 0;
        r->phase = ACLPCI_REQUEST_TERMINAL;
    } else {
        r->phase = ACLPCI_REQUEST_READY;
    }
    return 0;
}

void aclpci_dma_request_stop(struct aclpci_dma_request *r)
{
    if (!r || !r->mapping || r->phase == ACLPCI_REQUEST_TERMINAL)
        return;
    r->stop = true;
    if (r->phase != ACLPCI_REQUEST_IN_FLIGHT) {
        r->result = -ECANCELED;
        r->phase = ACLPCI_REQUEST_TERMINAL;
    }
}

int aclpci_dma_request_release(struct aclpci_dma_request *r)
{
    if (!r || !r->mapping)
        return -EINVAL;
    if (r->phase != ACLPCI_REQUEST_TERMINAL)
        return -EBUSY;
    aclpci_user_dma_release(r->mapping, r->may_have_written);
    r->mapping = NULL;
    return 0;
}
