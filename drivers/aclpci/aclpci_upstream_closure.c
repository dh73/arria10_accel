/* SPDX-License-Identifier: BSD-3-Clause */
#include <linux/errno.h>
#include <linux/string.h>
#include "aclpci_upstream_closure.h"
int aclpci_upstream_closure_init(struct aclpci_upstream_closure *c, const u32 context[6], u64 round)
{
    if (!c) return -EINVAL;
    memset(c, 0, sizeof(*c));
    if (!context || !round || !(context[0] | context[1]) ||
        !(context[2] | context[3] | context[4] | context[5]))
        return c->result = -EINVAL;
    memcpy(c->words, context, 6 * sizeof(u32));
    c->words[6] = (u32)round; c->words[7] = (u32)(round >> 32);
    return 0;
}
int aclpci_upstream_closure_step(struct aclpci_upstream_closure *c, const struct aclpci_fence_io *io)
{
    u32 value = 0;
    unsigned int n;
    int error;
    if (!c) return -EINVAL;
    if (c->result) return c->result;
    if (!io || !io->read || !io->write || !io->flush)
        return c->result = -EINVAL;
    n = c->step;
    if (n == 0) error = io->read(io->context, 0, &value);
    else if (n == 1 || n == 20 || n == 29) error = io->read(io->context, 4, &value);
    else if (n >= 2 && n <= 9) error = io->read(io->context, 8 + 4*(n-2), &value);
    else if (n >= 10 && n <= 17) error = io->write(io->context, 8 + 4*(n-10), c->words[n-10]);
    else if (n == 18) error = io->flush(io->context);
    else if (n == 19) error = io->write(io->context, 40, 0xa10b0001);
    else if (n >= 21 && n <= 28) error = io->read(io->context, 8 + 4*(n-21), &value);
    else return c->result = -EINVAL;
    if (error) return c->result = error < 0 ? error : -EIO;
    if ((n == 0 && value != 0xa10b0001) || (n == 1 && value != 8) ||
        ((n == 20 || n == 29) && value != 9)) return c->result = -EIO;
    if ((n >= 2 && n <= 9 && value != c->words[n-2]) ||
        (n >= 21 && n <= 28 && value != c->words[n-21])) return c->result = -ESTALE;
    ++c->step;
    return n == 29 ? (c->result = 1) : 0;
}
