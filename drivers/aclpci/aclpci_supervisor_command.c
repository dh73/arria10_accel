/* SPDX-License-Identifier: BSD-3-Clause */
#include <linux/errno.h>
#include <linux/string.h>
#include "aclpci_supervisor_command.h"
enum { C_READY, C_PREV_LO, C_PREV_HI, C_ID_LO, C_ID_HI, C_OP, C_FLUSH,
       C_COMMIT, C_STATUS, C_RESULT_LO, C_RESULT_HI, C_REASON };
int aclpci_supervisor_command_init(struct aclpci_supervisor_command *c, u64 id, u32 op)
{
    if (!c) return -EINVAL;
    memset(c, 0, sizeof(*c));
    if (!id || op > 2) return c->result = -EINVAL;
    c->id = id; c->operation = op;
    return 0;
}
int aclpci_supervisor_command_step(struct aclpci_supervisor_command *c,
                                   const struct aclpci_fence_io *io)
{
    u32 v = 0;
    int error;
    if (!c) return -EINVAL;
    if (c->result) return c->result;
    if (!io || !io->read || !io->write || !io->flush)
        return c->result = -EINVAL;
    switch (c->step) {
    case C_READY: case C_STATUS: error = io->read(io->context, 16, &v); break;
    case C_PREV_LO: case C_RESULT_LO: error = io->read(io->context, 24, &v); break;
    case C_PREV_HI: case C_RESULT_HI: error = io->read(io->context, 28, &v); break;
    case C_ID_LO: error = io->write(io->context, 0, (u32)c->id); break;
    case C_ID_HI: error = io->write(io->context, 4, (u32)(c->id >> 32)); break;
    case C_OP: error = io->write(io->context, 8, c->operation); break;
    case C_FLUSH: error = io->flush(io->context); break;
    case C_COMMIT: error = io->write(io->context, 12, 0xa10c0001); break;
    case C_REASON: error = io->read(io->context, 20, &v); break;
    default: return c->result = -EINVAL;
    }
    if (error) return c->result = error < 0 ? error : -EIO;
    switch (c->step) {
    case C_READY:
        if (v == 1) return 0;
        if (v != 0 && v != 2 && v != 6) return c->result = -EIO;
        break;
    case C_PREV_LO: c->previous = v; break;
    case C_PREV_HI:
        c->previous |= (u64)v << 32;
        if (c->id <= c->previous) return c->result = -ESTALE;
        break;
    case C_STATUS:
        if (v == 1) return 0;
        if (v != 2 && v != 6) return c->result = -EIO;
        c->accepted = v == 6; break;
    case C_RESULT_LO: c->returned = v; break;
    case C_RESULT_HI:
        c->returned |= (u64)v << 32;
        if (c->returned != c->id) return c->result = -ESTALE;
        break;
    case C_REASON:
        if (v > 7 || c->accepted != (v == 0)) return c->result = -EIO;
        c->reason = v;
        return c->result = c->accepted ? 1 : 2;
    default: break;
    }
    ++c->step;
    return 0;
}
