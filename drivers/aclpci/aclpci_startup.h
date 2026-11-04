/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_STARTUP_H
#define ACLPCI_STARTUP_H
#include "aclpci_context_provision.h"
#include "aclpci_supervisor_command.h"
/* First START in an exclusively owned, qualified coordinated-reset lifetime.
 * Caller supplies ordered window-relative MMIO and retains custody on failure.
 * This sequencer neither qualifies an image nor grants DMA admission.
 * Serialize every step with removal/reset and control-owner changes. */
struct aclpci_startup {
    struct aclpci_context_provision provision;
    struct aclpci_round_fence fence;
    struct aclpci_supervisor_command command;
    unsigned int phase;
    int result; /* 0 pending, 1 accepted, 2 rejected, negative permanent error */
};
int aclpci_startup_init(struct aclpci_startup *, const u32 context[6], u64 id);
/* At most one I/O per service event. Terminal outcomes never replay I/O. */
int aclpci_startup_step(struct aclpci_startup *,
                       const struct aclpci_fence_io *provision,
                       const struct aclpci_fence_io *fence,
                       const struct aclpci_fence_io *command);
#endif
