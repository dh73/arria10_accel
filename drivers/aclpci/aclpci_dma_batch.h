/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_DMA_BATCH_H
#define ACLPCI_DMA_BATCH_H
#include <linux/types.h>
#include "aclpci_user_dma.h"

/* Historical 16.1 descriptor ABI, NOT the currently loaded ASUS image ABI. */
struct aclpci_batch_descriptor { __le32 words[8]; };
struct aclpci_batch_cursor {
    unsigned int segment;
    size_t offset;
    u64 device_address;
};

/* Pure construction: no MMIO, no unmapping, and no mutation of input cursor.
 * Caller owns storage for 128 descriptors. Ignore all output on error.
 * Commit next ONLY with the corresponding submission/retirement bookkeeping.
 * Building a table does not prove any previously submitted table has drained. */
int aclpci_dma_build_batch(const struct aclpci_user_dma *mapping,
                          const struct aclpci_batch_cursor *cursor,
                          unsigned int first_id, bool device_to_host,
                          struct aclpci_batch_descriptor *table,
                          unsigned int *count,
                          struct aclpci_batch_cursor *next);
#endif
