/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_DMA_BATCH_H
#define ACLPCI_DMA_BATCH_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
typedef uint64_t u64;
struct aclpci_user_dma { unsigned int segments; bool direction; unsigned int releases; };
struct aclpci_batch_cursor { u64 device_address; unsigned int segment; };
struct aclpci_batch_descriptor { unsigned int unused; };
unsigned int aclpci_user_dma_segments(struct aclpci_user_dma *mapping);
bool aclpci_user_dma_matches_direction(struct aclpci_user_dma *mapping, bool direction);
void aclpci_user_dma_release(struct aclpci_user_dma *mapping, bool written);
int aclpci_dma_build_batch(struct aclpci_user_dma *mapping,
    const struct aclpci_batch_cursor *cursor, unsigned int first_id,
    bool direction, struct aclpci_batch_descriptor *table,
    unsigned int *count, struct aclpci_batch_cursor *pending);
#endif
