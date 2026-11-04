/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_SUPERVISOR_COMMAND_H
#define ACLPCI_SUPERVISOR_COMMAND_H
#include "aclpci_round_fence.h"
/* Kernel-owned command within one immutable, exclusively owned image/session.
 * Offsets are relative to the supervisor command window. Reset or mapping
 * changes invalidate the request. Acceptance does not establish DMA drain. */
struct aclpci_supervisor_command {
    u64 id, previous, returned;
    u32 operation, reason;
    unsigned int step;
    int accepted;
    int result; /* 0 pending, 1 accepted, 2 rejected, negative permanent error */
};
int aclpci_supervisor_command_init(struct aclpci_supervisor_command *, u64 id, u32 operation);
/* One I/O per externally triggered step; uncertain operations never replay. */
int aclpci_supervisor_command_step(struct aclpci_supervisor_command *, const struct aclpci_fence_io *);
#endif
