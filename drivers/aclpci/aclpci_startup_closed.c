/* SPDX-License-Identifier: BSD-3-Clause */
#include <linux/errno.h>
#include "aclpci_startup.h"

int aclpci_startup_closed_init(struct aclpci_startup *s, const u32 context[6], u64 id)
{
    int error = aclpci_startup_init(s, context, id);
    if (error) return error;
    error = aclpci_upstream_closure_init(&s->closure, context, 1);
    return s->result = error;
}

int aclpci_startup_closed_step(struct aclpci_startup *s,
    const struct aclpci_fence_io *provision,
    const struct aclpci_fence_io *closure,
    const struct aclpci_fence_io *fence,
    const struct aclpci_fence_io *command)
{
    int result;
    if (!s) return -EINVAL;
    if (s->result) return s->result;
    if (s->phase == 1 && s->closure.result != 1) {
        result = aclpci_upstream_closure_step(&s->closure, closure);
        if (result < 0) s->result = result;
        /* Closure acknowledgment is not START acceptance. At most one I/O. */
        return s->result;
    }
    return aclpci_startup_step(s, provision, fence, command);
}
