/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_DMA_STATUS_V2_H
#define ACLPCI_DMA_STATUS_V2_H
#ifdef __KERNEL__
#include <linux/types.h>
typedef u32 aclpci_status_u32;
#else
#include <stdbool.h>
#include <stdint.h>
typedef uint32_t aclpci_status_u32;
#endif

#define ACLPCI_DMA_STATUS_VERSION_V2 2u
#define ACLPCI_DMA_CAUSE_MASTER 1u
#define ACLPCI_DMA_CAUSE_PAUSE  2u
#define ACLPCI_DMA_CAUSE_ABORT  4u
#define ACLPCI_DMA_CAUSE_FLUSH  8u

enum aclpci_wire_status_v2 {
    ACLPCI_WIRE_INVALID,
    ACLPCI_WIRE_SUCCESS,
    ACLPCI_WIRE_PAUSED,
    ACLPCI_WIRE_ERROR
};
struct aclpci_status_fields_v2 {
    unsigned int id, slot, generation, causes;
    bool local_retired, terminal, error, success;
};

/* This decodes a transport word; no return value grants mapping release. */
static inline enum aclpci_wire_status_v2
aclpci_dma_status_v2_decode(aclpci_status_u32 word,
                          struct aclpci_status_fields_v2 *fields)
{
    struct aclpci_status_fields_v2 value;
    unsigned int flags = (word >> 8) & 15u;
    value.id = word & 255u;
    value.slot = (word >> 12) & 15u;
    value.generation = (word >> 16) & 255u;
    value.causes = (word >> 24) & 15u;
    value.local_retired = (flags & 8u) != 0;
    value.terminal = (flags & 4u) != 0;
    value.error = (flags & 2u) != 0;
    value.success = (flags & 1u) != 0;
    if (fields)
        *fields = value;
    if ((word >> 28) != ACLPCI_DMA_STATUS_VERSION_V2 || !value.generation)
        return ACLPCI_WIRE_INVALID;
    if (!value.causes && flags == 13u)
        return ACLPCI_WIRE_SUCCESS;
    if (value.causes == ACLPCI_DMA_CAUSE_PAUSE && flags == 0u)
        return ACLPCI_WIRE_PAUSED;
    if ((value.causes & (ACLPCI_DMA_CAUSE_MASTER | ACLPCI_DMA_CAUSE_ABORT |
                        ACLPCI_DMA_CAUSE_FLUSH)) && (flags & 7u) == 6u)
        return ACLPCI_WIRE_ERROR;
    return ACLPCI_WIRE_INVALID;
}

static inline bool aclpci_dma_status_v2_same_owner(
    const struct aclpci_status_fields_v2 *a,
    const struct aclpci_status_fields_v2 *b)
{
    return a && b && a->id == b->id && a->slot == b->slot &&
           a->generation != 0 && a->generation == b->generation;
}

enum aclpci_host_status_v2 {
    ACLPCI_HOST_PENDING,
    ACLPCI_HOST_SUCCESS,
    ACLPCI_HOST_RETAIN_ERROR,
    ACLPCI_HOST_RETAIN_NONTERMINAL,
    ACLPCI_HOST_MALFORMED,
    ACLPCI_HOST_UNQUALIFIED
};

/* Header flags are a different format from wire statuses. Only exact 1 under
 * a separately qualified shell is success. dma_rmb() must follow that exact
 * observation before the request owner is retired. Never turn raw v2 success,
 * local_retired, error, reset, abort, or timeout into permission to unpin.
 * Candidate-v2 does not set the production driver's contract_valid to true. */
static inline enum aclpci_host_status_v2
aclpci_dma_host_status_v2(aclpci_status_u32 flag, unsigned int expected_id,
                        bool contract_valid,
                        struct aclpci_status_fields_v2 *fields)
{
    struct aclpci_status_fields_v2 value;
    enum aclpci_wire_status_v2 kind;
    if (expected_id >= 128u)
        return ACLPCI_HOST_MALFORMED;
    if (!flag)
        return ACLPCI_HOST_PENDING;
    if (flag == 1u)
        return contract_valid ? ACLPCI_HOST_SUCCESS : ACLPCI_HOST_UNQUALIFIED;
    kind = aclpci_dma_status_v2_decode(flag, &value);
    if (fields)
        *fields = value;
    if (value.id != expected_id)
        return ACLPCI_HOST_MALFORMED;
    if (kind == ACLPCI_WIRE_ERROR)
        return ACLPCI_HOST_RETAIN_ERROR;
    if (kind == ACLPCI_WIRE_PAUSED)
        return ACLPCI_HOST_RETAIN_NONTERMINAL;
    return ACLPCI_HOST_MALFORMED;
}
#endif
