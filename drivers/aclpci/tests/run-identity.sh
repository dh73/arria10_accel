#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
python3 "$repo/tools/kernel_executor_codegen.py" \
    --snapshot "$repo/tests/fixtures/generated-kernel-abi.json" \
    --output "$tmp/generated_kernel_abi_data.inc"
${CC:-cc} -std=c11 -Wall -Wextra -Werror ${CFLAGS:-} \
    -c "$here/../aclpci_identity.c" -o "$tmp/identity.o"
# Keep standalone C++ linking intact, then compare the identical corpus against C.
for cross in standalone cross; do
    define=
    object=
    if [ "$cross" = cross ]; then
        define=-DA10_IDENTITY_CROSS_CHECK
        object="$tmp/identity.o"
    fi
    ${CXX:-c++} -std=c++17 -Wall -Wextra -Werror ${CFLAGS:-} $define \
        -I "$repo/host/include" -I "$tmp" \
        "$repo/host/src/generated_kernel_abi.cpp" \
        "$repo/host/src/shell_identity_v1.cpp" \
        "$repo/host/tests/shell_identity_v1_test.cpp" $object -o "$tmp/$cross"
    "$tmp/$cross"
done
