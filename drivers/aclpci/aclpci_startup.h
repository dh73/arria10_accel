/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef ACLPCI_STARTUP_H
#define ACLPCI_STARTUP_H
#include "aclpci_context_provision.h"
#include "aclpci_upstream_closure.h"
#include "aclpci_supervisor_command.h"
/* First START in an exclusively owned, qualified coordinated-reset lifetime.
 * Caller supplies ordered window-relative MMIO and retains custody on failure.
 * This sequencer neither qualifies an image nor grants DMA admission.
 * Serialize every step with removal/reset and control-owner changes. */
struct aclpci_startup {
    struct aclpci_context_provision provision;
    /* Owned transport services this after provisioning and before fence. */
    struct aclpci_upstream_closure closure;
    struct aclpci_round_fence fence;
    struct aclpci_supervisor_command command;
    unsigned int phase;
    int result; /* 0 pending, 1 accepted, 2 rejected, negative permanent error */
};
int aclpci_startup_init(struct aclpci_startup *, const u32 context[6], u64 id);
/* Revoke on reset, removal, mapping or custody loss, under the same caller
 * serialization as step. Even a previously accepted START becomes unusable.
 * Does not undo writes or release custody. Reinitialization requires a newly
 * qualified coordinated-reset lifetime, never just an observed idle device. */
int aclpci_startup_revoke(struct aclpci_startup *);
/* At most one I/O per service event. Terminal outcomes never replay I/O. */
int aclpci_startup_step(struct aclpci_startup *,
                       const struct aclpci_fence_io *provision,
                       const struct aclpci_fence_io *fence,
                       const struct aclpci_fence_io *command);
/* Production ordering: provision, upstream closure, drain fence, START.
 * Caller closes publication and serializes lifetime across all service events.
 * Use closed_init with closed_step; the three-window primitive above retains
 * its historical test interface and does not itself acknowledge closure. */
int aclpci_startup_closed_init(struct aclpci_startup *, const u32 context[6], u64 id);
int aclpci_startup_closed_step(struct aclpci_startup *,
    const struct aclpci_fence_io *provision,
    const struct aclpci_fence_io *closure,
    const struct aclpci_fence_io *fence,
    const struct aclpci_fence_io *command);
#endif
