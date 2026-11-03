/* SPDX-License-Identifier: BSD-3-Clause */
/* Replacement for ONLY the supplied harvest_locked() excerpt, in an isolated
 * candidate copy of its containing driver. Include aclpci_dma_status_v2.h and
 * build against the candidate request owner. No production caller is changed.
 * Production contract_valid remains false; v2 never sets it to true. */
static int harvest_locked(struct aclpci_dma *d)
{
    struct aclpci_dma_request *r = &d->request;
    unsigned int index, direction, scan;
    enum aclpci_host_status_v2 decision;
    u32 status;
    int error;
    if (!d->active || r->phase != ACLPCI_REQUEST_IN_FLIGHT)
        return 0;
    if (d->fault)
        return d->fault;
    direction = r->device_to_host;
    if (r->first_id >= 128 || !r->count || r->count > 128 - r->first_id) {
        error = -EIO;
        goto fault;
    }
    index = r->first_id + r->count - 1;
    if (d->last_id[direction] < 0 || d->last_id[direction] >= 128 ||
        (unsigned int)d->last_id[direction] != index) {
        error = -EIO;
        goto fault;
    }
    /* A failure on an earlier descriptor must be noticed even while the last
     * row is zero. Prefix retirement blocks the last success after any earlier
     * quarantined owner. Scanning errors does not itself establish drain. */
    for (scan = r->first_id; scan <= index; scan++) {
        status = le32_to_cpu(READ_ONCE(d->tables[direction]->header.flags[scan]));
        if (status != 0 && status != 1) {
            error = -EIO;
            goto fault;
        }
    }
    status = le32_to_cpu(READ_ONCE(d->tables[direction]->header.flags[index]));
    decision = aclpci_dma_host_status_v2(status, index,
                                       READ_ONCE(d->contract_valid), NULL);
    if (decision == ACLPCI_HOST_PENDING)
        return 0;
    if (decision != ACLPCI_HOST_SUCCESS) {
        error = decision == ACLPCI_HOST_UNQUALIFIED ? -EOPNOTSUPP : -EIO;
        goto fault;
    }
    /* Only qualified exact flag1 reaches here. The shell must independently
     * order all table transactions before this write and fence stale status. */
    dma_rmb();
    error = aclpci_dma_request_retire(r, d->ticket);
    if (error)
        goto fault;
    return 1;
fault:
    d->fault = error;
    WRITE_ONCE(d->contract_valid, false);
    /* A later flag overwrite cannot repair this request. Error, pause, abort,
     * flush, and local_retired do not establish independent retirement. */
    (void)aclpci_dma_request_latch_error(r, d->ticket, error);
    aclpci_dma_request_stop(r);
    return error;
}
