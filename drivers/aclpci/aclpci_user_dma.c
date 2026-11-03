/* SPDX-License-Identifier: BSD-3-Clause */
#include <linux/device.h>
#include <linux/err.h>
#include <linux/limits.h>
#include <linux/mm.h>
#include <linux/overflow.h>
#include <linux/sched.h>
#include <linux/sched/mm.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include "aclpci_user_dma.h"

struct aclpci_user_dma_entry {
    dma_addr_t address;
    size_t length;
};

struct aclpci_user_dma {
    struct device *dev;
    struct mm_struct *mm;
    unsigned long accounted;
    struct page **pages;
    struct aclpci_user_dma_entry *entries;
    unsigned int pinned;
    unsigned int mapped;
    enum dma_data_direction direction;
};

void aclpci_user_dma_release(struct aclpci_user_dma *m, bool written)
{
    unsigned int i;

    if (!m)
        return;
    for (i = 0; i < m->mapped; ++i)
        dma_unmap_page(m->dev, m->entries[i].address,
                       m->entries[i].length, m->direction);
    if (m->pinned)
        unpin_user_pages_dirty_lock(m->pages, m->pinned,
                                   written && m->direction == DMA_FROM_DEVICE);
    if (m->accounted)
        account_locked_vm(m->mm, m->accounted, false);
    if (m->mm)
        mmput(m->mm);
    kvfree(m->entries);
    kvfree(m->pages);
    put_device(m->dev);
    kfree(m);
}

int aclpci_user_dma_prepare(struct device *dev, unsigned long address,
                           size_t length, enum dma_data_direction direction,
                           struct aclpci_user_dma **out)
{
    struct aclpci_user_dma *m;
    unsigned long last, count;
    unsigned int i, flags = FOLL_LONGTERM;
    size_t remaining = length, offset = offset_in_page(address);
    int pinned, error = -ENOMEM;

    if (!out)
        return -EINVAL;
    *out = NULL;
    if (!dev || !current->mm || !length ||
        (direction != DMA_TO_DEVICE && direction != DMA_FROM_DEVICE))
        return -EINVAL;
    if (check_add_overflow(address, (unsigned long)length - 1, &last))
        return -EOVERFLOW;
    count = (last >> PAGE_SHIFT) - (address >> PAGE_SHIFT) + 1;
    /* pin_user_pages_fast accepts an int page count. This is an API range
     * check, not an execution/memory quota. */
    if (count > INT_MAX)
        return -EOVERFLOW;
    if (direction == DMA_FROM_DEVICE)
        flags |= FOLL_WRITE;
    m = kzalloc(sizeof(*m), GFP_KERNEL);
    if (!m)
        return -ENOMEM;
    m->dev = get_device(dev);
    m->direction = direction;
    m->mm = current->mm;
    mmget(m->mm);
    /* Use the submitting task's standard RLIMIT_MEMLOCK/CAP_IPC_LOCK policy.
     * Do not bypass it or invent an additional driver quota. */
    error = account_locked_vm(m->mm, count, true);
    if (error)
        goto fail;
    m->accounted = count;
    m->pages = kvmalloc_array(count, sizeof(*m->pages), GFP_KERNEL);
    m->entries = kvmalloc_array(count, sizeof(*m->entries), GFP_KERNEL);
    if (!m->pages || !m->entries) {
        error = -ENOMEM;
        goto fail;
    }
    pinned = pin_user_pages_fast(address & PAGE_MASK, count, flags, m->pages);
    if (pinned < 0) {
        error = pinned;
        goto fail;
    }
    m->pinned = pinned;
    if ((unsigned long)pinned != count) {
        error = -EFAULT;
        goto fail;
    }
    for (i = 0; i < count; ++i) {
        size_t bytes = min_t(size_t, remaining, PAGE_SIZE - offset);
        dma_addr_t bus;

        if (bytes > dma_max_mapping_size(dev)) {
            error = -E2BIG;
            goto fail;
        }
        bus = dma_map_page(dev, m->pages[i], offset, bytes, direction);
        /* Zero is a valid DMA address. Never substitute page_to_phys(). */
        if (dma_mapping_error(dev, bus)) {
            error = -EIO;
            goto fail;
        }
        m->entries[i].address = bus;
        m->entries[i].length = bytes;
        ++m->mapped;
        remaining -= bytes;
        offset = 0;
    }
    *out = m;
    return 0;
fail:
    /* Nothing was published/doorbelled; device could not have written. */
    aclpci_user_dma_release(m, false);
    return error;
}

unsigned int aclpci_user_dma_segments(const struct aclpci_user_dma *m)
{
    return m ? m->mapped : 0;
}

bool aclpci_user_dma_matches_direction(const struct aclpci_user_dma *m,
                                      bool device_to_host)
{
    return m && m->direction == (device_to_host ? DMA_FROM_DEVICE : DMA_TO_DEVICE);
}

int aclpci_user_dma_segment(const struct aclpci_user_dma *m,
                           unsigned int index, dma_addr_t *address,
                           size_t *length)
{
    if (!m || index >= m->mapped || !address || !length)
        return -EINVAL;
    *address = m->entries[index].address;
    *length = m->entries[index].length;
    return 0;
}
