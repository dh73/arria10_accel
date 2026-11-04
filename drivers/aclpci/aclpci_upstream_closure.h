/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_UPSTREAM_CLOSURE_H
#define ACLPCI_UPSTREAM_CLOSURE_H
#include "aclpci_round_fence.h"
/* Requires closed software publication, retained owner and ordered same-function
 * MMIO. Complete before requesting hardware STOP. Success acknowledges producer
 * closure only, not local/host DMA drain or permission to release memory. */
struct aclpci_upstream_closure {
    u32 words[8];
    unsigned int step;
    int result; /* 0 pending, 1 acknowledged, negative permanent failure */
};
int aclpci_upstream_closure_init(struct aclpci_upstream_closure *, const u32 context[6], u64 round);
int aclpci_upstream_closure_step(struct aclpci_upstream_closure *, const struct aclpci_fence_io *);
#endif
