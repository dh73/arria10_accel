/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_CONTEXT_PROVISION_H
#define ACLPCI_CONTEXT_PROVISION_H
#include "aclpci_round_fence.h"
/* Caller owns a qualified image/mapping and coordinated reset lifetime.
 * Relative offsets address the 32-byte context window. Success binds identity;
 * it does not grant DMA admission or prove host ownership/reset containment. */
struct aclpci_context_provision {
    u32 words[6];
    unsigned int step;
    int result; /* 0 pending, 1 verified, negative permanent failure */
};
int aclpci_context_provision_init(struct aclpci_context_provision *, const u32 words[6]);
int aclpci_context_provision_step(struct aclpci_context_provision *, const struct aclpci_fence_io *);
#endif
