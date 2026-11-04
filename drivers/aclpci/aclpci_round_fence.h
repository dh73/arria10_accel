/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_ROUND_FENCE_H
#define ACLPCI_ROUND_FENCE_H
#include <linux/types.h>
/* Kernel-owned immutable image/session context. Caller serializes service and
 * uses ordered, same-function, non-relaxed MMIO. No userspace certificates.
 * This protocol alone neither contains reset/removal nor releases DMA memory. */
struct aclpci_fence_io {
    void *context;
    int (*read)(void *, unsigned int offset, u32 *value);
    int (*write)(void *, unsigned int offset, u32 value);
    int (*flush)(void *);
};
struct aclpci_round_fence {
    u32 words[8];
    unsigned int step, index;
    int result; /* 0 pending, 1 settled, negative = permanently failed */
};
int aclpci_round_fence_init(struct aclpci_round_fence *, const u32 context[6], u64 round);
/* At most one I/O per external service event. Any failed/uncertain operation
 * permanently ends this attempt; caller retains all outstanding ownership. */
int aclpci_round_fence_step(struct aclpci_round_fence *, const struct aclpci_fence_io *);
#endif
