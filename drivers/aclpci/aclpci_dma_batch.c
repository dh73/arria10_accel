/* SPDX-License-Identifier: BSD-3-Clause */
#include <linux/errno.h>
#include <linux/kernel.h>
#include <linux/overflow.h>
#include <linux/string.h>
#include <asm/byteorder.h>
#include "aclpci_dma_batch.h"

int aclpci_dma_build_batch(const struct aclpci_user_dma *mapping,
                          const struct aclpci_batch_cursor *cursor,
                          unsigned int first_id, bool device_to_host,
                          struct aclpci_batch_descriptor *table,
                          unsigned int *count,
                          struct aclpci_batch_cursor *next)
{
    struct aclpci_batch_cursor work;
    unsigned int used = 0, segments;

    BUILD_BUG_ON(sizeof(struct aclpci_batch_descriptor) != 32);
    if (!count)
        return -EINVAL;
    *count = 0;
    if (!mapping || !cursor || !table || !next || first_id >= 128 ||
        !aclpci_user_dma_matches_direction(mapping, device_to_host))
        return -EINVAL;
    work = *cursor;
    segments = aclpci_user_dma_segments(mapping);
    if (!segments || work.segment > segments || (work.device_address & 3))
        return -EINVAL;
    if (work.segment == segments && work.offset)
        return -EINVAL;
    while (work.segment < segments && used < 128 - first_id) {
        dma_addr_t mapped;
        size_t length, available, bytes;
        u64 host, source, destination, end;
        int error = aclpci_user_dma_segment(mapping, work.segment, &mapped, &length);

        if (error)
            return error;
        if (work.offset >= length || (work.offset & 3) || (length & 3))
            return -EINVAL;
        if (check_add_overflow((u64)mapped, (u64)work.offset, &host))
            return -EOVERFLOW;
        if (host & 3)
            return -EINVAL;
        available = length - work.offset;
        /* Preserve the historical page/partial-page transfer sizes: 4096
         * for aligned full pages, otherwise powers of two from 2048 to 4.
         * No descriptor crosses a mapped segment or host 4KiB boundary. */
        available = min_t(size_t, available, 4096 - (host & 4095));
        bytes = (available >= 4096 && !(host & 4095)) ? 4096 : 2048;
        while (bytes > available)
            bytes >>= 1;
        if (bytes < 4)
            return -EINVAL;
        if (check_add_overflow(host, (u64)bytes - 1, &end) ||
            check_add_overflow(work.device_address, (u64)bytes, &end))
            return -EOVERFLOW;
        source = device_to_host ? work.device_address : host;
        destination = device_to_host ? host : work.device_address;
        memset(&table[used], 0, sizeof(table[used]));
        table[used].words[0] = cpu_to_le32((u32)source);
        table[used].words[1] = cpu_to_le32((u32)(source >> 32));
        table[used].words[2] = cpu_to_le32((u32)destination);
        table[used].words[3] = cpu_to_le32((u32)(destination >> 32));
        table[used].words[4] = cpu_to_le32((u32)(bytes / 4) |
                                         ((first_id + used) << 18));
        work.device_address = end;
        work.offset += bytes;
        if (work.offset == length) {
            ++work.segment;
            work.offset = 0;
        }
        ++used;
    }
    *next = work;
    *count = used;
    return 0;
}
