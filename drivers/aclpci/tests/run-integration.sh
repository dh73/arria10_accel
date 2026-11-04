#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/linux/sched" "$tmp/asm"
for header in device err limits mm overflow sched slab vmalloc dma-mapping errno kernel string types workqueue mutex spinlock atomic completion wait kref; do
    printf '#include "aclpci_dma_test_kernel.h"\n' > "$tmp/linux/$header.h"
done
printf '#include "aclpci_dma_test_kernel.h"\n' > "$tmp/linux/sched/mm.h"
printf '#include "aclpci_dma_test_kernel.h"\n' > "$tmp/asm/byteorder.h"
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -O1 -g \
    ${CFLAGS:-} -I "$here" -I "$tmp" -DACLPCI_DMA_TEST -DACLPCI_FILEIO_TEST \
    "$here/integration.c" -o "$tmp/integration"
"$tmp/integration"
mkdir -p "$tmp/lifecycle-headers/linux"
printf '#include <stdint.h>\ntypedef uint32_t u32;\ntypedef uint64_t u64;\n' > "$tmp/lifecycle-headers/linux/types.h"
printf '#include <asm-generic/errno.h>\n' > "$tmp/lifecycle-headers/linux/errno.h"
printf '#include <string.h>\n' > "$tmp/lifecycle-headers/linux/string.h"
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -O1 -g \
    ${CFLAGS:-} -I "$here" -I "$tmp/lifecycle-headers" "$here/lifecycle.c" \
    "$here/../aclpci_startup.c" "$here/../aclpci_context_provision.c" \
    "$here/../aclpci_round_fence.c" "$here/../aclpci_supervisor_command.c" -o "$tmp/lifecycle"
"$tmp/lifecycle"
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -O1 -g \
    ${CFLAGS:-} -I "$here" -I "$tmp" "$here/context_provision.c" -o "$tmp/context_provision"
"$tmp/context_provision"
