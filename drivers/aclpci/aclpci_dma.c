// Copyright (c) 2001-2016, Altera Corporation.
// All rights reserved.
//  
// This software is available to you under a choice of one of two
// licenses.  You may choose to be licensed under the terms of the GNU
// General Public License (GPL) Version 2, available from the file
// COPYING in the main directory of this source tree, or the
// BSD 3-Clause license below:
//  
//     Redistribution and use in source and binary forms, with or
//     without modification, are permitted provided that the following
//     conditions are met:
//  
//      - Redistributions of source code must retain the above
//        copyright notice, this list of conditions and the following
//        disclaimer.
//  
//      - Redistributions in binary form must reproduce the above
//        copyright notice, this list of conditions and the following
//        disclaimer in the documentation and/or other materials
//        provided with the distribution.
//  
//      - Neither Altera nor the names of its contributors may be 
//        used to endorse or promote products derived from this 
//        software without specific prior written permission.
//  
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//  

/* One mapping owner survives every descriptor table. The mutex serializes
 * submission, qualified retirement and stop. The hard IRQ only schedules a
 * rescan: it never clears flags or carries a request pointer/ticket. */
#ifdef ACLPCI_DMA_TEST
#include "aclpci_dma_test_kernel.h"
#else
#include <linux/overflow.h>
#include <linux/slab.h>
#include "aclpci.h"
#endif

struct dma_completion {
    struct aclpci_file *owner;
    struct task_struct *task;
    struct kernel_siginfo signal;
};

static void __iomem *dma_regs(struct aclpci_dev *aclpci)
{
    return aclpci->bar[ACL_PCIE_DMA_INTERNAL_BAR] +
           ACL_PCIE_DMA_INTERNAL_CTR_BASE;
}

/* No wait, timeout, reset, IRQ count or read-back below is drain evidence. */
static int harvest_locked(struct aclpci_dma *d)
{
    struct aclpci_dma_request *r = &d->request;
    unsigned int index, direction;
    u32 status;
    int error;

    if (!d->active || r->phase != ACLPCI_REQUEST_IN_FLIGHT)
        return 0;
    /* A malformed status or ownership invariant invalidates the contract.
     * A later overwrite with 1 cannot repair that evidence. Retain forever. */
    if (d->fault)
        return d->fault;
    direction = r->device_to_host;
    if (r->first_id >= 128 || !r->count || r->count > 128 - r->first_id) {
        d->fault = -EIO;
        WRITE_ONCE(d->contract_valid, false);
        aclpci_dma_request_stop(r);
        return -EIO;
    }
    index = r->first_id + r->count - 1;
    if (d->last_id[direction] < 0 || d->last_id[direction] >= 128 ||
        (unsigned int)d->last_id[direction] != index) {
        d->fault = -EIO;
        WRITE_ONCE(d->contract_valid, false);
        aclpci_dma_request_stop(r);
        return -EIO;
    }
    status = le32_to_cpu(READ_ONCE(d->tables[direction]->header.flags[index]));
    if (!status)
        return 0;
    if (status != 1) {
        d->fault = -EIO;
        WRITE_ONCE(d->contract_valid, false);
        aclpci_dma_request_stop(r);
        return -EIO;
    }
    /* The shell contract must order ALL table transactions before this exact
     * status write and prohibit late status writes from retired tables. */
    dma_rmb();
    error = aclpci_dma_request_retire(r, d->ticket);
    if (error) {
        d->fault = error;
        WRITE_ONCE(d->contract_valid, false);
        aclpci_dma_request_stop(r);
        return error;
    }
    return 1;
}

static void notify_completion(struct dma_completion *done)
{
    if (!done->owner)
        return;
    /* si_int remains the legacy payload; si_errno carries an async errno.
     * Send once even if the process has exited. Failure does not retry or
     * turn an already retired transfer into another completion. The caller
     * holds d->lock so notification precedes acceptance of the next request.
     * file_put is a context kref put, never fput or a worker flush. */
    send_sig_info(SIG_INT_NOTIFY, &done->signal, done->task);
    put_task_struct(done->task);
    aclpci_file_put(done->owner);
}

static int complete_locked(struct aclpci_dma *d, struct dma_completion *done)
{
    int result = d->request.result;
    int error;

    if (!d->active || d->request.phase != ACLPCI_REQUEST_TERMINAL)
        return -EBUSY;
    error = aclpci_dma_request_release(&d->request);
    if (error) {
        d->fault = error;
        WRITE_ONCE(d->contract_valid, false);
        return error;
    }
    done->owner = d->owner;
    done->task = d->task;
    done->signal = d->signal;
    done->signal.si_errno = result < 0 ? -result : 0;
    d->owner = NULL;
    d->task = NULL;
    d->async_result = result;
    d->active = false;
    return 0;
}

static int submit_locked(struct aclpci_dma *d)
{
    struct aclpci_dma_request *r = &d->request;
    void __iomem *regs = dma_regs(d->aclpci);
    unsigned int direction = r->device_to_host;
    unsigned int last = r->first_id + r->count - 1;
    dma_addr_t bus = d->table_dma[direction];
    int error;

    if (r->first_id >= 128 || !r->count || r->count > 128 - r->first_id)
        return -EINVAL;
    /* Reserve ownership before the first MMIO write. An ambiguous doorbell
     * remains IN_FLIGHT. This path never retries the table. */
    error = aclpci_dma_request_submit(r, &d->ticket);
    if (error)
        return error;
    d->active = true;
    d->last_id[direction] = last;
    dma_wmb();
    if (direction) {
        iowrite32(lower_32_bits(bus), regs + ACL_PCIE_DMA_RC_WR_DESC_BASE_LOW);
        iowrite32(upper_32_bits(bus), regs + ACL_PCIE_DMA_RC_WR_DESC_BASE_HIGH);
        iowrite32(ACL_PCIE_DMA_ONCHIP_WR_FIFO_BASE_LO,
                  regs + ACL_PCIE_DMA_EP_WR_FIFO_BASE_LOW);
        iowrite32(ACL_PCIE_DMA_ONCHIP_WR_FIFO_BASE_HI,
                  regs + ACL_PCIE_DMA_EP_WR_FIFO_BASE_HIGH);
        iowrite32(ACL_PCIE_DMA_TABLE_SIZE - 1, regs + ACL_PCIE_DMA_WR_TABLE_SIZE);
        iowrite32(last, regs + ACL_PCIE_DMA_WR_LAST_PTR);
    } else {
        iowrite32(lower_32_bits(bus), regs + ACL_PCIE_DMA_RC_RD_DESC_BASE_LOW);
        iowrite32(upper_32_bits(bus), regs + ACL_PCIE_DMA_RC_RD_DESC_BASE_HIGH);
        iowrite32(ACL_PCIE_DMA_ONCHIP_RD_FIFO_BASE_LO,
                  regs + ACL_PCIE_DMA_EP_RD_FIFO_BASE_LOW);
        iowrite32(ACL_PCIE_DMA_ONCHIP_RD_FIFO_BASE_HI,
                  regs + ACL_PCIE_DMA_EP_RD_FIFO_BASE_HIGH);
        iowrite32(ACL_PCIE_DMA_TABLE_SIZE - 1, regs + ACL_PCIE_DMA_RD_TABLE_SIZE);
        iowrite32(last, regs + ACL_PCIE_DMA_RD_LAST_PTR);
    }
    return 0;
}

static int build_locked(struct aclpci_dma *d)
{
    struct dma_desc_table *table = d->tables[d->request.device_to_host];

    /* Only before first submission or after the prior table has retired.
     * Clearing a flag is preparation, never an acknowledgement of drain. */
    memset(&table->header, 0, sizeof(table->header));
    return aclpci_dma_request_build(&d->request, table->descriptors);
}

static void dma_work(struct work_struct *work)
{
    struct aclpci_dma *d = container_of(work, struct aclpci_dma, work);
    struct dma_completion done = { 0 };
    int error;

    mutex_lock(&d->lock);
    if (!d->active)
        goto unlock;
    harvest_locked(d);
    if (d->request.phase == ACLPCI_REQUEST_READY) {
        if (!READ_ONCE(d->aclpci->online) ||
            READ_ONCE(d->aclpci->io_blocked) || !READ_ONCE(d->contract_valid)) {
            aclpci_dma_request_stop(&d->request);
        } else {
            error = build_locked(d);
            if (!error)
                error = submit_locked(d);
            if (error && d->request.phase != ACLPCI_REQUEST_IN_FLIGHT) {
                aclpci_dma_request_stop(&d->request);
                d->request.result = error;
            }
        }
    }
    if (d->request.phase == ACLPCI_REQUEST_TERMINAL)
        complete_locked(d, &done);
unlock:
    notify_completion(&done);
    mutex_unlock(&d->lock);
    /* queue_work() may requeue a currently executing work item. An IRQ
     * arriving during this callback therefore causes another rescan. A
     * coalesced IRQ needs no saved request identity: inspect current status.
     * No loop polls a device or waits for a flag to change. */
}

int aclpci_dma_init(struct aclpci_dev *aclpci)
{
    struct aclpci_dma *d = &aclpci->dma_data;
    unsigned int i;

    BUILD_BUG_ON(sizeof(struct dma_desc_header) != 512);
    BUILD_BUG_ON(offsetof(struct dma_desc_table, descriptors) != 512);
    BUILD_BUG_ON(sizeof(struct dma_desc_table) != 4608);
    memset(d, 0, sizeof(*d));
    mutex_init(&d->lock);
    INIT_WORK(&d->work, dma_work);
    d->aclpci = aclpci;
    d->last_id[0] = d->last_id[1] = ACL_PCIE_DMA_RESET_ID;
    d->wq = create_singlethread_workqueue("aclkmdq");
    if (!d->wq)
        return -ENOMEM;
    for (i = 0; i < 2; ++i) {
        d->tables[i] = dma_alloc_coherent(&aclpci->pci_dev->dev,
                                         sizeof(*d->tables[i]),
                                         &d->table_dma[i], GFP_KERNEL);
        if (!d->tables[i])
            goto fail;
        memset(d->tables[i], 0, sizeof(*d->tables[i]));
    }
    d->initialized = true;
    /* contract_valid stays false. A future qualified shell implementation
     * must establish attach, completion and device-removal guarantees. */
    return 0;
fail:
    while (i) {
        --i;
        dma_free_coherent(&aclpci->pci_dev->dev, sizeof(*d->tables[i]),
                          d->tables[i], d->table_dma[i]);
        d->tables[i] = NULL;
    }
    destroy_workqueue(d->wq);
    d->wq = NULL;
    return -ENOMEM;
}

/* Caller has prevented new submissions and masked/synchronized/freed IRQ.
 * Never invoke from this workqueue or while holding d->lock. */
int aclpci_dma_finish(struct aclpci_dev *aclpci)
{
    struct aclpci_dma *d = &aclpci->dma_data;
    unsigned int i;

    if (!d->initialized)
        return 0;
    /* One final rescan covers a status written while IRQs were masked.
     * It does not wait for hardware; missing retirement remains retained. */
    queue_work(d->wq, &d->work);
    flush_workqueue(d->wq);
    mutex_lock(&d->lock);
    if (d->active) {
        mutex_unlock(&d->lock);
        return -EBUSY;
    }
    d->initialized = false;
    mutex_unlock(&d->lock);
    destroy_workqueue(d->wq);
    d->wq = NULL;
    for (i = 0; i < 2; ++i) {
        dma_free_coherent(&aclpci->pci_dev->dev, sizeof(*d->tables[i]),
                          d->tables[i], d->table_dma[i]);
        d->tables[i] = NULL;
    }
    return 0;
}

int aclpci_dma_stop(struct aclpci_dev *aclpci)
{
    struct aclpci_dma *d = &aclpci->dma_data;
    struct dma_completion done = { 0 };
    int result = 0;

    if (!d->initialized)
        return 0;
    mutex_lock(&d->lock);
    if (d->active) {
        aclpci_dma_request_stop(&d->request);
        harvest_locked(d);
        if (d->request.phase == ACLPCI_REQUEST_TERMINAL)
            result = complete_locked(d, &done);
        else
            result = -EINPROGRESS;
    }
    notify_completion(&done);
    mutex_unlock(&d->lock);
    return result;
}

irqreturn_t aclpci_dma_service_interrupt(struct aclpci_dev *aclpci)
{
    struct aclpci_dma *d = &aclpci->dma_data;

    /* init_irq runs after init, finish after free_irq. Queueing while a
     * callback executes is supported; no request or status gets cleared. */
    if (READ_ONCE(d->initialized))
        queue_work(d->wq, &d->work);
    return IRQ_HANDLED;
}

bool aclpci_dma_busy(struct aclpci_dev *aclpci)
{
    struct aclpci_dma *d = &aclpci->dma_data;
    bool busy;

    mutex_lock(&d->lock);
    busy = d->active;
    mutex_unlock(&d->lock);
    return busy;
}

int aclpci_dma_get_idle_status(struct aclpci_dev *aclpci)
{
    struct aclpci_dma *d = &aclpci->dma_data;
    int result;

    mutex_lock(&d->lock);
    result = d->fault ? d->fault : d->active ? 0 :
             d->async_result ? d->async_result : 1;
    mutex_unlock(&d->lock);
    return result;
}

/* Validate every batch before publishing any descriptor: later construction
 * should not be the first place to discover a mapped-address/length error. */
static int preflight(struct aclpci_dma_request *r,
                     struct aclpci_batch_descriptor *table)
{
    struct aclpci_batch_cursor cursor = r->cursor, next;
    unsigned int count, first = r->first_id;
    int error;

    while (cursor.segment < aclpci_user_dma_segments(r->mapping)) {
        error = aclpci_dma_build_batch(r->mapping, &cursor, first,
                                      r->device_to_host, table, &count, &next);
        if (error || !count)
            return error ? error : -EINVAL;
        cursor = next;
        first = (first + count) & 127;
    }
    return 0;
}

ssize_t aclpci_dma_rw(struct aclpci_dev *aclpci, struct aclpci_file *owner,
                     void *dev_addr, void __user *user_addr,
                     ssize_t len, int reading)
{
    struct aclpci_dma *d = &aclpci->dma_data;
    struct aclpci_user_dma *mapping = NULL;
    enum dma_data_direction direction = reading ? DMA_FROM_DEVICE : DMA_TO_DEVICE;
    u64 end;
    u32 last;
    unsigned int first;
    int error;

    if (!owner || len <= 0 || ((unsigned long)user_addr & 3) ||
        ((unsigned long)dev_addr & 3) || (len & 3))
        return -EINVAL;
    if (check_add_overflow((u64)(unsigned long)dev_addr, (u64)len, &end))
        return -EOVERFLOW;
    mutex_lock(&d->lock);
    if (!d->initialized || !READ_ONCE(aclpci->online)) {
        error = -ENODEV;
        goto unlock;
    }
    if (d->active || READ_ONCE(aclpci->io_blocked)) {
        error = -EBUSY;
        goto unlock;
    }
    if (!READ_ONCE(d->contract_valid) || d->fault) {
        error = d->fault ? d->fault : -EOPNOTSUPP;
        goto unlock;
    }
    last = ioread32(dma_regs(aclpci) + (reading ? ACL_PCIE_DMA_WR_LAST_PTR :
                                                ACL_PCIE_DMA_RD_LAST_PTR));
    if (last == ACL_PCIE_DMA_RESET_ID || last == 127)
        first = 0;
    else if (last < 127)
        first = last + 1;
    else {
        error = -EIO;
        goto unlock;
    }
    /* This function runs in the submitting syscall's mm, before deferral. */
    error = aclpci_user_dma_prepare(&aclpci->pci_dev->dev,
                                    (unsigned long)user_addr, len, direction,
                                    &mapping);
    if (error)
        goto unlock;
    error = aclpci_dma_request_init(&d->request, mapping,
                                    (u64)(unsigned long)dev_addr, first, !!reading);
    if (error) {
        aclpci_user_dma_release(mapping, false);
        goto unlock;
    }
    error = preflight(&d->request, d->tables[!!reading]->descriptors);
    if (!error)
        error = build_locked(d);
    if (error)
        goto release_unsubmitted;
    d->owner = owner;
    aclpci_file_get(owner);
    d->task = current;
    get_task_struct(d->task);
    d->signal = aclpci->signal_info_dma;
    error = submit_locked(d);
    if (error) {
        put_task_struct(d->task);
        aclpci_file_put(d->owner);
        d->task = NULL;
        d->owner = NULL;
        goto release_unsubmitted;
    }
    d->async_result = 0;
    mutex_unlock(&d->lock);
    return 0; /* Historical ABI: accepted asynchronous request returns zero. */
release_unsubmitted:
    aclpci_dma_request_stop(&d->request);
    d->request.result = error;
    aclpci_dma_request_release(&d->request);
unlock:
    mutex_unlock(&d->lock);
    return error;
}
