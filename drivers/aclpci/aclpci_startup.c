/* SPDX-License-Identifier: BSD-3-Clause */
#include <linux/errno.h>
#include <linux/string.h>
#include "aclpci_startup.h"
int aclpci_startup_revoke(struct aclpci_startup *s)
{
    if (!s) return -EINVAL;
    /* Retain an earlier failure for diagnosis; success is not a lifetime pin. */
    if (s->result >= 0) s->result = -ESTALE;
    return s->result;
}
int aclpci_startup_init(struct aclpci_startup *s, const u32 context[6], u64 id)
{
    int error;
    if (!s) return -EINVAL;
    memset(s, 0, sizeof(*s));
    error = aclpci_context_provision_init(&s->provision, context);
    if (!error) error = aclpci_round_fence_init(&s->fence, context, 1);
    if (!error) error = aclpci_supervisor_command_init(&s->command, id, 0);
    return s->result = error;
}
int aclpci_startup_step(struct aclpci_startup *s,
                       const struct aclpci_fence_io *provision,
                       const struct aclpci_fence_io *fence,
                       const struct aclpci_fence_io *command)
{
    int result;
    if (!s) return -EINVAL;
    if (s->result) return s->result;
    switch (s->phase) {
    case 0: result = aclpci_context_provision_step(&s->provision, provision); break;
    case 1: result = aclpci_round_fence_step(&s->fence, fence); break;
    case 2: return s->result = aclpci_supervisor_command_step(&s->command, command);
    default: return s->result = -EINVAL;
    }
    if (result < 0) s->result = result;
    else if (result == 1) ++s->phase;
    return s->result;
}
