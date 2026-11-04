/* SPDX-License-Identifier: BSD-3-Clause */
#include <linux/errno.h>
#include <linux/string.h>
#include "aclpci_round_fence.h"
enum { F_READY, F_CONTEXT, F_RECHECK, F_ECHO, F_FLUSH, F_COMMIT, F_CONFIRM };
int aclpci_round_fence_init(struct aclpci_round_fence *f, const u32 context[6], u64 round)
{
    if (!f) return -EINVAL;
    memset(f, 0, sizeof(*f));
    if (!context || !round || !(context[0] | context[1]) ||
        !(context[2] | context[3] | context[4] | context[5]))
        return f->result = -EINVAL;
    memcpy(f->words, context, 6 * sizeof(u32));
    f->words[6] = (u32)round;
    f->words[7] = (u32)(round >> 32);
    return 0;
}
int aclpci_round_fence_step(struct aclpci_round_fence *f, const struct aclpci_fence_io *io)
{
    u32 value = 0;
    int error;
    if (!f) return -EINVAL;
    if (f->result) return f->result;
    if (!io || !io->read || !io->write || !io->flush || f->index >= 8)
        return f->result = -EINVAL;
    switch (f->step) {
    case F_READY: case F_RECHECK: case F_CONFIRM:
        error = io->read(io->context, 0, &value); break;
    case F_CONTEXT:
        error = io->read(io->context, 4 + 4*f->index, &value); break;
    case F_ECHO:
        error = io->write(io->context, 4 + 4*f->index, f->words[f->index]); break;
    case F_FLUSH: error = io->flush(io->context); break;
    case F_COMMIT: error = io->write(io->context, 36, 0xa10f0001); break;
    default: return f->result = -EINVAL;
    }
    if (error) return f->result = error < 0 ? error : -EIO;
    switch (f->step) {
    case F_READY:
        if (!value) break;
        if (value != 1) return f->result = -EIO;
        f->step = F_CONTEXT; break;
    case F_CONTEXT:
        if (value != f->words[f->index]) return f->result = -ESTALE;
        if (++f->index == 8) { f->index = 0; f->step = F_RECHECK; }
        break;
    case F_RECHECK:
        if (value != 1) return f->result = -EIO;
        f->step = F_ECHO; break;
    case F_ECHO:
        if (++f->index == 8) { f->index = 0; f->step = F_FLUSH; }
        break;
    case F_FLUSH: f->step = F_COMMIT; break;
    case F_COMMIT: f->step = F_CONFIRM; break;
    case F_CONFIRM:
        if (value == 3) f->result = 1;
        else if (value != 1) f->result = -EIO;
        break;
    }
    return f->result;
}
