/* SPDX-License-Identifier: BSD-3-Clause */
#include <linux/errno.h>
#include <linux/string.h>
#include "aclpci_context_provision.h"
int aclpci_context_provision_init(struct aclpci_context_provision *c, const u32 words[6])
{
    if (!c) return -EINVAL;
    memset(c, 0, sizeof(*c));
    if (!words || !(words[0] | words[1]) ||
        !(words[2] | words[3] | words[4] | words[5]))
        return c->result = -EINVAL;
    memcpy(c->words, words, sizeof(c->words));
    return 0;
}
int aclpci_context_provision_step(struct aclpci_context_provision *c,
                                  const struct aclpci_fence_io *io)
{
    int error;
    u32 value = 0;
    unsigned int step;
    if (!c) return -EINVAL;
    if (c->result) return c->result;
    if (!io || !io->read || !io->write || !io->flush)
        return c->result = -EINVAL;
    step = c->step;
    if (step == 0) error = io->read(io->context, 0, &value);
    else if (step == 1 || step == 11 || step == 18)
        error = io->read(io->context, 4, &value);
    else if (step <= 7)
        error = io->write(io->context, 8 + 4 * (step - 2), c->words[step - 2]);
    else if (step == 8 || step == 10) error = io->flush(io->context);
    else if (step == 9) error = io->write(io->context, 0, 0xa10e0001);
    else if (step <= 17) error = io->read(io->context, 8 + 4 * (step - 12), &value);
    else return c->result = -EINVAL;
    if (error) return c->result = error < 0 ? error : -EIO;
    if ((step == 0 && value != 0xa10e0001) ||
        (step == 1 && value != 0) ||
        ((step == 11 || step == 18) && value != 1) ||
        (step >= 12 && step <= 17 && value != c->words[step - 12]))
        return c->result = -EIO;
    ++c->step;
    return step == 18 ? (c->result = 1) : 0;
}
