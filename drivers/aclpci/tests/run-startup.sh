#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/linux"
printf '#include <stdint.h>\ntypedef uint32_t u32;\ntypedef uint64_t u64;\n' > "$tmp/linux/types.h"
printf '#define EINVAL 22\n#define EIO 5\n#define ESTALE 116\n' > "$tmp/linux/errno.h"
printf '#include <string.h>\n' > "$tmp/linux/string.h"
${CC:-cc} -std=c11 -Wall -Wextra -Werror ${CFLAGS:-} -I "$tmp" \
    "$here/startup.c" "$here/../aclpci_startup.c" \
    "$here/../aclpci_context_provision.c" "$here/../aclpci_round_fence.c" \
    "$here/../aclpci_supervisor_command.c" -o "$tmp/test"
"$tmp/test"
