/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_USER_DMA_H
#define ACLPCI_USER_DMA_H

#include <linux/dma-mapping.h>

/* Owns the entire user range across all descriptor batches. Caller serializes
 * access and must not copy this object. Prepare in the submitting user's mm,
 * before any doorbell. Never re-pin from a deferred worker's address space. */
struct aclpci_user_dma;

int aclpci_user_dma_prepare(struct device *dev, unsigned long address,
                           size_t length, enum dma_data_direction direction,
                           struct aclpci_user_dma **out);
int aclpci_user_dma_segment(const struct aclpci_user_dma *mapping,
                           unsigned int index, dma_addr_t *address,
                           size_t *length);
unsigned int aclpci_user_dma_segments(const struct aclpci_user_dma *mapping);
bool aclpci_user_dma_matches_direction(const struct aclpci_user_dma *mapping,
                                      bool device_to_host);

/* ONLY before first submission or after hardware retirement is proven by the
 * caller. Clearing bus mastering, software cancellation, and IRQ silence are
 * not retirement evidence. Unknown retirement retains this object and device
 * DMA context. device_may_have_written is conservative across every batch. */
void aclpci_user_dma_release(struct aclpci_user_dma *mapping,
                            bool device_may_have_written);
#endif
